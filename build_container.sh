#!/bin/bash

# FinTech Tools Container Build Script
# Follows the exact workflow described in README.md

set -e # Exit on any error

# Configuration
IMAGE_NAME="fintech-tools"
VERSION="0.6" # Neovim+LazyVim (html/python), Yazi (full deps), Zellij, uv, Claude Code CLI, gh Copilot, Python 3.13. R / TeX / h2o intentionally NOT included.
TAR_FILE="$HOME/fintech-tools.tar"
SIF_FILE="fintech-tools.sif"
REMOTE_USER="gson"
REMOTE_HOST="circe.rc.usf.edu"
REMOTE_PATH="~/containers/"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
  echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
  echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
  echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

# Timer functions
start_timer() {
  STEP_START_TIME=$(date +%s)
}

end_timer() {
  local step_name="$1"
  local end_time=$(date +%s)
  local elapsed=$((end_time - STEP_START_TIME))
  local minutes=$((elapsed / 60))
  local seconds=$((elapsed % 60))

  if [ $minutes -gt 0 ]; then
    print_success "✓ $step_name completed in ${minutes}m ${seconds}s"
  else
    print_success "✓ $step_name completed in ${seconds}s"
  fi
}

format_total_time() {
  local total_seconds="$1"
  local hours=$((total_seconds / 3600))
  local minutes=$(((total_seconds % 3600) / 60))
  local seconds=$((total_seconds % 60))

  if [ $hours -gt 0 ]; then
    echo "${hours}h ${minutes}m ${seconds}s"
  elif [ $minutes -gt 0 ]; then
    echo "${minutes}m ${seconds}s"
  else
    echo "${seconds}s"
  fi
}

# Function to check if command exists
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Pushover notification functions
load_pushover_config() {
  PUSHOVER_CONFIG="$HOME/.pushover_config"
  if [ -f "$PUSHOVER_CONFIG" ]; then
    source "$PUSHOVER_CONFIG"
    if [ -n "$PUSHOVER_TOKEN" ] && [ -n "$PUSHOVER_USER" ]; then
      NOTIFICATIONS_ENABLED=true
      print_status "✓ Pushover notifications enabled"
    else
      print_warning "Pushover config found but incomplete. Notifications disabled."
      NOTIFICATIONS_ENABLED=false
    fi
  else
    print_warning "Pushover config not found at $PUSHOVER_CONFIG. Notifications disabled."
    NOTIFICATIONS_ENABLED=false
  fi
}

