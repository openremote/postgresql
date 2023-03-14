# -----------------------------------------------------------------------------------------------
# POSTGIS and TimescaleDB (inc. toolkit for hyperfunctions) image built for aarch64 support
# using timescaledev/timescaledb-ha base image with:
#
# - OR specific ENV variables and a healthcheck added
# - PGDATA path set to match old Alpine image (for ease of DB migration)
# - POSTGRES user UID and GID changed to match old Alpine image (for ease of DB migration)
# - OR_DISABLE_REINDEX env variable with associated scripts to determine if a REINDEX of the entire DB should be carried
#   out at first startup with existing DB (checks whether or not $PGDATA/OR_REINDEX_COUNTER.$OR_REINDEX_COUNTER exists).
#   This is used when a collation change has occurred (glibc version change, muslc <-> glibc) which can break the indexes;
#   migration can either be manually handled or auto handled depending on OR_DISABLE_REINDEX env variable value.
#   NOTE THAT A REINDEX CAN TAKE A LONG TIME DEPENDING ON THE SIZE OF THE DB! And startup will be delayed until completed
#   This functionality is intended to simplify migration for basic users; advanced users with large DBs should take care of this
#   themselves.
#
#
#
# 
# timescale/timescaledb-ha image is ubuntu based and only currently supports amd64; they are
# working on ARM64 support in timescaledev/timescaledb-ha see:
#
#     https://github.com/timescale/timescaledb-docker-ha/pull/355
#
# See this issue for POSTGIS base image aarch64 support discussion:
# 
#    https://github.com/postgis/docker-postgis/issues/216
# -------   ----------------------------------------------------------------------------------------

# TODO: Switch over to timescale/timescaledb-ha once arm64 supported
# We get POSTGIS and timescale+toolkit from this image
FROM timescaledev/timescaledb-ha:pg14-multi as trimmed
MAINTAINER support@openremote.io

USER root

# Give postgres user the same UID and GID as the old alpine postgres image to simplify migration of existing DB
RUN usermod -u 70 postgres \
 && groupmod -g 70 postgres \
 && (find / -group 1000 -exec chgrp -h postgres {} \; || true) \
 && (find / -user 1000 -exec chown -h postgres {} \; || true)

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


## Create a smaller Docker image from the builder image
FROM scratch
COPY --from=trimmed / /

ARG PG_MAJOR=14

# Increment this to indicate that a re-index should be carried out on first startup with existing data; REINDEX can still be overidden
# with OR_DISABLE_REINDEX=true
ARG OR_REINDEX_COUNTER=1

ENTRYPOINT ["/or-entrypoint.sh"]
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
    OR_REINDEX_COUNTER=${OR_REINDEX_COUNTER} \
    OR_DISABLE_REINDEX=${OR_DISABLE_REINDEX:-false}

WORKDIR /var/lib/postgresql
EXPOSE 5432 8008 8081
USER postgres

HEALTHCHECK --interval=3s --timeout=3s --start-period=2s --retries=30 CMD pg_isready
