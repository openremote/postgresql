######################################################################################################
# Custom Dockerfile that builds Postgres with TimescaleDB and Postgis
# Based on https://github.com/timescale/timescaledb-docker-ha/blob/80b71545b7ff5163ac940982b9e811ee053d6ba7/Dockerfile
# Removed dependencies that were not necessary for use of OpenRemote.
#
# Uses Ubuntu 22.04, since Alpine and Debian did not serve glibc 2.33+
#
#####################################################################################################

# Major PostgreSQL version to use for dependencies
# Changing it would require to edit the image tag in line 200-202 as well.
ARG PG_MAJOR=14

# By including multiple versions of PostgreSQL we can use the same Docker image,
# regardless of the major PostgreSQL Version. It also allow us to support (eventually)
# pg_upgrade from one major version to another
ARG PG_VERSIONS="14"
ARG POSTGIS_VERSIONS="3"
ARG TS_VERSIONS="2.10.0"
ARG TOOLKIT_VERSION=1.13.0


# Available environment variables are specified during the final stage (line 271 and up)



###########################################################################
# Installing & Compiling process
###########################################################################
FROM ubuntu:22.04 AS compiler

ENV DEBIAN_FRONTEND=noninteractive
# We need full control over the running user, including the UID, therefore we
# create the postgres user as the first thing on our list
RUN adduser --home /home/postgres --uid 1000 --disabled-password --gecos "" postgres

RUN echo 'APT::Install-Recommends "false";' >> /etc/apt/apt.conf.d/01norecommend
RUN echo 'APT::Install-Suggests "false";' >> /etc/apt/apt.conf.d/01norecommend

# Make sure we're as up-to-date as possible, and install the highlest level dependencies
RUN apt-get update && apt-get upgrade -y \
    && apt-get install -y ca-certificates curl gnupg1 gpg gpg-agent locales lsb-release wget unzip

RUN mkdir -p /build/scripts
RUN chmod 777 /build
WORKDIR /build/

# Registering PostgreSQL packages repo
RUN wget -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor --output /usr/share/keyrings/postgresql.keyring
RUN for t in deb deb-src; do \
        echo "$t [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/postgresql.keyring] http://apt.postgresql.org/pub/repos/apt/ $(lsb_release -s -c)-pgdg main" >> /etc/apt/sources.list.d/pgdg.list; \
    done

RUN apt-get clean
RUN apt-get update

# The next 2 instructions (ENV + RUN) are directly copied from https://github.com/rust-lang/docker-rust/blob/d534735bae832da4c60ddf799a8dfbefa9939020/1.67.0/bullseye/Dockerfile
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH \
    RUST_VERSION=1.65.0

RUN set -eux; \
    dpkgArch="$(dpkg --print-architecture)"; \
    case "${dpkgArch##*-}" in \
        amd64) rustArch='x86_64-unknown-linux-gnu'; rustupSha256='bb31eaf643926b2ee9f4d8d6fc0e2835e03c0a60f34d324048aa194f0b29a71c' ;; \
        armhf) rustArch='armv7-unknown-linux-gnueabihf'; rustupSha256='6626b90205d7fe7058754c8e993b7efd91dedc6833a11a225b296b7c2941194f' ;; \
        arm64) rustArch='aarch64-unknown-linux-gnu'; rustupSha256='4ccaa7de6b8be1569f6b764acc28e84f5eca342f5162cd5c810891bff7ed7f74' ;; \
        i386) rustArch='i686-unknown-linux-gnu'; rustupSha256='34392b53a25c56435b411d3e575b63aab962034dd1409ba405e708610c829607' ;; \
        *) echo >&2 "unsupported architecture: ${dpkgArch}"; exit 1 ;; \
    esac; \
    url="https://static.rust-lang.org/rustup/archive/1.25.2/${rustArch}/rustup-init"; \
    wget "$url"; \
    echo "${rustupSha256} *rustup-init" | sha256sum -c -; \
    chmod +x rustup-init; \
    ./rustup-init -y --no-modify-path --profile minimal --default-toolchain $RUST_VERSION --default-host ${rustArch}; \
    rm rustup-init; \
    chmod -R a+w $RUSTUP_HOME $CARGO_HOME; \
    rustup --version; \
    cargo --version; \
    rustc --version;


# We install some build dependencies and mark the installed packages as auto-installed,
# this will cause the cleanup to get rid of all of these packages
ENV BUILD_PACKAGES="binutils cmake devscripts equivs gcc git gpg gpg-agent libc-dev libc6-dev libkrb5-dev libperl-dev libssl-dev lsb-release make patchutils python2-dev python3-dev wget"
RUN apt-get install -y ${BUILD_PACKAGES}
RUN apt-mark auto ${BUILD_PACKAGES}

ARG PG_VERSIONS

