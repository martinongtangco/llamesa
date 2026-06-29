#!/usr/bin/env bash
# LLaMesa — local inference control plane
# Server-side manager for Bazzite Linux with llama.cpp
# License: MIT

set -euo pipefail

# ── Global GPU selection ───────────────────────────────────────────────────
# Parse --gpu before everything else so all downstream logic can use GPU_ID
GPU_ID=0
_remaining_args=()
_i=0
_args=("$@")
while [[ $_i -lt ${#_args[@]} ]]; do
    if [[ "${_args[$_i]}" == "--gpu" ]]; then
        _i=$(( _i + 1 ))
        _gpu_val="${_args[$_i]:-}"
        if [[ "$_gpu_val" != "all" ]] && ! [[ "$_gpu_val" =~ ^[0-9]+$ ]]; then
            echo "[ERROR] Invalid GPU ID: $_gpu_val. Use 0, 1, or 'all'." >&2
            exit 1
        fi
        GPU_ID="$_gpu_val"
    else
        _remaining_args+=("${_args[$_i]}")
    fi
    _i=$(( _i + 1 ))
done
set -- "${_remaining_args[@]+"${_remaining_args[@]}"}"

# ── Paths ────────────────────────────────────────────────────────────────
LLAMESA_DIR="${HOME}/.llamesa"
CONFIG_FILE="${LLAMESA_DIR}/config.json"
_pid_gpu_id="${GPU_ID}"
[[ "$_pid_gpu_id" == "all" ]] && _pid_gpu_id=0
PID_FILE="${LLAMESA_DIR}/server-gpu${_pid_gpu_id}.pid"
LOG_FILE="${LLAMESA_DIR}/server-gpu${_pid_gpu_id}.log"

# Backward compat aliases — old code paths reference these names
SERVER_PID_FILE="$PID_FILE"
SERVER_LOG_FILE="$LOG_FILE"

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
    MODELS_DIR=$(jq -r '.models_dir // "/var/mnt/games/models"' "$CONFIG_FILE")
    LLAMA_BINARY=$(jq -r '.llama_binary // ""' "$CONFIG_FILE")
    CONTAINER=$(jq -r '.distrobox_container // "rocm-r9700"' "$CONFIG_FILE")
    DEFAULT_CTX=$(jq -r '.default_context // 131072' "$CONFIG_FILE")
    DEFAULT_GPU_LAYERS=$(jq -r '.default_gpu_layers // 99' "$CONFIG_FILE")
    DEFAULT_THINKING=$(jq -r '.default_thinking // true' "$CONFIG_FILE")


    # Backward compat: if gpus array exists, use GPU-specific port; otherwise fall back to legacy port field
    local has_gpus
    has_gpus=$(jq -r '.gpus // empty' "$CONFIG_FILE" 2>/dev/null || true)
    if [[ -n "$has_gpus" ]]; then
        local _gc_id="${GPU_ID:-0}"
        [[ "$_gc_id" == "all" ]] && _gc_id=0
        get_gpu_config "$_gc_id"
    else
        # Legacy single-port config
        PORT=$(json_get_raw "port")
        PORT="${PORT:-1234}"
        warn "Legacy config detected — single GPU mode. Consider running install.sh to upgrade."
        # Set GPU vars from legacy config for compatibility
        GPU_PORT="$PORT"
        GPU_NAME="GPU0"
        GPU_HIP_DEVICE=0
        GPU_DRM_CARD=0
        GPU_ENV=""
    fi
}

# Extract a GPU entry from config by ID. Populates GPU_PORT, GPU_NAME,
# GPU_HIP_DEVICE, GPU_DRM_CARD, and GPU_ENV.
get_gpu_config() {
    local gpu_id="${1:-0}"
    GPU_PORT=$(jq -r --argjson id "$gpu_id" '.gpus[] | select(.id == $id) | .port // 1234' "$CONFIG_FILE" 2>/dev/null)
    GPU_NAME=$(jq -r --argjson id "$gpu_id" '.gpus[] | select(.id == $id) | .name // "GPU${id}"' "$CONFIG_FILE" 2>/dev/null)
    GPU_HIP_DEVICE=$(jq -r --argjson id "$gpu_id" '.gpus[] | select(.id == $id) | .hip_device // $id' "$CONFIG_FILE" 2>/dev/null)
    GPU_DRM_CARD=$(jq -r --argjson id "$gpu_id" '.gpus[] | select(.id == $id) | .drm_card // $id' "$CONFIG_FILE" 2>/dev/null)

    # Build newline-separated export lines from .env object
    GPU_ENV=$(jq -r --argjson id "$gpu_id" '.gpus[] | select(.id == $id) | .env // {} | to_entries[] | "\(.key)=\(.value)"' "$CONFIG_FILE" 2>/dev/null || true)

    # Defaults
    GPU_PORT="${GPU_PORT:-1234}"
    GPU_NAME="${GPU_NAME:-GPU${gpu_id}}"
    GPU_HIP_DEVICE="${GPU_HIP_DEVICE:-$gpu_id}"
    GPU_DRM_CARD="${GPU_DRM_CARD:-$gpu_id}"
}

# GPU-aware port — used throughout the script
gpu_port() {
    echo "${GPU_PORT:-${PORT:-1234}}"
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
    local _check_port
    _check_port=$(gpu_port)
    if ss -tlnp 2>/dev/null | grep -q ":${_check_port}"; then
        info "Server detected on port ${_check_port} (PID file missing)"
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
    if [[ "$GPU_ID" == "all" ]]; then
        local gpu_count
        gpu_count=$(jq '.gpus | length' "$CONFIG_FILE" 2>/dev/null || echo "1")
        local -a gpu_statuses=()
        for _gid in $(seq 0 $((gpu_count - 1))); do
            gpu_statuses+=("$(cmd_status_single_gpu "$_gid")")
        done
        local total=${#gpu_statuses[@]}
        local i=0
        echo "["
        for entry in "${gpu_statuses[@]}"; do
            i=$((i + 1))
            if [[ $i -lt $total ]]; then
                echo "  ${entry},"
            else
                echo "  ${entry}"
            fi
        done
        echo "]"
        return 0
    fi
    cmd_status_single_gpu "${GPU_ID}"
}

cmd_status_single_gpu() {
    local _sg_id="${1:-0}"
    get_gpu_config "$_sg_id"
    local running=false pid="" model="none" mmproj="false" thinking="false" ctx="0"
    local _sg_port; _sg_port=$(gpu_port)
    local _sg_pid_file="${LLAMESA_DIR}/server-gpu${_sg_id}.pid"
    local _sg_log_file="${LLAMESA_DIR}/server-gpu${_sg_id}.log"
    if [[ -f "$_sg_pid_file" ]]; then
        pid=$(cat "$_sg_pid_file")
        if kill -0 "$pid" 2>/dev/null; then running=true; fi
    fi
    if [[ "$running" == "false" ]] && ss -tlnp 2>/dev/null | grep -q ":${_sg_port}"; then
        running=true
    fi
    if [[ "$running" == "true" ]]; then
        local health_response
        if health_response=$(curl -s --max-time 3 "http://localhost:${_sg_port}/health" 2>/dev/null); then
            info "Server healthy on port ${_sg_port} (GPU ${GPU_NAME})"
        fi
        local models_response
        if models_response=$(curl -s --max-time 3 "http://localhost:${_sg_port}/v1/models" 2>/dev/null); then
            local model_file
            model_file=$(echo "$models_response" | grep -o '"id": *"[^"]*"' | head -1 | grep -o '"[^"]*"$' | tr -d '"' || echo "")
            if [[ -n "$model_file" ]]; then
                local model_path
                model_path=$(find "$MODELS_DIR" -name "$model_file" -type f 2>/dev/null | head -1 || true)
                if [[ -n "$model_path" ]]; then model=$(basename "$(dirname "$model_path")")
                else model="$model_file"; fi
            else model="unknown"; fi
            local ctx_val
            ctx_val=$(echo "$models_response" | grep -o '"n_ctx": *[0-9]*' | grep -o '[0-9]*$' | head -1 || true)
            [[ -n "$ctx_val" ]] && ctx="$ctx_val"
        fi
        if [[ -f "${LLAMESA_DIR}/last_session.json" ]]; then
            local sess_thinking
            sess_thinking=$(grep -o '"thinking": *[^,}]*' "${LLAMESA_DIR}/last_session.json" | awk '{print $2}' | tr -d ' \r\n' || true)
            [[ "$sess_thinking" == "true" || "$sess_thinking" == "false" ]] && thinking="$sess_thinking"
        fi
        local vram_used=0 vram_total=0 gpu_busy=0 cpu_percent=0 ram_used=0 ram_total=0
        local drm_path="/sys/class/drm/card${GPU_DRM_CARD}/device"
        if [[ -d "$drm_path" ]]; then
            vram_used=$(cat "${drm_path}/mem_info_vram_used" 2>/dev/null || echo "0")
            vram_total=$(cat "${drm_path}/mem_info_vram_total" 2>/dev/null || echo "0")
        else
            warn "DRM sysfs path ${drm_path} not found - VRAM stats unavailable" >&2
        fi
        # GPU utilisation via sysfs (rocm-smi is not invoked here)
        local gpu_busy_path="/sys/class/drm/card${GPU_DRM_CARD}/device/gpu_busy_percent"
        if [[ -f "$gpu_busy_path" ]]; then
            gpu_busy=$(cat "$gpu_busy_path" 2>/dev/null || echo "0")
        fi
        cpu_percent=$(top -bn1 2>/dev/null | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1 || echo "0")
        ram_used=$(free -m 2>/dev/null | awk '/^Mem:/{print $3}' || echo "0")
        ram_total=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || echo "0")
        local uptime_str="00:00:00"
        if [[ -n "$pid" ]] && [[ -d "/proc/$pid" ]]; then
            local start_time now elapsed
            start_time=$(stat -c%Y "/proc/$pid" 2>/dev/null || echo "0")
            now=$(date +%s); elapsed=$((now - start_time))
            uptime_str=$(printf "%02d:%02d:%02d" $((elapsed/3600)) $(((elapsed%3600)/60)) $((elapsed%60)))
        fi
        if [[ -f "$_sg_log_file" ]]; then
            mmproj=$(grep -q '\-\-mmproj' "$_sg_log_file" 2>/dev/null && echo "true" || echo "false")
        fi

        cat <<EOF
{
  "gpu_id": ${_sg_id},
  "gpu_name": "${GPU_NAME}",
  "running": true,
  "model": "${model}",
  "mmproj": ${mmproj},
  "thinking": ${thinking},
  "ctx": ${ctx:-0},
  "port": ${_sg_port},
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
        local vram_used=0 vram_total=0
        local drm_path="/sys/class/drm/card${GPU_DRM_CARD}/device"
        if [[ -d "$drm_path" ]]; then
            vram_used=$(cat "${drm_path}/mem_info_vram_used" 2>/dev/null || echo "0")
            vram_total=$(cat "${drm_path}/mem_info_vram_total" 2>/dev/null || echo "0")
        fi
        cat <<EOF
{
  "gpu_id": ${_sg_id},
  "gpu_name": "${GPU_NAME}",
  "running": false,
  "model": null,
  "mmproj": false,
  "thinking": false,
  "ctx": 0,
  "port": ${_sg_port},
  "uptime": null,
  "vram_used_bytes": ${vram_used},
  "vram_total_bytes": ${vram_total},
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
            --gpu) gpu_cli_id="$2"; shift 2 ;;   # already consumed globally
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

    local use_port="${port_override:-$GPU_PORT}"
    export HIP_VISIBLE_DEVICES="$GPU_HIP_DEVICE"

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

    # Build env exports for the container launch
    local env_exports="export HIP_VISIBLE_DEVICES=$GPU_HIP_DEVICE"
    if [[ -n "$GPU_ENV" ]]; then
        env_exports="$env_exports
$(echo "$GPU_ENV" | sed 's/^/export /')"
    fi

    # Start server as detached daemon via podman exec -d (survives distrobox session exit)
    run_in_container_detached "
$env_exports
${full_cmd} >> ${LOG_FILE} 2>&1
"
    sleep 1
    # Get the PID of the launched process
    local server_pid
    server_pid=$(distrobox enter -T "$CONTAINER" -- bash -c "pgrep -f 'llama-server.*${use_port}' | head -1" 2>/dev/null || true)
    if [[ -n "$server_pid" ]]; then
        echo "$server_pid" > "$PID_FILE"
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
  "port": ${use_port},
  "gpu_id": ${GPU_ID}
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

    if [[ "$GPU_ID" == "all" ]]; then
        local gpu_count
        gpu_count=$(jq '.gpus | length' "$CONFIG_FILE" 2>/dev/null || echo "1")
        for _i in $(seq 0 $((gpu_count - 1))); do
            info "Stopping GPU ${_i}..."
            _do_stop "$_i"
        done
        info "All GPUs stopped."
        echo '{"running":false}'
        return 0
    fi

    _do_stop "$GPU_ID"
}

_do_stop() {
    local _d_id="${1:-0}"
    local _d_pid_file="${LLAMESA_DIR}/server-gpu${_d_id}.pid"
    local _d_running=false

    if [[ -f "$_d_pid_file" ]]; then
        local _d_pid
        _d_pid=$(cat "$_d_pid_file")
        if kill -0 "$_d_pid" 2>/dev/null; then _d_running=true; fi
    fi

    if [[ "$_d_running" == "false" ]]; then
        info "GPU ${_d_id}: Server is not running."
        return 0
    fi

    info "Stopping llama-server on GPU ${_d_id} inside container '${CONTAINER}'..."
    local container_id
    container_id=$(podman ps --filter "name=^${CONTAINER}$" --format "{{.ID}}" 2>/dev/null | head -1)

    if [[ -n "$container_id" ]]; then
        get_gpu_config "$_d_id"
        local _d_port
        _d_port=$(gpu_port)
        # Kill only the instance on this GPU's port
        podman exec "$container_id" bash -c "pkill -f 'llama-server.*--port ${_d_port}' 2>/dev/null || true"
        sleep 2
        podman exec "$container_id" bash -c "pkill -9 -f 'llama-server.*--port ${_d_port}' 2>/dev/null || true"
    fi

    rm -f "$_d_pid_file"
    info "GPU ${_d_id}: Server stopped."
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
    local gpu_id_saved
    gpu_id_saved=$(jq -r '.gpu_id // 0' "$session_file")
    GPU_ID="$gpu_id_saved"
    PID_FILE="${LLAMESA_DIR}/server-gpu${GPU_ID}.pid"
    LOG_FILE="${LLAMESA_DIR}/server-gpu${GPU_ID}.log"
    SERVER_PID_FILE="$PID_FILE"
    SERVER_LOG_FILE="$LOG_FILE"
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
LLaMesa — local inference control plane v0.1.1

Usage: llamesa.sh <command> [options]

Global options:
  --gpu <id|all>    Target GPU by ID (0, 1, ...) or 'all' for multi-GPU ops
                    Default: 0

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