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
        # Accepts v1's numeric IDs / 'all', plus the -dual instance keys (r9700, rx9060xt).
        # Widening this set only adds new accepted values — 0/1/all behavior is unchanged.
        if [[ "$_gpu_val" != "all" ]] && [[ "$_gpu_val" != "r9700" ]] && [[ "$_gpu_val" != "rx9060xt" ]] && ! [[ "$_gpu_val" =~ ^[0-9]+$ ]]; then
            echo "[ERROR] Invalid GPU ID: $_gpu_val. Use 0, 1, 'all', 'r9700', or 'rx9060xt'." >&2
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

# -big (Vulkan combined-VRAM) PID/log — fully separate from v1's per-GPU files above
BIG_PID_FILE="${LLAMESA_DIR}/big.pid"
BIG_LOG_FILE="${LLAMESA_DIR}/big.log"
BIG_SESSION_FILE="${LLAMESA_DIR}/big_session.json"

# -dual (independent ROCm processes) PID/log — fully separate from v1 and -big
DUAL_R9700_PID_FILE="${LLAMESA_DIR}/dual-r9700.pid"
DUAL_R9700_LOG_FILE="${LLAMESA_DIR}/dual-r9700.log"
DUAL_RX9060XT_PID_FILE="${LLAMESA_DIR}/dual-rx9060xt.pid"
DUAL_RX9060XT_LOG_FILE="${LLAMESA_DIR}/dual-rx9060xt.log"
DUAL_SESSION_FILE="${LLAMESA_DIR}/dual_session.json"

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

# Scan /sys/class/drm for the card whose VRAM total is closest to target_gb.
# Uses nearest-match so kernel-reported values (e.g. 31GB for a 32GB card) still resolve correctly.
# Falls back to fallback_card if no GPU sysfs entries found.
_resolve_drm_card() {
    local target_gb="${1:-0}"
    local fallback_card="${2:-0}"
    local card_path total_bytes gb
    local best_card="$fallback_card"
    local best_diff=99999
    for card_path in /sys/class/drm/card*/device; do
        [[ -f "${card_path}/mem_info_vram_total" ]] || continue
        total_bytes=$(cat "${card_path}/mem_info_vram_total" 2>/dev/null || echo "0")
        [[ "$total_bytes" -eq 0 ]] && continue
        gb=$(( total_bytes / 1073741824 ))
        local diff=$(( gb - target_gb ))
        [[ $diff -lt 0 ]] && diff=$(( -diff ))
        if [[ $diff -lt $best_diff ]]; then
            best_diff=$diff
            best_card=$(basename "$(dirname "$card_path")" | grep -o '[0-9]*$')
        fi
    done
    echo "$best_card"
}

# Extract a GPU entry from config by ID. Populates GPU_PORT, GPU_NAME,
# GPU_HIP_DEVICE, GPU_DRM_CARD, and GPU_ENV.
get_gpu_config() {
    local gpu_id="${1:-0}"
    GPU_PORT=$(jq -r --argjson id "$gpu_id" '.gpus[] | select(.id == $id) | .port // 1234' "$CONFIG_FILE" 2>/dev/null)
    GPU_NAME=$(jq -r --argjson id "$gpu_id" '.gpus[] | select(.id == $id) | .name // "GPU${id}"' "$CONFIG_FILE" 2>/dev/null)
    GPU_HIP_DEVICE=$(jq -r --argjson id "$gpu_id" '.gpus[] | select(.id == $id) | .hip_device // $id' "$CONFIG_FILE" 2>/dev/null)

    # Resolve drm_card dynamically from VRAM size — immune to reboot reordering
    local vram_gb config_drm_card
    vram_gb=$(jq -r --argjson id "$gpu_id" '.gpus[] | select(.id == $id) | .vram_gb // 0' "$CONFIG_FILE" 2>/dev/null)
    config_drm_card=$(jq -r --argjson id "$gpu_id" '.gpus[] | select(.id == $id) | .drm_card // empty' "$CONFIG_FILE" 2>/dev/null || echo "$gpu_id")
    GPU_DRM_CARD=$(_resolve_drm_card "$vram_gb" "${config_drm_card:-$gpu_id}")

    # Build newline-separated export lines from .env object
    GPU_ENV=$(jq -r --argjson id "$gpu_id" '.gpus[] | select(.id == $id) | .env // {} | to_entries[] | "\(.key)=\(.value)"' "$CONFIG_FILE" 2>/dev/null || true)

    # Defaults
    GPU_PORT="${GPU_PORT:-1234}"
    GPU_NAME="${GPU_NAME:-GPU${gpu_id}}"
    GPU_HIP_DEVICE="${GPU_HIP_DEVICE:-$gpu_id}"
}

# GPU-aware port — used throughout the script
gpu_port() {
    echo "${GPU_PORT:-${PORT:-1234}}"
}

# Read only the top-level base config fields (models_dir, container, defaults) —
# used by -big/-dual commands instead of v1's read_config, so they never depend
# on the global GPU_ID variable or v1's gpus[]-branch/get_gpu_config logic.
read_base_config() {
    check_config
    MODELS_DIR=$(jq -r '.models_dir // "/var/mnt/games/models"' "$CONFIG_FILE")
    CONTAINER=$(jq -r '.distrobox_container // "rocm-r9700"' "$CONFIG_FILE")
    DEFAULT_CTX=$(jq -r '.default_context // 131072' "$CONFIG_FILE")
    DEFAULT_GPU_LAYERS=$(jq -r '.default_gpu_layers // 99' "$CONFIG_FILE")
    DEFAULT_THINKING=$(jq -r '.default_thinking // true' "$CONFIG_FILE")
}