# We install the PostgreSQL build dependencies and mark the installed packages as auto-installed,
RUN for pg in ${PG_VERSIONS}; do \
        mk-build-deps postgresql-${pg} && apt-get install -y ./postgresql-${pg}-build-deps*.deb && apt-mark auto postgresql-${pg}-build-deps || exit 1; \
    done

# For the compiler image, we want all the PostgreSQL versions to be installed,
# so tools that depend on `pg_config` or other parts to exist can be run
RUN for pg in ${PG_VERSIONS}; do apt-get install -y postgresql-${pg} postgresql-server-dev-${pg} || exit 1; done



###########################################################################
# Building process
###########################################################################
FROM compiler as builder

# We put Postgis in first, so these layers can be reused
ARG POSTGIS_VERSIONS
RUN for postgisv in ${POSTGIS_VERSIONS}; do \
        for pg in ${PG_VERSIONS}; do \
            apt-get install -y postgresql-${pg}-postgis-${postgisv} || exit 1; \
        done; \
    done

# Add TimescaleDB to shared preload libraries (required)
RUN for file in $(find /usr/share/postgresql -name 'postgresql.conf.sample'); do \
        sed -r -i "s/[#]*\s*(shared_preload_libraries)\s*=\s*'(.*)'/\1 = 'timescaledb,\2'/;s/,'/'/" $file \
        # We need to listen on all interfaces, otherwise PostgreSQL is not accessible
        && echo "listen_addresses = '*'" >> $file; \
    done

ARG PG_VERSIONS

# timescaledb-tune, as well as timescaledb-parallel-copy
# TODO: Replace `focal` with `$(lsb_release -s -c)` once packages are available
# for Ubuntu 22.04
RUN wget -O - https://packagecloud.io/timescale/timescaledb/gpgkey | gpg --dearmor --output /usr/share/keyrings/timescaledb.keyring
RUN echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/timescaledb.keyring] https://packagecloud.io/timescale/timescaledb/ubuntu/ focal main" > /etc/apt/sources.list.d/timescaledb.list

RUN apt-get update && apt-get install -y timescaledb-tools


## Entrypoints as they are from the Timescale image and its default alpine upstream repositories.
## This ensures the default interface (entrypoint) equals the one of the github.com/timescale/timescaledb-docker one,
## which allows this Docker Image to be a drop-in replacement for those Docker Images.
ARG GITHUB_TIMESCALEDB_DOCKER_REF=main
ARG GITHUB_DOCKERLIB_POSTGRES_REF=main
RUN cd /build && git clone https://github.com/timescale/timescaledb-docker && cd /build/timescaledb-docker && git checkout ${GITHUB_TIMESCALEDB_DOCKER_REF}
RUN cp -a /build/timescaledb-docker/docker-entrypoint-initdb.d /docker-entrypoint-initdb.d/

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Satisfy assumptions of the entrypoint scripts
RUN ln -s /usr/bin/timescaledb-tune /usr/local/bin/timescaledb-tune
RUN ln -s /usr/local/bin/docker-entrypoint.sh /docker-entrypoint.sh

ENV REPO_SECRET_FILE=/run/secrets/private_repo_token

# The following allows *new* files to be created, so that extensions can be added to a running container.
# Existing files are still owned by root and have their sticky bit (the 1 in the 1775 permission mode) set,
# and therefore cannot be overwritten or removed by the unprivileged (postgres) user.
# This ensures the following:
# - libraries and supporting files that have been installed *before this step* are immutable
# - libraries and supporting files that have been installed *after this step* are mutable
# - files owned by postgres can be overwritten in a running container
# - new files can be added to the directories mentioned here
RUN for pg in ${PG_VERSIONS}; do \
        for dir in /usr/share/doc "$(/usr/lib/postgresql/${pg}/bin/pg_config --sharedir)/extension" "$(/usr/lib/postgresql/${pg}/bin/pg_config --pkglibdir)" "$(/usr/lib/postgresql/${pg}/bin/pg_config --bindir)"; do \
            install --directory "${dir}" --group postgres --mode 1775 \
            && find "${dir}" -type d -exec install --directory {} --group postgres --mode 1775 \; || exit 1 ; \
        done; \
    done

USER postgres

ENV MAKEFLAGS=-j8

ARG GITHUB_REPO=timescale/timescaledb
RUN --mount=type=secret,uid=1000,id=private_repo_token \
    if [ -f "{REPO_SECRET_FILE}" ]; then \
        git clone "https://github-actions:$(cat "${REPO_SECRET_FILE}")@github.com/${GITHUB_REPO}" /build/timescaledb; \
    else \
        git clone "https://github.com/${GITHUB_REPO}" /build/timescaledb; \
    fi


ARG GITHUB_TAG
ARG OSS_ONLY

COPY build_scripts /build/scripts


# If a specific GITHUB_TAG is provided, we will build that tag only. Otherwise
# we build all the public (recent) releases
ARG TS_VERSIONS
RUN if [ "${GITHUB_TAG}" != "" ]; then TS_VERSIONS="${GITHUB_TAG}"; fi \
    && cd /build/timescaledb && git pull \
    && set -e \
    && for pg in ${PG_VERSIONS}; do \
        /build/scripts/install_timescaledb.sh ${pg} ${TS_VERSIONS} || exit 1 ; \
    done


