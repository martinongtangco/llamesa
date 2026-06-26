#!/usr/bin/env bash
# LLaMesa — local inference control plane
# Server-side manager for Bazzite Linux with llama.cpp
# License: MIT

set -euo pipefail

# ── Paths ────────────────────────────────────────────────────────────────
LLAMESA_DIR="${HOME}/.llamesa"
CONFIG_FILE="${LLAMESA_DIR}/config.json"
SERVER_PID_FILE="${LLAMESA_DIR}/server.pid"
SERVER_LOG_FILE="${LLAMESA_DIR}/server.log"

# ── Helpers ──────────────────────────────────────────────────────────────

# Parse a value from JSON (simple regex-based parser, no jq dependency)
json_get() {
    local key="$1"
    local file="${2:-$CONFIG_FILE}"
    grep -o "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" 2>/dev/null | \
        head -1 | sed 's/.*"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/'
}

json_get_raw() {
    local key="$1"
    local file="${2:-$CONFIG_FILE}"
    grep -o "\"${key}\"[[:space:]]*:[[:space:]]*[^,}]*" "$file" 2>/dev/null | \
        head -1 | sed 's/.*"[[:space:]]*:[[:space:]]*//' | tr -d ' "'
}

error() {
    echo -e "\033[31m[ERROR]\033[0m $*" >&2
    exit 1
}

info() {
    echo -e "\033[32m[INFO]\033[0m $*" >&2
}

warn() {
    echo -e "\033[33m[WARN]\033[0m $*" >&2
}

# Check that config exists
check_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        error "Config not found at ${CONFIG_FILE}. Run install.sh first."
    fi
}

# Read config values
read_config() {
    check_config
    MODELS_DIR=$(json_get "models_dir")
    LLAMA_BINARY=$(json_get "llama_binary")
    CONTAINER=$(json_get "distrobox_container")
    DEFAULT_CTX=$(json_get_raw "default_context")
    DEFAULT_GPU_LAYERS=$(json_get_raw "default_gpu_layers")
    DEFAULT_THINKING=$(json_get_raw "default_thinking")
    PORT=$(json_get_raw "port")

    # Defaults if missing
    MODELS_DIR="${MODELS_DIR:-/var/mnt/games/models}"
    LLAMA_BINARY="${LLAMA_BINARY:-}"
    CONTAINER="${CONTAINER:-rocm-r9700}"
    DEFAULT_CTX="${DEFAULT_CTX:-131072}"
    DEFAULT_GPU_LAYERS="${DEFAULT_GPU_LAYERS:-99}"
    DEFAULT_THINKING="${DEFAULT_THINKING:-true}"
    PORT="${PORT:-1234}"
}

# Ensure the distrobox container is running; start it if not
ensure_container_running() {
    local container_id
    container_id=$(podman ps --filter "name=^${CONTAINER}$" --format "{{.ID}}" 2>/dev/null | head -1)
    if [[ -z "$container_id" ]]; then
        info "Container '${CONTAINER}' is not running, starting it..."
        distrobox enter -T "$CONTAINER" -- bash -c "echo container ready" >/dev/null 2>&1 || true
        sleep 2
        container_id=$(podman ps --filter "name=^${CONTAINER}$" --format "{{.ID}}" 2>/dev/null | head -1)
        if [[ -z "$container_id" ]]; then
            error "Failed to start container '${CONTAINER}'. Run: distrobox enter ${CONTAINER}"
        fi
    fi
    echo "$container_id"
}

# Run a command inside the distrobox container
run_in_container() {
    local cmd="$1"
    ensure_container_running >/dev/null
    distrobox enter -T "$CONTAINER" -- bash -c "$cmd"
}

# Launch a detached daemon inside the container via podman exec -d
run_in_container_detached() {
    local cmd="$1"
    local container_id
    container_id=$(ensure_container_running)
    podman exec -d "$container_id" bash -c "$cmd"
}

