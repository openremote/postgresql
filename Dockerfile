# -----------------------------------------------------------------------------------------------
# POSTGIS and TimescaleDB (inc. toolkit for hyperfunctions) image built for aarch64 support
# using alpine base image.
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


# Below is copied from https://github.com/timescale/timescaledb-docker-ha/blob/master/Dockerfile
# to minimise the size of this image
## Create a smaller Docker image from the builder image
FROM scratch
COPY --from=trimmed / /

ARG PG_MAJOR=14
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["postgres"]

ENV PGROOT=/home/postgres \
    PGDATA=/home/postgres/pgdata/data \
    PGLOG=/home/postgres/pg_log \
    PGSOCKET=/home/postgres/pgdata \
    BACKUPROOT=/home/postgres/pgdata/backup \
    PGBACKREST_CONFIG=/home/postgres/pgdata/backup/pgbackrest.conf \
    PGBACKREST_STANZA=poddb \
    PATH=/usr/lib/postgresql/${PG_MAJOR}/bin:${PATH} \
    LC_ALL=C.UTF-8 \
    LANG=C.UTF-8 \
    # When having an interactive psql session, it is useful if the PAGER is disable
    PAGER=""

WORKDIR /home/postgres
EXPOSE 5432 8008 8081
USER postgres

## ADD OR convenience default ENV values and healthcheck
ENV TZ ${TZ:-Europe/Amsterdam}
ENV PGTZ ${PGTZ:-Europe/Amsterdam}
ENV POSTGRES_DB ${POSTGRES_DB:-openremote}
ENV POSTGRES_USER ${POSTGRES_USER:-postgres}
ENV POSTGRES_PASSWORD ${POSTGRES_PASSWORD:-postgres}

HEALTHCHECK --interval=3s --timeout=3s --start-period=2s --retries=30 CMD pg_isready
