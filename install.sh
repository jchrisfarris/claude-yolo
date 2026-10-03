#!/bin/bash
set -euo pipefail

# claude-yolo CLI Helper
# Provides the `devc` command for managing devcontainers

# Resolve symlinks to get actual script location
SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE" ]]; do
  DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
SCRIPT_NAME="$(basename "$0")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_usage() {
  cat <<EOF
Usage: devc <command> [options]

Commands:
    .                   Install devcontainer template to current directory and start
    up                  Start the devcontainer in current directory
    claude              Runs claude --dangerously-skip-permissions in the container
    claude-bedrock      Runs claude against Amazon Bedrock instead of the Anthropic API
    rebuild             Rebuild the devcontainer (preserves auth volumes)
    down                Stop the devcontainer
    list [-a]           List running devcontainers (-a includes stopped)
    shell               Open a shell in the running container
    self-install        Install 'devc' command to ~/.local/bin
    update              Update devc to the latest version
    template [dir]      Copy devcontainer template to directory (default: current)
    exec <cmd>          Execute a command in the running container
    upgrade             Upgrade Claude Code to latest version
    mount <host> <cont> Add a mount to the devcontainer (recreates container)
    sync [project] [--trusted]  Sync sessions from devcontainers to host
    cp <cont> <host>    Copy files/directories from container to host
    destroy [-f]        Remove container, volumes, and image for current project
    aws-creds           Write scoped AWS credentials to Claude-Yolo-Creds/aws/
    refresh-aws-creds   Refresh SSO-backed profiles in Claude-Yolo-Creds/aws/credentials
    gcp-create-service-account  Create/scope the workspace's GCP service account
    gcp-creds           Mint a short-lived GCP access token into Claude-Yolo-Creds/gcp/
    bedrock-creds       Mint a short-lived Bedrock API key into Claude-Yolo-Creds/bedrock/
    help                Show this help message

Examples:
    devc .                      # Install template and start container
    devc up                     # Start container in current directory
    devc down                   # Stop the running container
    devc list                   # List running devcontainers
    devc list -a                # List all devcontainers (including stopped)
    devc claude                 # Starts Claude in Yolo Mode
    devc rebuild                # Clean rebuild
    devc shell                  # Open interactive shell
    devc self-install           # Install devc to PATH
    devc update                 # Update to latest version
    devc exec ls -la            # Run command in container
    devc upgrade                # Upgrade Claude Code to latest
    devc mount ~/data /data     # Add mount to container
    devc sync                   # Sync sessions from all devcontainers
    devc sync crypto            # Sync only matching devcontainer
    devc cp /some/file ./out    # Copy a path from container to host
    devc destroy                # Remove all project Docker resources
    devc destroy -f             # Skip confirmation prompt
    devc aws-creds --profile myprofile        # Write AWS credentials for container use
    devc refresh-aws-creds                    # Refresh SSO profiles in Claude-Yolo-Creds/aws/credentials
    devc refresh-aws-creds --dry-run          # Show which SSO session each profile maps to
    devc gcp-create-service-account --host-project my-proj --projects proj-a,proj-b
    devc gcp-creds                             # Mint/refresh the workspace's GCP access token
    devc bedrock-creds --region us-east-1      # Mint a short-lived Bedrock API key
    devc claude-bedrock                        # Run claude against Amazon Bedrock
EOF
}

log_info() {
  echo -e "${BLUE}[devc]${NC} $1"
}

log_success() {
  echo -e "${GREEN}[devc]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[devc]${NC} $1"
}

log_error() {
  echo -e "${RED}[devc]${NC} $1" >&2
}

check_devcontainer_cli() {
  if ! command -v devcontainer &>/dev/null; then
    log_error "devcontainer CLI not found."
    log_info "Install it with: npm install -g @devcontainers/cli"
    exit 1
  fi
}

check_gcloud_cli() {
  if ! command -v gcloud &>/dev/null; then
    log_error "gcloud CLI not found."
    log_info "Install it: https://cloud.google.com/sdk/docs/install"
    exit 1
  fi
}

# Makes sure gcloud actually has a usable, authenticated account — not just a
# configured [core/account] property, which can be set without valid credentials.
ensure_gcloud_login() {
  if gcloud auth print-access-token &>/dev/null; then
    return 0
  fi

  log_info "No usable gcloud login found. Running 'gcloud auth login'..."
  if ! gcloud auth login; then
    log_error "gcloud auth login failed or was cancelled."
    exit 1
  fi

  if ! gcloud auth print-access-token &>/dev/null; then
    log_error "Still no usable gcloud credentials after 'gcloud auth login'."
    exit 1
  fi
}

check_no_sys_admin() {
  local workspace="${1:-.}"
  local dc_json="$workspace/.devcontainer/devcontainer.json"
  [[ -f "$dc_json" ]] || return 0
  if jq -e \
    '.runArgs[]? | select(test("SYS_ADMIN"))' \
    "$dc_json" >/dev/null 2>&1; then
    log_error "SYS_ADMIN capability detected in runArgs."
    log_error "This defeats the read-only .devcontainer mount."
    exit 1
  fi
}

get_workspace_folder() {
  local dir="${1:-.}"
  cd "$dir" 2>/dev/null && pwd || echo "$dir"
}

