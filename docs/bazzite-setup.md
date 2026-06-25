# Bazzite Setup Guide

This guide walks you through setting up llama.cpp with GPU acceleration on Bazzite Linux using distrobox and an AMD GPU.

## Prerequisites

- **Bazzite Linux** installed and running
- **AMD GPU** (RDNA2 or newer recommended; RDNA4 requires Mesa 25+)
- Basic familiarity with terminal commands

---

## 1. Install distrobox

Bazzite may include distrobox by default. Check:

```bash
distrobox --version
```

If not installed:

```bash
# Via Flatpak (recommended on Bazzite)
flatpak install com.github.coldfix.distrobox

# Or via dnf if coreutils are enabled
sudo dnf install distrobox
```

## 2. Create a distrobox Container

Create an Ubuntu 22.04 container (compatible with ROCm):

```bash
distrobox create --name rocm-r9700 --image docker.io/library/ubuntu:22.04
```

Enter the container:

```bash
distrobox enter rocm-r9700
```

## 3. Install Dependencies Inside Container

```bash
# Update and install build tools
sudo apt update
sudo apt install -y git cmake g++ python3 python3-pip curl wget

# Install Vulkan dependencies
sudo apt install -y libvulkan1 vulkan-tools mesa-vulkan-drivers
```

## 4. Install Mesa Drivers

For AMD GPU support with Vulkan, you need recent Mesa drivers. For RDNA4 (like the R9700), Mesa 25+ is required.

```bash
# Add Kisak's PPA for newer Mesa
sudo add-apt-repository ppa:kisak/turtle
sudo apt update
sudo apt install --install-recommends mesa-vulkan-drivers
```

Verify:

```bash
vulkaninfo --summary
```

You should see your AMD GPU listed as a Vulkan device.

## 5. Build llama.cpp with Vulkan Backend

```bash
# Clone llama.cpp
git clone https://github.com/ggml-org/llama.cpp.git
cd llama.cpp

# Checkout a stable release (recommended)
git tag -l | sort -V | tail -10  # check latest tags
git checkout bXXX  # replace with latest version

# Build with Vulkan GPU support
mkdir build && cd build
cmake .. -DGGML_VULKAN=ON -DLLAMA_SERVER_LOGFILE=ON
make -j$(nproc)
```

The server binary will be at: `llama.cpp/build/bin/llama-server`

Test it:

```bash
./bin/llama-server --help
```

List GPU devices:

```bash
./bin/llama-server --list-devices
```

You should see your AMD GPU listed.

## 6. Install huggingface_hub (for model downloads)

```bash
pip3 install huggingface_hub
```

## 7. Add User to Video/Render Groups

Exit the container and on the host:

```bash
sudo usermod -aG video,$(id -gn) $USER
```

Log out and back in for group changes to take effect.

## 8. Set Up Models Directory

Create a directory for your models on a large disk:

```bash
mkdir -p /var/mnt/games/models
```

You can download models manually from HuggingFace or use LLaMesa's built-in `/download` command later.

## 9. Test Everything

Inside the container, test with a small model first:

```bash
# Download a small test model
huggingface-cli download bartowski/Llama-3.2-1B-Instruct-GGUF "Llama-3.2-1B-Instruct-Q4_K_M.gguf" --local-dir /var/mnt/games/models/test-model

# Run the server
/var/mnt/games/models/test-model/llama.cpp/build/bin/llama-server \
    --model /var/mnt/games/models/test-model/Llama-3.2-1B-Instruct-Q4_K_M.gguf \
    --n-gpu-layers 99 \
    --ctx-size 4096 \
    --port 1234
```

If the server starts and shows VRAM usage, GPU acceleration is working!

## 10. Run LLaMesa Installer

Once everything is working, run the LLaMesa installer:

```bash
cd /path/to/llamesa
bash install.sh
```

---

## Troubleshooting

### Vulkan not detected

- Make sure Mesa drivers are installed inside the container
- Check `vulkaninfo --summary` shows your GPU
- On Bazzite, GPU passthrough to containers may require additional setup

### Model loads slowly or CPU usage is high

- Verify `--n-gpu-layers 99` is set (offloads all layers to GPU)
- Check VRAM is sufficient for the model
- Monitor with `rocm-smi` inside the container

### Port already in use

```bash
# Find what's using port 1234
ss -tlnp | grep 1234

# Kill the process or choose a different port
```

---

## Next Steps

After setting up Bazzite, configure the Windows client: see [windows-setup.md](./windows-setup.md).