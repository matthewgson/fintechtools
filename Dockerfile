# Fintech Tools Docker Image
# Labels for metadata
LABEL maintainer="Matthew Son"
LABEL description="Containerized Environment for Financial / Quantitiative Computing for HPC"
LABEL version="0.1"

# Base: Ubuntu Latest with financial computing tools
FROM ubuntu:latest

# Set default command
CMD ["/bin/bash"]

# Set environment variables to avoid interactive prompts
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# Set working directory
WORKDIR /work_bgfs/g/gson

# Update package lists and install system dependencies
RUN apt-get update && apt-get install -y \
    software-properties-common \
    gnupg \
    build-essential \
    python3 \
    python3-pip \
    python3-dev \
    openjdk-11-jdk \
    libboost-all-dev \
    libquantlib0-dev \
    libcurl4-openssl-dev \
    cmake \
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
    wget \
    curl \
    ca-certificates \
    openssh-server sudo && \
    rm -rf /var/lib/apt/lists/*


# Add R repository and install R
RUN apt-key adv --keyserver keyserver.ubuntu.com --recv-keys E298A3A825C0D65DFD57CBB651716619E084DAB9 && \
    add-apt-repository "deb https://cloud.r-project.org/bin/linux/ubuntu $(lsb_release -cs)-cran40/" && \
    apt-get update && \
    apt-get install -y r-base && \
    rm -rf /var/lib/apt/lists/*


# Install R packages
RUN R -e "install.packages('RQuantLib', repos = 'https://cloud.r-project.org/', type = 'source', configure.args = c('--with-boost-include=/usr/include/boost/'), configure.vars = c('CPPFLAGS=\"-DQL_HIGH_RESOLUTION_DATE\"', 'LDFLAGS=-L/usr/lib'))"
RUN R -e "install.packages('h2o', repos = 'https://cloud.r-project.org/')"


# Configure SSH with custom port
RUN mkdir -p /var/run/sshd && \
    echo "Port 2222" >> /etc/ssh/sshd_config && \
    echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config && \
    echo "PermitRootLogin no" >> /etc/ssh/sshd_config && \
    echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config

# A Sticky note: Expose custom SSH port
EXPOSE 2222

# Start SSH daemon on custom port
RUN echo '#!/bin/bash\n/usr/sbin/sshd -D' > /start_ssh.sh && \
    chmod +x /start_ssh.sh

# Create user matching your credentials: For file permissions
# Then use your actual UID/GID numbers (below is mine)

RUN groupadd -g 10001 usfuser && \
    groupadd -g 663800067 circe_access && \
    groupadd -g 663800106 sism_group && \
    useradd -m -s /bin/bash -u 70230911 -g 10001 -G 663800067,663800106 gson && \
    echo "gson:fintech” | chpasswd && \
    echo "gson ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers # Add gson to sudoer container