# Read the vulkan_split config block for -big commands. Populates VULKAN_BINARY,
# VULKAN_PORT, VULKAN_SPLIT_MODE, VULKAN_TENSOR_SPLIT, VULKAN_GPU_LAYERS, VULKAN_ENV.
# Fails fast if the block is missing — -big never falls back to defaults.
read_vulkan_config() {
    check_config
    local has_vulkan
    has_vulkan=$(jq -r '.vulkan_split // empty' "$CONFIG_FILE" 2>/dev/null || true)
    if [[ -z "$has_vulkan" ]]; then
        error "no vulkan_split config found — see docs/dual-gpu.md"
    fi

    VULKAN_BINARY=$(jq -r '.vulkan_split.llama_binary // empty' "$CONFIG_FILE")
    if [[ -z "$VULKAN_BINARY" ]]; then
        error "vulkan_split.llama_binary not set in config — see docs/dual-gpu.md"
    fi
    VULKAN_PORT=$(jq -r '.vulkan_split.port // 1236' "$CONFIG_FILE")
    VULKAN_SPLIT_MODE=$(jq -r '.vulkan_split.split_mode // "layer"' "$CONFIG_FILE")
    VULKAN_TENSOR_SPLIT=$(jq -r '(.vulkan_split.tensor_split // []) | join(",")' "$CONFIG_FILE")
    VULKAN_GPU_LAYERS=$(jq -r '.vulkan_split.default_gpu_layers // 999' "$CONFIG_FILE")
    VULKAN_ENV=$(jq -r '(.vulkan_split.env // {}) | to_entries[] | "\(.key)=\(.value)"' "$CONFIG_FILE" 2>/dev/null || true)
}

# Read the dual_gpu config block for -dual commands. Populates R9700_PORT,
# R9700_BINARY, R9700_ENV, RX9060XT_PORT, RX9060XT_BINARY, RX9060XT_ENV.
# Fails fast if either sub-block is missing — -dual never falls back to defaults.
read_dual_gpu_config() {
    check_config
    local has_dual
    has_dual=$(jq -r '.dual_gpu // empty' "$CONFIG_FILE" 2>/dev/null || true)
    if [[ -z "$has_dual" ]]; then
        error "no dual_gpu config found — see docs/dual-gpu.md"
    fi

    local has_r9700 has_rx9060xt
    has_r9700=$(jq -r '.dual_gpu.r9700 // empty' "$CONFIG_FILE" 2>/dev/null || true)
    has_rx9060xt=$(jq -r '.dual_gpu.rx9060xt // empty' "$CONFIG_FILE" 2>/dev/null || true)
    if [[ -z "$has_r9700" ]] || [[ -z "$has_rx9060xt" ]]; then
        error "dual_gpu config must include both 'r9700' and 'rx9060xt' blocks — see docs/dual-gpu.md"
    fi

    R9700_PORT=$(jq -r '.dual_gpu.r9700.port // 1234' "$CONFIG_FILE")
    R9700_BINARY=$(jq -r '.dual_gpu.r9700.llama_binary // empty' "$CONFIG_FILE")
    R9700_ENV=$(jq -r '(.dual_gpu.r9700.env // {}) | to_entries[] | "\(.key)=\(.value)"' "$CONFIG_FILE" 2>/dev/null || true)

    RX9060XT_PORT=$(jq -r '.dual_gpu.rx9060xt.port // 1235' "$CONFIG_FILE")
    RX9060XT_BINARY=$(jq -r '.dual_gpu.rx9060xt.llama_binary // empty' "$CONFIG_FILE")
    RX9060XT_ENV=$(jq -r '(.dual_gpu.rx9060xt.env // {}) | to_entries[] | "\(.key)=\(.value)"' "$CONFIG_FILE" 2>/dev/null || true)

    if [[ -z "$R9700_BINARY" ]] || [[ -z "$RX9060XT_BINARY" ]]; then
        error "dual_gpu.r9700.llama_binary and dual_gpu.rx9060xt.llama_binary must both be set — see docs/dual-gpu.md"
    fi
}

# Check if the -big Vulkan server is running (PID file, falling back to port scan)
is_big_running() {
    if [[ -f "$BIG_PID_FILE" ]]; then
        local pid
        pid=$(cat "$BIG_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo "$pid"
            return 0
        fi
    fi
    if ss -tlnp 2>/dev/null | grep -q ":${VULKAN_PORT}"; then
        return 0
    fi
    return 1
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

# Refuse to launch a model that doesn't leave enough available system RAM
# headroom, in case GPU offload fails (partially or fully) and llama-server
# falls back to loading the model via CPU/mmap — which, left unchecked, can
# consume the model's entire size in system RAM. Added after a real incident:
# an unbounded CPU fallback across multiple simultaneous instances exhausted
# system memory and triggered a full OOM crash (kernel killed session
# processes, forcing a hard reboot). This assumes the worst case (100% CPU
# fallback) rather than trying to predict whether GPU offload will succeed,
# since that prediction is exactly what failed here.
check_ram_safety() {
    local model_file="$1"
    local mmproj_file="${2:-}"
    local label="${3:-model}"

    local model_bytes mmproj_bytes
    model_bytes=$(stat -c%s "$model_file" 2>/dev/null || echo 0)
    mmproj_bytes=0
    if [[ -n "$mmproj_file" ]] && [[ -f "$mmproj_file" ]]; then
        mmproj_bytes=$(stat -c%s "$mmproj_file" 2>/dev/null || echo 0)
    fi

    # 10% overhead margin for activation buffers/KV cache/runtime overhead
    local required_mb=$(( (model_bytes + mmproj_bytes) * 11 / 10 / 1048576 ))

    local available_mb
    available_mb=$(free -m 2>/dev/null | awk '/^Mem:/{print $7}')
    if [[ -z "$available_mb" ]]; then
        available_mb=$(free -m 2>/dev/null | awk '/^Mem:/{print $4}')
    fi

    if [[ -n "$available_mb" ]] && [[ "$available_mb" -lt "$required_mb" ]]; then
        error "${label}: refusing to start — only ${available_mb}MB RAM available, but ~${required_mb}MB may be needed if GPU offload fails and the model falls back to system RAM. This guard exists because that exact scenario crashed this system via OOM. Free up RAM, stop other running instances, or use a smaller quant before retrying."
    fi
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
    local parallel="1"

    # Parse CLI args
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --gpu) gpu_cli_id="$2"; shift 2 ;;   # already consumed globally
            --model) model_name="$2"; shift 2 ;;
            --thinking) thinking="$2"; shift 2 ;;
            --ctx) ctx="$2"; shift 2 ;;
            --gpu-layers) gpu_layers="$2"; shift 2 ;;
            --port) port_override="$2"; shift 2 ;;
            --parallel) parallel="$2"
                        if ! [[ "$parallel" =~ ^[1-4]$ ]]; then
                            error "--parallel must be 1-4"
                        fi
                        shift 2 ;;
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
    if [[ -n "$parallel" ]]; then
        cmd_args+=("--parallel" "$parallel")
    fi

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

    check_ram_safety "$model_file" "$mmproj_file" "start"

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
  "gpu_id": ${GPU_ID},
  "parallel": ${parallel:-1}
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

    local gpu_id_saved parallel_saved
    gpu_id_saved=$(jq -r '.gpu_id // 0' "$session_file")
    parallel_saved=$(jq -r '.parallel // empty' "$session_file")
    GPU_ID="$gpu_id_saved"
    PID_FILE="${LLAMESA_DIR}/server-gpu${GPU_ID}.pid"
    LOG_FILE="${LLAMESA_DIR}/server-gpu${GPU_ID}.log"
    SERVER_PID_FILE="$PID_FILE"
    SERVER_LOG_FILE="$LOG_FILE"

    info "Restarting with: model=${model_name} thinking=${thinking} ctx=${ctx} parallel=${parallel_saved:-auto}"
    cmd_stop
    sleep 3
    if [[ -n "$parallel_saved" ]]; then
        cmd_start --model "$model_name" --thinking "$thinking" --ctx "$ctx" --parallel "$parallel_saved"
    else
        cmd_start --model "$model_name" --thinking "$thinking" --ctx "$ctx"
    fi
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

