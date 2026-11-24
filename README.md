# claude-yolo

**A safe way to let Claude develop and deploy in AWS (and soon GCP).**

Security teams and platform engineers can hand developers a fully autonomous Claude Code environment — with real guardrails — instead of choosing between "hobbled AI" and "blast radius: everything."

> Built on [Trail of Bits' claude-code-devcontainer](https://github.com/trailofbits/claude-code-devcontainer), which provided the sandboxing foundations. This project has diverged significantly toward a different purpose: enabling real cloud deployments with scoped IAM permissions, rather than sandboxed code review.

## The Problem

Running Claude in `--dangerously-skip-permissions` mode is productive. It's also terrifying on a host machine with developer credentials. Most security-conscious teams respond by disabling autonomy, which defeats the purpose.

claude-yolo solves this with two independent constraint layers that security teams control:

**1. Filesystem isolation** — Claude runs in a Docker devcontainer. It cannot touch host files, install system packages, or affect other projects. The container is the blast radius.

**2. AWS permission scoping** — Claude's AWS credentials are the user's own, scoped down with `sts:GetScopedCredentials` so that irreversible actions are off the table by default. When Claude needs more, it writes a suggested policy and asks the user to run one command. The security team defines the starting policy; the user decides what Claude earns from there. No one hands Claude the keys.

Together these let developers work autonomously on real infrastructure tasks — including `terraform apply` and live AWS deployments — while security teams retain meaningful oversight without becoming a bottleneck.

## Design Principles

### The Three Laws of Agentic AI Identity

These laws apply to the system the agent runs in. They do not apply to the agent itself.

1. **Law One:** The system must not grant the agent more permissions than its user holds.
2. **Law Two:** The system must give the user the ability to restrict the agent's permissions below their own.
3. **Law Three:** The system must log that the agent acted on the user's behalf, attributable to both the agent and the authorizing human.

How claude-yolo meets them on AWS:

- **Law One:** `GetScopedCredentials` can only narrow the calling session. Claude's credentials are the intersection of the user's own permissions and the scope down policy, so they can never exceed what the user has.
- **Law Two:** the scope down policy is the restriction. The default blocks irreversible actions, and the user approves anything beyond that, one policy at a time.
- **Law Three:** the scoped credentials keep the user's identity, so CloudTrail attributes every call to the human. The `GetScopedCredentials` event records the policy, a description naming the workspace (or the reason the user gave), and the scoped access key ID, which is what ties later calls to the agent.

### Overzealousness, not maliciousness

claude-yolo exists to stop a well-meaning agent from being overzealous: deleting the database it thinks is stale, "cleaning up" a bucket, or quietly reaching for more access than the task needs. The deny-list, the read-only credential mounts, and the standing instructions loaded into every session are all aimed at that.

It is **not** a defense against a malicious agent. Anything that can run code with your credentials has options a scope down policy can't anticipate. If Claude ever decides it's time to kill off us meatbags, claude-yolo isn't going to stop that.

## For Security Teams

claude-yolo is designed to be deployed as a standard, organization-approved way to run Claude Code. What you control:

- **The AWS profile and scope** — you decide which profile `devc grant-aws-creds` scopes down, and the default scope down policy it applies
- **The GCP service account and its IAM roles** — `devc gcp-create-service-account` scopes Claude to exactly the projects/roles you grant, never your own `gcloud` identity
- **Whether Claude runs against Anthropic or Amazon Bedrock** — `devc claude` vs. `devc claude-bedrock`, with Bedrock inference bounded to a service-only bearer token via `devc bedrock-creds`
- **The default session policy** — you define the starting permissions (default: read-only)
- **The container image** — all Claude Code runs from the same hardened environment
- **Network and filesystem constraints** — inherited from the devcontainer spec

What users control:
- What repos they clone and work on inside the container
- Whether to approve Claude's permission escalation requests (by re-running `devc grant-aws-creds --policy`)

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
- **For GCP credential injection:** `gcloud` CLI must be installed on the host — `devc gcp-create-service-account`/`devc gcp-creds` will prompt you through `gcloud auth login` if you're not already authenticated
- **For Amazon Bedrock inference:** `uv` must be installed on the host (same as AWS credential injection)

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

## Standing Instructions for Claude

`managed-CLAUDE.md` is copied into `.devcontainer/` and bind-mounted read-only to `/etc/claude-code/CLAUDE.md`, Claude Code's managed policy location on Linux. Claude Code loads it in every session in the container, in every project, and it can't be excluded with `claudeMdExcludes`. Because it's a read-only bind mount and the container doesn't have `SYS_ADMIN`, Claude can't edit or remount it, even with sudo. It explains the scoped AWS credentials, the suggested-policy workflow below, what not to do to work around the scope, and that an allowed destructive action still needs the human's go-ahead.

It's guidance, not enforcement: the [Claude Code docs](https://code.claude.com/docs/en/memory) note that a session started with CLAUDE.md loading turned off doesn't load the managed file either. The enforced boundary is still the scope down policy. Edit `managed-CLAUDE.md` in the claude-yolo repo, then run `devc template` and `devc rebuild` to roll it out.

## AWS Credentials

`devc grant-aws-creds` narrows your host AWS profile's credentials with [`sts:GetScopedCredentials`](https://docs.aws.amazon.com/STS/latest/APIReference/API_GetScopedCredentials.html) and writes them into `Claude-Yolo-Creds/aws/`, which is bind-mounted read-only into the container at `~/.aws/`. Claude can use them but cannot modify them, and gets only what *both* your own permissions and the scope down policy allow. It can never get more than you have.

```bash
devc grant-aws-creds --profile my-profile                                # default scope
devc grant-aws-creds --profile my-profile --policy reviewed-policy.json    # a policy you've reviewed, from aws-config/
devc grant-aws-creds --profile my-profile --duration 3600                # shorter lifetime than your session
devc grant-aws-creds --profile my-profile --as-profile claude            # write as [claude] instead of [my-profile]
devc grant-aws-creds --profile my-profile --description "OPS-123 RDS migration"   # custom CloudTrail description
devc grant-aws-creds --profile my-profile --as-profile my-profile-once --once --duration 900 --policy ./suggestedpolicy.json   # one-time grant
```

It prints the account identity so you can confirm you're targeting the right account. Re-run any time to refresh. Credentials are never refreshed automatically inside the container.

- **Default scope** is `aws-config/session-policy.json`: everything *except* irreversible actions, expressed as a single `Allow` + `NotAction` deny-list. It blocks deleting resources that hold stateful data (S3 objects and buckets, databases and their snapshots and backups, volumes, file systems, queues, streams, secrets, logs, trails), indirect deletion (S3 lifecycle rules, log retention, backup lifecycle), and ways of escaping the scope (`sts:AssumeRole*`, creating IAM access keys or console passwords). The deny-list has to be the policy's only statement, because separate `Allow` statements combine as a union and would grant those actions back.
- **Policy location:** an absolute path, or one starting with `./` or `../`, is used as given, relative to where you run `devc`. Any other name is read from the same `aws-config/` directory as `session-policy.json` (in the claude-yolo install, e.g. `~/.claude-yolo/aws-config/`).
- **Asking for more:** the policy that was granted is written to `Claude-Yolo-Creds/aws/granted-policy.json` (`~/.aws/granted-policy.json` in the container). When Claude hits `AccessDenied` because of the scope, it writes `/workspace/suggestedpolicy.json`. That file is the current policy with the `AllowAllExceptIrreversible` statement left untouched and new `Allow` statements added after it (statements combine as a union, so an added statement grants back a specific blocked action). Claude then stops and explains each statement. You review it and run, from the workspace root:

  ```bash
  devc grant-aws-creds --profile my-profile --policy ./suggestedpolicy.json --description "why"
  ```

  `grant-aws-creds` prints each statement added on top of the deny-list. It warns if the `AllowAllExceptIrreversible` statement is missing or differs from the shipped default. You're approving a permission, not each action, and Claude is still told to ask before anything destructive.
- **Attribution:** the scoped credentials keep your identity (same role session ARN), so CloudTrail attributes every call to you. The `GetScopedCredentials` event records the granted policy and a `scopedSessionDescription` naming the claude-yolo workspace, along with the scoped access key ID, so you can tell the agent's calls apart from your own.
- **Requirements:** the profile must produce temporary credentials (SSO or assumed role), and its role needs `sts:GetScopedCredentials` allowed. The call goes to the regional STS endpoint, because the global endpoint doesn't support it. The scope down policy is limited to 2,048 characters after minification, and the command checks this before calling.
- **Lifetime:** scoped credentials can't outlive the session they came from.
- **`--as-profile` / `--description`:** `--as-profile` writes the credentials under a different profile name than the host profile they came from. `--description` replaces the default `ScopedSessionDescription` ("claude-yolo agent credentials for workspace <name>"). It must be 2–256 characters of printable ASCII or Latin-1, and the command checks this before calling. Both are recorded in `granted-policy.json` (`source_profile` and `description`, along with `--duration` as `duration_seconds`), and `devc refresh-aws-creds` reuses them.
- **One-time grants (`--once`):** for a permission needed once or briefly. The `granted-policy.json` entry is flagged `"once": true`. `devc refresh-aws-creds` never renews a one-time grant: on its next run it removes the entry, along with the profile's `credentials` and `config` sections. Combine it with `--as-profile` and a short `--duration`. `--once` refuses to overwrite a standing grant of the same name, because refresh would then delete that standing grant.
- **Additive:** only the named profile's section in `credentials`, its `region` in `config`, and its entry in `granted-policy.json` are updated. Other profiles are left alone, so you can grant several profiles side by side.

### SSO profiles

```bash
aws sso login --profile my-profile   # if token has expired
devc grant-aws-creds --profile my-profile
```

### IAM user profiles

`GetScopedCredentials` only accepts temporary credentials, so `devc grant-aws-creds` refuses IAM user profiles (long-lived access keys). Use an SSO or assumed-role profile instead.

### Refreshing grants

`devc refresh-aws-creds` re-runs every grant recorded in `granted-policy.json`, exactly as it was granted, across as many profiles, accounts and AWS organizations as you've granted:

```bash
devc refresh-aws-creds              # re-mint every recorded grant
devc refresh-aws-creds --dry-run    # show what would be refreshed or removed; changes nothing
```

For each entry, refresh does the following:
1. Resolves the recorded `source_profile` the same way `grant-aws-creds` does, so SSO, assumed-role and `credential_process` profiles all work.
2. If an SSO token is missing or expired, runs `aws sso login --profile <source_profile>` once and retries.
3. Scopes the credentials down with the entry's recorded policy, `description` and `--duration`, and rewrites that profile's sections.

If a grant fails, that profile is left unchanged: unscoped credentials are never written. One-time grants (`--once`) are removed rather than refreshed.

Credential sections that `grant-aws-creds` didn't create, such as ones pasted in from the SSO portal, are left alone. Use `devc grant-aws-creds` to add every profile, so it's scoped and recorded.

## GCP Credentials

Claude never sees your own `gcloud` identity. Instead, each workspace gets one dedicated service account that you scope to exactly the GCP projects (and roles) you want Claude to touch — `devc gcp-creds` then writes it a short-lived access token, never a refresh token or key.

Why not just bind-mount `~/.config/gcloud`, or use `gcloud auth application-default login --impersonate-service-account`? Both end up putting your own broad credentials in the container: ADC's `impersonated_service_account` file embeds your OAuth refresh token in cleartext right alongside the impersonation pointer, so anything that can read the file can use it to authenticate as *you*, not just the scoped service account.

### One-time setup per workspace

```bash
devc gcp-create-service-account --host-project my-host-proj --projects proj-a,proj-b --role roles/viewer
```

If `gcloud` doesn't already have a usable login, this runs `gcloud auth login` for you first (your own login stays on the host — it's never copied into the container). It then creates (or reuses) a service account named after the workspace directory in `--host-project`, grants it the given `--role`(s) — repeatable, default `roles/viewer` — in each of `--projects`, and grants *your* account `roles/iam.serviceAccountTokenCreator` on that service account only (so you can mint tokens for it, and nothing more). It writes `Claude-Yolo-Creds/gcp/manifest.json` recording each project's granted roles.

