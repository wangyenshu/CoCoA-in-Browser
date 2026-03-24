#!/bin/bash
set -e

# =================CONFIGURATION=================
IMAGE_TAG="cocoa-32bit-builder"
CONTAINER_NAME="cocoa-builder-tmp"
# Define a builder name to avoid conflicts
BUILDER_NAME="cocoa-proxy-builder"
PROXY_PORT=7897
IMAGES="$(dirname "$0")"/../../../images
OUT_ROOTFS_TAR="$IMAGES"/debian-9p-rootfs.tar
OUT_ROOTFS_FLAT="$IMAGES"/debian-9p-rootfs-flat
OUT_FSJSON="$IMAGES"/debian-base-fs.json

# DETECT HOST IP
HOST_IP=$(hostname -I | awk '{print $1}')

if [ -z "$HOST_IP" ]; then
    echo "Error: Could not detect Host IP. Please set HOST_IP manually in the script."
    exit 1
fi

PROXY_URL="http://${HOST_IP}:${PROXY_PORT}"
# ===============================================

# Cleanup
rm -f Dockerfile.32bit
mkdir -p "$IMAGES"

echo "Generating Dockerfile..."

# Generate 32-bit Dockerfile
cat <<EOF > Dockerfile.32bit
FROM i386/debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# Configure Mirrors
RUN rm -f /etc/apt/sources.list.d/* && \
    echo "deb http://mirrors.ustc.edu.cn/debian bookworm main contrib non-free non-free-firmware\n\
    deb http://mirrors.ustc.edu.cn/debian bookworm-updates main contrib non-free non-free-firmware\n\
    deb http://mirrors.ustc.edu.cn/debian bookworm-backports main contrib non-free non-free-firmware\n\
    deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware" > /etc/apt/sources.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    linux-image-686 \
    systemd-sysv \
    locales \
    libterm-readline-perl-perl

RUN echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen && \
    locale-gen && \
    echo 'LANG="en_US.UTF-8"' > /etc/default/locale && \
    chsh -s /bin/bash root  

RUN apt-get -o Acquire::Check-Valid-Until=false update && \
    apt-get install -y --no-install-recommends \
    ca-certificates curl git build-essential util-linux \
    libgmp-dev libboost-filesystem-dev libboost-system-dev libboost-thread-dev \
    libreadline-dev m4 make patch pkg-config python3 \
    txt2tags texlive texlive-latex-extra texlive-full default-jre \
    && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------
# ENABLE PROXY FOR GIT AND COCOA BUILD
# By setting ENV here, everything below this line uses the proxy
# -----------------------------------------------------------
ARG PROXY_URL
ENV http_proxy=\${PROXY_URL}
ENV https_proxy=\${PROXY_URL}
ENV HTTP_PROXY=\${PROXY_URL}
ENV HTTPS_PROXY=\${PROXY_URL}

# Clone CoCoA
RUN git clone https://github.com/cocoa-official/CoCoALib.git /opt/cocoa

# Build CoCoA (using linux32 to hide 64-bit host kernel)
WORKDIR /opt/cocoa
RUN linux32 ./configure  --no-qt-gui && \
    linux32 make library doc cocoa5 examples server

# Reset Proxy
ENV http_proxy=""
ENV https_proxy=""
ENV HTTP_PROXY=""
ENV HTTPS_PROXY=""

# Fix root password and pam
RUN passwd -d root && \
    sed -i 's/nullok_secure/nullok/' /etc/pam.d/common-auth

# Configure Serial Console (Autologin)
COPY getty-noclear.conf getty-override.conf /etc/systemd/system/getty@tty1.service.d/
COPY getty-autologin-serial.conf /etc/systemd/system/serial-getty@ttyS0.service.d/

RUN systemctl mask console-getty.service && \
    systemctl enable serial-getty@ttyS0.service

# Disable Unnecessary Services (Boot Speed)
RUN systemctl disable systemd-timesyncd.service && \
    systemctl disable apt-daily.timer && \
    systemctl disable apt-daily-upgrade.timer

RUN printf '%s\n' 9p 9pnet 9pnet_virtio virtio virtio_ring virtio_pci | tee -a /etc/initramfs-tools/modules

RUN echo '#!/bin/sh' > /etc/initramfs-tools/scripts/boot-9p && \
    echo 'case \$1 in prereqs) exit 0;; esac' >> /etc/initramfs-tools/scripts/boot-9p && \
    echo '. /scripts/functions' >> /etc/initramfs-tools/scripts/boot-9p && \
    echo 'mkdir -p \${rootmnt}' >> /etc/initramfs-tools/scripts/boot-9p && \
    echo 'mount -n -t 9p -o trans=virtio,version=9p2000.L,cache=loose,rw host9p \${rootmnt}' >> /etc/initramfs-tools/scripts/boot-9p && \
    chmod +x /etc/initramfs-tools/scripts/boot-9p


RUN echo 'BOOT=boot-9p' | tee -a /etc/initramfs-tools/initramfs.conf

RUN update-initramfs -u

# Add CoCoA to startup path
RUN echo "cd /opt/cocoa/src/CoCoA-5" >> /root/.bashrc
RUN echo "./cocoa5" >> /root/.bashrc

WORKDIR /opt/cocoa/src/CoCoA-5
EOF

# Build the Image
echo "--------------------------------------------------------"
echo "Building Docker Image..."
echo "Detected Host IP: $HOST_IP"
echo "Proxy will activate AFTER apt-get install: $PROXY_URL"
echo "--------------------------------------------------------"
echo "Ensure 'Allow LAN' is ENABLED in Clash!"
echo "--------------------------------------------------------"

# Clean up old builder
docker buildx rm "$BUILDER_NAME" 2>/dev/null || true

# Configure builder with Proxy so it can pull the base image
docker buildx create \
  --name "$BUILDER_NAME" \
  --driver docker-container \
  --driver-opt env.BUILDKIT_STEP_LOG_MAX_SIZE=-1 \
  --driver-opt env.BUILDKIT_STEP_LOG_MAX_SPEED=-1 \
  --driver-opt env.http_proxy="$PROXY_URL" \
  --driver-opt env.https_proxy="$PROXY_URL" \
  --use

docker buildx build \
    --load \
    --progress=plain \
    --platform linux/386 \
    -f Dockerfile.32bit \
    -t "$IMAGE_TAG" \
    --build-arg PROXY_URL="$PROXY_URL" \
    .
# ---------------------------------------------------------

# Export Docker
docker rm -f "$CONTAINER_NAME" || true
docker create --platform linux/386 --name "$CONTAINER_NAME" "$IMAGE_TAG"
docker export "$CONTAINER_NAME" > "$OUT_ROOTFS_TAR"

rm Dockerfile.32bit

echo "Converting to JSON..."
"$(dirname "$0")"/../../../tools/fs2json.py --zstd --out "$OUT_FSJSON" "$OUT_ROOTFS_TAR"

echo "Creating flat filesystem..."
# Clear old files to prevent conflicts
rm -rf "$OUT_ROOTFS_FLAT"
mkdir -p "$OUT_ROOTFS_FLAT"
"$(dirname "$0")"/../../../tools/copy-to-sha256.py --zstd "$OUT_ROOTFS_TAR" "$OUT_ROOTFS_FLAT"

echo "Done. Artifacts created at $IMAGES"