# ── -big commands (Vulkan combined-VRAM, single process) ────────────────
# Fully independent of cmd_start/cmd_stop/cmd_status/cmd_restart/cmd_logs above —
# these never call or modify any v1 function.

cmd_start_big() {
    read_base_config
    read_vulkan_config

    local model_name=""
    local thinking="$DEFAULT_THINKING"
    local ctx="$DEFAULT_CTX"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --model) model_name="$2"; shift 2 ;;
            --thinking) thinking="$2"; shift 2 ;;
            --ctx) ctx="$2"; shift 2 ;;
            *) error "Unknown option: $1" ;;
        esac
    done

    case "$thinking" in
        on|yes|1|true)  thinking="true" ;;
        off|no|0|false) thinking="false" ;;
        *) thinking="false" ;;
    esac

    if [[ -z "$model_name" ]]; then
        error "Model name required. Use --model <name>"
    fi

    if is_big_running >/dev/null 2>&1; then
        warn "Vulkan combined-VRAM server is already running. Use 'restart-big' to change models."
        cmd_stop_big
    fi

    # Find the model file
    local model_file="" model_dir_path=""
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
        if [[ -f "$model_name" ]]; then
            model_file="$model_name"
            model_dir_path=$(dirname "$model_file")
        else
            error "Model not found: ${model_name}. Run 'list-models' to see available models."
        fi
    fi

    info "Starting Vulkan combined-VRAM server with model: ${model_file}"

    # See _start_dual_instance for why "auto" is used instead of the configured
    # numeric default_gpu_layers (999): a hardcoded value makes this build's -fit
    # system abort its own device-memory adjustment instead of performing it.
    local cmd_args=(
        "$VULKAN_BINARY"
        "--model" "$model_file"
        "--ctx-size" "$ctx"
        "-sm" "$VULKAN_SPLIT_MODE"
        "--tensor-split" "$VULKAN_TENSOR_SPLIT"
        "-ngl" "auto"
        "--port" "$VULKAN_PORT"
        "--host" "0.0.0.0"
    )

    local mmproj_file=""
    if [[ -n "$model_dir_path" ]]; then
        mmproj_file=$(find "$model_dir_path" -maxdepth 1 -name "mmproj-*.gguf" 2>/dev/null | head -1)
    fi
    if [[ -n "$mmproj_file" ]]; then
        cmd_args+=("--mmproj" "$mmproj_file")
        info "Multi-modal projector loaded: ${mmproj_file}"
    fi

    check_ram_safety "$model_file" "$mmproj_file" "start-big"

    mkdir -p "$LLAMESA_DIR"
    {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting (vulkan/-big): ${cmd_args[*]}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Model: ${model_file}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Context: ${ctx}, Split: ${VULKAN_SPLIT_MODE}, Tensor-split: ${VULKAN_TENSOR_SPLIT}"
    } > "$BIG_LOG_FILE"

    local full_cmd="${cmd_args[*]}"
    local env_exports=""
    if [[ -n "$VULKAN_ENV" ]]; then
        env_exports="$(echo "$VULKAN_ENV" | sed 's/^/export /')"
    fi

    info "Launching Vulkan llama-server in container '${CONTAINER}'..."
    run_in_container_detached "
$env_exports
${full_cmd} >> ${BIG_LOG_FILE} 2>&1
"
    sleep 1
    local server_pid
    server_pid=$(distrobox enter -T "$CONTAINER" -- bash -c "pgrep -f 'llama-server.*${VULKAN_PORT}' | head -1" 2>/dev/null || true)
    if [[ -n "$server_pid" ]]; then
        echo "$server_pid" > "$BIG_PID_FILE"
        info "Vulkan server started with PID ${server_pid}"
    else
        info "Vulkan server launched (PID unavailable)"
    fi

    info "Waiting for server to be ready on port ${VULKAN_PORT}..."
    info "Large models may take 1-5 minutes to load. Use 'llamesa.sh logs-big' to monitor."
    local max_wait=300
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        if curl -s --max-time 2 "http://localhost:${VULKAN_PORT}/health" >/dev/null 2>&1; then
            info "Vulkan server is ready!"
            cat > "$BIG_SESSION_FILE" <<EOF
{
  "model": "${model_name}",
  "thinking": ${thinking},
  "ctx": ${ctx}
}
EOF
            cmd_status_big
            return 0
        fi
        if [[ $((waited % 30)) -eq 0 ]] && [[ $waited -gt 0 ]]; then
            info "Still loading... (${waited}s elapsed)"
        fi
        sleep 2
        waited=$((waited + 2))
    done

    warn "Vulkan server did not respond after ${max_wait}s. Check logs with 'llamesa.sh logs-big'"
    return 1
}