IAM changes can take a few minutes to propagate. If `devc gcp-creds` fails with `PERMISSION_DENIED` right after setup, wait a bit and retry before assuming something's wrong.

### Adding more projects or roles later

A workspace has exactly one service account, so `--host-project` only needs to be given once — later calls reuse it (and refuse a different value, since moving a workspace's service account to another host project isn't supported):

```bash
devc gcp-create-service-account --projects proj-a --role roles/storage.admin   # add a role to an existing project
devc gcp-create-service-account --projects proj-c --role roles/viewer         # grant access to a new project
```

This is additive — safe to re-run any time. Each project's granted roles accumulate in the manifest (nothing already granted is ever revoked by this command).

Run `devc rebuild` once after the first time you set this up for a workspace, so the container picks up the new bind mount.

### Minting credentials before a session

```bash
devc gcp-creds
```

This impersonates the workspace's service account and writes a short-lived OAuth access token (1 hour by default; `--lifetime SECONDS` to change it) to `Claude-Yolo-Creds/gcp/access_token`, which is bind-mounted read-only into the container at `~/.gcp/access_token` and picked up automatically via `CLOUDSDK_AUTH_ACCESS_TOKEN_FILE`. Re-run before it expires — like AWS credentials, it's never refreshed automatically inside the container.

