#!/bin/bash
#
# Shared script to slim a PostgreSQL Docker image using slimtoolkit.
# Used by both local development (build_and_slim.sh) and GitHub Actions workflow.
#
# Usage: ./slim-image.sh <source-image> <target-image> <architecture>
#   architecture: amd64 or arm64
#
# Prerequisites:
#   - slim toolkit must be installed (https://github.com/slimtoolkit/slim)
#   - Install via: curl -sL https://raw.githubusercontent.com/slimtoolkit/slim/master/scripts/install-slim.sh | sudo -E bash -
#   - Or via Homebrew: brew install docker-slim

set -e

SOURCE_IMAGE=$1
TARGET_IMAGE=$2
ARCH=${3:-$(uname -m)}

if [ -z "$SOURCE_IMAGE" ] || [ -z "$TARGET_IMAGE" ]; then
    echo "Usage: $0 <source-image> <target-image> [architecture]"
    echo "  architecture: amd64, arm64, x86_64, aarch64 (default: auto-detect)"
    exit 1
fi

# Normalize architecture names
case "$ARCH" in
    amd64|x86_64)
        LIB_ARCH="x86_64-linux-gnu"
        ;;
    arm64|aarch64)
        LIB_ARCH="aarch64-linux-gnu"
        ;;
    *)
        echo "Unsupported architecture: $ARCH"
        echo "Supported: amd64, arm64, x86_64, aarch64"
        exit 1
        ;;
esac

echo "Slimming image: $SOURCE_IMAGE -> $TARGET_IMAGE (arch: $ARCH, lib: $LIB_ARCH)"

# use /tmp dir for data during build so it starts with an empty PGDATA directory to initdb will be called and the components used for it will be perserved
slim build --target "$SOURCE_IMAGE" \
    --tag "$TARGET_IMAGE" \
    --include-new=false \
    --env=PGROOT=/tmp/postgresql \
    --env=PGDATA=/tmp/postgresql/data \
    --env=PGLOG=/tmp/postgresql/pg_log \
    --env=PGSOCKET=/tmp/postgresql \
    --exclude-varlock-files=false \
    --http-probe=false \
    --continue-after=60 \
    --expose=5432 \
    --expose=8008 \
    --expose=8081 \
    --include-shell \
    --include-bin=/bin/cat \
    --include-bin=/bin/chmod \
    --include-bin=/bin/cp \
    --include-bin=/bin/du \
    --include-bin=/bin/ln \
    --include-bin=/bin/mkdir \
    --include-bin=/bin/mv \
    --include-bin=/bin/rm \
    --include-bin=/bin/sleep \
    --include-bin=/bin/touch \
    --include-bin=/usr/bin/awk \
    --include-bin=/usr/bin/basename \
    --include-bin=/usr/bin/chown \
    --include-bin=/usr/bin/cut \
    --include-bin=/usr/bin/dirname \
    --include-bin=/usr/bin/env \
    --include-bin=/usr/bin/find \
    --include-bin=/usr/bin/grep \
    --include-bin=/usr/bin/head \
    --include-bin=/usr/bin/id \
    --include-bin=/usr/bin/less \
    --include-bin=/usr/bin/locale \
    --include-bin=/usr/bin/localedef \
    --include-bin=/usr/bin/ls \
    --include-bin=/usr/bin/mktemp \
    --include-bin=/usr/bin/pg_isready \
    --include-bin=/usr/bin/psql \
    --include-bin=/usr/bin/sed \
    --include-bin=/usr/bin/sort \
    --include-bin=/usr/bin/tail \
    --include-bin=/usr/bin/test \
    --include-bin=/usr/bin/timescaledb-parallel-copy \
    --include-bin=/usr/bin/timescaledb-tune \
    --include-bin=/usr/bin/tr \
    --include-bin=/usr/bin/wc \
    --include-bin=/usr/bin/xargs \
    --include-bin=/usr/lib/postgresql/17/bin/psql \
    --include-path=/etc/alternatives \
    --include-path=/run \
    --include-path=/usr/bin/timescaledb-tune \
    --include-path=/usr/lib/${LIB_ARCH} \
    --include-path=/usr/lib/postgresql \
    --include-path=/usr/local/bin/timescaledb-tune \
    --include-path=/usr/share/postgresql \
    --include-path=/usr/share/postgresql-common \
    --include-path=/usr/share/proj \
    --include-path=/usr/share/gdal \
    --include-path=/usr/share/pgbouncer \
    --include-path=/usr/share/locales \
    --include-path=/usr/share/zoneinfo \
    --include-path=/var \
    --preserve-path=/docker-entrypoint-initdb.d \
    --preserve-path=/etc/postgresql \
    --preserve-path=/etc/ssl \
    --preserve-path=/or-entrypoint.sh \
    --preserve-path=/var/lib/postgresql

echo "Successfully created slimmed image: $TARGET_IMAGE"