# Check if server is running
is_server_running() {
    if [[ -f "$SERVER_PID_FILE" ]]; then
        local pid
        pid=$(cat "$SERVER_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo "$pid"
            return 0
        fi
    fi

    # Fallback: check if llama-server is listening on the port
    read_config 2>/dev/null || return 1
    if ss -tlnp 2>/dev/null | grep -q ":${PORT:-1234}"; then
        info "Server detected on port ${PORT:-1234} (PID file missing)"
        return 0
    fi

    return 1
}

# ── Commands ─────────────────────────────────────────────────────────────

cmd_list_models() {
    read_config
    local models_dir="$MODELS_DIR"

    if [[ ! -d "$models_dir" ]]; then
        error "Models directory not found: ${models_dir}"
    fi

    # Collect model data
    local -a model_entries=()
    local -A seen_dirs=()

    # Find all .gguf files that are NOT mmproj files
    while IFS= read -r gguf_file; do
        [[ -z "$gguf_file" ]] && continue

        # Skip mmproj files
        local basename
        basename=$(basename "$gguf_file")
        [[ "$basename" == mmproj-* ]] && continue

        local model_dir
        model_dir=$(dirname "$gguf_file")
        local dir_name
        dir_name=$(basename "$model_dir")

        # Skip if we already processed this directory
        if [[ -n "${seen_dirs[$dir_name]:-}" ]]; then
            continue
        fi
        seen_dirs[$dir_name]=1

        # Get file size
        local size_bytes
        size_bytes=$(stat -c%s "$gguf_file" 2>/dev/null || echo "0")

        # Check for mmproj in same directory
        local has_mmproj="false"
        local mmproj_path=""
        local mmproj_file
        mmproj_file=$(find "$model_dir" -maxdepth 1 -name "mmproj-*.gguf" 2>/dev/null | head -1)
        if [[ -n "$mmproj_file" ]]; then
            has_mmproj="true"
            mmproj_path="$mmproj_file"
        fi

        model_entries+=("{\"name\":\"${dir_name}\",\"path\":\"${gguf_file}\",\"size_bytes\":${size_bytes},\"has_mmproj\":${has_mmproj},\"mmproj_path\":\"${mmproj_path}\"}")

    done < <(find "$models_dir" -name "*.gguf" -type f 2>/dev/null | sort)

    # Output as JSON array
    if [[ ${#model_entries[@]} -eq 0 ]]; then
        echo "[]"
    else
        echo "["
        local i=0
        local total=${#model_entries[@]}
        for entry in "${model_entries[@]}"; do
            i=$((i + 1))
            if [[ $i -lt $total ]]; then
                echo "  ${entry},"
            else
                echo "  ${entry}"
            fi
        done
        echo "]"
    fi
}

cmd_status() {
    read_config

    local running=false
    local pid=""
    local model="none"
    local mmproj="false"
    local thinking="false"
    local ctx="0"

    if pid=$(is_server_running 2>/dev/null); then
        running=true

        # Try to get info from the /health endpoint
        local health_response
        if health_response=$(curl -s --max-time 3 "http://localhost:${PORT}/health" 2>/dev/null); then
            # Parse mux.LLM version or other health info
            info "Server healthy on port ${PORT}" >&2
        fi

        # Try to get model info from /v1/models endpoint
        local models_response
        if models_response=$(curl -s --max-time 3 "http://localhost:${PORT}/v1/models" 2>/dev/null); then
            # Extract model name from response
            model=$(echo "$models_response" | grep -o '"id": *"[^"]*"' | head -1 | grep -o '"[^"]*"$' | tr -d '"' || echo "unknown")
            [[ -z "$model" ]] && model="unknown"
        fi

        # Try to get stats from /health endpoint for GPU info
        local vram_used=0
        local vram_total=0
        local gpu_busy=0
        local cpu_percent=0
        local ram_used=0
        local ram_total=0

        # Get VRAM usage from rocm-smi inside container via podman exec
        local container_id
        container_id=$(podman ps --filter "name=^${CONTAINER}$" --format "{{.ID}}" 2>/dev/null | head -1 || true)
        if [[ -n "$container_id" ]]; then
            local rocm_output
            if rocm_output=$(podman exec "$container_id" bash -c "rocm-smi --showmeminfo vram 2>/dev/null" 2>/dev/null); then
                local used_bytes total_bytes
                used_bytes=$(echo "$rocm_output" | grep -i "VRAM Total Used Memory" | grep -o '[0-9]*$' || echo "")
                total_bytes=$(echo "$rocm_output" | grep -i "VRAM Total Memory (B)" | grep -v "Used" | grep -o '[0-9]*$' || echo "")
                if [[ -n "$used_bytes" ]]; then
                    vram_used=$used_bytes
                fi
                if [[ -n "$total_bytes" ]]; then
                    vram_total=$total_bytes
                fi
            fi
        fi

        # CPU and RAM from standard tools
        cpu_percent=$(top -bn1 2>/dev/null | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1 || echo "0")
        ram_used=$(free -m 2>/dev/null | awk '/^Mem:/{print $3}' || echo "0")
        ram_total=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || echo "0")

        # Calculate uptime from PID
        local uptime_str="00:00:00"
        if [[ -n "$pid" ]] && [[ -d "/proc/$pid" ]]; then
            local start_time
            start_time=$(stat -c%Y "/proc/$pid" 2>/dev/null || echo "0")
            local now
            now=$(date +%s)
            local elapsed=$((now - start_time))
            local hours=$((elapsed / 3600))
            local minutes=$(( (elapsed % 3600) / 60 ))
            local seconds=$((elapsed % 60))
            uptime_str=$(printf "%02d:%02d:%02d" $hours $minutes $seconds)
        fi

        # Read last start args from log
        if [[ -f "$SERVER_LOG_FILE" ]]; then
            thinking=$(tail -5 "$SERVER_LOG_FILE" 2>/dev/null | grep -o 'Thinking: \(true\|false\)' | head -1 | awk '{print $2}' || echo "false")
            ctx=$(tail -5 "$SERVER_LOG_FILE" 2>/dev/null | grep -o 'Context: [0-9]*' | head -1 | awk '{print $2}' || echo "0")
        fi

        # Check mmproj from start log
        if [[ -f "$SERVER_LOG_FILE" ]]; then
            mmproj=$(grep -q '\-\-mmproj' "$SERVER_LOG_FILE" 2>/dev/null && echo "true" || echo "false")
        fi

        # Output JSON status
        cat <<EOF
{
  "running": ${running},
  "model": "${model}",
  "mmproj": ${mmproj},
  "thinking": ${thinking},
  "ctx": ${ctx:-0},
  "port": ${PORT},
  "uptime": "${uptime_str}",
  "vram_used_bytes": ${vram_used},
  "vram_total_bytes": ${vram_total},
  "gpu_busy_percent": ${gpu_busy},
  "cpu_percent": ${cpu_percent:-0},
  "ram_used_mb": ${ram_used:-0},
  "ram_total_mb": ${ram_total:-0}
}
EOF
    else
        # Server not running
        cat <<EOF
{
  "running": false,
  "model": "none",
  "mmproj": false,
  "thinking": false,
  "ctx": 0,
  "port": ${PORT},
  "uptime": "00:00:00",
  "vram_used_bytes": 0,
  "vram_total_bytes": 0,
  "gpu_busy_percent": 0,
  "cpu_percent": 0,
  "ram_used_mb": 0,
  "ram_total_mb": 0
}
EOF
    fi
}

cmd_start() {
    read_config

    local model_name=""
    local thinking="$DEFAULT_THINKING"
    local ctx="$DEFAULT_CTX"
    local gpu_layers="$DEFAULT_GPU_LAYERS"
    local port_override=""

    # Parse CLI args
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --model) model_name="$2"; shift 2 ;;
            --thinking) thinking="$2"; shift 2 ;;
            --ctx) ctx="$2"; shift 2 ;;
            --gpu-layers) gpu_layers="$2"; shift 2 ;;
            --port) port_override="$2"; shift 2 ;;
            *) error "Unknown option: $1" ;;
        esac
    done

    # Normalize thinking to JSON boolean (accept on/off/yes/no/true/false/1/0)
    case "$thinking" in
        on|yes|1|true)  thinking="true" ;;
        off|no|0|false) thinking="false" ;;
        *) thinking="false" ;;
    esac

    local use_port="${port_override:-$PORT}"

    if [[ -z "$model_name" ]]; then
        error "Model name required. Use --model <name>"
    fi

    # Check if server is already running
    if is_server_running >/dev/null 2>&1; then
        warn "Server is already running. Use 'restart' to change models."
        cmd_stop
    fi

    # Find the model file
    local model_file=""
    local model_dir_path=""

    # Search in models_dir for a matching model
    while IFS= read -r candidate; do
        local bname
        bname=$(basename "$candidate")
        [[ "$bname" == mmproj-* ]] && continue
        local dname
        dname=$(basename "$(dirname "$candidate")")
        if [[ "$dname" == "$model_name" ]]; then
            model_file="$candidate"
            model_dir_path=$(dirname "$candidate")
            break
        fi
    done < <(find "$MODELS_DIR" -name "*.gguf" -type f 2>/dev/null)

    if [[ -z "$model_file" ]]; then
        # Try direct path
        if [[ -f "$model_name" ]]; then
            model_file="$model_name"
            model_dir_path=$(dirname "$model_file")
        else
            error "Model not found: ${model_name}. Run 'list-models' to see available models."
        fi
    fi

    info "Starting server with model: ${model_file}"

    # Build llama-server command
    local cmd_args=(
        "$LLAMA_BINARY"
        "--model" "$model_file"
        "--ctx-size" "$ctx"
        "--n-gpu-layers" "$gpu_layers"
        "--port" "$use_port"
        "--host" "0.0.0.0"
        "--log-file" "/tmp/llama-server.log"
    )

    # Add mmproj if found
    local mmproj_file=""
    if [[ -n "$model_dir_path" ]]; then
        mmproj_file=$(find "$model_dir_path" -maxdepth 1 -name "mmproj-*.gguf" 2>/dev/null | head -1)
    fi

    if [[ -n "$mmproj_file" ]]; then
        cmd_args+=("--mmproj" "$mmproj_file")
        mmproj="true"
        info "Multi-modal projector loaded: ${mmproj_file}"
    fi

    # Thinking mode for Qwen3 is controlled via system prompt at inference time, not a server flag.
    if [[ "$thinking" == "true" ]]; then
        info "Thinking mode enabled (handled via chat template)"
    fi

    # Log the start command
    mkdir -p "$LLAMESA_DIR"
    {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting: ${cmd_args[*]}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Model: ${model_file}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Context: ${ctx}, GPU Layers: ${gpu_layers}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Thinking: ${thinking}, mmproj: ${mmproj:-false}"
    } > "$SERVER_LOG_FILE"

    # Launch in container
    local full_cmd="${cmd_args[*]}"
    info "Launching llama-server in container '${CONTAINER}'..."

    # Start server as detached daemon via podman exec -d (survives distrobox session exit)
    run_in_container_detached "${full_cmd} >> ${SERVER_LOG_FILE} 2>&1"
    sleep 1
    # Get the PID of the launched process
    local server_pid
    server_pid=$(distrobox enter -T "$CONTAINER" -- bash -c "pgrep -f 'llama-server.*${use_port}' | head -1" 2>/dev/null || true)
    if [[ -n "$server_pid" ]]; then
        echo "$server_pid" > "$SERVER_PID_FILE"
        info "Server started with PID ${server_pid}"
    else
        info "Server launched (PID unavailable)"
    fi

    # Wait for server to be ready
    info "Waiting for server to be ready on port ${use_port}..."
    info "Large models may take 1-5 minutes to load. Use 'llamesa.sh logs' to monitor."
    local max_wait=300
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        if curl -s --max-time 2 "http://localhost:${use_port}/health" >/dev/null 2>&1; then
            info "Server is ready!"
            # Persist session for restart
            cat > "${LLAMESA_DIR}/last_session.json" <<EOF
{
  "model": "${model_name}",
  "thinking": ${thinking},
  "ctx": ${ctx},
  "gpu_layers": ${gpu_layers},
  "port": ${use_port}
}
EOF
            cmd_status
            return 0
        fi
        if [[ $((waited % 30)) -eq 0 ]] && [[ $waited -gt 0 ]]; then
            info "Still loading... (${waited}s elapsed)"
        fi
        sleep 2
        waited=$((waited + 2))
    done

    warn "Server did not respond after ${max_wait}s. Check logs with 'llamesa.sh logs'"
    return 1
}