Because the actual security boundary is the IAM roles bound to the service account (not anything client-side), always pass `--project` explicitly on `gcloud`/`gsutil`/`bq` commands inside the container — there's no single "default" project when a service account spans several.

## Amazon Bedrock Inference

`devc claude-bedrock` runs Claude Code against Amazon Bedrock instead of the Anthropic API — useful if your organization routes model spend and access through AWS rather than an Anthropic account. It reuses whatever AWS credentials you already have; it doesn't need a new credential mechanism, because Claude Code's own Bedrock support just uses the standard AWS SDK credential chain.

### Minting a Bedrock API key

```bash
devc bedrock-creds --region us-east-1 --profile my-profile
```

This mints a *short-term Amazon Bedrock API key* — a bearer token, valid for up to 12 hours (`--lifetime SECONDS` to change it, default 28800 = 8h), signed locally from whichever AWS profile you point it at. Omit `--profile` and it resolves the same way the AWS CLI itself would: `AWS_DEFAULT_PROFILE`, then `AWS_PROFILE`, then the config file's default profile. It's written to `Claude-Yolo-Creds/bedrock/token`, bind-mounted read-only into the container.

This is deliberately not the same credential as `devc grant-aws-creds` writes, even though both can come from the same AWS profile. A Bedrock API key inherits that profile's IAM permissions, but — unlike the raw AWS credentials in `Claude-Yolo-Creds/aws/` — it can *only* ever be replayed against the Bedrock API, never against S3, EC2, or anything else the profile might also be able to touch. If the profile you use here has permissions beyond Bedrock (common, since people reuse a broader role for convenience), this bounds what a compromised container session can actually do with it.

