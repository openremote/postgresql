#!/bin/bash
#
# Build and slim the PostgreSQL Docker image for local development.
#
# Prerequisites:
#   - Docker must be installed and running
#   - slim toolkit must be installed (https://github.com/slimtoolkit/slim)
#     Install via: curl -sL https://raw.githubusercontent.com/slimtoolkit/slim/master/scripts/install-slim.sh | sudo -E bash -
#     Or via Homebrew: brew install docker-slim

set -e

# PostgreSQL version tag - this is passed to Docker build to ensure consistency
PG_MAJOR=17
IMAGE_NAME="openremote/postgresql:pg${PG_MAJOR}"

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)
        ARCH="amd64"
        ;;
    aarch64|arm64)
        ARCH="arm64"
        ;;
esac

# Build the regular Docker image first
echo "Building regular Docker image..."
docker build --build-arg PG_MAJOR=$PG_MAJOR -t $IMAGE_NAME .

# Use the shared slim script to create an optimized version
echo "Creating optimized image with slimtoolkit..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"${SCRIPT_DIR}/slim-image.sh" "$IMAGE_NAME" "${IMAGE_NAME}-slim" "$ARCH"

# Replace original with slim version
docker tag "${IMAGE_NAME}-slim" "$IMAGE_NAME"
echo "Tagged slimmed image as: $IMAGE_NAME"