cmd_stop() {
    read_config

    if ! is_server_running >/dev/null 2>&1; then
        info "Server is not running."
        echo '{"running":false}'
        return 0
    fi

    info "Stopping llama-server inside container '${CONTAINER}'..."
    local container_id
    container_id=$(podman ps --filter "name=^${CONTAINER}$" --format "{{.ID}}" 2>/dev/null | head -1)

    if [[ -n "$container_id" ]]; then
        podman exec "$container_id" bash -c "pkill -f 'llama-server' 2>/dev/null || true"
        sleep 2
        # Force kill if still running
        podman exec "$container_id" bash -c "pkill -9 -f 'llama-server' 2>/dev/null || true"
    fi

    rm -f "$SERVER_PID_FILE"
    info "Server stopped."
    echo '{"running":false}'
}

cmd_restart() {
    read_config
    info "Restarting server..."

    local session_file="${LLAMESA_DIR}/last_session.json"
    if [[ ! -f "$session_file" ]]; then
        error "No previous session found. Use 'start --model <name>' instead."
    fi

    # Read last session settings
    local model_name thinking ctx
    model_name=$(grep -o '"model": *"[^"]*"' "$session_file" | grep -o '"[^"]*"$' | tr -d '"' || echo "")
    thinking=$(grep -o '"thinking": *[^,}]*' "$session_file" | awk '{print $2}' || echo "true")
    ctx=$(grep -o '"ctx": *[0-9]*' "$session_file" | awk '{print $2}' || echo "131072")

    if [[ -z "$model_name" ]]; then
        error "Could not read model from last session. Use 'start --model <name>' instead."
    fi

    info "Restarting with: model=${model_name} thinking=${thinking} ctx=${ctx}"
    cmd_stop
    sleep 3
    cmd_start --model "$model_name" --thinking "$thinking" --ctx "$ctx"
}