# Extract custom mounts from devcontainer.json to a temp file
# Returns the temp file path, or empty string if no custom mounts
#
# Security: .devcontainer/ is mounted read-only inside the container to prevent
# a compromised process from injecting malicious mounts or commands into
# devcontainer.json that execute on the host during rebuild. This protection
# requires that SYS_ADMIN is never added to runArgs (it would allow remounting
# read-write).
extract_mounts_to_file() {
  local devcontainer_json="$1"
  local temp_file

  [[ -f "$devcontainer_json" ]] || return 0

  temp_file=$(mktemp)

  # Filter out default mounts by target path (immune to project name changes)
  local custom_mounts
  custom_mounts=$(jq -c '
    .mounts // [] | map(
      select(
        (contains("target=/commandhistory,") | not) and
        (contains("target=/home/vscode/.claude,") | not) and
        (contains("target=/home/vscode/.config/gh,") | not) and
        (contains("target=/home/vscode/.gitconfig,") | not) and
        (contains("target=/workspace/.devcontainer,") | not) and
        (contains("target=/home/vscode/.aws,") | not) and
        (contains("target=/home/vscode/.ssh,") | not) and
        (contains("target=/home/vscode/.gcp,") | not) and
        (contains("target=/home/vscode/.bedrock,") | not)
      )
    ) | if length > 0 then . else empty end
  ' "$devcontainer_json" 2>/dev/null) || true

  if [[ -n "$custom_mounts" ]]; then
    echo "$custom_mounts" >"$temp_file"
    echo "$temp_file"
  else
    rm -f "$temp_file"
  fi
}