send_pushover_notification() {
  local title="$1"
  local message="$2"
  local priority="${3:-0}" # Default priority is normal (0)

  if [ "$NOTIFICATIONS_ENABLED" != "true" ]; then
    return 0
  fi

  if ! command_exists curl; then
    print_warning "curl not found. Cannot send notification."
    return 1
  fi

  print_status "📱 Sending notification: $title"

  # Use URL-encoded data as per Pushover API documentation
  local response=$(curl -s \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "token=${PUSHOVER_TOKEN}" \
    -d "user=${PUSHOVER_USER}" \
    -d "title=${title}" \
    -d "message=${message}" \
    -d "priority=${priority}" \
    https://api.pushover.net/1/messages.json)

  # Check if response contains "status":1 (success)
  if echo "$response" | grep -q '"status":1'; then
    print_status "✓ Notification sent successfully"
    return 0
  else
    print_warning "Failed to send notification: $response"
    return 1
  fi
}

# Check if we're in Podman VM environment
check_podman_vm() {
  if [ -d "/Users" ] && [ -d "/var/home" ]; then
    return 0 # We're in Podman VM (virtiofs mounts Mac /Users at /Users)
  else
    return 1 # We're not in Podman VM
  fi
}

# Function to check and clean up containers using the image
cleanup_containers_using_image() {
  local image_name="$1"
  local containers_using_image

  # Find containers using this image (both running and stopped)
  containers_using_image=$(podman ps -a --filter "ancestor=localhost/${image_name}" --format "{{.ID}} {{.Names}} {{.Status}}" 2>/dev/null)

  if [ -n "$containers_using_image" ]; then
    print_warning "Found containers using image ${image_name}:"
    echo "$containers_using_image"
    echo

    read -r -p "Do you want to remove these containers? (Y/n): " REPLY </dev/tty
    echo

    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
      # Get container IDs
      local container_ids=$(echo "$containers_using_image" | awk '{print $1}')

      print_status "Removing containers..."
      for container_id in $container_ids; do
        print_status "Removing container: $container_id"
        if podman rm -f "$container_id" 2>/dev/null; then
          print_success "✓ Container $container_id removed"
        else
          print_warning "Failed to remove container $container_id"
        fi
      done
    else
      print_error "Cannot proceed with image removal while containers are using it."
      print_status "Please remove containers manually and try again."
      exit 1
    fi
  fi
}

# Main function
main() {
  # Start total timer
  TOTAL_START_TIME=$(date +%s)

  # Load Pushover configuration
  load_pushover_config

  echo "========================================="
  echo "FinTech Tools Container Build Script"
  echo "Following README.md workflow"
  echo "Started at: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "========================================="

  # Send start notification
  send_pushover_notification "🚀 Container Build Started" "FinTech Tools container build process has begun on $(hostname)"

  # Check prerequisites
  print_status "Checking prerequisites..."
  start_timer

  # Check if we're on macOS
  if [[ "$OSTYPE" != "darwin"* ]]; then
    print_warning "This script was designed and tested on macOS. You may encounter issues on other platforms."
  fi

  if ! command_exists podman; then
    print_error "Podman is not installed. Please install Podman first."
    print_status "On macOS, run: brew install podman"
    print_status "Then initialize: podman machine init && podman machine start"
    exit 1
  fi

  # Check if Podman machine is running
  if ! podman machine list | grep -q "Currently running"; then
    print_error "Podman machine is not running."
    print_status "Start it with: podman machine start"
    exit 1
  fi

  # Check if Dockerfile exists
  if [ ! -f "Dockerfile" ]; then
    print_error "Dockerfile not found in current directory!"
    exit 1
  fi

  print_status "✓ macOS environment detected"
  print_status "✓ Podman installed and running"
  print_status "✓ Dockerfile found"

  end_timer "Prerequisites check"

  # Step 1: Clean existing image and build Docker Image with Podman
  print_status "Step 1: Checking for existing images and building Docker image with Podman..."

  # Check if image exists and handle it properly
  DO_BUILD=1 # 1 = build, 0 = skip

  if podman images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep -qE "^(localhost/)?${IMAGE_NAME}:${VERSION}$"; then
    print_warning "Existing image found: ${IMAGE_NAME}:${VERSION}"

    # Show image details
    print_status "Current image details:"
    podman images "localhost/${IMAGE_NAME}:${VERSION}" --format "table {{.Repository}}:{{.Tag}}  {{.Created}}  {{.Size}}"

    echo
    read -r -p "Do you want to rebuild the image? (y/N): " REBUILD_ANSWER </dev/tty
    echo

    case "${REBUILD_ANSWER}" in
    [yY] | [yY][eE][sS])
      print_status "Rebuilding image: ${IMAGE_NAME}:${VERSION}"

      # Check and clean up any containers using this image
      cleanup_containers_using_image "${IMAGE_NAME}:${VERSION}"

      # Remove the image
      if podman image rm -f "localhost/${IMAGE_NAME}:${VERSION}"; then
        print_success "✓ Existing image removed successfully"
      else
        print_error "Failed to remove existing image."
        print_status "This might be due to:"
        echo "  1. Containers still using the image (check: podman ps -a)"
        echo "  2. Image being used by other processes"
        echo "  3. Permission issues"
        exit 1
      fi
      ;;
    *)
      print_status "Keeping existing image. Skipping build — proceeding to next steps."
      DO_BUILD=0
      ;;
    esac
  else
    print_status "No existing image found. Proceeding with fresh build."
  fi

  if [ "${DO_BUILD}" -eq 1 ]; then
    echo "Command: podman build --platform linux/amd64 -t ${IMAGE_NAME}:${VERSION} ."
    start_timer

    if podman build --platform linux/amd64 -t "${IMAGE_NAME}:${VERSION}" .; then
      end_timer "Docker image build"
      send_pushover_notification "✅ Docker Build Complete" "FinTech Tools Docker image built successfully (${IMAGE_NAME}:${VERSION})"
    else
      print_error "Failed to build Docker image"
      send_pushover_notification "❌ Build Failed" "Docker image build failed. Check logs for details."
      exit 1
    fi
  fi

  # Step 2: Save image as tar file (from README Step 1)
  print_status "Saving image as tar file..."
  echo "Command: podman save -o ${TAR_FILE} localhost/${IMAGE_NAME}:${VERSION}"
  start_timer

  podman save -o "${TAR_FILE}" "localhost/${IMAGE_NAME}:${VERSION}"

  if [ $? -eq 0 ]; then
    print_status "Tar file size: $(du -h "${TAR_FILE}" | cut -f1)"
    end_timer "Image save to tar"
  else
    print_error "Failed to save image as tar file"
    exit 1
  fi

  # Step 3: Automatically enter Podman VM and convert (from README Step 2)
  print_status "Step 3: Container conversion to Singularity format..."
  start_timer

  if check_podman_vm; then
    convert_in_podman_vm
  else
    print_status "Entering Podman VM and toolbox for conversion..."
    auto_convert_via_podman_vm
  fi

  end_timer "Singularity conversion"

  # Step 4: Offer transfer to HPC (from README Step 3)
  print_status "Step 4: HPC deployment preparation..."
  start_timer
  offer_transfer_to_hpc
  end_timer "HPC transfer process"

  # Calculate and display total time
  TOTAL_END_TIME=$(date +%s)
  TOTAL_ELAPSED=$((TOTAL_END_TIME - TOTAL_START_TIME))

  echo
  echo "========================================="
  print_success "BUILD PROCESS COMPLETED SUCCESSFULLY!"
  echo "========================================="
  print_status "Total build time: $(format_total_time $TOTAL_ELAPSED)"
  print_status "Finished at: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "========================================="
  echo

  # Send completion notification
  send_pushover_notification "🎉 Build Complete" "FinTech Tools container build completed successfully in $(format_total_time $TOTAL_ELAPSED)"
}

