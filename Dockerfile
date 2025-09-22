# Fintech Tools Docker Image
# Base: Ubuntu Latest with financial computing tools
FROM ubuntu:latest

# Labels for metadata
LABEL maintainer="Matthew Son"
LABEL description="Containerized Environment for Financial / Quantitiative Computing for HPC"
LABEL version="0.4"

# Set environment variables to avoid interactive prompts when installing packages (e.g. tzdata)
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=America/New_York

# Set locale
ENV LC_ALL=C.UTF-8
ENV LANG=C.UTF-8

# SLURM environment variables for container compatibility
ENV SLURM_CONF=/etc/slurm/slurm.conf
ENV MUNGE_SOCKET=/var/run/munge/munge.socket.2

# Set working directory
WORKDIR /work_bgfs/g/gson

# Update package lists and install system dependencies
RUN apt-get update && \
    apt-get install -y \
    locales \
    software-properties-common \
    gnupg \
    build-essential \
    pkg-config \
    python3 \
    python3-pip \
    python3-dev \
    python3-venv \
    python3-setuptools \
    openjdk-11-jdk \
    libboost-all-dev \
    libquantlib0-dev \
    libcurl4-openssl-dev \
    cmake \
    libxml2-dev \
    libxml2-utils \
    libz-dev \
    libbz2-dev \
    liblz4-dev \
    libzstd-dev \
    libsnappy-dev \
    libblas-dev \
    liblapack-dev \
    libopenblas-dev \
    libffi-dev \
    zlib1g-dev \
    libprotobuf-dev \
    protobuf-compiler \
    libhdf5-dev \
    libfontconfig1-dev \
    libfreetype6-dev \
    libpng-dev \
    libtiff5-dev \
    libtiff-dev \
    libjpeg-dev \
    libcairo2-dev \
    libxt-dev \
    libfribidi-dev \
    libharfbuzz-dev \
    pandoc \
    nvidia-cuda-toolkit \
    git \
    nano \
    vim \
    htop \
    wget \
    curl \
    sudo \
    ca-certificates \
    openssh-server && \
    locale-gen en_US.UTF-8 && \
    rm -rf /var/lib/apt/lists/*

# Install modern SLURM from Ubuntu repositories
# This uses the current stable version available in Ubuntu repos
RUN apt-get update && \
    apt-get install -y \
    slurm-wlm \
    slurm-client \
    libmunge2 \
    libmunge-dev \
    munge && \
    rm -rf /var/lib/apt/lists/*

# Install Python packages system-wide for enhanced R development (radian)
# Temporarily remove EXTERNALLY-MANAGED, install radian, then restore protection
RUN MANAGED_FILE=$(find /usr/lib/python* -name "EXTERNALLY-MANAGED" 2>/dev/null | head -1) && \
    [ -f "$MANAGED_FILE" ] && cp "$MANAGED_FILE" "$MANAGED_FILE.backup" || true && \
    rm -f /usr/lib/python*/EXTERNALLY-MANAGED && \
    python3 -m pip install --upgrade pip && \
    pip3 install radian && \
    [ -f "$MANAGED_FILE.backup" ] && mv "$MANAGED_FILE.backup" "$MANAGED_FILE" || true

    
