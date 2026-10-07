#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IMAGE_NAME="${IMAGE_NAME:-carla-editor:0.9.15-ubuntu20.04}"
CARLA_BRANCH="${CARLA_BRANCH:-0.9.15}"
UNREAL_BRANCH="${UNREAL_BRANCH:-carla}"
BUILD_DIR="${BUILD_DIR:-$SCRIPT_DIR/carla-build}"
BASE_IMAGE="${IMAGE_NAME}-base"
BUILD_CONTAINER="carla-editor-finish-$$"
NO_CACHE=0

usage() {
  cat <<'USAGE'
Build a CARLA 0.9.15 Unreal Editor/cooker image using Ubuntu 20.04.

Required environment variables:
  EPIC_USER   GitHub username for CarlaUnreal/UnrealEngine
  EPIC_PASS   GitHub token/password with access to the repository

Optional environment variables:
  IMAGE_NAME       Output Docker image tag
                   default: carla-editor:0.9.15-ubuntu20.04
  CARLA_BRANCH     CARLA git branch/tag            default: 0.9.15
  UNREAL_BRANCH    CARLA Unreal Engine branch      default: carla
  BUILD_DIR        Host folder used as CARLA's Build/ directory
                   default: <script folder>/carla-build

Options:
  --no-cache       Disable Docker layer cache for the base image
                   (NOT recommended for normal retries)
  --help           Show this help

How it works:
  Phase 1 (docker build): Unreal Engine, CARLA source, Content download and
          URL patches -> <IMAGE_NAME>-base. Fully layer-cached.
  Phase 2 (docker run):   `make setup` and `make CarlaUE4Editor` run in a
          container with BUILD_DIR mounted as CARLA's Build/ folder. The
          container is then committed as <IMAGE_NAME>.

  Build/ (third-party dependencies) is NOT part of the final image. It stays
  on the host in BUILD_DIR. Always mount it when you run the image:
    docker run --rm -it -v "<BUILD_DIR>:/home/carla/carla/Build" <IMAGE_NAME>
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-cache)
      NO_CACHE=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

: "${EPIC_USER:?EPIC_USER must be set}"
: "${EPIC_PASS:?EPIC_PASS must be set}"

command -v docker >/dev/null 2>&1 || {
  echo "ERROR: docker is not installed or not in PATH." >&2
  exit 1
}
docker info >/dev/null 2>&1 || {
  echo "ERROR: Docker daemon is not reachable." >&2
  exit 1
}
docker buildx version >/dev/null 2>&1 || {
  echo "ERROR: Docker Buildx support is required." >&2
  exit 1
}

