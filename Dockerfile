######################################################################################################
# Custom Dockerfile that builds Postgres with TimescaleDB and Postgis, made by OpenRemote.
#
# Based on several sources such as docker-postgis dockerfile, TimescaleDBs official documentation,
# and several GitHub issues where users are troubleshooting their docerfiles.
#
# Using Alpine 3.17
#####################################################################################################


#--------------------------------------------------
# Building TimescaleDB toolkit, which requires manual build of Rust source code.
# Practicing Docker multi-stage builds (https://docs.docker.com/build/building/multi-stage/)
# to reduce image size by only copying over necessary files without any SDKs.
#
# Required a lot of finetuning versions / build steps, but seems to run solid.
# Based on https://github.com/timescale/timescaledb-toolkit/issues/344#issuecomment-1045939452, which is
# similar to the official documentation: https://github.com/timescale/timescaledb-toolkit#-installing-from-source
#--------------------------------------------------
FROM timescale/timescaledb:2.9.3-pg14 AS toolkit-tools

ENV TOOLKIT_VERSION 1.14.0

RUN apk add --no-cache clang14 pkgconfig openssl-dev gcc postgresql14-dev curl jq make musl-dev

RUN chown postgres /usr/local/share/postgresql/extension /usr/local/lib/postgresql

USER postgres
ENV PATH="/var/lib/postgresql/.cargo/bin:${PATH}" RUSTFLAGS='-C target-feature=-crt-static'
WORKDIR /var/lib/postgresql

# Cargo installation
# Using seperate RUN statements here to maximize use of cache
RUN curl https://sh.rustup.rs -sSf | bash -s -- -y --profile=minimal -c rustfmt

RUN cargo install cargo-pgx --version '=0.6.1'

RUN cargo pgx init -v --pg14 `which pg_config`

# Downloading toolkit
RUN mkdir timescaledb-toolkit && \
    curl -s -L `curl -s https://api.github.com/repos/timescale/timescaledb-toolkit/releases/tags/${TOOLKIT_VERSION} | jq -r ".tarball_url"` | tar -zx -C timescaledb-toolkit --strip-components 1

# Installing toolkit
RUN cd timescaledb-toolkit/extension && \
    cargo pgx install -v --release

RUN cargo run -v --manifest-path timescaledb-toolkit/tools/post-install/Cargo.toml -- pg_config



#--------------------------------------------------
# Building final image by combining TimescaleDB with its toolkit and PostGIS extension.
#
# PostGIS image built for aarch64 support using alternative base image, copied from
# https://github.com/postgis/docker-postgis/blob/master/14-3.3/alpine/Dockerfile.
# See this issue for aarch64 support: https://github.com/postgis/docker-postgis/issues/216
#--------------------------------------------------
FROM timescale/timescaledb:2.9.3-pg14 AS final

ENV POSTGIS_VERSION 3.3.2
ENV POSTGIS_SHA256 2a6858d1df06de1c5f85a5b780773e92f6ba3a5dc09ac31120ac895242f5a77b

ENV TZ ${TZ:-Europe/Amsterdam}
ENV PGTZ ${PGTZ:-Europe/Amsterdam}
ENV POSTGRES_DB ${POSTGRES_DB:-openremote}
ENV POSTGRES_USER ${POSTGRES_USER:-postgres}
ENV POSTGRES_PASSWORD ${POSTGRES_PASSWORD:-postgres}
ENV PGUSER "$POSTGRES_USER"

