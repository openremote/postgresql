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

### Prerequisites

- **Docker** must be installed and running
- **slim toolkit** must be installed for image optimization

Install slim toolkit via the install script:
```bash
curl -sL https://raw.githubusercontent.com/slimtoolkit/slim/master/scripts/install-slim.sh | sudo -E bash -
```

Or via Homebrew (macOS):
```bash
brew install docker-slim
```

For more installation options, see the [slim toolkit documentation](https://github.com/slimtoolkit/slim#installation).

### Building the Image

To build and slim the image locally:

```bash
./build_and_slim.sh
```

This will:
1. Build the regular Docker image with the correct `PG_MAJOR` build argument
2. Use slim toolkit to create an optimized version with reduced size (~60% smaller)

## Upgrading

***NOTE: If you change the version of container you use then make sure you have backed up your DB first as this container will try to auto upgrade your DB and/or TimescaleDB extension; this auto upgrade functionality can be disabled using `OR_DISABLE_AUTO_UPGRADE=true`***

### Automatic Upgrade

This image supports automatic upgrades from the previous PostgreSQL major version. When the container starts with an existing database from a supported older version, it will:

1. Upgrade TimescaleDB extensions on the old PostgreSQL version
2. Run `pg_upgrade` to migrate the database to the new PostgreSQL version
3. Upgrade TimescaleDB extensions on the new PostgreSQL version

### Manual Upgrade

If automatic upgrade is not supported for your database version (e.g., skipping multiple major versions), you will need to perform a manual upgrade. Follow these steps:

1. **Backup your database** using `pg_dump` or `pg_dumpall`
2. **Upgrade TimescaleDB first** (if installed) - this must be done before PostgreSQL upgrade
3. **Use pg_upgrade** to migrate between PostgreSQL versions, or restore from backup to a fresh database

#### Useful Resources

- [PostgreSQL pg_upgrade documentation](https://www.postgresql.org/docs/current/pgupgrade.html)
- [TimescaleDB upgrade guide](https://docs.timescale.com/self-hosted/latest/upgrades/)
- [TimescaleDB major upgrade guide](https://docs.timescale.com/self-hosted/latest/upgrades/major-upgrade/)

#### Example: Manual pg_dump/restore

```bash
# On the old container, dump the database
docker exec -it <old_container> pg_dumpall -U postgres > backup.sql

# Start the new container with a fresh data directory
docker run -d --name new_postgres -v /path/to/new/data:/var/lib/postgresql/data openremote/postgresql:latest

# Restore the backup
docker exec -i new_postgres psql -U postgres < backup.sql
```
