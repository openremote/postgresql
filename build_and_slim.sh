#!/bin/bash

# PostgreSQL version tag
PG_MAJOR=17
IMAGE_NAME="openremote/postgresql:pg${PG_MAJOR}"
SLIM_IMAGE_NAME="openremote/postgresql:pg${PG_MAJOR}-slim"

# Build the regular Docker image first
echo "Building regular Docker image..."
docker build -t $IMAGE_NAME .

# Use slimtoolkit to create an optimized version
echo "Creating optimized image with slimtoolkit..."
slim build --target $IMAGE_NAME \
    --tag $SLIM_IMAGE_NAME \
    --http-probe=false \
    --continue-after=10 \
    --expose=5432 \
    --expose=8008 \
    --expose=8081 \
    --include-path=/usr/lib/postgresql \
    --include-path=/usr/lib/aarch64-linux-gnu \
    --include-path=/usr/share/postgresql \
    --include-path=/usr/share/proj \
    --include-path=/usr/share/gdal \
    --include-path=/etc/alternatives \
    --preserve-path=/var/lib/postgresql \
    --preserve-path=/docker-entrypoint-initdb.d \
    --preserve-path=/or-entrypoint.sh \
    --preserve-path=/etc/postgresql \
    --preserve-path=/etc/ssl \
    --include-shell \
    --include-bin=/usr/bin/sort \
    --include-bin=/usr/bin/find \
    --include-bin=/usr/bin/xargs \
    --include-bin=/usr/bin/dirname \
    --include-bin=/usr/bin/basename \
    --include-bin=/usr/bin/head \
    --include-bin=/usr/bin/tail \
    --include-bin=/usr/bin/wc \
    --include-bin=/usr/bin/cut \
    --include-bin=/usr/bin/tr \
    --include-bin=/usr/bin/sed \
    --include-bin=/usr/bin/awk \
    --include-bin=/usr/bin/grep \
    --include-bin=/bin/cat \
    --include-bin=/bin/mv \
    --include-bin=/bin/mkdir \
    --include-bin=/bin/chmod \
    --include-bin=/bin/rm \
    --include-bin=/bin/cp \
    --include-bin=/bin/touch \
    --include-bin=/usr/bin/id \
    --include-bin=/usr/bin/env \
    --show-clogs
