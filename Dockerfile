######################################################################################################
# Custom Dockerfile that builds Postgres with TimescaleDB and Postgis, made by OpenRemote.
#
# Based on several sources such as docker-postgis dockerfile, TimescaleDBs official documentation,
# and several GitHub issues where users are troubleshooting their docerfiles.
#
# Using Debian Bullseye (11)
#####################################################################################################

# Bitnami Image of TimescaleDB that includes PostGIS 3.1.8
FROM timescale/timescaledb:2.10.0-pg14-bitnami

ENV TZ ${TZ:-Europe/Amsterdam}
ENV PGTZ ${PGTZ:-Europe/Amsterdam}
ENV POSTGRES_DB ${POSTGRES_DB:-openremote}
ENV POSTGRES_USER ${POSTGRES_USER:-postgres}
ENV POSTGRES_PASSWORD ${POSTGRES_PASSWORD:-postgres}
ENV PGUSER "$POSTGRES_USER"

# Running PostGIS initialization scripts
# Copied from https://github.com/postgis/docker-postgis/tree/9f1f1baadddd06a8d1b9c9f7316278f5a82dfb96/14-3.3
RUN mkdir -p /docker-entrypoint-initdb.d
COPY ./initdb-postgis.sh /docker-entrypoint-initdb.d/10_postgis.sh
COPY ./update-postgis.sh /usr/local/bin

# Copying over TimescaleDB Toolkit, specifically only version 1.13.0
COPY --from=timescale/timescaledb-ha:pg14-ts2.9-latest /usr/share/postgresql/14/extension/timescaledb_toolkit--1.13.0.sql /opt/bitnami/postgresql/share/extension/timescaledb_toolkit--1.13.0.sql
COPY --from=timescale/timescaledb-ha:pg14-ts2.9-latest /usr/share/postgresql/14/extension/timescaledb_toolkit.control /opt/bitnami/postgresql/share/extension/timescaledb_toolkit.control
COPY --from=timescale/timescaledb-ha:pg14-ts2.9-latest /usr/lib/postgresql/14/lib/timescaledb_toolkit-1.13.0.so /opt/bitnami/postgresql/lib/timescaledb_toolkit-1.13.0.so

# Running TimescaleDBs initialization scripts
# Copied from https://github.com/timescale/timescaledb-docker/tree/main/docker-entrypoint-initdb.d
COPY ./000_install_timescaledb.sh /docker-entrypoint-initdb.d/001_install_timescaledb.sh
COPY ./001_timescaledb_tune.sh /docker-entrypoint-initdb.d/002_timescaledb_tune.sh

HEALTHCHECK --interval=3s --timeout=3s --start-period=2s --retries=30 CMD pg_isready