cmd_stop_big() {
    read_base_config
    read_vulkan_config

    if ! is_big_running >/dev/null 2>&1; then
        info "Vulkan combined-VRAM server is not running."
        echo '{"running":false}'
        return 0
    fi

    info "Stopping Vulkan llama-server inside container '${CONTAINER}'..."
    local container_id
    container_id=$(podman ps --filter "name=^${CONTAINER}$" --format "{{.ID}}" 2>/dev/null | head -1)

    if [[ -n "$container_id" ]]; then
        podman exec "$container_id" bash -c "pkill -f 'llama-server.*--port ${VULKAN_PORT}' 2>/dev/null || true"
        sleep 2
        podman exec "$container_id" bash -c "pkill -9 -f 'llama-server.*--port ${VULKAN_PORT}' 2>/dev/null || true"
    fi

    rm -f "$BIG_PID_FILE"
    info "Vulkan combined-VRAM server stopped."
    echo '{"running":false}'
}

cmd_status_big() {
    read_base_config
    read_vulkan_config

    local running=false pid=""
    if [[ -f "$BIG_PID_FILE" ]]; then
        pid=$(cat "$BIG_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then running=true; fi
    fi
    if [[ "$running" == "false" ]] && ss -tlnp 2>/dev/null | grep -q ":${VULKAN_PORT}"; then
        running=true
    fi

    if [[ "$running" != "true" ]]; then
        cat <<EOF
{
  "running": false,
  "model": null,
  "backend": "vulkan",
  "ctx": 0,
  "port": ${VULKAN_PORT},
  "uptime": null,
  "devices": [],
  "thinking": false,
  "cpu_percent": 0,
  "ram_used_mb": 0,
  "ram_total_mb": 0
}
EOF
        return 0
    fi

    local model="unknown" ctx=0 thinking=false
    local models_response
    if models_response=$(curl -s --max-time 3 "http://localhost:${VULKAN_PORT}/v1/models" 2>/dev/null); then
        local model_file
        model_file=$(echo "$models_response" | grep -o '"id": *"[^"]*"' | head -1 | grep -o '"[^"]*"$' | tr -d '"' || echo "")
        if [[ -n "$model_file" ]]; then
            local model_path
            model_path=$(find "$MODELS_DIR" -name "$model_file" -type f 2>/dev/null | head -1 || true)
            if [[ -n "$model_path" ]]; then model=$(basename "$(dirname "$model_path")")
            else model="$model_file"; fi
        fi
        local ctx_val
        ctx_val=$(echo "$models_response" | grep -o '"n_ctx": *[0-9]*' | grep -o '[0-9]*$' | head -1 || true)
        [[ -n "$ctx_val" ]] && ctx="$ctx_val"
    fi

    if [[ -f "$BIG_SESSION_FILE" ]]; then
        local sess_thinking
        sess_thinking=$(jq -r '.thinking // empty' "$BIG_SESSION_FILE" 2>/dev/null || true)
        [[ "$sess_thinking" == "true" || "$sess_thinking" == "false" ]] && thinking="$sess_thinking"
    fi

    local uptime_str="00:00:00"
    if [[ -n "$pid" ]] && [[ -d "/proc/$pid" ]]; then
        local start_time now elapsed
        start_time=$(stat -c%Y "/proc/$pid" 2>/dev/null || echo "0")
        now=$(date +%s); elapsed=$((now - start_time))
        uptime_str=$(printf "%02d:%02d:%02d" $((elapsed/3600)) $(((elapsed%3600)/60)) $((elapsed%60)))
    fi

    local cpu_percent ram_used ram_total
    cpu_percent=$(top -bn1 2>/dev/null | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1 || echo "0")
    ram_used=$(free -m 2>/dev/null | awk '/^Mem:/{print $3}' || echo "0")
    ram_total=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || echo "0")

    # Per-device VRAM/util — reuses the existing (read-only) gpus[] config and
    # get_gpu_config/_resolve_drm_card helpers to identify each physical card.
    local -a device_entries=()
    local gpu_count
    gpu_count=$(jq '.gpus | length' "$CONFIG_FILE" 2>/dev/null || echo "0")
    if [[ "$gpu_count" -gt 0 ]]; then
        for _gid in $(seq 0 $((gpu_count - 1))); do
            get_gpu_config "$_gid"
            local drm_path="/sys/class/drm/card${GPU_DRM_CARD}/device"
            local d_vram_used=0 d_vram_total=0 d_busy=0
            if [[ -d "$drm_path" ]]; then
                d_vram_used=$(cat "${drm_path}/mem_info_vram_used" 2>/dev/null || echo "0")
                d_vram_total=$(cat "${drm_path}/mem_info_vram_total" 2>/dev/null || echo "0")
                d_busy=$(cat "${drm_path}/gpu_busy_percent" 2>/dev/null || echo "0")
            fi
            local dev_id
            dev_id=$(echo "$GPU_NAME" | tr '[:upper:]' '[:lower:]')
            device_entries+=("{\"id\":\"${dev_id}\",\"vram_used_bytes\":${d_vram_used},\"vram_total_bytes\":${d_vram_total},\"gpu_busy_percent\":${d_busy}}")
        done
    fi

    local devices_json="[]"
    if [[ ${#device_entries[@]} -gt 0 ]]; then
        devices_json="["
        local _di=0 _dtotal=${#device_entries[@]}
        for _de in "${device_entries[@]}"; do
            _di=$((_di + 1))
            if [[ $_di -lt $_dtotal ]]; then devices_json="${devices_json}${_de},"
            else devices_json="${devices_json}${_de}"; fi
        done
        devices_json="${devices_json}]"
    fi

    cat <<EOF
{
  "running": true,
  "model": "${model}",
  "backend": "vulkan",
  "ctx": ${ctx:-0},
  "port": ${VULKAN_PORT},
  "uptime": "${uptime_str}",
  "devices": ${devices_json},
  "thinking": ${thinking},
  "cpu_percent": ${cpu_percent:-0},
  "ram_used_mb": ${ram_used:-0},
  "ram_total_mb": ${ram_total:-0}
}
EOF
}

cmd_restart_big() {
    read_base_config
    read_vulkan_config

    local has_model=false
    for arg in "$@"; do
        [[ "$arg" == "--model" ]] && has_model=true
    done
    if [[ "$has_model" == "false" ]]; then
        error "Model name required. Use --model <name> (restart-big does not remember the last model)"
    fi

    info "Restarting Vulkan combined-VRAM server..."
    cmd_stop_big
    sleep 3
    cmd_start_big "$@"
}

cmd_logs_big() {
    if [[ ! -f "$BIG_LOG_FILE" ]]; then
        warn "No log file found at ${BIG_LOG_FILE}"
        return 1
    fi
    tail -f "$BIG_LOG_FILE"
}

# ── -dual commands (independent ROCm processes, two GPUs) ───────────────
# Fully independent of cmd_start/cmd_stop/cmd_status/cmd_restart/cmd_logs and of
# the -big commands above — these never call or modify any of them.

# Internal helper: launch one -dual instance for a given GPU key (r9700 | rx9060xt)
# Resolve which GPU device INDEX (0, 1, ...) corresponds to a GPU by matching
# `llama-server --list-devices` output against a target VRAM size. Backend-
# agnostic — matches "Vulkan0"/"Vulkan1" (Vulkan builds) or "ROCm0"/"ROCm1"
# (ROCm/HIP builds) alike, since -dual's per-GPU llama_binary can be either.
# Mirrors _resolve_drm_card's nearest-match approach — device enumeration
# order is not guaranteed stable across process launches on this hardware.
#
# Used with `-sm none -mg <index>` rather than `--device <name>`: testing found
# --device pinning never achieved real GPU VRAM offload (always fell back to
# system RAM, no error), while -sm none -mg <index> — leaving both devices
# visible and explicitly selecting one for compute — was confirmed working
# (stable, real VRAM usage, on the R9700). See docs/dual-gpu.md Known Limitations.
_resolve_device_index() {
    local binary="$1"
    local target_gb="${2:-0}"
    local list_output
    list_output=$(distrobox enter -T "$CONTAINER" -- bash -c "'${binary}' --list-devices 2>&1" 2>/dev/null || true)

    local best_index="" best_diff=99999
    while IFS= read -r line; do
        if [[ "$line" =~ [A-Za-z]+([0-9]+):.*\(([0-9]+)\ MiB, ]]; then
            local dev_idx="${BASH_REMATCH[1]}"
            local mib="${BASH_REMATCH[2]}"
            local gb=$(( mib / 1024 ))
            local diff=$(( gb - target_gb ))
            [[ $diff -lt 0 ]] && diff=$(( -diff ))
            if [[ $diff -lt $best_diff ]]; then
                best_diff=$diff
                best_index="$dev_idx"
            fi
        fi
    done <<< "$list_output"

    echo "$best_index"
}

_start_dual_instance() {
    local gpu_key="$1" port="$2" binary="$3" env_lines="$4" model_name="$5" ctx="$6" device_index="$7"
    local pid_file="${LLAMESA_DIR}/dual-${gpu_key}.pid"
    local log_file="${LLAMESA_DIR}/dual-${gpu_key}.log"

    local model_file="" model_dir_path=""
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
        if [[ -f "$model_name" ]]; then
            model_file="$model_name"
            model_dir_path=$(dirname "$model_file")
        else
            error "Model not found for ${gpu_key}: ${model_name}. Run 'list-models' to see available models."
        fi
    fi

    info "[${gpu_key}] Starting server with model: ${model_file}"
    info "[${gpu_key}] Pinned to main-gpu index: ${device_index}"

    # This llama.cpp build's -fit system (default on) picks the right layer
    # split for a single pinned device on its own; a hardcoded numeric
    # --n-gpu-layers (e.g. the v1 config's default_gpu_layers=99) makes it
    # abort that adjustment instead ("n_gpu_layers already set by user... abort"),
    # which silently left both -dual instances running on CPU. "auto" lets -fit do its job.
    #
    # -sm none -mg <index> (not --device <name>): testing found --device pinning
    # never achieved real GPU VRAM offload (silent full fallback to system RAM,
    # no error) — -sm none -mg, which leaves both devices visible and explicitly
    # selects one for compute, was confirmed working. See docs/dual-gpu.md.
    local cmd_args=(
        "$binary"
        "--model" "$model_file"
        "--ctx-size" "$ctx"
        "--n-gpu-layers" "auto"
        "-sm" "none"
        "-mg" "$device_index"
        "--port" "$port"
        "--host" "0.0.0.0"
    )

    local mmproj_file=""
    if [[ -n "$model_dir_path" ]]; then
        mmproj_file=$(find "$model_dir_path" -maxdepth 1 -name "mmproj-*.gguf" 2>/dev/null | head -1)
    fi
    if [[ -n "$mmproj_file" ]]; then
        cmd_args+=("--mmproj" "$mmproj_file")
        info "[${gpu_key}] Multi-modal projector loaded: ${mmproj_file}"
    fi

    check_ram_safety "$model_file" "$mmproj_file" "start-dual/${gpu_key}"

    mkdir -p "$LLAMESA_DIR"
    {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting (-dual/${gpu_key}): ${cmd_args[*]}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Model: ${model_file}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Context: ${ctx}"
    } > "$log_file"

    local full_cmd="${cmd_args[*]}"
    local env_exports=""
    if [[ -n "$env_lines" ]]; then
        env_exports="$(echo "$env_lines" | sed 's/^/export /')"
    fi

    info "[${gpu_key}] Launching llama-server in container '${CONTAINER}'..."
    run_in_container_detached "
$env_exports
${full_cmd} >> ${log_file} 2>&1
"
    sleep 1
    local server_pid
    server_pid=$(distrobox enter -T "$CONTAINER" -- bash -c "pgrep -f 'llama-server.*${port}' | head -1" 2>/dev/null || true)
    if [[ -n "$server_pid" ]]; then
        echo "$server_pid" > "$pid_file"
        info "[${gpu_key}] Server started with PID ${server_pid}"
    else
        info "[${gpu_key}] Server launched (PID unavailable)"
    fi
}

# Internal helper: wait for one -dual instance's /health endpoint
_wait_dual_instance() {
    local gpu_key="$1" port="$2"
    info "[${gpu_key}] Waiting for server to be ready on port ${port}..."
    local max_wait=300 waited=0
    while [[ $waited -lt $max_wait ]]; do
        if curl -s --max-time 2 "http://localhost:${port}/health" >/dev/null 2>&1; then
            info "[${gpu_key}] Server is ready!"
            return 0
        fi
        if [[ $((waited % 30)) -eq 0 ]] && [[ $waited -gt 0 ]]; then
            info "[${gpu_key}] Still loading... (${waited}s elapsed)"
        fi
        sleep 2
        waited=$((waited + 2))
    done
    warn "[${gpu_key}] Server did not respond after ${max_wait}s. Check logs with 'llamesa.sh logs-dual --gpu ${gpu_key}'"
    return 1
}

# Internal helper: stop one -dual instance
_stop_dual_instance() {
    local gpu_key="$1" port="$2"
    local pid_file="${LLAMESA_DIR}/dual-${gpu_key}.pid"

    if [[ ! -f "$pid_file" ]] && ! ss -tlnp 2>/dev/null | grep -q ":${port}"; then
        info "[${gpu_key}] Server is not running."
        return 0
    fi

    info "[${gpu_key}] Stopping llama-server inside container '${CONTAINER}'..."
    local container_id
    container_id=$(podman ps --filter "name=^${CONTAINER}$" --format "{{.ID}}" 2>/dev/null | head -1)

    if [[ -n "$container_id" ]]; then
        podman exec "$container_id" bash -c "pkill -f 'llama-server.*--port ${port}' 2>/dev/null || true"
        sleep 2
        podman exec "$container_id" bash -c "pkill -9 -f 'llama-server.*--port ${port}' 2>/dev/null || true"
    fi

    rm -f "$pid_file"
    info "[${gpu_key}] Server stopped."
}

# Internal helper: build one -dual instance's status JSON object (same field
# shape as v1's single-GPU status). VRAM/drm data is read-only-reused from the
# existing gpus[] config, matched by lower-cased name.
_status_dual_instance() {
    local gpu_key="$1" port="$2"
    local pid_file="${LLAMESA_DIR}/dual-${gpu_key}.pid"
    local log_file="${LLAMESA_DIR}/dual-${gpu_key}.log"
    local running=false pid="" model="none" mmproj="false" thinking="false" ctx="0"

    if [[ -f "$pid_file" ]]; then
        pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then running=true; fi
    fi
    if [[ "$running" == "false" ]] && ss -tlnp 2>/dev/null | grep -q ":${port}"; then
        running=true
    fi

    local drm_card=0 vram_used=0 vram_total=0 gpu_busy=0
    local gpu_count
    gpu_count=$(jq '.gpus | length' "$CONFIG_FILE" 2>/dev/null || echo "0")
    if [[ "$gpu_count" -gt 0 ]]; then
        for _gid in $(seq 0 $((gpu_count - 1))); do
            get_gpu_config "$_gid"
            local lname
            lname=$(echo "$GPU_NAME" | tr '[:upper:]' '[:lower:]')
            if [[ "$lname" == "$gpu_key" ]]; then
                drm_card="$GPU_DRM_CARD"
                break
            fi
        done
    fi
    local drm_path="/sys/class/drm/card${drm_card}/device"
    if [[ -d "$drm_path" ]]; then
        vram_used=$(cat "${drm_path}/mem_info_vram_used" 2>/dev/null || echo "0")
        vram_total=$(cat "${drm_path}/mem_info_vram_total" 2>/dev/null || echo "0")
        gpu_busy=$(cat "${drm_path}/gpu_busy_percent" 2>/dev/null || echo "0")
    fi

    if [[ "$running" == "true" ]]; then
        local models_response
        if models_response=$(curl -s --max-time 3 "http://localhost:${port}/v1/models" 2>/dev/null); then
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
        if [[ -f "$DUAL_SESSION_FILE" ]]; then
            local sess_thinking
            sess_thinking=$(jq -r '.thinking // empty' "$DUAL_SESSION_FILE" 2>/dev/null || true)
            [[ "$sess_thinking" == "true" || "$sess_thinking" == "false" ]] && thinking="$sess_thinking"
        fi
        if [[ -f "$log_file" ]]; then
            mmproj=$(grep -q '\-\-mmproj' "$log_file" 2>/dev/null && echo "true" || echo "false")
        fi
        local uptime_str="00:00:00"
        if [[ -n "$pid" ]] && [[ -d "/proc/$pid" ]]; then
            local start_time now elapsed
            start_time=$(stat -c%Y "/proc/$pid" 2>/dev/null || echo "0")
            now=$(date +%s); elapsed=$((now - start_time))
            uptime_str=$(printf "%02d:%02d:%02d" $((elapsed/3600)) $(((elapsed%3600)/60)) $((elapsed%60)))
        fi
        local cpu_percent ram_used ram_total
        cpu_percent=$(top -bn1 2>/dev/null | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1 || echo "0")
        ram_used=$(free -m 2>/dev/null | awk '/^Mem:/{print $3}' || echo "0")
        ram_total=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || echo "0")

        cat <<EOF
{
  "gpu_id": "${gpu_key}",
  "gpu_name": "${gpu_key}",
  "running": true,
  "model": "${model}",
  "mmproj": ${mmproj},
  "thinking": ${thinking},
  "ctx": ${ctx:-0},
  "port": ${port},
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
        cat <<EOF
{
  "gpu_id": "${gpu_key}",
  "gpu_name": "${gpu_key}",
  "running": false,
  "model": null,
  "mmproj": false,
  "thinking": false,
  "ctx": 0,
  "port": ${port},
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

cmd_start_dual() {
    read_base_config
    read_dual_gpu_config

    local model_r9700="" model_rx9060xt=""
    local thinking="$DEFAULT_THINKING"
    local ctx="$DEFAULT_CTX"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --model-r9700) model_r9700="$2"; shift 2 ;;
            --model-rx9060xt) model_rx9060xt="$2"; shift 2 ;;
            --thinking) thinking="$2"; shift 2 ;;
            --ctx) ctx="$2"; shift 2 ;;
            *) error "Unknown option: $1" ;;
        esac
    done

    case "$thinking" in
        on|yes|1|true)  thinking="true" ;;
        off|no|0|false) thinking="false" ;;
        *) thinking="false" ;;
    esac

    if [[ -z "$model_r9700" ]] || [[ -z "$model_rx9060xt" ]]; then
        error "Both --model-r9700 and --model-rx9060xt are required"
    fi

    if [[ -f "$DUAL_R9700_PID_FILE" ]] && kill -0 "$(cat "$DUAL_R9700_PID_FILE")" 2>/dev/null; then
        warn "r9700 dual instance is already running. Stopping it first."
        _stop_dual_instance "r9700" "$R9700_PORT"
    fi
    if [[ -f "$DUAL_RX9060XT_PID_FILE" ]] && kill -0 "$(cat "$DUAL_RX9060XT_PID_FILE")" 2>/dev/null; then
        warn "rx9060xt dual instance is already running. Stopping it first."
        _stop_dual_instance "rx9060xt" "$RX9060XT_PORT"
    fi

    local r9700_device rx9060xt_device
    r9700_device=$(_resolve_device_index "$R9700_BINARY" 32)
    rx9060xt_device=$(_resolve_device_index "$RX9060XT_BINARY" 16)
    if [[ -z "$r9700_device" ]]; then
        error "Could not resolve a Vulkan device for r9700 via --list-devices. Check dual_gpu.r9700.llama_binary and that both GPUs are visible to Vulkan (vulkaninfo --summary)."
    fi
    if [[ -z "$rx9060xt_device" ]]; then
        error "Could not resolve a Vulkan device for rx9060xt via --list-devices. Check dual_gpu.rx9060xt.llama_binary and that both GPUs are visible to Vulkan (vulkaninfo --summary)."
    fi

    _start_dual_instance "r9700" "$R9700_PORT" "$R9700_BINARY" "$R9700_ENV" "$model_r9700" "$ctx" "$r9700_device"
    _start_dual_instance "rx9060xt" "$RX9060XT_PORT" "$RX9060XT_BINARY" "$RX9060XT_ENV" "$model_rx9060xt" "$ctx" "$rx9060xt_device"

    _wait_dual_instance "r9700" "$R9700_PORT"
    _wait_dual_instance "rx9060xt" "$RX9060XT_PORT"

    mkdir -p "$LLAMESA_DIR"
    cat > "$DUAL_SESSION_FILE" <<EOF
{
  "r9700": {"model": "${model_r9700}"},
  "rx9060xt": {"model": "${model_rx9060xt}"},
  "thinking": ${thinking},
  "ctx": ${ctx}
}
EOF

    cmd_status_dual
}

