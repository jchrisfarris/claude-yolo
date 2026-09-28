# claude-yolo

**A safe way to let Claude develop and deploy in AWS (and soon GCP).**

Security teams and platform engineers can hand developers a fully autonomous Claude Code environment — with real guardrails — instead of choosing between "hobbled AI" and "blast radius: everything."

> Built on [Trail of Bits' claude-code-devcontainer](https://github.com/trailofbits/claude-code-devcontainer), which provided the sandboxing foundations. This project has diverged significantly toward a different purpose: enabling real cloud deployments with scoped IAM permissions, rather than sandboxed code review.

## The Problem

Running Claude in `--dangerously-skip-permissions` mode is productive. It's also terrifying on a host machine with developer credentials. Most security-conscious teams respond by disabling autonomy, which defeats the purpose.

claude-yolo solves this with two independent constraint layers that security teams control:

**1. Filesystem isolation** — Claude runs in a Docker devcontainer. It cannot touch host files, install system packages, or affect other projects. The container is the blast radius.

**2. AWS permission scoping** — Claude starts with read-only AWS access. When it needs more, it edits a session policy file and asks the user to re-run one command. The security team defines what's in the starting policy; the user decides what Claude earns from there. No one hands Claude the keys.

Together these let developers work autonomously on real infrastructure tasks — including `terraform apply` and live AWS deployments — while security teams retain meaningful oversight without becoming a bottleneck.

## For Security Teams

claude-yolo is designed to be deployed as a standard, organization-approved way to run Claude Code. What you control:

- **The AWS profile** — you decide which credentials `devc aws-creds` writes into the workspace
- **The default session policy** — you define the starting permissions (default: read-only)
- **The container image** — all Claude Code runs from the same hardened environment
- **Network and filesystem constraints** — inherited from the devcontainer spec

What users control:
- What repos they clone and work on inside the container
- Whether to approve Claude's permission escalation requests (by re-running `devc aws-creds`)

## Prerequisites

- **Docker runtime** (one of):
  - [Docker Desktop](https://docker.com/products/docker-desktop)

- **For terminal workflows** (one-time install):

  ```bash
  npm install -g @devcontainers/cli
  git clone https://github.com/securosis/claude-yolo ~/.claude-yolo
  ~/.claude-yolo/install.sh self-install
  ```

- **For AWS credential injection:** `uv` must be installed on the host (`brew install uv`)

## Quick Start

### Setup your workspace

A parent directory holds the devcontainer config; clone multiple repos inside. Best for multiple repos or files that don't belong in git.

```bash
mkdir -p ~/Development/my-project && cd ~/Development/my-project
devc .
devc shell

# On your machine
git clone <repo-1>
git clone <repo-2>

devc claude
```

## Token-Based Auth (Headless)

To skip the interactive login wizard:

```bash
claude setup-token                        # run on host, one-time
export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...
devc rebuild                              # rebuilds with token injected
```

The token is forwarded into the container. On each container creation, `post_install.py` runs a one-shot auth handshake so `claude` starts without the login wizard.

This works around Claude Code's interactive onboarding wizard always showing in containers, even with valid credentials ([#8938](https://github.com/anthropics/claude-code/issues/8938)).

If you don't set a token, the interactive login flow works as before.

**Note:** Anthropic requires you to do the OIDC (not token login) to use the `/remote-control` functionality.

## AWS Credentials

`devc aws-creds` writes credentials from your host AWS profile into `Claude-Yolo-Creds/aws/`, which is bind-mounted read-only into the container at `~/.aws/`. Claude can use them but cannot modify them.

```bash
devc aws-creds --profile my-profile
```

This resolves credentials from the named profile (SSO, assumed role, or IAM user), writes `credentials` and `config` files into `Claude-Yolo-Creds/aws/`, and prints the account identity so you can confirm you're targeting the right account.

Re-run any time to refresh — credentials are never auto-refreshed inside the container.

### SSO profiles

```bash
aws sso login --profile my-profile   # if token has expired
devc aws-creds --profile my-profile
```

### Multiple AWS accounts

Each `devc aws-creds` call overwrites the credential files. To work with multiple accounts simultaneously, use separate workspace directories with separate `Claude-Yolo-Creds/` trees.

### IAM user profiles

`devc aws-creds` will warn if the profile uses long-lived IAM credentials (no session token). They work, but an IAM role or SSO profile is preferred.

### Refreshing multiple SSO profiles at once

If `Claude-Yolo-Creds/aws/credentials` has `[<accountId>_<RoleName>]` sections (for example, hand-populated to give Claude several accounts/roles at once), `devc refresh-aws-creds` refreshes all of them from your IAM Identity Center (SSO) sessions in one pass, instead of running `devc aws-creds` per profile:

```bash
devc refresh-aws-creds              # refresh every [<accountId>_<RoleName>] section
devc refresh-aws-creds --dry-run    # show which SSO session each section maps to; changes nothing
```

For each section, it matches the account/role to a `[profile ...]` in `~/.aws/config` to find the right SSO session, uses the cached SSO token (running `aws sso login` if it's missing or expired), and rewrites just that section's keys. If no matching profile exists, pass `--sso-session NAME` (or `--start-url URL --sso-region REGION`) to name the SSO session to use for unmapped accounts.

## CLI Reference

```
devc .              Install devcontainer template + start container
devc up             Start the devcontainer
devc down           Stop the container
devc rebuild        Rebuild container (preserves persistent volumes)
devc destroy [-f]   Remove container, volumes, and image
devc list [-a]      List running devcontainers (-a includes stopped)
devc shell          Open zsh shell in container
devc exec CMD       Execute command inside the container
devc upgrade        Upgrade Claude Code in the container
devc mount SRC DST  Add a bind mount (host → container)
devc sync [NAME]    Sync Claude Code sessions to host (for /insights)
devc cp CONT HOST   Copy files from container to host
devc aws-creds      Write AWS credentials to Claude-Yolo-Creds/aws/
devc refresh-aws-creds  Refresh SSO-backed profiles in Claude-Yolo-Creds/aws/credentials
devc self-install   Install devc to ~/.local/bin
devc update         Update devc to latest version
devc claude         Run claude --dangerously-skip-permissions in container
```

> Use `devc destroy` to clean up Docker resources. Removing containers manually (e.g. `docker rm`) leaves orphaned volumes that `devc destroy` won't find.

## Updating

There are three separate steps to getting updates, and they must happen in order:

```
devc update       → pulls new commits into the devc source repo (~/.claude-yolo/)
devc template     → copies updated Dockerfile, devcontainer.json, etc. into your project's .devcontainer/
devc rebuild      → builds a new image from .devcontainer/ and starts a fresh container
```

**Why three steps?**

- `devc update` only refreshes the source repo on disk — it does a `git pull` and nothing else. Your running container is untouched.
- `devc template` copies template files (Dockerfile, devcontainer.json, post_install.py, scripts) from the source repo into a specific project's `.devcontainer/` directory. Without this step, your project still has the old Dockerfile.
- `devc rebuild` rebuilds the Docker image from whatever is currently in `.devcontainer/`. It only knows what's there — not what's in the source repo.

If you skip `devc template`, `devc rebuild` will use the old template files and nothing will change in the container. Running `devc update` alone changes nothing about any running container.

## Session Sync for `/insights`

Claude Code's `/insights` reads from `~/.claude/projects/` on the host. Sessions inside devcontainer volumes are invisible to it. `devc sync` copies them:

```bash
devc sync              # Sync all devcontainers
devc sync my-project   # Filter by name (substring match)
```

Devcontainers are auto-discovered via Docker labels — no need to know container names or IDs. The sync is incremental, so it's safe to run repeatedly.

## File Sharing

### VS Code / Cursor

Drag files from your host into the VS Code Explorer panel — they are copied into `/workspace/` automatically. No configuration needed.

### Terminal: `devc mount`

To make a host directory available inside the container:

```bash
devc mount ~/drop /drop           # Read-write
devc mount ~/secrets /secrets --readonly
```

This adds a bind mount to `devcontainer.json` and recreates the container. Existing mounts are preserved across `devc template` updates.

> Avoid mounting large host directories. Every mounted path is writable from inside the container unless `--readonly` is specified.

## Container Details

| Component | Details |
|-----------|---------|
| Base | Ubuntu 24.04, Node.js 22, Python 3.13 + uv, zsh |
| User | `vscode` (passwordless sudo), working dir `/workspace` |
| Tools | `rg`, `fd`, `ast-grep`, `tmux`, `fzf`, `delta`, `iptables`, `terraform`, AWS CLI |
| Persistent volumes | Shell history (`/commandhistory`), Claude config (`~/.claude`), GitHub CLI auth (`~/.config/gh`) |
| Host mounts | `~/.gitconfig` (read-only), `.devcontainer/` (read-only) |
| AWS credentials | Not persisted — lost on `devc rebuild` (intentional) |

## Troubleshooting

**`devcontainer CLI not found`**
```bash
npm install -g @devcontainers/cli
```

**`uv: command not found` when running `devc aws-creds`**
```bash
brew install uv
```

**SSO credentials expired**
```bash
aws sso login --profile my-profile
devc aws-creds --profile my-profile
```

**Container won't start**
1. Check Docker is running
2. `devc rebuild`
3. `docker logs $(docker ps -lq)`

**GitHub CLI auth not persisting**
```bash
sudo chown -R $(id -u):$(id -g) ~/.config/gh
```

## License

[MIT](LICENSE) — Securosis. Built on foundations from [Trail of Bits](https://github.com/trailofbits/claude-code-devcontainer).
