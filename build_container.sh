#!/bin/bash

# FinTech Tools Container Build Script
# Follows the exact workflow described in README.md

set -e  # Exit on any error

# Configuration
IMAGE_NAME="fintech-tools"
VERSION="0.3"
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
    local priority="${3:-0}"  # Default priority is normal (0)
    
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
    if [ -d "/run/host/Users" ]; then
        return 0  # We're in Podman VM
    else
        return 1  # We're not in Podman VM
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
    print_status "Step 1: Cleaning existing image and building Docker image with Podman..."
    
    # Check if image exists and remove it
    if podman image exists "localhost/${IMAGE_NAME}:${VERSION}" 2>/dev/null; then
        print_status "Removing existing image: ${IMAGE_NAME}:${VERSION}"
        podman image rmi -f "localhost/${IMAGE_NAME}:${VERSION}" || true
    fi
    
    echo "Command: podman build --platform linux/amd64 -t ${IMAGE_NAME}:${VERSION} ."
    start_timer
    
    podman build --platform linux/amd64 -t "${IMAGE_NAME}:${VERSION}" .
    
    if [ $? -eq 0 ]; then
        end_timer "Docker image build"
        send_pushover_notification "✅ Docker Build Complete" "FinTech Tools Docker image built successfully (${IMAGE_NAME}:${VERSION})"
    else
        print_error "Failed to build Docker image"
        send_pushover_notification "❌ Build Failed" "Docker image build failed. Check logs for details."
        exit 1
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
        echo 'export APPTAINER_TMPDIR=~/apptainer-builds' >> ~/.bashrc
        print_status "Added APPTAINER_TMPDIR to ~/.bashrc"
    fi
    
    # Check if we have apptainer
    if ! command_exists apptainer; then
        print_error "Apptainer not found. Make sure you're in the toolbox environment."
        print_status "Run: toolbox enter"
        exit 1
    fi
    
    # Navigate to the host mount point if available
    if [ -d "/run/host/Users/matthewson" ]; then
        cd /run/host/Users/matthewson
        print_status "Changed to /run/host/Users/matthewson"
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

# Automatically enter Podman VM and toolbox for conversion
auto_convert_via_podman_vm() {
    print_status "Automatically entering Podman VM and toolbox for conversion..."
    print_status "Using automatic conversion method..."
    
    # Create a temporary script that will run inside the toolbox
    TEMP_SCRIPT=$(mktemp)
    cat > "$TEMP_SCRIPT" << 'EOF'
#!/bin/bash

# Colors for output inside VM
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Set up environment variables
IMAGE_NAME="fintech-tools"
VERSION="0.3"
SIF_FILE="fintech-tools.sif"

print_status "Setting up build directory in toolbox..."
BUILD_DIR="$HOME/apptainer-builds"
mkdir -p "$BUILD_DIR"
export APPTAINER_TMPDIR="$BUILD_DIR"

# Add to bashrc as per README
if ! grep -q "APPTAINER_TMPDIR" ~/.bashrc; then
    echo 'export APPTAINER_TMPDIR=~/apptainer-builds' >> ~/.bashrc
    print_status "Added APPTAINER_TMPDIR to ~/.bashrc"
fi

# Check if we have apptainer
if ! command -v apptainer >/dev/null 2>&1; then
    print_error "Apptainer not found in toolbox environment"
    exit 1
fi

# Navigate to the host mount point and find the TAR file
cd /run/host/Users/matthewson
HOST_TAR_FILE="/run/host/Users/matthewson/fintech-tools.tar"

if [ ! -f "$HOST_TAR_FILE" ]; then
    print_error "TAR file not found at $HOST_TAR_FILE"
    print_status "Available files in directory:"
    ls -la /run/host/Users/matthewson/*.tar 2>/dev/null || echo "No .tar files found"
    exit 1
fi

print_status "Found TAR file at: $HOST_TAR_FILE"
print_status "Changed to /run/host/Users/matthewson"

# Convert following README command exactly
print_status "Converting Docker archive to Singularity image..."
echo "Command: apptainer build --force --arch amd64 ${SIF_FILE} docker-archive://${HOST_TAR_FILE}"

if apptainer build --force --arch amd64 "${SIF_FILE}" "docker-archive://${HOST_TAR_FILE}"; then
    print_success "Singularity image created: ${SIF_FILE}"
    print_status "SIF file size: $(du -h "${SIF_FILE}" | cut -f1)"
    
    # Copy the SIF file back to host if we're in a different location
    if [ -d "/run/host/Users/matthewson" ] && [ ! -f "/run/host/Users/matthewson/${SIF_FILE}" ]; then
        cp "${SIF_FILE}" "/run/host/Users/matthewson/"
        print_status "Copied SIF file to host directory"
    fi
else
    print_error "Failed to convert to Singularity format"
    exit 1
fi
EOF

    # Make the temporary script executable
    chmod +x "$TEMP_SCRIPT"
    
    # Copy the script to a location accessible by Podman VM
    SCRIPT_NAME="convert_to_sif.sh"
    cp "$TEMP_SCRIPT" "$HOME/$SCRIPT_NAME"
    
    print_status "Created conversion script: $HOME/$SCRIPT_NAME"
    print_status "Following README steps: podman machine ssh -> toolbox enter -> conversion"
    
    # Step 1: Enter Podman machine SSH (following README exactly)
    print_status "Step 1: Entering Podman machine (podman machine ssh)..."
    print_status "Step 2: Entering toolbox environment (toolbox enter)..."
    print_status "Step 3: Running apptainer conversion..."
    
    # Execute the conversion following README steps exactly:
    # 1. podman machine ssh 
    # 2. toolbox enter
    # 3. run the conversion script
    # Combined into: podman machine ssh -- "toolbox run script"
    podman machine ssh -- "toolbox run bash /run/host/Users/$(whoami)/$SCRIPT_NAME"
    
    CONVERSION_EXIT_CODE=$?
    
    # Clean up temporary files
    rm -f "$TEMP_SCRIPT" "$HOME/$SCRIPT_NAME"
    
    if [ $CONVERSION_EXIT_CODE -eq 0 ]; then
        print_success "Conversion completed successfully!"
        
        # Check if SIF file was created in the expected location
        if [ -f "$HOME/$SIF_FILE" ] || [ -f "./$SIF_FILE" ]; then
            print_success "SIF file found and ready for transfer"
            # Update the SIF_FILE path for the transfer function
            if [ -f "$HOME/$SIF_FILE" ]; then
                SIF_FILE="$HOME/$SIF_FILE"
            fi
        else
            print_warning "SIF file may be in Podman VM. Checking..."
        fi
    else
        print_error "Conversion failed in Podman VM toolbox"
        print_status "You may need to check the TAR file location manually"
        exit 1
    fi
}

# Transfer to HPC (README Step 3)
offer_transfer_to_hpc() {
    if [ -f "${SIF_FILE}" ]; then
        echo
        print_status "Deploy to HPC System"
        send_pushover_notification "🔐 Transfer Ready" "Container build complete! Ready to transfer ${SIF_FILE} to CIRCE HPC. Please check your terminal to confirm transfer."
        read -p "Do you want to transfer ${SIF_FILE} to CIRCE HPC? (y/N): " -n 1 -r
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
        -h|--help)
            usage
            exit 0
            ;;
        -v|--version)
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
