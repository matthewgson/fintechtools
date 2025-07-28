# Fintech Tools Docker Image
# Base: Ubuntu Latest with financial computing tools
FROM ubuntu:latest

# Labels for metadata
LABEL maintainer="Matthew Son"
LABEL description="Containerized Environment for Financial / Quantitiative Computing for HPC"
LABEL version="0.22"

# Set environment variables to avoid interactive prompts when installing packages (e.g. tzdata)
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=America/New_York

# Set locale
ENV LC_ALL=C.UTF-8
ENV LANG=C.UTF-

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


# Create user matching your credentials: For file permissions
# Then use your actual UID/GID numbers (below is mine)

RUN groupadd -g 10001 usfuser && \
    groupadd -g 663800067 circe_access && \
    groupadd -g 663800106 sism_group && \
    useradd -m -s /bin/bash -u 70230911 -g 10001 -G 663800067,663800106 gson && \
    echo "gson:fintech" | chpasswd && \
    echo "gson ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers # Add gson to sudoer container

# Set default command / User

CMD ["/bin/bash"]
USER gson