# Merge preserved mounts back into devcontainer.json
merge_mounts_from_file() {
  local devcontainer_json="$1"
  local mounts_file="$2"

  [[ -f "$mounts_file" ]] || return 0
  [[ -s "$mounts_file" ]] || return 0

  local custom_mounts
  custom_mounts=$(cat "$mounts_file")

  local updated
  updated=$(jq --argjson custom "$custom_mounts" '
    .mounts = ((.mounts // []) + $custom | unique)
  ' "$devcontainer_json")

  echo "$updated" >"$devcontainer_json"
}

# Add or update a mount in devcontainer.json
update_devcontainer_mounts() {
  local devcontainer_json="$1"
  local host_path="$2"
  local container_path="$3"
  local readonly="${4:-false}"

  local mount_str="source=${host_path},target=${container_path},type=bind"
  [[ "$readonly" == "true" ]] && mount_str="${mount_str},readonly"

  local updated
  updated=$(jq --arg target "$container_path" --arg mount "$mount_str" '
    .mounts = (
      ((.mounts // []) | map(select(contains("target=" + $target + ",") or endswith("target=" + $target) | not)))
      + [$mount]
    )
  ' "$devcontainer_json")

  echo "$updated" >"$devcontainer_json"
}

cmd_template() {
  local target_dir="${1:-.}"
  target_dir="$(cd "$target_dir" 2>/dev/null && pwd)" || {
    log_error "Directory does not exist: $1"
    exit 1
  }

  local devcontainer_dir="$target_dir/.devcontainer"
  local devcontainer_json="$devcontainer_dir/devcontainer.json"
  local preserved_mounts=""

  if [[ -d "$devcontainer_dir" ]]; then
    log_warn "Devcontainer already exists at $devcontainer_dir"
    read -p "Overwrite? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      log_info "Aborted."
      exit 0
    fi

    # Preserve custom mounts before overwriting
    preserved_mounts=$(extract_mounts_to_file "$devcontainer_json")
    if [[ -n "$preserved_mounts" ]]; then
      log_info "Preserving custom mounts..."
    fi
  fi

  mkdir -p "$devcontainer_dir"

  # Copy template files
  cp "$SCRIPT_DIR/Dockerfile" "$devcontainer_dir/"
  cp "$SCRIPT_DIR/devcontainer.json" "$devcontainer_dir/"
  cp "$SCRIPT_DIR/post_install.py" "$devcontainer_dir/"
  cp "$SCRIPT_DIR/.zshrc" "$devcontainer_dir/"
  cp "$SCRIPT_DIR/statusline.sh" "$devcontainer_dir/"
  cp "$SCRIPT_DIR/mcp.json" "$devcontainer_dir/"
  cp -a "$SCRIPT_DIR/aws-config" "$devcontainer_dir/"
  cp -a "$SCRIPT_DIR/commands" "$devcontainer_dir/"

  # Restore preserved mounts
  if [[ -n "$preserved_mounts" ]]; then
    merge_mounts_from_file "$devcontainer_json" "$preserved_mounts"
    rm -f "$preserved_mounts"
    log_info "Custom mounts restored"
  fi

  log_success "Template installed to $devcontainer_dir"
}

# Sanitize a workspace basename into a valid Docker container name:
# lowercase, restricted to [a-z0-9_.-], leading char must be alphanumeric.
sanitize_container_name() {
  local raw="$1"
  echo "$raw" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9_.-]/-/g; s/^[^a-z0-9]*//'
}

# Rename the workspace's container to the lowercase basename of the workspace
# folder (e.g. /Users/chris/MyProject -> myproject) instead of Docker's random
# pet name. Skips silently if the desired name is already in use.
rename_container_to_workspace() {
  local workspace_folder="$1"
  local label="devcontainer.local_folder=$workspace_folder"
  local container_id current_name desired_name

  container_id=$(docker ps -q --filter "label=$label" 2>/dev/null | head -1 || true)
  [[ -z "$container_id" ]] && return 0

  desired_name=$(sanitize_container_name "$(basename "$workspace_folder")")
  [[ -z "$desired_name" ]] && return 0

  current_name=$(docker inspect --format '{{.Name}}' "$container_id" 2>/dev/null | sed 's|^/||')
  [[ "$current_name" == "$desired_name" ]] && return 0

  if docker rename "$container_id" "$desired_name" 2>/dev/null; then
    log_info "Renamed container: $current_name -> $desired_name"
  else
    log_warn "Could not rename container to '$desired_name' (name already in use?)"
  fi
}

cmd_up() {
  local workspace_folder
  workspace_folder="$(get_workspace_folder "${1:-}")"

  check_devcontainer_cli
  check_no_sys_admin "$workspace_folder"

  # Ensure credential directories exist — required by bind mounts in devcontainer.json
  mkdir -p "$workspace_folder/Claude-Yolo-Creds/aws"
  mkdir -p "$workspace_folder/Claude-Yolo-Creds/ssh"
  mkdir -p "$workspace_folder/Claude-Yolo-Creds/gcp"
  mkdir -p "$workspace_folder/Claude-Yolo-Creds/bedrock"
  # Seed default AWS config if missing — the bind mount overlays ~/.aws so the
  # Dockerfile-baked copy is hidden without this.
  if [[ ! -f "$workspace_folder/Claude-Yolo-Creds/aws/config" ]]; then
    cp "$SCRIPT_DIR/aws-config/config" "$workspace_folder/Claude-Yolo-Creds/aws/config"
  fi

  log_info "Starting devcontainer in $workspace_folder..."

  export DEVC_BUILD_TIMESTAMP
  DEVC_BUILD_TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  devcontainer up --workspace-folder "$workspace_folder"
  rename_container_to_workspace "$workspace_folder"
  log_success "Devcontainer started"
}

cmd_rebuild() {
  local workspace_folder
  workspace_folder="$(get_workspace_folder "${1:-}")"

  check_devcontainer_cli
  check_no_sys_admin "$workspace_folder"

  # Ensure credential directories exist — required by bind mounts in devcontainer.json
  mkdir -p "$workspace_folder/Claude-Yolo-Creds/aws"
  mkdir -p "$workspace_folder/Claude-Yolo-Creds/ssh"
  mkdir -p "$workspace_folder/Claude-Yolo-Creds/gcp"
  mkdir -p "$workspace_folder/Claude-Yolo-Creds/bedrock"
  if [[ ! -f "$workspace_folder/Claude-Yolo-Creds/aws/config" ]]; then
    cp "$SCRIPT_DIR/aws-config/config" "$workspace_folder/Claude-Yolo-Creds/aws/config"
  fi

  log_info "Rebuilding devcontainer in $workspace_folder..."

  export DEVC_BUILD_TIMESTAMP
  DEVC_BUILD_TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  devcontainer up --workspace-folder "$workspace_folder" --remove-existing-container
  rename_container_to_workspace "$workspace_folder"
  log_success "Devcontainer rebuilt"
}

cmd_list() {
  local show_all=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -a|--all)
        show_all=true
        shift
        ;;
      *)
        log_error "Unknown option: $1"
        log_info "Usage: devc list [-a|--all]"
        exit 1
        ;;
    esac
  done

  local ps_args=("--filter" "label=devcontainer.local_folder"
    "--format" 'table {{.Names}}\t{{.Status}}\t{{.Label "devcontainer.build.timestamp"}}\t{{.Label "devcontainer.local_folder"}}')
  $show_all && ps_args=("-a" "${ps_args[@]}")

  docker ps "${ps_args[@]}"
}

cmd_down() {
  local workspace_folder
  workspace_folder="$(get_workspace_folder "${1:-}")"

  check_devcontainer_cli
  log_info "Stopping devcontainer..."

  # Get container ID and stop it
  local label="devcontainer.local_folder=$workspace_folder"
  local container_id
  container_id=$(docker ps -q --filter "label=$label" 2>/dev/null || true)

  if [[ -n "$container_id" ]]; then
    docker stop "$container_id"
    log_success "Devcontainer stopped"
  else
    log_warn "No running devcontainer found for $workspace_folder"
  fi
}

cmd_shell() {
  local workspace_folder
  workspace_folder="$(get_workspace_folder)"

  check_devcontainer_cli
  log_info "Opening shell in devcontainer..."

  devcontainer exec --workspace-folder "$workspace_folder" zsh
}

cmd_exec() {
  local workspace_folder
  workspace_folder="$(get_workspace_folder)"

  check_devcontainer_cli
  devcontainer exec --workspace-folder "$workspace_folder" "$@"
}

cmd_upgrade() {
  local workspace_folder
  workspace_folder="$(get_workspace_folder)"

  check_devcontainer_cli
  log_info "Upgrading Claude Code..."

  devcontainer exec --workspace-folder "$workspace_folder" claude update

  log_success "Claude Code upgraded"
}

cmd_mount() {
  local host_path="${1:-}"
  local container_path="${2:-}"
  local readonly="false"

  if [[ -z "$host_path" ]] || [[ -z "$container_path" ]]; then
    log_error "Usage: devc mount <host_path> <container_path> [--readonly]"
    exit 1
  fi

  [[ "${3:-}" == "--readonly" ]] && readonly="true"

  # Expand and validate host path
  host_path="$(cd "$host_path" 2>/dev/null && pwd)" || {
    log_error "Host path does not exist: $1"
    exit 1
  }

  local workspace_folder
  workspace_folder="$(get_workspace_folder)"
  local devcontainer_json="$workspace_folder/.devcontainer/devcontainer.json"

  if [[ ! -f "$devcontainer_json" ]]; then
    log_error "No devcontainer.json found. Run 'devc template' first."
    exit 1
  fi

  check_devcontainer_cli

  log_info "Adding mount: $host_path → $container_path"
  update_devcontainer_mounts "$devcontainer_json" "$host_path" "$container_path" "$readonly"

  log_info "Recreating container with new mount..."
  export DEVC_BUILD_TIMESTAMP
  DEVC_BUILD_TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  devcontainer up --workspace-folder "$workspace_folder" --remove-existing-container
  rename_container_to_workspace "$workspace_folder"

  log_success "Mount added: $host_path → $container_path"
}

cmd_sync() {
  local filter=""
  local trusted=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --trusted)
      trusted=true
      shift
      ;;
    *)
      filter="$1"
      shift
      ;;
    esac
  done

  local host_projects="${HOME}/.claude/projects"

  if [[ "$trusted" == false ]]; then
    log_warn "This copies files from devcontainers to your host filesystem."
    log_warn "Only proceed if you trust the container contents."
    log_info "Use --trusted to skip this prompt."
    read -p "Continue? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      log_info "Aborted."
      exit 0
    fi
  fi

  # Discover all devcontainers (running + stopped) by label.
  local container_ids
  container_ids=$(docker ps -a -q \
    --filter "label=devcontainer.local_folder" 2>/dev/null || true)

  if [[ -z "$container_ids" ]]; then
    log_error "No devcontainers found (running or stopped)."
    exit 1
  fi

  # List discovered devcontainers.
  log_info "Discovered devcontainers:"
  local matched_any=false
  while IFS= read -r cid; do
    local name folder status
    name=$(sync_get_project_name "$cid")
    folder=$(docker inspect --format \
      '{{index .Config.Labels "devcontainer.local_folder"}}' "$cid")
    status=$(docker inspect --format '{{.State.Status}}' "$cid")

    if [[ -n "$filter" ]]; then
      if ! echo "$name" | grep -qi "$filter"; then
        continue
      fi
    fi

    matched_any=true
    echo "  - ${name} (${status}) ${folder}"
  done <<< "$container_ids"

  if [[ "$matched_any" == false ]]; then
    log_error "No devcontainers matching '${filter}'."
    echo ""
    echo "Available:"
    while IFS= read -r cid; do
      local name status
      name=$(sync_get_project_name "$cid")
      status=$(docker inspect --format '{{.State.Status}}' "$cid")
      echo "  - ${name} (${status})"
    done <<< "$container_ids"
    exit 1
  fi

  echo ""

  # Sync matching containers.
  while IFS= read -r cid; do
    local name
    name=$(sync_get_project_name "$cid")

    if [[ -n "$filter" ]]; then
      if ! echo "$name" | grep -qi "$filter"; then
        continue
      fi
    fi

    sync_one_container "$cid" "$host_projects"
    echo ""
  done <<< "$container_ids"

  log_success "Run '/insights' in Claude Code to include these sessions."
}

# Extract project name from devcontainer.local_folder label.
sync_get_project_name() {
  local folder
  folder=$(docker inspect --format \
    '{{index .Config.Labels "devcontainer.local_folder"}}' "$1")
  basename "$folder"
}

# Resolve the Claude projects dir inside a container without
# docker exec (works on stopped containers too).
# Reads CLAUDE_CONFIG_DIR from container env, falls back to
# /home/<user>/.claude.
sync_get_claude_projects_dir() {
  local cid="$1"
  local claude_dir

  claude_dir=$(docker inspect --format '{{json .Config.Env}}' "$cid" \
    | tr ',' '\n' | tr -d '[]"' \
    | grep '^CLAUDE_CONFIG_DIR=' \
    | cut -d= -f2- || true)

  if [[ -n "$claude_dir" ]]; then
    echo "${claude_dir}/projects"
    return
  fi

  local user
  user=$(docker inspect --format '{{.Config.User}}' "$cid")
  if [[ -z "$user" || "$user" == "root" ]]; then
    echo "/root/.claude/projects"
  else
    echo "/home/${user}/.claude/projects"
  fi
}

sync_one_container() {
  local cid="$1"
  local host_projects="$2"
  local project_name status claude_dir folder

  project_name=$(sync_get_project_name "$cid")
  folder=$(docker inspect --format \
    '{{index .Config.Labels "devcontainer.local_folder"}}' "$cid")
  status=$(docker inspect --format '{{.State.Status}}' "$cid")
  claude_dir=$(sync_get_claude_projects_dir "$cid")

  log_info "=== ${project_name} (${status}) ==="
  echo "  Host path:  ${folder}"
  echo "  Container:  ${cid:0:12}"

  # docker cp works on both running and stopped containers.
  local tmpdir
  tmpdir=$(mktemp -d)

  if ! docker cp "${cid}:${claude_dir}/." "$tmpdir/" 2>/dev/null; then
    echo "  No sessions found, skipping."
    rm -rf "$tmpdir"
    return 0
  fi

  local session_count
  session_count=$(find "$tmpdir" -name '*.jsonl' | wc -l | tr -d ' ')

  if [[ "$session_count" -eq 0 ]]; then
    echo "  No sessions found, skipping."
    rm -rf "$tmpdir"
    return 0
  fi

  echo "  Sessions:   ${session_count}"

  local total_copied=0

  # Sync each project key subdirectory.
  for key_path in "$tmpdir"/*/; do
    [[ ! -d "$key_path" ]] && continue
    local key dest_key
    key=$(basename "$key_path")

    if [[ "$key" == "-workspace" ]]; then
      dest_key="-devcontainer-${project_name}"
    else
      dest_key="${key}"
    fi

    local dest_dir="${host_projects}/${dest_key}"
    mkdir -p "$dest_dir"

    local copied=0
    while IFS= read -r -d '' file; do
      local rel="${file#"$key_path"}"
      local dest_file="${dest_dir}/${rel}"
      mkdir -p "$(dirname "$dest_file")"

      if [[ ! -e "$dest_file" ]] \
          || [[ "$file" -nt "$dest_file" ]]; then
        cp -p "$file" "$dest_file"
        copied=$((copied + 1))
      fi
    done < <(find "$key_path" -type f -print0)

    if [[ "$copied" -gt 0 ]]; then
      echo "  Synced ${copied} file(s) -> ${dest_key}"
    fi
    total_copied=$((total_copied + copied))
  done

  # Handle .jsonl files directly in projects/ (no subdirectory).
  local orphan_copied=0
  local dest_dir="${host_projects}/-devcontainer-${project_name}"
  mkdir -p "$dest_dir"

  while IFS= read -r -d '' file; do
    local name
    name=$(basename "$file")
    local dest_file="${dest_dir}/${name}"

    if [[ ! -e "$dest_file" ]] \
        || [[ "$file" -nt "$dest_file" ]]; then
      cp -p "$file" "$dest_file"
      orphan_copied=$((orphan_copied + 1))
    fi
  done < <(find "$tmpdir" -maxdepth 1 -name '*.jsonl' -print0)

  if [[ "$orphan_copied" -gt 0 ]]; then
    echo "  Synced ${orphan_copied} file(s) -> -devcontainer-${project_name}"
    total_copied=$((total_copied + orphan_copied))
  fi

  rm -rf "$tmpdir"

  echo "  Total: ${total_copied} file(s) synced."
}

cmd_cp() {
  local container_path="${1:-}"
  local host_path="${2:-}"

  if [[ -z "$container_path" ]] || [[ -z "$host_path" ]]; then
    log_error "Usage: devc cp <container_path> <host_path>"
    exit 1
  fi

  local workspace_folder
  workspace_folder="$(get_workspace_folder)"

  # Find the running container
  local label="devcontainer.local_folder=$workspace_folder"
  local container_id
  container_id=$(docker ps -q --filter "label=$label" 2>/dev/null || true)

  if [[ -z "$container_id" ]]; then
    log_error "No running devcontainer found for $workspace_folder"
    exit 1
  fi

  log_info "Copying $container_path → $host_path"
  docker cp "$container_id:$container_path" "$host_path"
  log_success "Copied $container_path → $host_path"
}

cmd_self_install() {
  local install_dir="$HOME/.local/bin"
  local install_path="$install_dir/devc"

  mkdir -p "$install_dir"

  # Create a symlink to the original script
  ln -sf "$SCRIPT_DIR/$SCRIPT_NAME" "$install_path"

  log_success "Installed 'devc' to $install_path"

  # Check if in PATH
  if [[ ":$PATH:" != *":$install_dir:"* ]]; then
    log_warn "$install_dir is not in your PATH"
    log_info "Add this to your shell profile:"
    echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
  fi

  # Add Claude-Yolo-Creds/ to the global gitignore (append-only, never overwrite)
  local global_gitignore
  global_gitignore=$(git config --global core.excludesfile 2>/dev/null || true)
  # Expand ~ if present
  global_gitignore="${global_gitignore/#\~/$HOME}"
  if [[ -z "$global_gitignore" ]]; then
    global_gitignore="$HOME/.gitignore_global"
    git config --global core.excludesfile "$global_gitignore"
    log_info "Set git core.excludesfile to $global_gitignore"
  fi
  touch "$global_gitignore"
  if ! grep -qxF "Claude-Yolo-Creds/" "$global_gitignore" 2>/dev/null; then
    echo "Claude-Yolo-Creds/" >> "$global_gitignore"
    log_success "Added Claude-Yolo-Creds/ to global gitignore ($global_gitignore)"
  else
    log_info "Claude-Yolo-Creds/ already in global gitignore"
  fi
}

cmd_update() {
  log_info "Updating devc..."

  if ! git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree &>/dev/null; then
    log_error "Not a git repository: $SCRIPT_DIR"
    log_info "Re-clone with: rm -rf ~/.claude-yolo && git clone https://github.com/securosis/claude-yolo ~/.claude-yolo"
    exit 1
  fi

  local before_sha after_sha
  before_sha=$(git -C "$SCRIPT_DIR" rev-parse HEAD)

  if ! git -C "$SCRIPT_DIR" pull --ff-only; then
    log_error "Update failed. Try: cd $SCRIPT_DIR && git pull"
    exit 1
  fi

  after_sha=$(git -C "$SCRIPT_DIR" rev-parse HEAD)

  if [[ "$before_sha" == "$after_sha" ]]; then
    log_success "Already up to date"
  else
    log_success "Updated from ${before_sha:0:7} to ${after_sha:0:7}"
  fi
}

cmd_aws_creds() {
  local profile=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile)
        profile="$2"
        shift 2
        ;;
      *)
        log_error "Unknown option: $1"
        log_info "Usage: devc aws-creds --profile PROFILE"
        exit 1
        ;;
    esac
  done

  if [[ -z "$profile" ]]; then
    log_error "Usage: devc aws-creds --profile PROFILE"
    exit 1
  fi

  local workspace
  workspace="$(get_workspace_folder)"

  local creds_dir="$workspace/Claude-Yolo-Creds"
  if [[ ! -d "$creds_dir" ]]; then
    log_error "Claude-Yolo-Creds/ not found in $workspace"
    log_info "Run 'devc .' first to set up the workspace."
    exit 1
  fi

  uv run "$SCRIPT_DIR/aws_creds.py" --profile "$profile" --creds-dir "$creds_dir"
}

cmd_refresh_aws_creds() {
  local workspace
  workspace="$(get_workspace_folder)"

  local creds_file="$workspace/Claude-Yolo-Creds/aws/credentials"
  if [[ ! -f "$creds_file" ]]; then
    log_error "No credentials file at Claude-Yolo-Creds/aws/credentials"
    log_info "It needs [<accountId>_<RoleName>] sections to refresh. Run 'devc .' first if the workspace isn't set up."
    exit 1
  fi

  python3 "$SCRIPT_DIR/refresh-sso-creds.py" "$creds_file" "$@"
}

cmd_gcp_create_service_account() {
  local host_project="" projects_csv="" sa_id=""
  local roles=()
  local usage="Usage: devc gcp-create-service-account [--host-project PROJECT] --projects PROJECT[,PROJECT...] [--role ROLE]... [--sa-id NAME]"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --host-project)
        host_project="$2"
        shift 2
        ;;
      --projects)
        projects_csv="$2"
        shift 2
        ;;
      --role)
        roles+=("$2")
        shift 2
        ;;
      --sa-id)
        sa_id="$2"
        shift 2
        ;;
      *)
        log_error "Unknown option: $1"
        log_info "$usage"
        exit 1
        ;;
    esac
  done

  if [[ -z "$projects_csv" ]]; then
    log_error "$usage"
    exit 1
  fi

  [[ ${#roles[@]} -eq 0 ]] && roles=("roles/viewer")

  check_gcloud_cli

  local workspace
  workspace="$(get_workspace_folder)"
  local creds_dir="$workspace/Claude-Yolo-Creds"
  if [[ ! -d "$creds_dir" ]]; then
    log_error "Claude-Yolo-Creds/ not found in $workspace"
    log_info "Run 'devc .' first to set up the workspace."
    exit 1
  fi

  mkdir -p "$creds_dir/gcp"
  local manifest="$creds_dir/gcp/manifest.json"

  # A workspace has exactly one service account. On a repeat run, --host-project/--sa-id
  # default to (and must match) what's already recorded — only --projects/--role are additive.
  local existing_sa_email="" existing_host_project="" created=""
  if [[ -f "$manifest" ]]; then
    existing_sa_email="$(jq -r '.sa_email' "$manifest")"
    existing_host_project="$(jq -r '.host_project' "$manifest")"
    created="$(jq -r '.created' "$manifest")"
  fi
  [[ -z "$created" ]] && created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [[ -n "$existing_host_project" ]]; then
    if [[ -n "$host_project" && "$host_project" != "$existing_host_project" ]]; then
      log_error "This workspace's service account already lives in '$existing_host_project'."
      log_info "Each workspace has exactly one service account — use a different workspace for a service account in a different host project."
      exit 1
    fi
    host_project="$existing_host_project"
  elif [[ -z "$host_project" ]]; then
    log_error "$usage"
    log_info "--host-project is required the first time you set up this workspace."
    exit 1
  fi

  ensure_gcloud_login

  local user_account
  user_account="$(gcloud config get-value account 2>/dev/null)"

  local sa_email
  if [[ -n "$existing_sa_email" ]]; then
    sa_email="$existing_sa_email"
  else
    # Derive a valid SA id (6-30 chars, lowercase alphanumeric + hyphen, starts with a letter) from the workspace name
    if [[ -z "$sa_id" ]]; then
      local base
      base="$(basename "$workspace" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
      sa_id="claude-yolo-${base}"
      sa_id="${sa_id:0:30}"
      sa_id="${sa_id%-}"
    fi
    sa_email="${sa_id}@${host_project}.iam.gserviceaccount.com"
  fi

  if gcloud iam service-accounts describe "$sa_email" --project "$host_project" &>/dev/null; then
    log_info "Service account already exists: $sa_email"
  else
    log_info "Creating service account $sa_email in $host_project..."
    gcloud iam service-accounts create "$sa_id" \
      --project "$host_project" \
      --display-name "claude-yolo: $(basename "$workspace")"
  fi

  log_info "Granting $user_account permission to impersonate $sa_email..."
  gcloud iam service-accounts add-iam-policy-binding "$sa_email" \
    --project "$host_project" \
    --member "user:$user_account" \
    --role "roles/iam.serviceAccountTokenCreator" >/dev/null

  IFS=',' read -ra projects <<<"$projects_csv"
  for project in "${projects[@]}"; do
    for role in "${roles[@]}"; do
      log_info "Granting $role on $project to $sa_email..."
      gcloud projects add-iam-policy-binding "$project" \
        --member "serviceAccount:$sa_email" \
        --role "$role" >/dev/null
    done
  done

  # Merge this run's project->roles into whatever's already recorded, rather than overwriting it —
  # devc gcp-create-service-account is meant to be re-run to add more projects/roles over time.
  local new_projects existing_projects merged_projects
  new_projects="$(jq -n \
    --argjson projects "$(printf '%s\n' "${projects[@]}" | jq -R . | jq -s 'unique')" \
    --argjson roles "$(printf '%s\n' "${roles[@]}" | jq -R . | jq -s 'unique')" \
    '[$projects[] | {(.): $roles}] | add')"
  # Tolerate manifests written by the old pre-merge schema (projects as a flat array
  # + a separate top-level roles array) by migrating them to {project: [roles]} on read.
  existing_projects="$([[ -f "$manifest" ]] && jq -c '
    if (.projects | type) == "object" then .projects
    elif (.projects | type) == "array" then
      ([ .projects[] as $p | { ($p): (.roles // ["roles/viewer"]) } ] | add // {})
    else {}
    end
  ' "$manifest" || echo '{}')"
  merged_projects="$(jq -n --argjson a "$existing_projects" --argjson b "$new_projects" '
    reduce (($a|keys) + ($b|keys) | unique)[] as $k
      ({}; . + {($k): ((($a[$k] // []) + ($b[$k] // [])) | unique)})
  ')"

  jq -n \
    --arg sa_email "$sa_email" \
    --arg host_project "$host_project" \
    --argjson projects "$merged_projects" \
    --arg created "$created" \
    --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{sa_email: $sa_email, host_project: $host_project, projects: $projects, created: $created, updated: $updated}' \
    >"$manifest"
  chmod 600 "$manifest"

  log_success "Service account ready: $sa_email"
  log_info "Full scope: $(jq -r '.projects | to_entries | map("\(.key) [\(.value | join(", "))]") | join("; ")' "$manifest")"
  log_info "IAM changes can take a few minutes to propagate — if 'devc gcp-creds' fails with PERMISSION_DENIED right away, wait a bit and retry."
  log_info "Run 'devc gcp-creds' to mint a token. Run 'devc rebuild' if this is the first time GCP credentials were added to this workspace."
}

cmd_gcp_creds() {
  local lifetime="3600"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --lifetime)
        lifetime="$2"
        shift 2
        ;;
      *)
        log_error "Unknown option: $1"
        log_info "Usage: devc gcp-creds [--lifetime SECONDS]"
        exit 1
        ;;
    esac
  done

  check_gcloud_cli
  ensure_gcloud_login

  local workspace
  workspace="$(get_workspace_folder)"
  local creds_dir="$workspace/Claude-Yolo-Creds/gcp"
  local manifest="$creds_dir/manifest.json"

  if [[ ! -f "$manifest" ]]; then
    log_error "No GCP service account configured for this workspace."
    log_info "Run 'devc gcp-create-service-account' first."
    exit 1
  fi

  local sa_email projects
  sa_email="$(jq -r '.sa_email' "$manifest")"
  projects="$(jq -r '.projects | to_entries | map("\(.key) [\(.value | join(", "))]") | join("; ")' "$manifest")"

  local token
  if ! token="$(gcloud auth print-access-token --impersonate-service-account="$sa_email" --lifetime="$lifetime" 2>&1)"; then
    log_error "Failed to mint a token for $sa_email"
    printf '%s\n' "$token" >&2
    log_info "If you just ran 'devc gcp-create-service-account', IAM changes can take a few minutes to propagate — wait and retry."
    log_info "Otherwise, re-run 'devc gcp-create-service-account' to (re-)grant your current account roles/iam.serviceAccountTokenCreator on this service account."
    exit 1
  fi

  local tmp
  tmp="$(mktemp "$creds_dir/.access_token.XXXXXX")"
  printf '%s' "$token" >"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$creds_dir/access_token"

  log_success "Minted token for $sa_email (expires in ${lifetime}s)"
  log_info "Scoped to: $projects"
}

cmd_bedrock_creds() {
  local region="" profile="" lifetime="28800"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --region)
        region="$2"
        shift 2
        ;;
      --profile)
        profile="$2"
        shift 2
        ;;
      --lifetime)
        lifetime="$2"
        shift 2
        ;;
      *)
        log_error "Unknown option: $1"
        log_info "Usage: devc bedrock-creds [--region REGION] [--profile PROFILE] [--lifetime SECONDS]"
        exit 1
        ;;
    esac
  done

  [[ -z "$region" ]] && region="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

  local workspace
  workspace="$(get_workspace_folder)"
  local creds_dir="$workspace/Claude-Yolo-Creds"
  if [[ ! -d "$creds_dir" ]]; then
    log_error "Claude-Yolo-Creds/ not found in $workspace"
    log_info "Run 'devc .' first to set up the workspace."
    exit 1
  fi

  # Only pass --profile through when explicitly given, so bedrock_creds.py's own default
  # (None) lets boto3 resolve AWS_DEFAULT_PROFILE/AWS_PROFILE/the config default itself,
  # instead of us shadowing that chain with a hardcoded "default" here.
  # (No array here: an empty array expands unsafely under `set -u` on bash 3.2, which is
  # what /bin/bash still is on macOS.)
  if [[ -n "$profile" ]]; then
    uv run "$SCRIPT_DIR/bedrock_creds.py" --region "$region" --profile "$profile" --lifetime "$lifetime" --creds-dir "$creds_dir"
  else
    uv run "$SCRIPT_DIR/bedrock_creds.py" --region "$region" --lifetime "$lifetime" --creds-dir "$creds_dir"
  fi
}

cmd_claude_bedrock() {
  local workspace
  workspace="$(get_workspace_folder)"

  check_devcontainer_cli

  local manifest="$workspace/Claude-Yolo-Creds/bedrock/manifest.json"
  if [[ ! -f "$manifest" ]]; then
    log_error "No Bedrock credentials configured for this workspace."
    log_info "Run 'devc bedrock-creds' first."
    exit 1
  fi

  local region
  region="$(jq -r '.region' "$manifest")"

  # CLAUDE_CODE_USE_BEDROCK and the bearer token are set inside the container's own shell,
  # not via --remote-env, so the token never appears as a devcontainer-exec argument on the host.
  # shellcheck disable=SC2016 # intentional: expanded by the container's bash, not this one
  devcontainer exec --workspace-folder "$workspace" \
    --remote-env AWS_REGION="$region" \
    /bin/bash -c 'CLAUDE_CODE_USE_BEDROCK=1 AWS_BEARER_TOKEN_BEDROCK="$(cat "$HOME/.bedrock/token")" exec /home/vscode/.local/bin/claude --dangerously-skip-permissions "$@"' -- "$@"
}

cmd_dot() {
  local target_dir
  target_dir="$(get_workspace_folder ".")"

  # Warn if running inside a git repo — workspaces normally live outside repos
  if [[ -d "$target_dir/.git" ]]; then
    log_warn "This directory is a git repository."
    log_warn "Workspaces normally live outside a repo. Claude-Yolo-Creds/ will be gitignored, but proceed with caution."
    read -p "Continue anyway? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      log_info "Aborted."
      exit 0
    fi
  fi

  cmd_template "."

  # Create credential directories (mounted read-only into the container)
  mkdir -p "$target_dir/Claude-Yolo-Creds/aws"
  mkdir -p "$target_dir/Claude-Yolo-Creds/ssh"
  mkdir -p "$target_dir/Claude-Yolo-Creds/gcp"
  mkdir -p "$target_dir/Claude-Yolo-Creds/bedrock"
  # Seed default AWS config — the bind mount overlays ~/.aws so the
  # Dockerfile-baked copy is hidden without a host-side file.
  if [[ ! -f "$target_dir/Claude-Yolo-Creds/aws/config" ]]; then
    cp "$SCRIPT_DIR/aws-config/config" "$target_dir/Claude-Yolo-Creds/aws/config"
    log_info "Copied default AWS config to Claude-Yolo-Creds/aws/config"
  fi
  log_success "Created Claude-Yolo-Creds/ (aws/, ssh/, gcp/, bedrock/)"

  # Belt-and-suspenders: add to local .gitignore in case global gitignore isn't set up
  local gitignore="$target_dir/.gitignore"
  if ! grep -qxF "Claude-Yolo-Creds/" "$gitignore" 2>/dev/null; then
    echo "Claude-Yolo-Creds/" >> "$gitignore"
    log_info "Added Claude-Yolo-Creds/ to .gitignore"
  fi

  cmd_up "."
}

# Discovers all Docker resources associated with the current workspace.
# Sets global variables: CONTAINER_ID, CONTAINER_STATUS, VOLUMES (array), IMAGE, IMAGE_UID
discover_resources() {
  local workspace_folder="$1"
  local label="devcontainer.local_folder=$workspace_folder"

  CONTAINER_ID=""
  CONTAINER_STATUS=""
  VOLUMES=()
  IMAGE=""
  IMAGE_UID=""

  # Find container (any state: running, stopped, created, etc.)
  CONTAINER_ID=$(docker ps -aq --filter "label=$label" 2>/dev/null | head -1)

  if [[ -z "$CONTAINER_ID" ]]; then
    return 0
  fi

  # Get container status
  CONTAINER_STATUS=$(docker inspect "$CONTAINER_ID" --format '{{.State.Status}}' 2>/dev/null || true)

  # Get volumes (docker volumes only, not bind mounts)
  while IFS= read -r vol; do
    [[ -n "$vol" ]] && VOLUMES+=("$vol")
  done < <(docker inspect "$CONTAINER_ID" --format '{{json .Mounts}}' 2>/dev/null \
    | jq -r '.[] | select(.Type == "volume") | .Name' 2>/dev/null)

  # Get image and its -uid variant
  IMAGE=$(docker inspect "$CONTAINER_ID" --format '{{.Config.Image}}' 2>/dev/null || true)
  if [[ -n "$IMAGE" ]]; then
    if [[ "$IMAGE" == *-uid ]]; then
      IMAGE_UID="$IMAGE"
      IMAGE="${IMAGE%-uid}"
    else
      IMAGE_UID="${IMAGE}-uid"
    fi
  fi
}

print_destroy_summary() {
  echo ""
  log_warn "The following resources will be permanently removed:"
  echo ""

  if [[ -n "$CONTAINER_ID" ]]; then
    local container_name
    container_name=$(docker inspect "$CONTAINER_ID" --format '{{.Name}}' 2>/dev/null | sed 's|^/||')
    echo "  Container:  ${container_name:-$CONTAINER_ID}"
    if [[ "$CONTAINER_STATUS" == "running" ]]; then
      echo "              (currently running -- will be force-stopped)"
    fi
  fi

  if [[ ${#VOLUMES[@]} -gt 0 ]]; then
    echo "  Volumes:"
    for vol in "${VOLUMES[@]}"; do
      echo "              $vol"
    done
  fi

  if [[ -n "$IMAGE" ]]; then
    echo "  Image:      $IMAGE"
    if docker image inspect "$IMAGE_UID" &>/dev/null; then
      echo "              $IMAGE_UID"
    fi
  fi

  echo ""
}

cmd_destroy() {
  local force=false

  # Parse flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--force)
        force=true
        shift
        ;;
      *)
        break
        ;;
    esac
  done

  local workspace_folder
  workspace_folder="$(get_workspace_folder "${1:-}")"

  discover_resources "$workspace_folder"

  # No resources found (idempotent behavior)
  if [[ -z "$CONTAINER_ID" ]]; then
    log_info "No devcontainer found for $workspace_folder"
    return 0
  fi

  print_destroy_summary

  # Running container warning
  if [[ "$CONTAINER_STATUS" == "running" && "$force" != true ]]; then
    log_warn "Container is currently running!"
    read -p "Force-stop the running container? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      log_info "Aborted."
      return 0
    fi
  fi

  # Main confirmation prompt
  if [[ "$force" != true ]]; then
    read -p "Destroy these resources? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      log_info "Aborted."
      return 0
    fi
  fi

  # Deletion, in order: stop, remove container, volumes, images
  if [[ -n "$CONTAINER_ID" && "$CONTAINER_STATUS" == "running" ]]; then
    log_info "Stopping container..."
    docker stop "$CONTAINER_ID" >/dev/null 2>&1 || true
  fi

  if [[ -n "$CONTAINER_ID" ]]; then
    log_info "Removing container..."
    docker rm -f "$CONTAINER_ID" >/dev/null 2>&1 || true
  fi

  if [[ ${#VOLUMES[@]} -gt 0 ]]; then
    for vol in "${VOLUMES[@]}"; do
      log_info "Removing volume: $vol"
      docker volume rm -f "$vol" >/dev/null 2>&1 || true
    done
  fi

  if [[ -n "$IMAGE" ]]; then
    log_info "Removing image: $IMAGE"
    docker rmi -f "$IMAGE" >/dev/null 2>&1 || true
    if docker image inspect "$IMAGE_UID" &>/dev/null 2>&1; then
      log_info "Removing image: $IMAGE_UID"
      docker rmi -f "$IMAGE_UID" >/dev/null 2>&1 || true
    fi
  fi

  log_success "All resources destroyed for $workspace_folder"
}

# Main command dispatcher
main() {
  if [[ $# -eq 0 ]]; then
    print_usage
    exit 1
  fi

  local command="$1"
  shift

  case "$command" in
  .)
    cmd_dot
    ;;
  claude)
    [[ "${1:-}" == "--" ]] && shift
    cmd_exec "/home/vscode/.local/bin/claude" "--dangerously-skip-permissions" "--remote-control" "$@"
    ;;
  claude-bedrock)
    [[ "${1:-}" == "--" ]] && shift
    cmd_claude_bedrock "$@"
    ;;
  up)
    cmd_up "$@"
    ;;
  rebuild)
    cmd_rebuild "$@"
    ;;
  down)
    cmd_down "$@"
    ;;
  list | ls)
    cmd_list "$@"
    ;;
  destroy)
    cmd_destroy "$@"
    ;;
  shell)
    cmd_shell
    ;;
  exec)
    [[ "${1:-}" == "--" ]] && shift
    cmd_exec "$@"
    ;;
  upgrade)
    cmd_upgrade
    ;;
  mount)
    cmd_mount "$@"
    ;;
  sync)
    cmd_sync "$@"
    ;;
  cp)
    cmd_cp "$@"
    ;;
  self-install)
    cmd_self_install
    ;;
  update)
    cmd_update
    ;;
  template)
    cmd_template "$@"
    ;;
  aws-creds)
    cmd_aws_creds "$@"
    ;;
  refresh-aws-creds)
    cmd_refresh_aws_creds "$@"
    ;;
  gcp-create-service-account)
    cmd_gcp_create_service_account "$@"
    ;;
  gcp-creds)
    cmd_gcp_creds "$@"
    ;;
  bedrock-creds)
    cmd_bedrock_creds "$@"
    ;;
  help | --help | -h)
    print_usage
    ;;
  *)
    log_error "Unknown command: $command"
    print_usage
    exit 1
    ;;
  esac
}

main "$@"
