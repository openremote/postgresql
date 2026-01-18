ARG PG_MAJOR=17
ARG PREV_PG_MAJOR=15

# Stage 1: Get PostgreSQL ${PREV_PG_MAJOR} binaries for upgrade support
FROM timescale/timescaledb-ha:pg${PG_MAJOR}-all AS pg-all

USER root

ARG PREV_PG_MAJOR

# Strip debug symbols and remove unnecessary files from PG ${PREV_PG_MAJOR} in this stage
# For pg_upgrade we need bin/, lib/, and extension/ (for TimescaleDB upgrade scripts)
RUN find /usr/lib/postgresql/${PREV_PG_MAJOR} -type f -name '*.so*' -exec strip --strip-unneeded {} \; 2>/dev/null || true \
    && find /usr/lib/postgresql/${PREV_PG_MAJOR} -type f -executable -exec strip --strip-unneeded {} \; 2>/dev/null || true \
    && rm -rf /usr/share/postgresql/${PREV_PG_MAJOR}/man \
              /usr/share/postgresql/${PREV_PG_MAJOR}/doc \
              /usr/share/postgresql/${PREV_PG_MAJOR}/contrib

# Stage 2: Prepare the main image with UID/GID changes and cleanup
FROM timescale/timescaledb-ha:pg${PG_MAJOR} AS final
LABEL maintainer="support@openremote.io"

USER root

ARG PREV_PG_MAJOR

# Copy PG ${PREV_PG_MAJOR} bin and lib directories for pg_upgrade
COPY --from=pg-all /usr/lib/postgresql/${PREV_PG_MAJOR}/bin /usr/lib/postgresql/${PREV_PG_MAJOR}/bin
COPY --from=pg-all /usr/lib/postgresql/${PREV_PG_MAJOR}/lib /usr/lib/postgresql/${PREV_PG_MAJOR}/lib
# Copy share files including extensions (needed for TimescaleDB upgrade on old PG before pg_upgrade)
COPY --from=pg-all /usr/share/postgresql/${PREV_PG_MAJOR} /usr/share/postgresql/${PREV_PG_MAJOR}

# Copy entrypoint scripts
COPY or-entrypoint.sh /
COPY docker-entrypoint-initdb.d/ /docker-entrypoint-initdb.d/

# Install fd-find, fix UID/GID, setup directories, strip binaries, and cleanup - all in one layer
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
    # Strip debug symbols from PostgreSQL binaries to reduce size
    && find /usr/lib/postgresql -type f -name '*.so*' -exec strip --strip-unneeded {} \; 2>/dev/null || true \
    && find /usr/lib/postgresql -type f -executable -exec strip --strip-unneeded {} \; 2>/dev/null || true \
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
              /usr/share/locale/* \
              /tmp/* \
              /var/tmp/* \
              /root/.cache \
              /home/postgres/.cache \
              /usr/local/lib/pgai \
              /usr/share/postgresql/*/man \
              /usr/share/postgresql/*/doc

ARG PG_MAJOR
ARG PREV_PG_MAJOR

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
    PREV_PG_MAJOR=$PREV_PG_MAJOR \
    OR_REINDEX_COUNTER=${OR_REINDEX_COUNTER} \
    OR_DISABLE_REINDEX=${OR_DISABLE_REINDEX:-false} \
    POSTGRES_MAX_CONNECTIONS=${POSTGRES_MAX_CONNECTIONS:-50} \
    OR_DISABLE_AUTO_UPGRADE=${OR_DISABLE_AUTO_UPGRADE:-false}

WORKDIR /var/lib/postgresql
EXPOSE 5432 8008 8081
USER postgres

HEALTHCHECK --interval=3s --timeout=3s --start-period=2s --retries=30 CMD pg_isready