# Copying over PostGIS
COPY --from=postgis/postgis:14-3.3-alpine /usr/local/share/postgresql/* /usr/local/share/postgresql/
COPY --from=postgis/postgis:14-3.3-alpine /usr/local/lib/postgresql/* /usr/local/lib/postgresql/

# Copying over TimescaleDB Toolkit
COPY --from=toolkit-tools /usr/local/share/postgresql/extension/timescaledb_toolkit* /usr/local/share/postgresql/extension/
COPY --from=toolkit-tools /usr/local/lib/postgresql/timescaledb_toolkit* /usr/local/lib/postgresql/
# RUN echo "shared_preload_libraries = 'timescaledb'" >> /var/lib/postgresql/data/postgresql.conf

# Dependency versions copied from docker-postgis
# ENV GEOS_ALPINE_VER 3.11
# ENV GDAL_ALPINE_VER 3.5
# ENV PROJ_ALPINE_VER 9.1

# PostGIS steps
#RUN set -eux \
#    \
#    && apk add --no-cache --virtual .fetch-deps \
#        ca-certificates \
#        openssl \
#        tar \
#    \
#    && wget -O postgis.tar.gz "https://github.com/postgis/postgis/archive/${POSTGIS_VERSION}.tar.gz" \
#    && echo "${POSTGIS_SHA256} *postgis.tar.gz" | sha256sum -c - \
#    && mkdir -p /usr/src/postgis \
#    && tar \
#        --extract \
#        --file postgis.tar.gz \
#        --directory /usr/src/postgis \
#        --strip-components 1 \
#    && rm postgis.tar.gz \
#    \
#    && apk add --no-cache --virtual .build-deps \
#        \
#        gdal-dev~=${GDAL_ALPINE_VER} \
#        geos-dev~=${GEOS_ALPINE_VER} \
#        proj-dev~=${PROJ_ALPINE_VER} \
#        \
#        autoconf \
#        automake \
#        clang-dev \
#        file \
#        g++ \
#        gcc \
#        gettext-dev \
#        json-c-dev \
#        libtool \
#        libxml2-dev \
#        llvm-dev \
#        make \
#        pcre-dev \
#        perl \
#        protobuf-c-dev \
#    \
# build PostGIS
#    \
#    && cd /usr/src/postgis \
#    && gettextize \
#    && ./autogen.sh \
#    && ./configure \
#        --with-pcredir="$(pcre-config --prefix)" \
#    && make -j$(nproc) \
#    && make install \
#    \
# regress check
#    && mkdir /tempdb \
#    && chown -R postgres:postgres /tempdb \
#    && su postgres -c 'pg_ctl -D /tempdb init' \
#    && su postgres -c 'pg_ctl -D /tempdb start' \
#    && cd regress \
#    && make -j$(nproc) check RUNTESTFLAGS=--extension   PGUSER=postgres \
    #&& make -j$(nproc) check RUNTESTFLAGS=--dumprestore PGUSER=postgres \
    #&& make garden                                      PGUSER=postgres \
#    \
#    && su postgres -c 'psql    -c "CREATE EXTENSION IF NOT EXISTS postgis;"' \
#    && su postgres -c 'psql -t -c "SELECT version();"'              >> /_pgis_full_version.txt \
#    && su postgres -c 'psql -t -c "SELECT PostGIS_Full_Version();"' >> /_pgis_full_version.txt \
#    \
#    && su postgres -c 'pg_ctl -D /tempdb --mode=immediate stop' \
#    && rm -rf /tempdb \
#    && rm -rf /tmp/pgis_reg \
# add .postgis-rundeps
#    && apk add --no-cache --virtual .postgis-rundeps \
#        \
#        gdal~=${GDAL_ALPINE_VER} \
#        geos~=${GEOS_ALPINE_VER} \
#        proj~=${PROJ_ALPINE_VER} \
#        \
#        json-c \
#        libstdc++ \
#        pcre \
#        protobuf-c \
#        \
        # ca-certificates: for accessing remote raster files
        #   fix https://github.com/postgis/docker-postgis/issues/307
#        ca-certificates \
# clean
#    && cd / \
#    && rm -rf /usr/src/postgis \
#    && apk del .fetch-deps .build-deps

COPY ./initdb-postgis.sh /docker-entrypoint-initdb.d/10_postgis.sh
COPY ./update-postgis.sh /usr/local/bin

HEALTHCHECK --interval=3s --timeout=3s --start-period=2s --retries=30 CMD pg_isready