cmd_logs() {
    read_config

    if [[ ! -f "$SERVER_LOG_FILE" ]]; then
        warn "No log file found at ${SERVER_LOG_FILE}"
        return 1
    fi

    # Stream logs using tail -f
    tail -f "$SERVER_LOG_FILE"
}

cmd_download() {
    local repo=""
    local file_pattern=""
    local list_only=false

    # Parse CLI args
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo) repo="$2"; shift 2 ;;
            --file) file_pattern="$2"; shift 2 ;;
            --list) list_only=true; shift ;;
            *) error "Unknown option: $1" ;;
        esac
    done

    read_config

    if [[ -z "$repo" ]]; then
        error "Repository required. Use --repo <huggingface_repo_id>"
    fi

    info "Processing download request for: ${repo}"

    # Derive target directory from repo name
    local repo_name
    repo_name=$(echo "$repo" | awk -F'/' '{print $NF}')
    local target_dir="${MODELS_DIR}/${repo_name}"

    if [[ "$list_only" == "true" ]]; then
        # List available files using huggingface_hub
        info "Listing files in ${repo}..."
        run_in_container "python3 -c \"
from huggingface_hub import list_repo_files
import json

files = list(list_repo_files('${repo}', revision='main'))
gguf_files = [f for f in files if f.endswith('.gguf')]