cmd_stop_dual() {
    read_base_config
    read_dual_gpu_config

    case "$GPU_ID" in
        r9700)
            _stop_dual_instance "r9700" "$R9700_PORT"
            ;;
        rx9060xt)
            _stop_dual_instance "rx9060xt" "$RX9060XT_PORT"
            ;;
        *)
            _stop_dual_instance "r9700" "$R9700_PORT"
            _stop_dual_instance "rx9060xt" "$RX9060XT_PORT"
            ;;
    esac
    echo '{"running":false}'
}

cmd_restart_dual() {
    read_base_config
    read_dual_gpu_config

    if [[ ! -f "$DUAL_SESSION_FILE" ]]; then
        error "No previous -dual session found. Use 'start-dual --model-r9700 <name> --model-rx9060xt <name>' instead."
    fi

    local model_r9700 model_rx9060xt ctx
    model_r9700=$(jq -r '.r9700.model // empty' "$DUAL_SESSION_FILE")
    model_rx9060xt=$(jq -r '.rx9060xt.model // empty' "$DUAL_SESSION_FILE")
    ctx=$(jq -r '.ctx // empty' "$DUAL_SESSION_FILE")
    [[ -z "$ctx" ]] && ctx="$DEFAULT_CTX"

    case "$GPU_ID" in
        r9700)
            if [[ -z "$model_r9700" ]]; then
                error "No remembered model for r9700. Use 'start-dual' instead."
            fi
            info "Restarting r9700 dual instance..."
            _stop_dual_instance "r9700" "$R9700_PORT"
            sleep 3
            local r9700_device
            r9700_device=$(_resolve_device_index "$R9700_BINARY" 32)
            [[ -z "$r9700_device" ]] && error "Could not resolve a Vulkan device for r9700 via --list-devices."
            _start_dual_instance "r9700" "$R9700_PORT" "$R9700_BINARY" "$R9700_ENV" "$model_r9700" "$ctx" "$r9700_device"
            _wait_dual_instance "r9700" "$R9700_PORT"
            ;;
        rx9060xt)
            if [[ -z "$model_rx9060xt" ]]; then
                error "No remembered model for rx9060xt. Use 'start-dual' instead."
            fi
            info "Restarting rx9060xt dual instance..."
            _stop_dual_instance "rx9060xt" "$RX9060XT_PORT"
            sleep 3
            local rx9060xt_device
            rx9060xt_device=$(_resolve_device_index "$RX9060XT_BINARY" 16)
            [[ -z "$rx9060xt_device" ]] && error "Could not resolve a Vulkan device for rx9060xt via --list-devices."
            _start_dual_instance "rx9060xt" "$RX9060XT_PORT" "$RX9060XT_BINARY" "$RX9060XT_ENV" "$model_rx9060xt" "$ctx" "$rx9060xt_device"
            _wait_dual_instance "rx9060xt" "$RX9060XT_PORT"
            ;;
        *)
            if [[ -z "$model_r9700" ]] || [[ -z "$model_rx9060xt" ]]; then
                error "No remembered models for one or both GPUs. Use 'start-dual' instead."
            fi
            info "Restarting both dual instances..."
            _stop_dual_instance "r9700" "$R9700_PORT"
            _stop_dual_instance "rx9060xt" "$RX9060XT_PORT"
            sleep 3
            local both_r9700_device both_rx9060xt_device
            both_r9700_device=$(_resolve_device_index "$R9700_BINARY" 32)
            both_rx9060xt_device=$(_resolve_device_index "$RX9060XT_BINARY" 16)
            [[ -z "$both_r9700_device" ]] && error "Could not resolve a Vulkan device for r9700 via --list-devices."
            [[ -z "$both_rx9060xt_device" ]] && error "Could not resolve a Vulkan device for rx9060xt via --list-devices."
            _start_dual_instance "r9700" "$R9700_PORT" "$R9700_BINARY" "$R9700_ENV" "$model_r9700" "$ctx" "$both_r9700_device"
            _start_dual_instance "rx9060xt" "$RX9060XT_PORT" "$RX9060XT_BINARY" "$RX9060XT_ENV" "$model_rx9060xt" "$ctx" "$both_rx9060xt_device"
            _wait_dual_instance "r9700" "$R9700_PORT"
            _wait_dual_instance "rx9060xt" "$RX9060XT_PORT"
            ;;
    esac

    cmd_status_dual
}

