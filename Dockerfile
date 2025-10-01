
ARG PG_MAJOR_PREVIOUS=15
ARG PG_MAJOR=17
ARG TIMESCALE_VERSION=2.22

FROM timescale/timescaledb-ha:pg17-ts${TIMESCALE_VERSION} AS trimmed
LABEL maintainer="support@openremote.io"

USER root

# install fd to find files to speed up chown and chgrp
RUN apt-get update && apt-get install -y fd-find && rm -rf /var/lib/apt/lists/*

# Give postgres user the same UID and GID as the old alpine postgres image to simplify migration of existing DB
RUN usermod -u 70 postgres \
 && groupmod -g 70 postgres \
 && (fd / -group 1000 -exec chgrp -h postgres {} \; || true) \
 && (fd / -user 1000 -exec chown -h postgres {} \; || true)

# Set PGDATA to the same location as our old alpine image
RUN mkdir -p /var/lib/postgresql && mv /home/postgres/pgdata/* /var/lib/postgresql/ && chown -R postgres:postgres /var/lib/postgresql

# Add custom entry point (see file header for details)
COPY or-entrypoint.sh /
RUN chmod +x /or-entrypoint.sh

# Add custom initdb script(s)
COPY docker-entrypoint-initdb.d/ /docker-entrypoint-initdb.d/
RUN chmod +x /docker-entrypoint-initdb.d/*


# Below is mostly copied from https://github.com/timescale/timescaledb-docker-ha/blob/master/Dockerfile (with OR specific entrypoint,
# workdir and OR env defaults)

# Get the -all variant which contains multiple PostgreSQL versions
# According to TimescaleDB docs: "timescale/timescaledb-ha images have the files necessary to run previous versions"
FROM timescale/timescaledb-ha:pg17-ts${TIMESCALE_VERSION}-all AS trimmed-all

## Create a smaller Docker image from the builder image
FROM scratch
COPY --from=trimmed / /

ARG PG_MAJOR_PREVIOUS
ARG PG_MAJOR

## Copy previous PG MAJOR version executable
COPY --from=trimmed-all /usr/lib/postgresql/${PG_MAJOR_PREVIOUS} /usr/lib/postgresql/${PG_MAJOR_PREVIOUS}
COPY --from=trimmed-all /usr/share/postgresql/${PG_MAJOR_PREVIOUS} /usr/share/postgresql/${PG_MAJOR_PREVIOUS}

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