for f in sorted(gguf_files):
    print(f)
\""
        return 0
    fi

    # Download with progress
    mkdir -p "$target_dir"

    if [[ -n "$file_pattern" ]]; then
        info "Downloading matching files to ${target_dir}..."
        run_in_container "python3 -c \"
from huggingface_hub import hf_hub_download, list_repo_files
import glob
import os

repo_id = '${repo}'
pattern = '${file_pattern}'
target_dir = '${target_dir}'

files = list(list_repo_files(repo_id, revision='main'))
matches = [f for f in files if f.endswith('.gguf')]

# Simple pattern matching
import fnmatch
matches = [f for f in matches if fnmatch.fnmatch(f, pattern)]

if not matches:
    print(f'No files matching pattern: {pattern}')
    exit(1)

for f in matches:
    print(f'Downloading: {{f}}')
    hf_hub_download(repo_id=repo_id, filename=f, local_dir=target_dir, local_dir_use_symlinks=False)
    print(f'  Done: {{f}}')

print(f'Downloaded {{len(matches)}} file(s) to {{target_dir}}')
\""
    else
        # List files and let user pick (interactive mode)
        info "Available GGUF files:"
        local files
        files=$(run_in_container "python3 -c \"
from huggingface_hub import list_repo_files
files = list(list_repo_files('${repo}', revision='main'))
gguf_files = [f for f in files if f.endswith('.gguf')]
for i, f in enumerate(sorted(gguf_files)):
    print(f'{{i+1}}. {{f}}')
\"")

        echo "$files"
        echo ""
        read -p "Enter file number (0 to cancel): " choice

        if [[ "$choice" == "0" ]]; then
            info "Download cancelled."
            return 0
        fi

        # Get the selected filename
        local selected_file
        selected_file=$(echo "$files" | sed -n "${choice}p" | awk '{print $2}')

        if [[ -z "$selected_file" ]]; then
            error "Invalid selection."
        fi

        info "Downloading ${selected_file}..."
        run_in_container "python3 -c \"