cmd_status_dual() {
    read_base_config
    read_dual_gpu_config

    case "$GPU_ID" in
        r9700)
            _status_dual_instance "r9700" "$R9700_PORT"
            ;;
        rx9060xt)
            _status_dual_instance "rx9060xt" "$RX9060XT_PORT"
            ;;
        *)
            local r9700_json rx9060xt_json
            r9700_json=$(_status_dual_instance "r9700" "$R9700_PORT")
            rx9060xt_json=$(_status_dual_instance "rx9060xt" "$RX9060XT_PORT")
            echo "["
            echo "  ${r9700_json},"
            echo "  ${rx9060xt_json}"
            echo "]"
            ;;
    esac
}

cmd_logs_dual() {
    local log_file
    case "$GPU_ID" in
        r9700)    log_file="$DUAL_R9700_LOG_FILE" ;;
        rx9060xt) log_file="$DUAL_RX9060XT_LOG_FILE" ;;
        *)        error "logs-dual requires --gpu r9700 or --gpu rx9060xt" ;;
    esac

    if [[ ! -f "$log_file" ]]; then
        warn "No log file found at ${log_file}"
        return 1
    fi

    tail -f "$log_file"
}

# ── Main ─────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
LLaMesa — local inference control plane v0.1.1

Usage: llamesa.sh <command> [options]

