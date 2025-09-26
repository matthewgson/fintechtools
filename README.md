# FinTech Tools Container for Docker / Apptainer (Singularity)

A containerized environment for financial computing with GPU support, designed for local development and HPC deployment.

**Built and tested on macOS** with Podman virtualization for HPC deployment.

## 🚀 Quick Start

Get up and running in 3 simple steps:

### 1. Install Prerequisites
```bash
# Install Podman on macOS
brew install podman
podman machine init && podman machine start

# Set up Podman VM with Apptainer support
podman machine ssh -- "sudo dnf install -y toolbox && toolbox create"
```

### 2. Configure User Settings
Before building, customize these settings in `build_container.sh`:

```bash
# Open the build script and update these variables:
nano build_container.sh

# Required changes:
REMOTE_USER="gson"          # ← Change to YOUR username
REMOTE_HOST="circe.rc.usf.edu"  # ← Change to YOUR HPC system
REMOTE_PATH="~/containers/"     # ← Adjust path as needed

# Also update paths in the conversion script:
# Line ~200: "/run/host/Users/matthewson"  ← Change to YOUR macOS username
# Line ~350: "/run/host/Users/$(whoami)"   ← Should auto-detect, but verify
```

**Important customizations needed:**
- **`REMOTE_USER`**: Replace `"gson"` with your HPC username
- **`REMOTE_HOST`**: Replace with your HPC system (if not CIRCE)
- **`/run/host/Users/matthewson`**: Replace `matthewson` with your macOS username
- **SSH key paths**: Update paths in SSH setup if using different key names

### 3. Build Container
```bash
# Clone this repository and build
git clone <your-repo-url>
cd <repo-directory>
chmod +x build_container.sh
./build_container.sh
```

### 4. Deploy and Connect
```bash
# SSH keys will be set up automatically by the build script
# Connect to your container via SSH jump (use YOUR usernames):
ssh -J your_username@your_hpc_system your_username@compute_node -p 2222
```

**That's it!** The automated build script handles container building, Singularity conversion, HPC transfer, and SSH configuration.

---

## Overview

This project provides a Docker container based on Ubuntu 24.04 that includes comprehensive tools for financial computing and data analysis. The container is configured to run as an SSH server on port 2222, enabling remote development access on USF CIRCE HPC systems.

**Key Features:**

- **Base OS:** Ubuntu 24.04 LTS with financial computing tools
- **SSH Port:** 2222 for remote development access
- **Build Tool:** Podman (macOS) with automated Singularity conversion
- **HPC Platform:** AMD64/Linux compatible
- **IDE Support:** VSCode and Positron remote development
- **Notifications:** Optional Pushover mobile alerts for build status

## 📋 Detailed Prerequisites

**System Requirements:**

- **macOS** (tested and developed on macOS)
- **Podman** for container building and management
- **Podman VM** with toolbox environment for Singularity conversion
- **Apptainer/Singularity** for HPC-compatible container format
- **SSH access** to USF CIRCE HPC system

### Install Podman on macOS

```bash
# Using Homebrew (recommended)
brew install podman

# Initialize and start Podman machine
podman machine init
podman machine start
```

### Set up Podman VM with Toolbox

```bash
# Enter Podman VM
podman machine ssh

# Install toolbox (if not already available)
sudo dnf install -y toolbox

# Create and enter toolbox environment
toolbox create
toolbox enter

# Install Apptainer in toolbox
sudo dnf install -y apptainer

# Exit back to host
exit
exit
```

### Verify Installation

```bash
# Check Podman
podman --version

# Check Podman machine status
podman machine list

# Verify toolbox and Apptainer access
podman machine ssh -- "toolbox run apptainer --version"
```

### Optional: Configure Pushover Notifications

For build status notifications on your mobile device:

```bash
# Create Pushover configuration file
cat > ~/.pushover_config << 'EOF'
# Pushover API Configuration
# Get your API token from https://pushover.net/apps/build
# Get your user key from https://pushover.net/

# Your application's API token
PUSHOVER_TOKEN="your_api_token_here"

# Your user key (identifies your account)
PUSHOVER_USER="your_user_key_here"

# Optional: device name to send to specific device
# PUSHOVER_DEVICE=""

# Optional: sound to use for notifications
# PUSHOVER_SOUND="pushover"
EOF
```

**How to get Pushover credentials:**