from huggingface_hub import hf_hub_download
hf_hub_download(repo_id='${repo}', filename='${selected_file}', local_dir='${target_dir}', local_dir_use_symlinks=False)
print('Download complete.')
\""

        # Check for mmproj files
        info "Checking for mmproj files..."
        local mmproj_files
        mmproj_files=$(run_in_container "python3 -c \"
from huggingface_hub import list_repo_files
files = list(list_repo_files('${repo}', revision='main'))
mmprojs = [f for f in files if 'mmproj' in f]
for f in mmprojs:
    print(f)
\"")

        if [[ -n "$mmproj_files" ]]; then
            echo "Found mmproj files:"
            echo "$mmproj_files"
            read -p "Download mmproj? (y/N): " download_mmproj
            if [[ "$download_mmproj" == "y" ]] || [[ "$download_mmproj" == "Y" ]]; then
                local mmproj_file
                mmproj_file=$(echo "$mmproj_files" | head -1)
                info "Downloading ${mmproj_file}..."
                run_in_container "python3 -c \"
from huggingface_hub import hf_hub_download
hf_hub_download(repo_id='${repo}', filename='${mmproj_file}', local_dir='${target_dir}', local_dir_use_symlinks=False)
print('mmproj downloaded.')
\""
            fi
        fi
    fi

    info "Download complete. Models in: ${target_dir}"
}

# ── Main ─────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
LLaMesa — local inference control plane v0.1

Usage: llamesa.sh <command> [options]

Commands:
  start       Start the inference server
    --model <name>      Model name (required)
    --thinking <bool>   Enable thinking mode (default: ${DEFAULT_THINKING:-true})
    --ctx <n>           Context size (default: ${DEFAULT_CTX:-131072})
    --gpu-layers <n>    GPU layers (default: ${DEFAULT_GPU_LAYERS:-99})
    --port <n>          Override port

  stop        Stop the inference server
  restart     Restart with current or new settings
  status      Show server status as JSON
  list-models List available models as JSON
  logs        Stream server logs
  download    Download a model from HuggingFace
    --repo <id>         HuggingFace repo ID (required)
    --file <pattern>    Filename glob pattern
    --list              List available files only

  help        Show this help message

Config: ~/.llamesa/config.json
EOF
}

main() {
    if [[ $# -eq 0 ]]; then
        usage
        exit 0
    fi

    local command="$1"
    shift

    case "$command" in
        start)       cmd_start "$@" ;;
        stop)        cmd_stop "$@" ;;
        restart)     cmd_restart "$@" ;;
        status)      cmd_status "$@" ;;
        list-models) cmd_list_models "$@" ;;
        logs)        cmd_logs "$@" ;;
        download)    cmd_download "$@" ;;
        help|--help|-h) usage ;;
        *)           error "Unknown command: ${command}. Run 'llamesa.sh help' for usage." ;;
    esac
}

main "$@"