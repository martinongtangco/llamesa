#!/usr/bin/env bash
# LLaMesa — First-time Installation Wizard
# Installs llamesa.sh and configures ~/.llamesa/config.json on Bazzite Linux
# License: MIT

set -euo pipefail

# ── Colors ───────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

check_mark="✓"
cross_mark="✗"
warn_mark="⚠"

# ── Helpers ──────────────────────────────────────────────────────────────

info()    { echo -e "${GREEN}[INFO]${RESET} $*"; }
warn()    { echo -e "${YELLOW}${warn_mark}${RESET} $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
success() { echo -e "${GREEN}${check_mark} $*${RESET}"; }

prompt() {
    local prompt_text="$1"
    local default="${2:-}"
    local result

    if [[ -n "$default" ]]; then
        echo -n "${CYAN}${prompt_text} [${default}]${RESET} "
    else
        echo -n "${CYAN}${prompt_text}${RESET} "
    fi
    read -r result

    if [[ -z "$result" ]] && [[ -n "$default" ]]; then
        echo "$default"
    else
        echo "$result"
    fi
}

# ── Banner ───────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}LLaMesa Installer v0.1${RESET}"
echo "======================"
echo ""

# ── Environment Detection ────────────────────────────────────────────────

info "Detecting environment..."

# Check for Bazzite (or fallback to any Fedora-based system)
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    os_name="$NAME"
    info "OS: ${os_name}"

    if echo "$os_name" | grep -qi "bazzite"; then
        success "Bazzite Linux detected"
    else
        warn "Not running Bazzite Linux (detected: ${os_name}). LLaMesa is designed for Bazzite but may work on other systems."
    fi
else
    warn "Could not detect OS (no /etc/os-release)"
fi

# ── Dependency Checks ────────────────────────────────────────────────────

# Check distrobox
if command -v distrobox &>/dev/null; then
    success "distrobox found ($(distrobox --version 2>/dev/null || echo 'unknown version'))"
else
    error "distrobox not found. Install it first: https://github.com/89luca89/distrobox"
fi

# Check Python3 inside container (will check after container selection)
# Check curl
if command -v curl &>/dev/null; then
    success "curl found"
else
    warn "curl not found. Some features may not work."
fi

echo ""

# ── Container Selection ──────────────────────────────────────────────────

info "Available distrobox containers:"
container_list=$(distrobox list 2>/dev/null | grep -oP '(?<=\().*?(?=\))' || true)

if [[ -z "$container_list" ]]; then
    # Try alternate parsing
    container_list=$(distrobox list 2>/dev/null | awk '/^\s*\*/{print $2}' || true)
fi

if [[ -n "$container_list" ]]; then
    echo "$container_list" | nl -w2 -s') '
    echo ""
fi

container=$(prompt "Which distrobox container has your llama.cpp build?" "")

if [[ -z "$container" ]]; then
    error "No container specified."
fi

# Validate container exists
if ! distrobox list 2>/dev/null | grep -q "$container"; then
    warn "Container '${container}' not found in distrobox list. It may still exist."
    read -p "Continue anyway? (y/N): " confirm
    if [[ "$confirm" != "y" ]] && [[ "$confirm" != "Y" ]]; then
        error "Aborted."
    fi
fi

success "Using container: ${container}"
echo ""

# ── Locate llama-server ──────────────────────────────────────────────────

info "Locating llama-server binary inside ${container}..."

# Try common locations
llama_binary=""
common_paths=(
    "/run/host/home/*/llama.cpp/build/bin/llama-server"
    "/home/*/llama.cpp/build/bin/llama-server"
    "/opt/llama.cpp/build/bin/llama-server"
    "/usr/local/bin/llama-server"
)

# First try to find it automatically
auto_detected=$(distrobox enter "$container" -- bash -c "
    # Search common locations
    for path in /run/host/home/*/llama.cpp/build/bin/llama-server; do
        if [[ -x \"\$path\" ]]; then
            echo \"\$path\"
            break
        fi
    done

    # Try which
    which llama-server 2>/dev/null || true

    # Search broader
    find /run/host/home /home /opt -name 'llama-server' -type f -executable 2>/dev/null | head -1
" 2>/dev/null | head -1)

if [[ -n "$auto_detected" ]]; then
    llama_binary="$auto_detected"
    success "Found: ${llama_binary}"
else
    info "Could not auto-detect llama-server. Common locations:"
    echo "  /run/host/home/<user>/llama.cpp/build/bin/llama-server"
    echo "  /usr/local/bin/llama-server"
    echo ""

    llama_binary=$(prompt "Path to llama-server (inside container)?" "")
    if [[ -z "$llama_binary" ]]; then
        error "llama-server path is required."
    fi

    # Validate
    if ! distrobox enter "$container" -- bash -c "[[ -x '${llama_binary}' ]]" 2>/dev/null; then
        warn "Cannot verify binary at ${llama_binary}. It must be accessible inside the container."
    fi
fi

success "llama-server: ${llama_binary}"
echo ""

# ── Models Directory ─────────────────────────────────────────────────────

models_dir=$(prompt "Where are your models stored?" "/var/mnt/games/models")

if [[ ! -d "$models_dir" ]]; then
    warn "Models directory does not exist yet: ${models_dir}"
    read -p "Create it? (Y/n): " create_dir
    if [[ "$create_dir" != "n" ]] && [[ "$create_dir" != "N" ]]; then
        mkdir -p "$models_dir" 2>/dev/null && success "Created ${models_dir}" || warn "Could not create directory"
    fi
else
    # Count models
    model_count=$(find "$models_dir" -name "*.gguf" -not -name "mmproj-*" -type f 2>/dev/null | wc -l)
    if [[ $model_count -gt 0 ]]; then
        success "Found ${model_count} model(s):"
        find "$models_dir" -name "*.gguf" -not -name "mmproj-*" -type f 2>/dev/null | while read -r f; do
            dir_name=$(basename "$(dirname "$f")")
            file_size=$(du -h "$f" 2>/dev/null | cut -f1)
            echo "  - ${dir_name} (${file_size})"
        done
    else
        info "No models found in ${models_dir}"
    fi
fi

echo ""

# ── Default Settings ─────────────────────────────────────────────────────

default_ctx=$(prompt "Default context size?" "131072")
default_thinking=$(prompt "Default thinking mode? (on/off)" "on")
default_port=$(prompt "Default port?" "1234")

# Normalize thinking
if [[ "$default_thinking" == "on" ]] || [[ "$default_thinking" == "true" ]]; then
    default_thinking="true"
elif [[ "$default_thinking" == "off" ]] || [[ "$default_thinking" == "false" ]]; then
    default_thinking="false"
else
    default_thinking="true"
fi

# Validate port
if [[ -n "$default_port" ]]; then
    if ss -tlnp 2>/dev/null | grep -q ":${default_port} "; then
        warn "Port ${default_port} is already in use!"
    fi
fi

echo ""

# ── Check huggingface_hub ────────────────────────────────────────────────

info "Checking for huggingface_hub (needed for downloads)..."

hf_check=$(distrobox enter "$container" -- bash -c "python3 -c 'import huggingface_hub; print(huggingface_hub.__version__)' 2>/dev/null || echo ''" 2>/dev/null)

if [[ -n "$hf_check" ]]; then
    success "huggingface_hub ${hf_check} found"
else
    warn "huggingface_hub not found in container. Downloads will not work."
    warn "Install with: distrobox enter ${container} -- pip3 install huggingface_hub"
fi

echo ""

# ── SSH Key Check ────────────────────────────────────────────────────────

if [[ -f "${HOME}/.ssh/id_ed25519.pub" ]] || [[ -f "${HOME}/.ssh/id_rsa.pub" ]]; then
    success "SSH key found"
else
    warn "No SSH key found. Windows client will use password auth."
    warn "Set up keys: ssh-keygen -t ed25519"
fi

echo ""

# ── Write Config ─────────────────────────────────────────────────────────

info "Writing configuration..."

mkdir -p "${HOME}/.llamesa"

cat > "${HOME}/.llamesa/config.json" <<EOF
{
  "models_dir": "${models_dir}",
  "llama_binary": "${llama_binary}",
  "distrobox_container": "${container}",
  "default_context": ${default_ctx},
  "default_gpu_layers": 99,
  "default_thinking": ${default_thinking},
  "port": ${default_port}
}
EOF

success "Config written to ${HOME}/.llamesa/config.json"

# ── Install llamesa.sh ───────────────────────────────────────────────────

# Determine the source of llamesa.sh
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_script=""

if [[ -f "${script_dir}/server/llamesa.sh" ]]; then
    source_script="${script_dir}/server/llamesa.sh"
elif [[ -f "${script_dir}/llamesa.sh" ]]; then
    source_script="${script_dir}/llamesa.sh"
elif command -v git &>/dev/null; then
    # Try to fetch from repo
    info "Cloning llamesa.sh from GitHub..."
    git clone --depth 1 https://github.com/martinongtangco/llamesa.git /tmp/llamesa-repo 2>/dev/null
    if [[ -f "/tmp/llamesa-repo/server/llamesa.sh" ]]; then
        source_script="/tmp/llamesa-repo/server/llamesa.sh"
        rm -rf /tmp/llamesa-repo
    fi
fi

if [[ -n "$source_script" ]] && [[ -f "$source_script" ]]; then
    cp "$source_script" "${HOME}/.llamesa/llamesa.sh"
    chmod +x "${HOME}/.llamesa/llamesa.sh"
    success "Installed ${HOME}/.llamesa/llamesa.sh"
else
    warn "Could not find llamesa.sh to install."
    warn "Copy it manually to ${HOME}/.llamesa/llamesa.sh"
fi

# ── Shell Integration (optional) ─────────────────────────────────────────

echo ""
read -p "Add llamesa to PATH in ~/.bashrc? (Y/n): " add_path
if [[ "$add_path" != "n" ]] && [[ "$add_path" != "N" ]]; then
    if ! grep -q ".llamesa" "${HOME}/.bashrc" 2>/dev/null; then
        echo "" >> "${HOME}/.bashrc"
        echo "# LLaMesa" >> "${HOME}/.bashrc"
        echo 'export PATH="$HOME/.llamesa:$PATH"' >> "${HOME}/.bashrc"
        success "Added to ~/.bashrc"
    else
        info "Already in ~/.bashrc"
    fi
fi

# ── Done ─────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}Installation complete!${RESET}"
echo ""
echo "Test with:"
echo "  bash ${HOME}/.llamesa/llamesa.sh status"
echo ""
echo "Or reload your shell and run:"
echo "  llamesa status"
echo ""
echo "For Windows client, see: docs/windows-setup.md"
echo ""