- Visit [https://pushover.net/apps/build](https://pushover.net/apps/build) to create an application and get your API token
- Your user key is available on your [Pushover dashboard](https://pushover.net/)
- Install the Pushover app on your mobile device and log in with your account

## 🔧 Building the Container

### Automated Build (Recommended)

Use the provided build script for a streamlined process:

```bash
# Make the script executable and run it
chmod +x build_container.sh
./build_container.sh
```

The script will automatically:

1. Build the Docker image with Podman
2. Save it as a tar file
3. Convert to Singularity format (with automatic or manual options)
4. Optionally transfer to CIRCE HPC
5. Send push notifications for build status updates (if configured)

#### Build Script Options:

- **Automatic conversion**: Uses `podman machine ssh -- "toolbox run"` for seamless conversion
- **Manual conversion**: Provides step-by-step instructions following README exactly
- **Version control**: Use `-v` flag to specify custom version (e.g., `./build_container.sh -v 0.42`)
- **Help**: Use `--help` flag to see all options
- **Notifications**: Automatically detects Pushover configuration for mobile alerts

#### Notification Features:

If you've configured Pushover (see Prerequisites section), the build script provides:

- 🚀 **Build Start**: Notification when container build begins
- ✅ **Docker Build Complete**: Success notification when image is built
- ❌ **Build Failed**: Error alerts if any step fails
- 🔐 **Credential Required**: Alert when script needs your CIRCE password for transfer
- ✅ **Transfer Complete**: Confirmation when file successfully transfers to HPC
- 🎉 **Build Complete**: Final notification with total build time

This enables remote monitoring of long builds and alerts you exactly when credential input is needed.

The script detects your environment and guides you through the appropriate workflow.

### Manual Build Process (Advanced Users)

#### Step 1: Build Docker Image with Podman

From the directory containing the Dockerfile:

```bash
# Build the container image
podman build --platform linux/amd64 -t fintech-tools:0.3 .

# Save the image as a tar file for transfer
podman save -o ~/fintech-tools.tar localhost/fintech-tools:0.3
```

#### Step 2: Convert to Singularity Format for HPC

The Docker image must be converted to Singularity format for use on HPC systems.

**On Podman VM (Fedora):**

```bash
# Enter the Podman machine and toolbox
podman machine ssh
toolbox enter

# Set up build directory to avoid /tmp limitations
mkdir -p ~/apptainer-builds
export APPTAINER_TMPDIR=~/apptainer-builds
echo 'export APPTAINER_TMPDIR=~/apptainer-builds' >> ~/.bashrc

# Convert Docker archive to Singularity image
cd /run/host/Users/matthewson/
apptainer build --force --arch amd64 fintech-tools.sif docker-archive://fintech-tools.tar
```

#### Step 3: Deploy to HPC System

```bash
# Transfer the Singularity image to CIRCE
scp fintech-tools.sif gson@circe.rc.usf.edu:~/containers/
```

#### Verify Installation

Check if the SSH port is available:

```bash
lsof -i :2222
```

## 🔑 SSH Configuration and Remote Access

### Quick SSH Setup

The build script automatically handles SSH configuration, but here are the details for manual setup or troubleshooting.

**⚠️ User Configuration Required:**
Before using SSH connections, make sure you've updated usernames in examples below:
- Replace `your_username` with your actual HPC username
- Replace `your_hpc_system` with your HPC hostname (e.g., `circe.rc.usf.edu`)
- Replace `compute_node` with the actual compute node hostname

### SSH Connection Methods

#### VSCode Remote Development
```bash
# Direct connection via SSH jump (update usernames!)
ssh -J your_username@your_hpc_system your_username@compute_node -p 2222 -i ~/.ssh/local_mac_to_singularity
```

#### Positron IDE Remote Development
Positron requires port forwarding since it doesn't support proxy jumps directly:

```bash
# Option 1: Manual port forwarding (update usernames!)
ssh -L 2223:compute_node:2222 your_username@your_hpc_system

# Option 2: Persistent forwarding with autossh (update usernames!)
brew install autossh
autossh -M 0 -f -N -L 2223:compute_node:2222 your_username@your_hpc_system

# Then connect Positron to: localhost:2223
```

### Detailed SSH Configuration Setup

Since the container runs in rootless mode, SSH keys must be properly configured for client authentication.

#### Local Machine Setup (macOS)

Generate SSH key pair for container access:

```bash
# Generate ED25519 key pair
ssh-keygen -t ed25519 -f ~/.ssh/local_mac_to_singularity -C "your_username@mac"
```

#### CIRCE Server Setup

**1. Configure Authorized Keys**

```bash
# Add your public key to authorized_keys
nano ~/.ssh/authorized_keys
# Copy and paste the public key content from ~/.ssh/local_mac_to_singularity.pub

# Set proper permissions
chmod 600 ~/.ssh/authorized_keys
```

**2. Generate Host Keys**

```bash
# Create SSH keys directory
mkdir -p ~/ssh_keys
chmod 700 ~/ssh_keys

# Generate host keys (if they don't exist)
[ ! -f ~/ssh_keys/ssh_host_rsa_key ] && ssh-keygen -t rsa -f ~/ssh_keys/ssh_host_rsa_key -N "" -q
[ ! -f ~/ssh_keys/ssh_host_ecdsa_key ] && ssh-keygen -t ecdsa -f ~/ssh_keys/ssh_host_ecdsa_key -N "" -q
[ ! -f ~/ssh_keys/ssh_host_ed25519_key ] && ssh-keygen -t ed25519 -f ~/ssh_keys/ssh_host_ed25519_key -N "" -q
```

**3. Create SSH Daemon Configuration**

Create `sshd_config` in `~/ssh_keys` directory (this will be mounted as `/etc/ssh` in the container):

```bash
cat > ~/ssh_keys/sshd_config << 'EOF'
# SSH Daemon Configuration for Container
Port 2222
ListenAddress 0.0.0.0

# Host Keys
HostKey ~/ssh_keys/ssh_host_rsa_key
HostKey ~/ssh_keys/ssh_host_ecdsa_key
HostKey ~/ssh_keys/ssh_host_ed25519_key

# Authentication
PermitRootLogin no
PasswordAuthentication yes
PubkeyAuthentication yes
AuthorizedKeysFile ~/.ssh/authorized_keys

# Security Settings
UsePAM no
StrictModes no

# Logging and Process Management
LogLevel VERBOSE
PidFile ~/ssh_keys/sshd.pid

# Subsystems
Subsystem sftp /usr/lib/openssh/sftp-server
EOF
```

#### Positron IDE Configuration Details

**Positron Remote SSH Configuration:**

1. Open Positron IDE
2. Go to Remote SSH extension
3. Add new SSH target with:
   - **Host**: `localhost`
   - **Port**: `2223`
   - **Username**: `your_username`
   - **Identity File**: `~/.ssh/local_mac_to_singularity`

The port forwarding creates a local tunnel from your machine's port 2223 to the container's SSH port 2222 on the compute node, allowing Positron to connect as if the container were running locally.

## 📚 Included Software and Tools

### Computing Frameworks

- **NVIDIA CUDA Toolkit:** GPU acceleration support
- **Java (OpenJDK 11):** Required for H2O machine learning platform
  - Location: `/usr/bin/java`
- **Python 3.12.3:**
  - Location: `/usr/bin/python3`
- **R 4.5.1:**
  - Location: `/usr/bin/R`

### Financial Computing Libraries

- **QuantLib:** Advanced quantitative finance library
- **RQuantLib:** R interface to QuantLib with intraday trading specifications
- **H2O (3.44.0.3):** Machine learning and AI platform

### Interactive Development Tools

- Build tools (GCC, CMake)
- Version control (Git)
- Text editors (Nano, Vim)
- System monitoring (htop)
- Network utilities (wget, curl)

### HPC Integration

- **Container Runtime:** Optimized for Apptainer/Singularity on HPC systems
- **GPU Support:** CUDA-enabled with `--nv` flag for GPU acceleration
- **File System Access:** Seamless access to HPC storage and file systems
- **Simple Deployment:** Minimal dependencies, clean container design
- **Job Management:** Use host system's SLURM commands for job submission and monitoring

**Note:** This container focuses on providing a clean financial computing environment. Use host system tools for HPC-specific operations to avoid conflicts.

## 📁 Repository Files

- `Dockerfile` - Container definition and software installation
- `build_container.sh` - Automated build script with notification support
- `dev_session.sh` - Development session script for container management
- `README.md` - This documentation
- `ssh_config` - SSH client configuration template
- `sshd_config` - SSH daemon configuration template
- `.gitignore` - Git ignore rules for the repository
- `.vscode/` - VS Code workspace settings and configurations

**User-Created Files:**
- `~/.pushover_config` - Pushover notification configuration (optional, user-created)

---

## Legacy Manual Build Reference

### Build Container (Manual Method)

```bash
chmod +x build_container.sh
./build_container.sh
```
