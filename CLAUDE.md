# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

claude-yolo — a safe way to let Claude develop and deploy in AWS and GCP. A sandboxed devcontainer for running Claude Code with `bypassPermissions` safely enabled, with AWS/GCP/SSH credentials written to a host-side directory that is bind-mounted read-only into the container, so security teams can deploy this for their users without handing Claude unrestricted cloud access. The repo ships as a template: users clone it to `~/.claude-yolo/` and the `devc` CLI installs the template into target project directories. Built on Trail of Bits' devcontainer foundations; diverged significantly toward cloud deployment use cases.

## Key Files

| File | Purpose |
|------|---------|
| `install.sh` | The `devc` CLI — all container lifecycle commands live here |
| `Dockerfile` | Container image (Ubuntu 24.04, Node 22, Python 3.13, Claude Code) |
| `devcontainer.json` | VS Code devcontainer spec, volume mounts, env vars |
| `post_install.py` | Runs on container creation: auth bypass, settings, commands, statusline, tmux, git |
| `.zshrc` | Zsh config copied into the container |
| `statusline.sh` | Two-line Claude Code status bar (model, folder, branch, context %, cost, time) |
| `commands/` | Slash commands installed to `~/.claude/commands/` on first run |
| `aws-config/config` | AWS CLI config copied into the container |
| `aws_creds.py` | `devc aws-creds` — writes one profile's resolved credentials to `Claude-Yolo-Creds/aws/` |
| `refresh-sso-creds.py` | `devc refresh-aws-creds` — refreshes every `[<accountId>_<RoleName>]` section in `Claude-Yolo-Creds/aws/credentials` from IAM Identity Center (SSO) sessions |

GCP has no dedicated script file — `cmd_gcp_create_service_account` and `cmd_gcp_creds` in `install.sh` shell out to `gcloud` directly, since (unlike AWS) there's no SSO-cache-parsing complexity to warrant a helper.

## Building and Testing

Build the container image manually:
```bash
devcontainer build --workspace-folder .
```

Test the full container lifecycle:
```bash
devcontainer up --workspace-folder .
devcontainer exec --workspace-folder . zsh
```

Lint the shell script:
```bash
shellcheck install.sh
shfmt -d install.sh
```

There are no automated tests. The post_install.py script runs inside the container via `postCreateCommand`.

## Architecture

**Template distribution model:** `install.sh` is both the `devc` CLI and the source of truth for template files. When a user runs `devc .`, it copies `Dockerfile`, `devcontainer.json`, `post_install.py`, `.zshrc`, and `aws-config/` into the target project's `.devcontainer/` directory.

**Volume strategy:** Three named Docker volumes survive `devc rebuild` — shell history (`/commandhistory`), Claude config (`~/.claude`), and GitHub CLI auth (`~/.config/gh`). The host's `~/.gitconfig` is bind-mounted read-only. The `.devcontainer/` dir is mounted read-only inside the container to prevent a compromised process from injecting mounts that execute on the host during rebuild. `SYS_ADMIN` is explicitly blocked for this reason.

**Cloud credentials never include the user's own identity:** `Claude-Yolo-Creds/{aws,ssh,gcp}` are bind-mounted read-only into the container (`~/.aws`, `~/.ssh`, `~/.gcp`). For GCP specifically, the container is never handed the host's own `gcloud` credentials or an ADC file — `devc gcp-creds` mints a short-lived access token by impersonating a per-workspace service account and writes only that token to `Claude-Yolo-Creds/gcp/access_token`, read via `CLOUDSDK_AUTH_ACCESS_TOKEN_FILE` (set in `devcontainer.json`). This avoids `gcloud auth application-default login --impersonate-service-account`, whose output file embeds the user's own OAuth refresh token in cleartext next to the impersonation pointer — bind-mounting that would hand the container the user's full identity, not just the scoped service account.

**Auth flow:** When `CLAUDE_CODE_OAUTH_TOKEN` is set in the host environment, `post_install.py` runs `claude -p ok` with a 30s timeout to seed `~/.claude.json`, then sets `hasCompletedOnboarding: true`. This works around anthropics/claude-code#8938. The token is forwarded from host env via `remoteEnv` in `devcontainer.json`.

**Git identity:** Because `~/.gitconfig` is mounted read-only, `post_install.py` creates `~/.gitconfig.local` that `[include]`s the host config and adds container-specific settings (delta pager, global gitignore). `GIT_CONFIG_GLOBAL` env var points git to the local config.

**bypassPermissions:** `post_install.py` writes `settings.json` with `permissions.defaultMode = "bypassPermissions"` on every container creation. The container is the sandbox. Explicit `deny` rules (destructive Bash commands, credential reads) still apply even in bypassPermissions mode.

**Hooks:** Two `PreToolUse` hooks block `rm -rf` (suggesting `trash` instead) and direct `git push` to `main`/`master`. Set via `post_install.py` on first container creation.

**Statusline:** `statusline.sh` provides a two-line status bar showing model, folder, git branch, context usage %, cost, and elapsed time. Installed to `~/.claude/statusline.sh` on first run.

**Commands:** `commands/` is bind-mounted from `.devcontainer/commands/` on the host directly to `~/.claude/commands/` in the container. Updates to command files on the host are immediately reflected without a rebuild. Includes `review-pr`, `fix-issue`, and `merge-dependabot` workflows.

## Renovate Versioning Convention

Dockerfile ARG versions that should be auto-updated must use this comment format immediately above the ARG:

```dockerfile
# renovate: datasource=github-releases depName=owner/repo
ARG TOOL_VERSION=1.2.3
```

Renovate runs weekly (Monday before 9am) and groups all updates into a single PR with a 7-day minimum release age.

## devc Command Map

The `main()` dispatcher in `install.sh` routes subcommands to `cmd_*` functions. `devc claude` runs `claude --dangerously-skip-permissions --remote-control` in the container. `devc sync` copies `.jsonl` session files from container volumes to `~/.claude/projects/` on the host using `docker cp` (works on stopped containers too). `devc gcp-create-service-account` (re-run any time to add projects/roles) and `devc gcp-creds` (re-run to refresh, ~hourly) are the GCP analogs of `devc aws-creds`/`devc refresh-aws-creds`. Both call `ensure_gcloud_login`, which checks `gcloud auth print-access-token` (not just the `[core/account]` property, which can be set without valid credentials) and runs `gcloud auth login` if needed. A workspace has exactly one service account; `gcp-create-service-account` merges each run's `--projects`/`--role` into `Claude-Yolo-Creds/gcp/manifest.json`'s `projects` map (`{project: [roles...]}`) rather than overwriting it, so earlier grants are never lost from the record.
