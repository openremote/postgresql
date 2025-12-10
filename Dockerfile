ARG PG_MAJOR=17
ARG TIMESCALE_VERSION=2.22

# Stage 1: Prepare the main image with UID/GID changes and cleanup
FROM timescale/timescaledb-ha:pg17-ts${TIMESCALE_VERSION} AS trimmed
LABEL maintainer="support@openremote.io"

USER root

# Install fd-find, fix UID/GID, setup directories, copy files, and cleanup - all in one layer
COPY or-entrypoint.sh /
COPY docker-entrypoint-initdb.d/ /docker-entrypoint-initdb.d/

RUN apt-get update && apt-get install -y --no-install-recommends fd-find \
    # Give postgres user the same UID and GID as the old alpine postgres image
    && usermod -u 70 postgres \
    && groupmod -g 70 postgres \
    && (fdfind . / -group 1000 -exec chgrp -h postgres {} \; 2>/dev/null || true) \
    && (fdfind . / -user 1000 -exec chown -h postgres {} \; 2>/dev/null || true) \
    # Set PGDATA to the same location as our old alpine image
    && mkdir -p /var/lib/postgresql \
    && mv /home/postgres/pgdata/* /var/lib/postgresql/ \
    && chown -R postgres:postgres /var/lib/postgresql \
    # Make scripts executable
    && chmod +x /or-entrypoint.sh /docker-entrypoint-initdb.d/* \
    # Remove fd-find and clean up
    && apt-get purge -y fd-find \
    && apt-get autoremove -y --purge \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
              /var/cache/apt/* \
              /var/log/* \
              /usr/share/doc/* \
              /usr/share/man/* \
              /usr/share/info/* \
              /usr/share/lintian/* \
              /tmp/* \
              /var/tmp/* \
              /root/.cache

# Stage 2: Get PostgreSQL 14/15 binaries for upgrade support
FROM timescale/timescaledb-ha:pg17-ts${TIMESCALE_VERSION}-all AS trimmed-all

# Stage 3: Create final minimal image
FROM scratch
COPY --from=trimmed / /

ARG PG_MAJOR

# Copy only PostgreSQL 14 and 15 lib directories for pg_upgrade support
COPY --from=trimmed-all /usr/lib/postgresql/14 /usr/lib/postgresql/14
COPY --from=trimmed-all /usr/lib/postgresql/15 /usr/lib/postgresql/15
# Copy minimal share files needed for upgrades
COPY --from=trimmed-all /usr/share/postgresql/14 /usr/share/postgresql/14
COPY --from=trimmed-all /usr/share/postgresql/15 /usr/share/postgresql/15

# Clean up docs/man from copied PG versions and any remaining cruft
RUN rm -rf /usr/share/postgresql/14/man \
           /usr/share/postgresql/15/man \
           /usr/share/doc/* \
           /usr/share/man/* \
           /var/cache/* \
           /var/log/*

# Increment this to indicate that a re-index should be carried out on first startup with existing data; REINDEX can still be overidden
# with OR_DISABLE_REINDEX=true
ARG OR_REINDEX_COUNTER=1

# This is important otherwise connections will prevent a graceful shutdown
STOPSIGNAL SIGINT

#ENTRYPOINT ["/bin/sh", "-c", "/or-entrypoint.sh postgres -c max_connections=${POSTGRES_MAX_CONNECTIONS}"]
ENTRYPOINT ["/or-entrypoint.sh"]

# Use exec form of CMD with exec call so kill signals are correctly forwarded whilst allowing variable expansion
# see: https://github.com/moby/moby/issues/5509#issuecomment-890126570
CMD ["postgres"]

ENV PGROOT=/var/lib/postgresql \
    PGDATA=/var/lib/postgresql/data \
    PGLOG=/var/lib/postgresql/pg_log \
    PGSOCKET=/var/lib/postgresql \
    BACKUPROOT=/var/lib/postgresql/backup \
    PGBACKREST_CONFIG=/var/lib/postgresql/backup/pgbackrest.conf \
    PGBACKREST_STANZA=poddb \
    PATH=/usr/lib/postgresql/${PG_MAJOR}/bin:${PATH} \
    LC_ALL=C.UTF-8 \
    LANG=C.UTF-8 \
    # When having an interactive psql session, it is useful if the PAGER is disable
    PAGER="" \
    # OR ENV DEFAULTS
    TZ=${TZ:-Europe/Amsterdam} \
    PGTZ=${PGTZ:-Europe/Amsterdam} \
    POSTGRES_DB=${POSTGRES_DB:-openremote} \
    POSTGRES_USER=${POSTGRES_USER:-postgres} \
    POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-postgres} \
    PG_MAJOR=$PG_MAJOR \
    OR_REINDEX_COUNTER=${OR_REINDEX_COUNTER} \
    OR_DISABLE_REINDEX=${OR_DISABLE_REINDEX:-false} \
    POSTGRES_MAX_CONNECTIONS=${POSTGRES_MAX_CONNECTIONS:-50} \
    OR_DISABLE_AUTO_UPGRADE=${OR_DISABLE_AUTO_UPGRADE:-false}

WORKDIR /var/lib/postgresql
EXPOSE 5432 8008 8081
USER postgres

HEALTHCHECK --interval=3s --timeout=3s --start-period=2s --retries=30 CMD pg_isready