# Convert to Singularity in Podman VM environment (README Step 2)
convert_in_podman_vm() {
  print_status "Converting to Singularity format in Podman VM..."

  # Set up build directory (following README exactly)
  BUILD_DIR="$HOME/apptainer-builds"
  print_status "Setting up build directory: ${BUILD_DIR}"
  mkdir -p "$BUILD_DIR"
  export APPTAINER_TMPDIR="$BUILD_DIR"

  # Add to bashrc as per README
  if ! grep -q "APPTAINER_TMPDIR" ~/.bashrc; then
    echo 'export APPTAINER_TMPDIR=~/apptainer-builds' >>~/.bashrc
    print_status "Added APPTAINER_TMPDIR to ~/.bashrc"
  fi

  # Check if we have apptainer
  if ! command_exists apptainer; then
    print_error "Apptainer not found in Podman VM."
    exit 1
  fi

  # Navigate to Mac home directory (mounted via virtiofs at same path in VM)
  MAC_USER=$(ls /Users/ | head -1)
  if [ -d "/Users/$MAC_USER" ]; then
    cd "/Users/$MAC_USER"
    print_status "Changed to /Users/$MAC_USER"
  fi

  # Convert following README command exactly
  print_status "Converting Docker archive to Singularity image..."
  echo "Command: apptainer build --force --arch amd64 ${SIF_FILE} docker-archive://${TAR_FILE}"

  apptainer build --force --arch amd64 "${SIF_FILE}" "docker-archive://${TAR_FILE}"

  if [ $? -eq 0 ]; then
    print_status "SIF file size: $(du -h "${SIF_FILE}" | cut -f1)"
    print_success "Singularity image created: ${SIF_FILE}"
  else
    print_error "Failed to convert to Singularity format"
    exit 1
  fi
}