Global options:
  --gpu <id|all>    Target GPU by ID (0, 1, ...) or 'all' for multi-GPU ops
                    Default: 0
                    For -dual commands, also accepts 'r9700' or 'rx9060xt'
                    to scope to one dual instance (default: both)

Commands:
  start       Start the inference server
    --model <name>      Model name (required)
    --thinking <bool>   Enable thinking mode (default: ${DEFAULT_THINKING:-true})
    --ctx <n>           Context size (default: ${DEFAULT_CTX:-131072})
    --gpu-layers <n>    GPU layers (default: ${DEFAULT_GPU_LAYERS:-99})
    --parallel <n>      Parallel slots / concurrent requests (default: 1, max: 4)
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

  start-big   Start the Vulkan combined-VRAM server (both GPUs, one process)
    --model <name>      Model name (required)
    --thinking <bool>   Enable thinking mode (default: ${DEFAULT_THINKING:-true})
    --ctx <n>           Context size (default: ${DEFAULT_CTX:-131072})
  stop-big    Stop the Vulkan combined-VRAM server
  restart-big Restart the Vulkan combined-VRAM server
    --model <name>      Model name (required — not remembered between restarts)
    --thinking <bool>   Enable thinking mode (default: ${DEFAULT_THINKING:-true})
    --ctx <n>           Context size (default: ${DEFAULT_CTX:-131072})
  status-big  Show Vulkan combined-VRAM server status as JSON
  logs-big    Stream Vulkan combined-VRAM server logs
    Requires a vulkan_split block in config.json — see docs/dual-gpu.md

  start-dual  Start two independent servers, one per GPU (ROCm)
    --model-r9700 <name>      Model for the R9700 (required)
    --model-rx9060xt <name>   Model for the RX 9060 XT (required)
    --thinking <bool>   Enable thinking mode (default: ${DEFAULT_THINKING:-true})
    --ctx <n>           Context size (default: ${DEFAULT_CTX:-131072})
  stop-dual   Stop dual-mode instance(s)
    --gpu <r9700|rx9060xt>  Scope to one instance (default: both)
  restart-dual  Restart dual-mode instance(s) with their remembered model(s)
    --gpu <r9700|rx9060xt>  Scope to one instance (default: both)
  status-dual Show dual-mode instance(s)' status as JSON
    --gpu <r9700|rx9060xt>  Scope to one instance (default: both, returned as an array)
  logs-dual   Stream one dual-mode instance's logs
    --gpu <r9700|rx9060xt>  Required — no combined-tail mode
    Requires a dual_gpu block (with r9700 and rx9060xt) in config.json — see docs/dual-gpu.md

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
        start-big)   cmd_start_big "$@" ;;
        stop-big)    cmd_stop_big "$@" ;;
        restart-big) cmd_restart_big "$@" ;;
        status-big)  cmd_status_big "$@" ;;
        logs-big)    cmd_logs_big "$@" ;;
        start-dual)   cmd_start_dual "$@" ;;
        stop-dual)    cmd_stop_dual "$@" ;;
        restart-dual) cmd_restart_dual "$@" ;;
        status-dual)  cmd_status_dual "$@" ;;
        logs-dual)    cmd_logs_dual "$@" ;;
        help|--help|-h) usage ;;
        *)           error "Unknown command: ${command}. Run 'llamesa.sh help' for usage." ;;
    esac
}

main "$@"