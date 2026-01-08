# Postgresql docker image
[![build multiarch postgresql Docker image and push to dockerhub](https://github.com/openremote/postgresql/actions/workflows/postgresql.yml/badge.svg)](https://github.com/openremote/postgresql/actions/workflows/postgresql.yml)

POSTGIS and TimescaleDB (inc. toolkit for hyperfunctions) image built for amd64 and arm64 using `timescale/timescaledb-ha` base image with:

- OR specific ENV variables and a healthcheck added
- Easy configuration of `max_connections` using `POSTGRES_MAX_CONNECTIONS` environment variable (set to `-1` to disable this setting)
- PGDATA path set to match old Alpine image (for ease of DB migration)
- POSTGRES user UID and GID changed to match old Alpine image (for ease of DB migration)
- Auto upgrade of database with PG major version changes from previous PG major version; can be disabled using
  `OR_DISABLE_AUTO_UPGRADE=true`
- Auto upgrade of timescaleDB extension when a new version is available in the container; can be disabled using
  `OR_DISABLE_AUTO_UPGRADE=true`
- OR_DISABLE_REINDEX env variable with associated scripts to determine if a REINDEX of the entire DB should be carried
  out at first startup with existing DB (checks whether or not `$PGDATA/OR_REINDEX_COUNTER.$OR_REINDEX_COUNTER` exists).
  This is used when a collation change has occurred (glibc version change, muslc <-> glibc) which can break the indexes;
  migration can either be manually handled or auto handled depending on OR_DISABLE_REINDEX env variable value.
  NOTE THAT A REINDEX CAN TAKE A LONG TIME DEPENDING ON THE SIZE OF THE DB! And startup will be delayed until completed.
  This functionality is intended to simplify migration for basic users; advanced users with large DBs should take care of this
  themselves.
- **Slimmed images** using [slim toolkit](https://github.com/slimtoolkit/slim) to reduce image size by ~60%

## Local Development

To build and slim the image locally:

```bash
./build_and_slim.sh
```

This will:
1. Build the regular Docker image
2. Use slim toolkit to create an optimized version with reduced size

## Upgrading
***NOTE: If you change the version of container you use then make sure you have backed up your DB first as this container will try to auto upgrade your DB and/or TimescaleDB extension; this auto upgrade functionality can be disabled using `OR_DISABLE_AUTO_UPGRADE=true`***