Short-term keys are region-locked to wherever they were generated, so `devc claude-bedrock` reads the region back out of `Claude-Yolo-Creds/bedrock/manifest.json` rather than guessing — the two commands can't disagree about which region to use.

### Running Claude against Bedrock

```bash
devc claude-bedrock
devc claude-bedrock --model us.anthropic.claude-sonnet-4-6   # any native Claude Code flag passes through
```

The token is read from the bind-mounted file *inside* the container's own shell and exported only for that one `claude` process — it's never passed as a `--remote-env` value or a command-line argument, so it never sits in any process's argument list where `ps` could see it.

Re-run `devc bedrock-creds` whenever the key expires — like the other credentials in this repo, nothing here refreshes itself automatically.

### IAM permissions needed

Whatever AWS profile/role you point `devc bedrock-creds` at needs, at minimum:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
      "bedrock:ListInferenceProfiles",
      "bedrock:GetInferenceProfile"
    ],
    "Resource": [
      "arn:aws:bedrock:*:*:inference-profile/*",
      "arn:aws:bedrock:*:*:application-inference-profile/*",
      "arn:aws:bedrock:*:*:foundation-model/*"
    ]
  }]
}
```

You'll also need to have submitted Bedrock's one-time "use case details" form for the Anthropic models in your AWS account (Bedrock console → Model catalog). See [Claude Code on Amazon Bedrock](https://code.claude.com/docs/en/amazon-bedrock) for the full reference, including model pinning — without pinning a model, `claude-bedrock` defaults to Claude Code's built-in Bedrock default (Opus-tier pricing), which matters a lot if you're deploying this to multiple users.

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
devc grant-aws-creds  Write scoped-down (GetScopedCredentials) AWS credentials to Claude-Yolo-Creds/aws/
devc refresh-aws-creds  Re-mint every grant recorded by grant-aws-creds; remove --once grants
devc gcp-create-service-account  Create/scope this workspace's GCP service account
devc gcp-creds      Mint a short-lived GCP access token into Claude-Yolo-Creds/gcp/
devc bedrock-creds  Mint a short-lived Bedrock API key into Claude-Yolo-Creds/bedrock/
devc self-install   Install devc to ~/.local/bin
devc update         Update devc to latest version
devc claude         Run claude --dangerously-skip-permissions in container
devc claude-bedrock Run claude against Amazon Bedrock instead of the Anthropic API
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
| Tools | `rg`, `fd`, `ast-grep`, `tmux`, `fzf`, `delta`, `iptables`, `terraform`, AWS CLI, gcloud CLI |
| Persistent volumes | Shell history (`/commandhistory`), Claude config (`~/.claude`), GitHub CLI auth (`~/.config/gh`) |
| Host mounts | `~/.gitconfig` (read-only), `.devcontainer/` (read-only), `.devcontainer/managed-CLAUDE.md` → `/etc/claude-code/CLAUDE.md` (read-only) |
| AWS credentials | Not persisted — lost on `devc rebuild` (intentional) |
| GCP credentials | Not persisted — lost on `devc rebuild` (intentional) |
| Bedrock credentials | Not persisted — lost on `devc rebuild` (intentional) |

## Troubleshooting

**`devcontainer CLI not found`**
```bash
npm install -g @devcontainers/cli
```

**`uv: command not found` when running `devc grant-aws-creds`**
```bash
brew install uv
```

**SSO credentials expired**
```bash
aws sso login --profile my-profile
devc grant-aws-creds --profile my-profile
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