# Automatically enter Podman VM and run apptainer conversion
auto_convert_via_podman_vm() {
  print_status "Entering Podman VM for apptainer conversion..."
  print_status "Using automatic conversion method..."

  # Create a temporary script that will run inside the Podman VM.
  # Use __MAC_HOME__ as a placeholder; sed replaces it with the real Mac $HOME
  # before the script is copied to disk (virtiofs mounts Mac /Users at /Users in the VM).
  TEMP_SCRIPT=$(mktemp)
  cat >"$TEMP_SCRIPT" <<'EOF'
#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

SIF_FILE="fintech-tools.sif"
MAC_HOME="__MAC_HOME__"
HOST_TAR_FILE="$MAC_HOME/fintech-tools.tar"

# Set up apptainer tmp dir
BUILD_DIR="$HOME/apptainer-builds"
mkdir -p "$BUILD_DIR"
export APPTAINER_TMPDIR="$BUILD_DIR"

if ! command -v apptainer >/dev/null 2>&1; then
    print_error "Apptainer not found in Podman VM"
    exit 1
fi

if [ ! -f "$HOST_TAR_FILE" ]; then
    print_error "TAR file not found at $HOST_TAR_FILE"
    ls -la "$MAC_HOME"/*.tar 2>/dev/null || echo "No .tar files found"
    exit 1
fi

# Build SIF directly into the Mac home directory
cd "$MAC_HOME" || { print_error "Cannot cd to $MAC_HOME"; exit 1; }

print_status "Found TAR file: $HOST_TAR_FILE"
print_status "Converting Docker archive to Singularity image..."
echo "Command: apptainer build --force --arch amd64 $SIF_FILE docker-archive://$HOST_TAR_FILE"

if apptainer build --force --arch amd64 "$SIF_FILE" "docker-archive://$HOST_TAR_FILE"; then
    print_success "Singularity image created: $MAC_HOME/$SIF_FILE"
    print_status "SIF file size: $(du -h "$SIF_FILE" | cut -f1)"
else
    print_error "Failed to convert to Singularity format"
    exit 1
fi
EOF

  # Inject the actual Mac home path (virtiofs mounts it at the same path in the VM)
  sed -i '' "s|__MAC_HOME__|${HOME}|g" "$TEMP_SCRIPT"
  chmod +x "$TEMP_SCRIPT"

  SCRIPT_NAME="convert_to_sif.sh"
  cp "$TEMP_SCRIPT" "$HOME/$SCRIPT_NAME"

  print_status "Created conversion script: $HOME/$SCRIPT_NAME"
  print_status "SSHing into Podman VM and running apptainer conversion..."

  # Mac's /Users is mounted at /Users in the Podman VM via virtiofs
  podman machine ssh -- "bash /Users/$(whoami)/$SCRIPT_NAME"

  CONVERSION_EXIT_CODE=$?

  # Clean up temporary files
  rm -f "$TEMP_SCRIPT" "$HOME/$SCRIPT_NAME"

  if [ $CONVERSION_EXIT_CODE -eq 0 ]; then
    print_success "Conversion completed successfully!"
    if [ -f "$HOME/$SIF_FILE" ]; then
      print_success "SIF file ready: $HOME/$SIF_FILE"
      SIF_FILE="$HOME/$SIF_FILE"
    fi
  else
    print_error "Conversion failed in Podman VM"
    print_status "Check that $HOME/fintech-tools.tar exists and Podman VM is running."
    exit 1
  fi
}

# Transfer to HPC (README Step 3)
offer_transfer_to_hpc() {
  if [ -f "${SIF_FILE}" ]; then
    echo
    print_status "Deploy to HPC System"
    send_pushover_notification "🔐 Transfer Ready" "Container build complete! Ready to transfer ${SIF_FILE} to CIRCE HPC. Please check your terminal to confirm transfer."
    read -r -p "Do you want to transfer ${SIF_FILE} to CIRCE HPC? (y/N): " REPLY </dev/tty
    echo

    if [[ $REPLY =~ ^[Yy]$ ]]; then
      print_status "Transferring to ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}..."
      send_pushover_notification "🔐 Credential Required" "Starting transfer to CIRCE HPC. Please enter your password when prompted."
      echo "Command: scp ${SIF_FILE} ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}"

      # Time the transfer
      transfer_start=$(date +%s)
      scp "${SIF_FILE}" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}"
      transfer_end=$(date +%s)
      transfer_time=$((transfer_end - transfer_start))

      if [ $? -eq 0 ]; then
        print_success "File transferred successfully to CIRCE in ${transfer_time}s!"
        send_pushover_notification "✅ Transfer Complete" "File transferred successfully to CIRCE HPC in ${transfer_time}s!"
      else
        print_error "Failed to transfer file to CIRCE"
        send_pushover_notification "❌ Transfer Failed" "Failed to transfer file to CIRCE HPC. Manual transfer required."
        print_status "You can transfer manually using:"
        echo "scp ${SIF_FILE} ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}"
      fi
    else
      print_status "Skipping transfer to CIRCE"
      print_status "To transfer manually, run:"
      echo "scp ${SIF_FILE} ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}"
    fi
  else
    print_warning "No .sif file found to transfer"
  fi
}

# Show usage
usage() {
  echo "Usage: $0 [OPTIONS]"
  echo
  echo "This script follows the exact workflow from README.md:"
  echo "  1. Build Docker image with Podman"
  echo "  2. Save image as tar file"
  echo "  3. Convert to Singularity format via Podman VM + toolbox"
  echo "  4. Transfer to CIRCE HPC (optional)"
  echo
  echo "Options:"
  echo "  -h, --help     Show this help message"
  echo "  -v, --version  Set version tag (default: ${VERSION})"
  echo
  echo "System Requirements:"
  echo "  - macOS with Podman installed and running"
  echo "  - Podman VM with toolbox environment"
  echo "  - Apptainer installed in toolbox"
  echo "  - Commands: podman machine ssh && toolbox enter"
  echo
  echo "Setup Instructions:"
  echo "  brew install podman"
  echo "  podman machine init && podman machine start"
  echo "  podman machine ssh -- 'toolbox create && toolbox run sudo dnf install -y apptainer'"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
  -h | --help)
    usage
    exit 0
    ;;
  -v | --version)
    VERSION="$2"
    shift 2
    ;;
  *)
    print_error "Unknown option: $1"
    usage
    exit 1
    ;;
  esac
done

# Run main function
main