# Copy timescaledb-toolkit files
ARG PG_MAJOR
ARG TOOLKIT_VERSION
COPY --from=timescale/timescaledb-ha:pg14-ts2.9-latest /usr/share/postgresql/${PG_MAJOR}/extension/timescaledb_toolkit.control /usr/share/postgresql/${PG_MAJOR}/extension/timescaledb_toolkit.control
COPY --from=timescale/timescaledb-ha:pg14-ts2.9-latest /usr/share/postgresql/${PG_MAJOR}/extension/timescaledb_toolkit--${TOOLKIT_VERSION}.sql /usr/share/postgresql/${PG_MAJOR}/extension/timescaledb_toolkit--${TOOLKIT_VERSION}.sql
COPY --from=timescale/timescaledb-ha:pg14-ts2.9-latest /usr/lib/postgresql/${PG_MAJOR}/lib/timescaledb_toolkit-${TOOLKIT_VERSION}.so /usr/lib/postgresql/${PG_MAJOR}/lib/timescaledb_toolkit-${TOOLKIT_VERSION}.so


USER root

# All the tools that were built in the previous steps have their ownership set to postgres
# to allow mutability. To allow one to build this image with the default privileges (owned by root)
# one can set the ALLOW_ADDING_EXTENSIONS argument to anything but "true".
ARG ALLOW_ADDING_EXTENSIONS=true
RUN if [ "${ALLOW_ADDING_EXTENSIONS}" != "true" ]; then \
        for pg in ${PG_VERSIONS}; do \
            for dir in /usr/share/doc "$(/usr/lib/postgresql/${pg}/bin/pg_config --sharedir)/extension" "$(/usr/lib/postgresql/${pg}/bin/pg_config --pkglibdir)" "$(/usr/lib/postgresql/${pg}/bin/pg_config --bindir)"; do \
                chown root:root "{dir}" -R ; \
            done ; \
        done ; \
    fi



###########################################################################
# Cleanup
###########################################################################
FROM builder AS trimmed

RUN apt-get purge -y ${BUILD_PACKAGES}
RUN apt-get autoremove -y \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
            /var/cache/debconf/* \
            /usr/share/doc \
            /usr/share/man \
            /usr/share/locale/?? \
            /usr/share/locale/??_?? \
            /home/postgres/.pgx \
            /build/ \
            /usr/local/rustup \
            /usr/local/cargo \
    && find /var/log -type f -exec truncate --size 0 {} \;



###########################################################################
# Create a smaller Docker image from the builder image
###########################################################################
FROM scratch
COPY --from=trimmed / /

ARG PG_MAJOR
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["postgres"]

## The mount being used by the Zalando postgres-operator is /home/postgres/pgdata
## for Patroni to do it's work it will sometimes move an old/invalid data directory
## inside the parent directory; therefore we need a subdirectory inside the mount

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


ENV TZ ${TZ:-Europe/Amsterdam}
ENV PGTZ ${PGTZ:-Europe/Amsterdam}
ENV POSTGRES_DB ${POSTGRES_DB:-openremote}
ENV POSTGRES_USER ${POSTGRES_USER:-postgres}
ENV POSTGRES_PASSWORD ${POSTGRES_PASSWORD:-postgres}
ENV PGUSER "$POSTGRES_USER"


## The Zalando postgres-operator has strong opinions about the HOME directory of postgres,
## whereas we do not. Make the operator happy then
RUN usermod postgres --home "${PGROOT}" --move-home

## The /etc/supervisor/conf.d directory is a very Spilo (Zalando postgres-operator) oriented directory.
## However, to make things work the user postgres currently needs to have write access to this directory
## The /var/lib/postgresql/data is used as PGDATA by alpine/bitnami, which makes it useful to have it be owned by Postgres
RUN install -o postgres -g postgres -m 0750 -d "${PGROOT}" "${PGLOG}" "${PGDATA}" "${BACKUPROOT}" /etc/supervisor/conf.d /scripts /var/lib/postgresql

## Some configurations allow daily csv files, with foreign data wrappers pointing to the files.
## to make this work nicely, they need to exist though
RUN for i in $(seq 0 7); do touch "${PGLOG}/postgresql-$i.log" "${PGLOG}/postgresql-$i.csv"; done

## Fix permissions
RUN chown postgres:postgres "${PGLOG}" "${PGROOT}" "${PGDATA}" /var/run/postgresql/ -R
RUN chmod 1777 /var/run/postgresql
RUN chmod 755 "${PGROOT}"

WORKDIR /home/postgres
EXPOSE 5432 8008 8081
USER postgres

# Healthcheck using PSQL command
HEALTHCHECK --interval=3s --timeout=3s --start-period=2s --retries=30 CMD pg_isready