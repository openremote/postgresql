# -----------------------------------------------------------------------------------------------
# POST GIS image built for aarch64 support using alternative base image, copied from:
#
#    https://github.com/postgis/docker-postgis/blob/master/14-3.2/alpine/Dockerfile
#
# See this issue for aarch64 support:
# 
#    https://github.com/postgis/docker-postgis/issues/216
# -----------------------------------------------------------------------------------------------
FROM postgres:14-alpine3.14
MAINTAINER support@openremote.io

ENV POSTGIS_VERSION 3.2.0
ENV POSTGIS_SHA256 c725d1be6d57ad199bbb6393cc3546defb70de1c78fe1787f7ccef2d51c3647b

#Temporary fix:
#   for PostGIS 2.* - building a special geos
#   reason:  PostGIS 2.5.5 is not working with GEOS 3.9.*
ENV POSTGIS2_GEOS_VERSION tags/3.8.2

RUN set -eux \
    \
    && apk add --no-cache --virtual .fetch-deps \
        ca-certificates \
        openssl \
        tar \
    \
    && wget -O postgis.tar.gz "https://github.com/postgis/postgis/archive/$POSTGIS_VERSION.tar.gz" \
    && echo "$POSTGIS_SHA256 *postgis.tar.gz" | sha256sum -c - \
    && mkdir -p /usr/src/postgis \
    && tar \
        --extract \
        --file postgis.tar.gz \
        --directory /usr/src/postgis \
        --strip-components 1 \
    && rm postgis.tar.gz \
    \
    && apk add --no-cache --virtual .build-deps \
        autoconf \
        automake \
        clang-dev \
        file \
        g++ \
        gcc \
        gdal-dev \
        gettext-dev \
        json-c-dev \
        libtool \
        libxml2-dev \
        llvm11-dev \
        make \
        pcre-dev \
        perl \
        proj-dev \
        protobuf-c-dev \
     \
# GEOS setup
     && if   [ $(printf %.1s "$POSTGIS_VERSION") == 3 ]; then \
            apk add --no-cache --virtual .build-deps-geos geos-dev cunit-dev ; \
        elif [ $(printf %.1s "$POSTGIS_VERSION") == 2 ]; then \
            apk add --no-cache --virtual .build-deps-geos cmake git ; \
            cd /usr/src ; \
            git clone https://github.com/libgeos/geos.git ; \
            cd geos ; \
            git checkout ${POSTGIS2_GEOS_VERSION} -b geos_build ; \
            mkdir cmake-build ; \
            cd cmake-build ; \
                cmake -DCMAKE_BUILD_TYPE=Release .. ; \
                make -j$(nproc) ; \
                make check ; \
                make install ; \
            cd / ; \
            rm -fr /usr/src/geos ; \
        else \
            echo ".... unknown PosGIS ...." ; \
        fi \
    \
# build PostGIS
    \
    && cd /usr/src/postgis \
    && gettextize \
    && ./autogen.sh \
    && ./configure \
        --with-pcredir="$(pcre-config --prefix)" \
    && make -j$(nproc) \
    && make install \
    \
# regress check
    && mkdir /tempdb \
    && chown -R postgres:postgres /tempdb \
    && su postgres -c 'pg_ctl -D /tempdb init' \
    && su postgres -c 'pg_ctl -D /tempdb start' \
    && cd regress \
    && make -j$(nproc) check RUNTESTFLAGS=--extension   PGUSER=postgres \
    #&& make -j$(nproc) check RUNTESTFLAGS=--dumprestore PGUSER=postgres \
    #&& make garden                                      PGUSER=postgres \
    && su postgres -c 'pg_ctl -D /tempdb --mode=immediate stop' \
    && rm -rf /tempdb \
    && rm -rf /tmp/pgis_reg \
# add .postgis-rundeps
    && apk add --no-cache --virtual .postgis-rundeps \
        gdal \
        json-c \
        libstdc++ \
        pcre \
        proj \
        protobuf-c \
     # Geos setup
     && if [ $(printf %.1s "$POSTGIS_VERSION") == 3 ]; then \
            apk add --no-cache --virtual .postgis-rundeps-geos geos ; \
        fi \
# clean
    && cd / \
    && rm -rf /usr/src/postgis \
    && apk del .fetch-deps .build-deps .build-deps-geos

COPY ./initdb-postgis.sh /docker-entrypoint-initdb.d/10_postgis.sh
COPY ./update-postgis.sh /usr/local/bin

HEALTHCHECK --interval=3s --timeout=3s --start-period=2s --retries=30 CMD pg_isready