# Add R repository and install R
RUN wget -qO- https://cloud.r-project.org/bin/linux/ubuntu/marutter_pubkey.asc | gpg --dearmor -o /usr/share/keyrings/r-project.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/r-project.gpg] https://cloud.r-project.org/bin/linux/ubuntu $(lsb_release -cs)-cran40/" | tee -a /etc/apt/sources.list.d/cran.list && \
    apt-get update && \
    apt-get install -y r-base r-base-dev && \
    rm -rf /var/lib/apt/lists/*


# Install R packages
RUN R -e "install.packages('RQuantLib', repos = 'https://cloud.r-project.org/', type = 'source', configure.args = c('--with-boost-include=/usr/include/boost/'), configure.vars = c('CPPFLAGS=\"-DQL_HIGH_RESOLUTION_DATE\"', 'LDFLAGS=-L/usr/lib'))"
RUN R -e "install.packages('h2o', repos = 'https://cloud.r-project.org/')"

# Create SLURM configuration directories and set permissions
# These will be mounted from the host system when running on HPC
RUN mkdir -p /etc/slurm \
             /var/lib/slurm \
             /var/run/munge \
             /var/log/slurm \
             /tmp/slurm && \
    chmod 755 /etc/slurm /var/lib/slurm /var/log/slurm /tmp/slurm && \
    chmod 711 /var/run/munge

# Create a minimal SLURM configuration to avoid conflicts
# This will be overridden by host mounts but provides fallback
RUN echo "# Minimal SLURM configuration for container compatibility" > /etc/slurm/slurm.conf && \
    echo "ClusterName=container_cluster" >> /etc/slurm/slurm.conf && \
    echo "ControlMachine=localhost" >> /etc/slurm/slurm.conf && \
    echo "SlurmUser=slurm" >> /etc/slurm/slurm.conf && \
    echo "SlurmdUser=root" >> /etc/slurm/slurm.conf && \
    echo "StateSaveLocation=/var/lib/slurm" >> /etc/slurm/slurm.conf && \
    echo "SlurmdSpoolDir=/tmp/slurm" >> /etc/slurm/slurm.conf && \
    echo "SwitchType=switch/none" >> /etc/slurm/slurm.conf && \
    echo "MpiDefault=none" >> /etc/slurm/slurm.conf && \
    echo "ProctrackType=proctrack/pgid" >> /etc/slurm/slurm.conf && \
    echo "TaskPlugin=task/none" >> /etc/slurm/slurm.conf && \
    echo "ReturnToService=2" >> /etc/slurm/slurm.conf && \
    echo "# JobAcctGatherParams - only use compatible options" >> /etc/slurm/slurm.conf && \
    echo "JobAcctGatherType=jobacct_gather/none" >> /etc/slurm/slurm.conf && \
    echo "AccountingStorageType=accounting_storage/none" >> /etc/slurm/slurm.conf && \
    echo "# Node definition for minimal functionality" >> /etc/slurm/slurm.conf && \
    echo "NodeName=localhost CPUs=1 State=UNKNOWN" >> /etc/slurm/slurm.conf && \
    echo "PartitionName=debug Nodes=localhost Default=YES MaxTime=INFINITE State=UP" >> /etc/slurm/slurm.conf

# Create a script to fix SLURM configuration conflicts at runtime
RUN echo '#!/bin/bash' > /usr/local/bin/fix-slurm-config.sh && \
    echo '# Comprehensive SLURM configuration fix for container environment' >> /usr/local/bin/fix-slurm-config.sh && \
    echo '# Handles JobAcctGatherParams conflicts and protocol compatibility' >> /usr/local/bin/fix-slurm-config.sh && \
    echo '' >> /usr/local/bin/fix-slurm-config.sh && \
    echo 'SLURM_CONF_FILE="/etc/slurm/slurm.conf"' >> /usr/local/bin/fix-slurm-config.sh && \
    echo 'SANITIZED_CONF="/tmp/slurm/slurm.conf.sanitized"' >> /usr/local/bin/fix-slurm-config.sh && \
    echo '' >> /usr/local/bin/fix-slurm-config.sh && \
    echo '# Create sanitized config directory' >> /usr/local/bin/fix-slurm-config.sh && \
    echo 'mkdir -p /tmp/slurm' >> /usr/local/bin/fix-slurm-config.sh && \
    echo '' >> /usr/local/bin/fix-slurm-config.sh && \
    echo 'if [ -f "$SLURM_CONF_FILE" ]; then' >> /usr/local/bin/fix-slurm-config.sh && \
    echo '    echo "Sanitizing SLURM configuration from: $SLURM_CONF_FILE"' >> /usr/local/bin/fix-slurm-config.sh && \
    echo '    ' >> /usr/local/bin/fix-slurm-config.sh && \
    echo '    # Advanced sanitization to handle multiple conflicts' >> /usr/local/bin/fix-slurm-config.sh && \
    echo '    awk '\''BEGIN{IGNORECASE=1}' >> /usr/local/bin/fix-slurm-config.sh && \
    echo '         /^\s*JobAcctGatherParams\s*=/{' >> /usr/local/bin/fix-slurm-config.sh && \
    echo '             original=$0' >> /usr/local/bin/fix-slurm-config.sh && \
    echo '             line=$0; gsub(/[ \t]/, "", line)' >> /usr/local/bin/fix-slurm-config.sh && \
    echo '             split(line, a, "=")' >> /usr/local/bin/fix-slurm-config.sh && \
    echo '             params = (a[1]=="JobAcctGatherParams") ? a[2] : line' >> /usr/local/bin/fix-slurm-config.sh && \
    echo '             ' >> /usr/local/bin/fix-slurm-config.sh && \
    echo '             # Check for conflicting parameters' >> /usr/local/bin/fix-slurm-config.sh && \
    echo '             has_pss = (params ~ /(^|,)UsePSS(,|$)/)' >> /usr/local/bin/fix-slurm-config.sh && \
    echo '             has_noshared = (params ~ /(^|,)NoShared(,|$)/)' >> /usr/local/bin/fix-slurm-config.sh && \
    echo '             ' >> /usr/local/bin/fix-slurm-config.sh && \
    echo '             if (has_pss && has_noshared) {' >> /usr/local/bin/fix-slurm-config.sh && \
    echo '                 print "# WARNING: Removed conflicting NoShared option (conflicts with UsePSS)"' >> /usr/local/bin/fix-slurm-config.sh && \
    echo '                 gsub(/(^|,)NoShared(,|$)/, ",", params)' >> /usr/local/bin/fix-slurm-config.sh && \
    echo '             }' >> /usr/local/bin/fix-slurm-config.sh && \
    echo '             ' >> /usr/local/bin/fix-slurm-config.sh && \
    echo '             # Clean up multiple commas and leading/trailing commas' >> /usr/local/bin/fix-slurm-config.sh && \
    echo '             gsub(/,,+/, ",", params)' >> /usr/local/bin/fix-slurm-config.sh && \
    echo '             sub(/^,/, "", params)' >> /usr/local/bin/fix-slurm-config.sh && \
    echo '             sub(/,$/, "", params)' >> /usr/local/bin/fix-slurm-config.sh && \
    echo '             ' >> /usr/local/bin/fix-slurm-config.sh && \
    echo '             # Use safe default if params is empty' >> /usr/local/bin/fix-slurm-config.sh && \
    echo '             if (params == "" || params ~ /^[,\s]*$/) {' >> /usr/local/bin/fix-slurm-config.sh && \
    echo '                 print "JobAcctGatherParams=UsePSS"' >> /usr/local/bin/fix-slurm-config.sh && \
    echo '             } else {' >> /usr/local/bin/fix-slurm-config.sh && \
    echo '                 print "JobAcctGatherParams=" params' >> /usr/local/bin/fix-slurm-config.sh && \
    echo '             }' >> /usr/local/bin/fix-slurm-config.sh && \
    echo '             next' >> /usr/local/bin/fix-slurm-config.sh && \
    echo '         }' >> /usr/local/bin/fix-slurm-config.sh && \
    echo '         { print }'\'' "$SLURM_CONF_FILE" > "$SANITIZED_CONF"' >> /usr/local/bin/fix-slurm-config.sh && \
    echo 'else' >> /usr/local/bin/fix-slurm-config.sh && \
    echo '    echo "No SLURM config found, creating minimal safe config"' >> /usr/local/bin/fix-slurm-config.sh && \
    echo '    cat > "$SANITIZED_CONF" << EOF' >> /usr/local/bin/fix-slurm-config.sh && \
    echo '# Minimal safe SLURM configuration for container' >> /usr/local/bin/fix-slurm-config.sh && \
    echo 'ClusterName=container_cluster' >> /usr/local/bin/fix-slurm-config.sh && \
    echo 'ControlMachine=localhost' >> /usr/local/bin/fix-slurm-config.sh && \
    echo 'SlurmUser=slurm' >> /usr/local/bin/fix-slurm-config.sh && \
    echo 'SlurmdUser=root' >> /usr/local/bin/fix-slurm-config.sh && \
    echo 'StateSaveLocation=/var/lib/slurm' >> /usr/local/bin/fix-slurm-config.sh && \
    echo 'SlurmdSpoolDir=/tmp/slurm' >> /usr/local/bin/fix-slurm-config.sh && \
    echo 'SwitchType=switch/none' >> /usr/local/bin/fix-slurm-config.sh && \
    echo 'MpiDefault=none' >> /usr/local/bin/fix-slurm-config.sh && \
    echo 'ProctrackType=proctrack/pgid' >> /usr/local/bin/fix-slurm-config.sh && \
    echo 'TaskPlugin=task/none' >> /usr/local/bin/fix-slurm-config.sh && \
    echo 'ReturnToService=2' >> /usr/local/bin/fix-slurm-config.sh && \
    echo 'JobAcctGatherType=jobacct_gather/none' >> /usr/local/bin/fix-slurm-config.sh && \
    echo 'AccountingStorageType=accounting_storage/none' >> /usr/local/bin/fix-slurm-config.sh && \
    echo 'NodeName=localhost CPUs=1 State=UNKNOWN' >> /usr/local/bin/fix-slurm-config.sh && \
    echo 'PartitionName=debug Nodes=localhost Default=YES MaxTime=INFINITE State=UP' >> /usr/local/bin/fix-slurm-config.sh && \
    echo 'EOF' >> /usr/local/bin/fix-slurm-config.sh && \
    echo 'fi' >> /usr/local/bin/fix-slurm-config.sh && \
    echo '' >> /usr/local/bin/fix-slurm-config.sh && \
    echo '# Set environment variable' >> /usr/local/bin/fix-slurm-config.sh && \
    echo 'export SLURM_CONF="$SANITIZED_CONF"' >> /usr/local/bin/fix-slurm-config.sh && \
    echo 'echo "SLURM_CONF set to: $SLURM_CONF"' >> /usr/local/bin/fix-slurm-config.sh && \
    chmod +x /usr/local/bin/fix-slurm-config.sh

# Create user matching your credentials: For file permissions
# Then use your actual UID/GID numbers (below is mine)

RUN groupadd -g 10001 usfuser && \
    groupadd -g 663800067 circe_access && \
    groupadd -g 663800106 sism_group && \
    useradd -m -s /bin/bash -u 70230911 -g 10001 -G 663800067,663800106 gson && \
    echo "gson ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers # Add gson to sudoers with no password required

# Add SLURM configuration fix to user's bashrc
RUN echo '# Fix SLURM configuration conflicts on container startup' >> /home/gson/.bashrc && \
    echo 'if [ -f /usr/local/bin/fix-slurm-config.sh ]; then' >> /home/gson/.bashrc && \
    echo '    sudo /usr/local/bin/fix-slurm-config.sh 2>/dev/null || true' >> /home/gson/.bashrc && \
    echo '    export SLURM_CONF=/tmp/slurm/slurm.conf.sanitized' >> /home/gson/.bashrc && \
    echo 'fi' >> /home/gson/.bashrc

# Set default command / User

CMD ["/bin/bash"]
USER gson