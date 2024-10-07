#!/bin/bash
###############################################################################
#
# This build script is for running the QEMU build in a container
#
# It expects to be run in with the qemu source present in the directory called
# '$WORKSPACE/qemu', where WORKSPACE is an environment variable.
#
# In Jenkins configure the git SCM 'Additional Behaviours', 'check-out to a sub
# directory' called 'qemu'.
#
# When building locally set WORKSPACE to be the directory above the qemu
# checkout:
#   git clone https://github.com/qemu/qemu
#   WORKSPACE=$PWD/qemu ~/openbmc-build-scripts/qemu-build.sh
#
###############################################################################
#
# Script Variables:
#  http_proxy         The HTTP address of the proxy server to connect to.
#                     Default: "", proxy is not setup if this is not set
#  WORKSPACE          Path of the workspace directory where the build will
#                     occur, and output artifacts will be produced.
#  DOCKER_REG:        <optional, the URL of a docker registry to utilize
#                     instead of the default docker hub
#                     (ex. public.ecr.aws/ubuntu)
#
###############################################################################
# Trace bash processing
#set -x

# Script Variables:
http_proxy=${http_proxy:-}

if [ -z ${WORKSPACE+x} ]; then
    echo "Please set WORKSPACE variable"
    exit 1
fi

docker_reg=${DOCKER_REG:-"docker.io"}

# Docker Image Build Variables:
img_name=qemu-build

# Timestamp for job
echo "Build started, $(date)"

# Setup Proxy
if [[ -n "${http_proxy}" ]]; then
    PROXY="RUN echo \"Acquire::http::Proxy \\"\"${http_proxy}/\\"\";\" > /etc/apt/apt.conf.d/000apt-cacher-ng-proxy"
fi

# Create the docker run script
export PROXY_HOST=${http_proxy/#http*:\/\/}
export PROXY_HOST=${PROXY_HOST/%:[0-9]*}
export PROXY_PORT=${http_proxy/#http*:\/\/*:}

cat > "${WORKSPACE}"/build.sh << EOF_SCRIPT
#!/bin/bash

set -x

# Go into the build directory
cd ${WORKSPACE}/qemu

gcc --version
git submodule update --init dtc
# disable anything that requires us to pull in X
./configure \
    --target-list=arm-softmmu \
    --disable-spice \
    --disable-docs \
    --disable-gtk \
    --disable-smartcard \
    --disable-usb-redir \
    --disable-libusb \
    --disable-sdl \
    --disable-gnutls \
    --disable-vte \
    --disable-vnc \
    --disable-werror
make clean
make -j4

EOF_SCRIPT

chmod a+x "${WORKSPACE}"/build.sh

# Configure docker build

# !!!
# Keep the base docker image in sync with the image under which we run the
# resulting qemu binary.
# !!!

Dockerfile=$(cat << EOF
FROM ${docker_reg}/ubuntu:jammy

${PROXY}

ENV DEBIAN_FRONTEND noninteractive
RUN apt-get update && apt-get install -yy --no-install-recommends \
    bison \
    bzip2 \
    ca-certificates \
    flex \
    gcc \
    git \
    libc6-dev \
    libfdt-dev \
    libglib2.0-dev \
    libpixman-1-dev \
    libslirp-dev \
    make \
    ninja-build \
    python3-venv \
    python3-yaml \
    iputils-ping

RUN grep -q ${GROUPS[0]} /etc/group || groupadd -g ${GROUPS[0]} ${USER}
RUN grep -q ${UID} /etc/passwd || useradd -d ${HOME} -m -u ${UID} -g ${GROUPS[0]} ${USER}
USER ${USER}
ENV HOME ${HOME}
EOF
)

if ! docker build -t ${img_name} - <<< "${Dockerfile}" ; then
    echo "Failed to build docker container."
    exit 1
fi

docker run \
    --rm=true \
    -e WORKSPACE="${WORKSPACE}" \
    -w "${HOME}" \
    --user="${USER}" \
    -v "${HOME}":"${HOME}" \
    -t ${img_name} \
    "${WORKSPACE}"/build.sh
