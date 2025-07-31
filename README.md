# FinTech Tools Container for Docker / Apptainer (Singularity)

A containerized environment for financial and quantitative computing, designed for High Performance Computing (HPC) systems and remote development with VSCode / Positron IDE.

**Built and tested on macOS** with Podman virtualization for HPC deployment.

## Overview

This project provides a Docker container based on Ubuntu 24.04 (latest) that includes comprehensive tools for financial computing and data analysis. The container is configured to run as an SSH server on port 2222, enabling remote development access on USF CIRCE HPC systems.

**Key Features:**

- **Base OS:** Ubuntu 24.04 LTS
- **SSH Port:** 2222
- **Build Tool:** Podman (macOS)
- **HPC Platform:** AMD64/Linux
- **Development Environment:** macOS host with Podman VM

## Quick Start

### Prerequisites

**System Requirements:**

- **macOS** (tested and developed on macOS)
- **Podman** for container building and management
- **Podman VM** with toolbox environment for Singularity conversion
- **Apptainer/Singularity** for HPC-compatible container format
- **SSH access** to USF CIRCE HPC system

**Installation Steps:**

1. **Install Podman on macOS:**

   ```bash
   # Using Homebrew (recommended)
   brew install podman

   # Initialize and start Podman machine
   podman machine init
   podman machine start
   ```

2. **Optional: Configure Pushover Notifications:**

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
3. **Set up Podman VM with Toolbox:**

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
4. **Verify Installation:**

   ```bash
   # Check Podman
   podman --version

   # Check Podman machine status
   podman machine list

   # Verify toolbox and Apptainer access
   podman machine ssh -- "toolbox run apptainer --version"
   ```

## Building the Container

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
- **Version control**: Use `-v` flag to specify custom version (e.g., `./build_container.sh -v 0.3`)
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

### Manual Build Process

#### Step 1: Build Docker Image with Podman

From the directory containing the Dockerfile:

```bash
# Build the container image
podman build --platform linux/amd64 -t fintech-tools:0.2 .

# Save the image as a tar file for transfer
podman save -o ~/fintech-tools.tar localhost/fintech-tools:0.2
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

## SSH Configuration Setup

Since the container runs in rootless mode, SSH keys must be properly configured for client authentication.

### Local Machine Setup (macOS)

Generate SSH key pair for container access:

```bash
# Generate ED25519 key pair
ssh-keygen -t ed25519 -f ~/.ssh/local_mac_to_singularity -C "matthewson@mac"
```

### CIRCE Server Setup

#### 1. Configure Authorized Keys

```bash
# Add your public key to authorized_keys
nano ~/.ssh/authorized_keys
# Copy and paste the public key content from ~/.ssh/local_mac_to_singularity.pub

# Set proper permissions
chmod 600 ~/.ssh/authorized_keys
```

#### 2. Generate Host Keys

```bash
# Create SSH keys directory
mkdir -p ~/ssh_keys
chmod 700 ~/ssh_keys

# Generate host keys (if they don't exist)
[ ! -f ~/ssh_keys/ssh_host_rsa_key ] && ssh-keygen -t rsa -f ~/ssh_keys/ssh_host_rsa_key -N "" -q
[ ! -f ~/ssh_keys/ssh_host_ecdsa_key ] && ssh-keygen -t ecdsa -f ~/ssh_keys/ssh_host_ecdsa_key -N "" -q
[ ! -f ~/ssh_keys/ssh_host_ed25519_key ] && ssh-keygen -t ed25519 -f ~/ssh_keys/ssh_host_ed25519_key -N "" -q
```

#### 3. Create SSH Daemon Configuration

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

### Connecting to the Container

Use SSH with proxy jump to connect through the login node: (replace `gson` with your username and `<compute-hostname>` with the actual hostname of the compute node you want to access):

```bash
ssh -J gson@circe.rc.usf.edu gson@<compute-hostname> -p 2222 -i ~/.ssh/local_mac_to_singularity
```

#### Connecting with Positron IDE

Unlike VSCode, Positron's remote SSH doesn't handle proxy jump connections directly, so you need to set up port forwarding first:

**Option 1: Manual SSH Port Forwarding**

```bash
# Set up port forwarding (replace compute_node with actual hostname)
ssh -L 2223:compute_node:2222 gson@circe.rc.usf.edu

# Keep this terminal open and use Positron to connect to:
# Host: localhost
# Port: 2223
# Username: gson
```

**Option 2: Automated Port Forwarding with autossh**

```bash
# Install autossh if not already available
brew install autossh

# Set up persistent port forwarding (replace compute_node with actual hostname)
autossh -M 0 -f -N -L 2223:compute_node:2222 id@login_node

# This runs in background. Use Positron to connect to:
# Host: localhost
# Port: 2223
# Username: gson
```

**Positron Remote SSH Configuration:**

1. Open Positron IDE
2. Go to Remote SSH extension
3. Add new SSH target with:
   - **Host**: `localhost`
   - **Port**: `2223`
   - **Username**: `gson`
   - **Identity File**: `~/.ssh/local_mac_to_singularity`

The port forwarding creates a local tunnel from your machine's port 2223 to the container's SSH port 2222 on the compute node, allowing Positron to connect as if the container were running locally.

## Included Software and Tools

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

## Build Container 

### Automated Build (Recommended)

```bash
chmod +x build_container.sh
./build_container.sh
```

## Files in This Repository

- `Dockerfile` - Container definition and software installation
- `build_container.sh` - Automated build script with notification support
- `positron_1Ncontainer.sh` - SLURM job script for launching the container
- `README.md` - This documentation
- `ssh_config` - SSH client configuration template
- `sshd_config` - SSH daemon configuration template
- `~/.pushover_config` - Pushover notification configuration (user-created)