TMP_DIR="$(mktemp -d -t carla-editor-build.XXXXXXXX)"
NETRC_FILE="$TMP_DIR/netrc"
cleanup() {
  rm -rf "$TMP_DIR"
  docker rm -f "$BUILD_CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

# Host-side Build/ folder. The container user (uid 1000) must be able to write
# to it even if your host uid differs, hence the permissive mode.
mkdir -p "$BUILD_DIR"
chmod 777 "$BUILD_DIR"

cat > "$NETRC_FILE" <<EOF_NETRC
machine github.com
  login ${EPIC_USER}
  password ${EPIC_PASS}
EOF_NETRC
chmod 600 "$NETRC_FILE"

# This helper patches only Update.sh's download function.
cat > "$TMP_DIR/patch_update.py" <<'PY_UPDATE'
from pathlib import Path

p = Path("Update.sh")
s = p.read_text()
old = """  if hash aria2c 2>/dev/null; then
    echo -e \"${CONTENT_LINK}\\n\\tout=Content.tar.gz\" > .aria2c.input
    aria2c -j16 -x16 --input-file=.aria2c.input
    rm -f .aria2c.input
  else
    wget -c ${CONTENT_LINK} -O Content.tar.gz
  fi
"""
new = """  CACHE_DIR=\"${CARLA_CONTENT_CACHE:-${HOME}/.cache/carla-content}\"
  CACHE_ARCHIVE=\"${CACHE_DIR}/${CONTENT_ID}.tar.gz\"
  mkdir -p \"${CACHE_DIR}\"
  if [[ -f \"${CACHE_ARCHIVE}\" ]] && tar -tzf \"${CACHE_ARCHIVE}\" >/dev/null 2>&1; then
    echo \"Using cached CARLA content archive: ${CACHE_ARCHIVE}\"
    cp -f \"${CACHE_ARCHIVE}\" Content.tar.gz
  elif hash aria2c 2>/dev/null; then
    echo -e \"${CONTENT_LINK}\\n\\tout=Content.tar.gz\" > .aria2c.input
    aria2c -j16 -x16 --input-file=.aria2c.input
    rm -f .aria2c.input
    tar -tzf Content.tar.gz >/dev/null
    cp -f Content.tar.gz \"${CACHE_ARCHIVE}\"
  else
    wget -c ${CONTENT_LINK} -O Content.tar.gz
    tar -tzf Content.tar.gz >/dev/null
    cp -f Content.tar.gz \"${CACHE_ARCHIVE}\"
  fi
"""
if old not in s:
    raise SystemExit("Update.sh download block not found")
p.write_text(s.replace(old, new, 1))
PY_UPDATE

# NOTE: this heredoc is quoted, so its content is literal. Inside the sed
# commands below, a single backslash (\.) is what sed needs. Do not double it.
cat > "$TMP_DIR/Dockerfile" <<'EOF_DOCKERFILE'
# syntax=docker/dockerfile:1.7

FROM ubuntu:20.04

ARG CARLA_BRANCH=0.9.15
ARG UNREAL_BRANCH=carla

USER root
ENV DEBIAN_FRONTEND=noninteractive

# CARLA 0.9.15 Ubuntu 20.04 toolchain. Kept identical to the previous build
# script so Docker can reuse its cached layer.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      wget \
      software-properties-common \
      gnupg \
      dirmngr \
      apt-transport-https && \
    add-apt-repository ppa:ubuntu-toolchain-r/test && \
    wget -qO /usr/share/keyrings/apt-llvm.asc https://apt.llvm.org/llvm-snapshot.gpg.key && \
    echo "deb [signed-by=/usr/share/keyrings/apt-llvm.asc] http://apt.llvm.org/focal/ llvm-toolchain-focal-10 main" \
      > /etc/apt/sources.list.d/llvm-10.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      build-essential \
      clang-10 \
      lld-10 \
      g++-7 \
      cmake \
      ninja-build \
      libvulkan1 \
      python3 \
      python3-dev \
      python3-pip \
      python-is-python3 \
      libpng-dev \
      libtiff5-dev \
      libjpeg-dev \
      tzdata \
      sed \
      curl \
      unzip \
      autoconf \
      libtool \
      rsync \
      libxml2-dev \
      git \
      aria2 && \
    python3 -m pip install --no-cache-dir -Iv setuptools==47.3.1 && \
    python3 -m pip install --no-cache-dir distro wheel auditwheel && \
    update-alternatives --install /usr/bin/clang++ clang++ /usr/lib/llvm-10/bin/clang++ 180 && \
    update-alternatives --install /usr/bin/clang clang /usr/lib/llvm-10/bin/clang 180 && \
    rm -rf /var/lib/apt/lists/*

RUN useradd -m -u 1000 -s /bin/bash carla
USER carla
WORKDIR /home/carla
ENV HOME=/home/carla
ENV UE4_ROOT=/home/carla/UE4.26

# ------------------------------------------------------------------------------
# Stage 1: CARLA-patched Unreal Engine 4.26 (expensive, cached)
# ------------------------------------------------------------------------------
RUN --mount=type=secret,id=github_netrc,target=/home/carla/.netrc,uid=1000,gid=1000,mode=0400 \
    git clone --depth 1 --branch "${UNREAL_BRANCH}" \
      https://github.com/CarlaUnreal/UnrealEngine.git "${UE4_ROOT}" && \
    cd "${UE4_ROOT}" && \
    ./Setup.sh && \
    ./GenerateProjectFiles.sh && \
    make

# ------------------------------------------------------------------------------
# Stage 2: CARLA source
# ------------------------------------------------------------------------------
RUN git clone --depth 1 --branch "${CARLA_BRANCH}" \
      https://github.com/carla-simulator/carla.git /home/carla/carla

WORKDIR /home/carla/carla

# ------------------------------------------------------------------------------
# Stage 3: CARLA content download (patched URL), isolated and cached
# ------------------------------------------------------------------------------
COPY patch_update.py /tmp/patch_update.py
RUN sed -i \
      's#http://carla-assets\.s3\.amazonaws\.com/#https://carla-assets.s3.us-east-005.backblazeb2.com/#' \
      Update.sh && \
    ! grep -qF 'carla-assets.s3.amazonaws.com' Update.sh && \
    grep -qF 'backblazeb2.com' Update.sh && \
    python3 /tmp/patch_update.py

ENV CARLA_CONTENT_CACHE=/home/carla/.cache/carla-content
RUN --mount=type=cache,id=carla-content-0.9.15,target=/home/carla/.cache/carla-content,uid=1000,gid=1000,sharing=locked \
    ./Update.sh

# ------------------------------------------------------------------------------
# Stage 4: dependency/build patches (each one is verified, because sed -i
# silently does nothing when a pattern does not match)
# ------------------------------------------------------------------------------
RUN sed -i \
      's#https://boostorg\.jfrog\.io/artifactory/main/release/#https://archives.boost.io/release/#' \
      Util/BuildTools/Setup.sh && \
    sed -i \
      's#https://carla-releases\.s3\.eu-west-3\.amazonaws\.com/Backup/#https://carla-releases.s3.us-east-005.backblazeb2.com/Backup/#' \
      Util/BuildTools/Setup.sh && \
    sed -i \
      's#https://sourceforge\.net/projects/libpng/files/libpng16/${LIBPNG_VERSION}/#https://sourceforge.net/projects/libpng/files/libpng16/older-releases/${LIBPNG_VERSION}/#' \
      Util/BuildTools/Setup.sh && \
    sed -i \
      's#https://github\.com/NixOS/patchelf/archive/${PATCHELF_VERSION}\.tar\.gz#https://github.com/NixOS/patchelf/archive/refs/tags/${PATCHELF_VERSION}.tar.gz#' \
      Util/BuildTools/Setup.sh && \
    sed -i 's/^    git fetch$/    git fetch origin ${CURRENT_STREETMAP_COMMIT} --depth=1/' Util/BuildTools/BuildUE4Plugins.sh && \
    sed -i '/^project(CARLA)$/a set(CMAKE_BUILD_WITH_INSTALL_RPATH TRUE)' CMakeLists.txt && \
    ! grep -qF 'boostorg.jfrog.io' Util/BuildTools/Setup.sh && \
    ! grep -qF 'carla-releases.s3.eu-west-3.amazonaws.com' Util/BuildTools/Setup.sh && \
    ! grep -qF 'libpng16/${LIBPNG_VERSION}/' Util/BuildTools/Setup.sh && \
    ! grep -qF 'archive/${PATCHELF_VERSION}.tar.gz' Util/BuildTools/Setup.sh && \
    ! grep -qxF '    git fetch' Util/BuildTools/BuildUE4Plugins.sh && \
    grep -qF 'CMAKE_BUILD_WITH_INSTALL_RPATH' CMakeLists.txt

# Stage 4b: extra build tools missing from the stock CARLA package list
USER root
RUN apt-get update && \
    apt-get install -y --no-install-recommends automake && \
    rm -rf /var/lib/apt/lists/*
USER carla

ENV PATH="/home/carla/UE4.26/Engine/Binaries/Linux:/home/carla/carla/Util:${PATH}"
WORKDIR /home/carla/carla

ENTRYPOINT ["/bin/bash"]
EOF_DOCKERFILE

# ------------------------------------------------------------------------------
# Phase 1: base image (UE4, CARLA source, content, patches)
# ------------------------------------------------------------------------------
BUILD_ARGS=(
  --build-arg "CARLA_BRANCH=${CARLA_BRANCH}"
  --build-arg "UNREAL_BRANCH=${UNREAL_BRANCH}"
  --secret "id=github_netrc,src=${NETRC_FILE}"
  --progress=plain
  --load
  -t "${BASE_IMAGE}"
  -f "$TMP_DIR/Dockerfile"
)

if [[ "$NO_CACHE" -eq 1 ]]; then
  BUILD_ARGS+=(--no-cache)
fi

echo "Phase 1/2: building base image ${BASE_IMAGE}"
echo "  CARLA branch  : ${CARLA_BRANCH}"
echo "  UE branch     : ${UNREAL_BRANCH}"
echo "  Content cache : carla-content-0.9.15 (BuildKit cache mount)"
echo
echo "Do NOT use --no-cache for normal retries."
echo

docker buildx build "${BUILD_ARGS[@]}" "$TMP_DIR"

# ------------------------------------------------------------------------------
# Phase 2: make setup + make CarlaUE4Editor with host-mounted Build/
# ------------------------------------------------------------------------------
echo
echo "Phase 2/2: make setup + make CarlaUE4Editor"
echo "  Host Build dir: ${BUILD_DIR}"
echo "  (mounted at /home/carla/carla/Build, reused on retries)"
echo

docker rm -f "$BUILD_CONTAINER" >/dev/null 2>&1 || true
docker run --name "$BUILD_CONTAINER" \
  -e GIT_DISCOVERY_ACROSS_FILESYSTEM=1 \
  --entrypoint /bin/bash \
  -v "${BUILD_DIR}:/home/carla/carla/Build" \
  "${BASE_IMAGE}" \
  -c 'set -Eeuo pipefail; make setup; make CarlaUE4Editor'

# The container's CMD is the make command above; reset it so the final image
# behaves like a normal interactive image. The bind mount is not committed.
docker commit \
  --change 'ENTRYPOINT ["/bin/bash"]' \
  --change 'CMD []' \
  "$BUILD_CONTAINER" "${IMAGE_NAME}" >/dev/null

docker run --rm --entrypoint /bin/bash "${IMAGE_NAME}" -c \
  'test -x /home/carla/UE4.26/Engine/Binaries/Linux/UE4Editor && test -f /home/carla/carla/Unreal/CarlaUE4/CarlaUE4.uproject'

echo
echo "Build complete: ${IMAGE_NAME}"
echo "Third-party Build/ folder kept on the host: ${BUILD_DIR}"
echo
echo "Run it with Build/ mounted:"
echo "  docker run --rm -it -v \"${BUILD_DIR}:/home/carla/carla/Build\" ${IMAGE_NAME}"
