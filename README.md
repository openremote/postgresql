# Postgresql docker image
[![build multirach postgresql Docker image and push to it dockerhub](https://github.com/openremote/postgresql/actions/workflows/postgresql.yml/badge.svg)](https://github.com/openremote/postgresql/actions/workflows/postgresql.yml)

 POSTGIS and TimescaleDB (inc. toolkit for hyperfunctions) image built for aarch64 support using `timescaledev/timescaledb-ha` base image with:

- OR specific ENV variables and a healthcheck added
- Easy configuration of `max_connections` using `POSTGRES_MAX_CONNECTIONS` environment variable (set to `-1` to disable this setting)
- PGDATA path set to match old Alpine image (for ease of DB migration)
- POSTGRES user UID and GID changed to match old Alpine image (for ease of DB migration)
- Auto upgrade of database with PG major version changes from previous PG major version; can be disabled using
  OR_DISABLE_AUTO_UPGRADE=true.
- Auto upgrade of timescaleDB extension when a new version is available in the container; can be disabled using
  OR_DISABLE_AUTO_UPGRADE=true.
- OR_DISABLE_REINDEX env variable with associated scripts to determine if a REINDEX of the entire DB should be carried
  out at first startup with existing DB (checks whether or not $PGDATA/OR_REINDEX_COUNTER.$OR_REINDEX_COUNTER exists).
  This is used when a collation change has occurred (glibc version change, muslc <-> glibc) which can break the indexes;
  migration can either be manually handled or auto handled depending on OR_DISABLE_REINDEX env variable value.
  NOTE THAT A REINDEX CAN TAKE A LONG TIME DEPENDING ON THE SIZE OF THE DB! And startup will be delayed until completed
  This functionality is intended to simplify migration for basic users; advanced users with large DBs should take care of this
  themselves.
- Automatic TimescaleDB retention policy configuration for asset datapoint tables using environment variables:
  - `OR_ASSET_DATAPOINT_RETENTION` - Sets retention period for `asset_datapoint` table (default: "90 days")
  - `OR_ASSET_PREDICTED_DATAPOINT_RETENTION` - Sets retention period for `asset_predicted_datapoint` table (default: "90 days")
  - Supports flexible time units: hours, days, weeks, months, years (e.g., "48 hours", "2 weeks", "6 months")
  - Retention policies automatically delete data older than the specified period
  - Policies are applied on both new database initialization and existing database startup
  - Can be changed at any time by updating the environment variables and restarting the container

`timescale/timescaledb-ha` image is ubuntu based and only currently supports amd64; they are working on ARM64 support in timescaledev/timescaledb-ha see:

https://github.com/timescale/timescaledb-docker-ha/pull/355

See this issue for POSTGIS base image aarch64 support discussion:

https://github.com/postgis/docker-postgis/issues/216

TODO: Switch over to timescale/timescaledb-ha once arm64 supported

## TimescaleDB Retention Policies

This image supports automatic configuration of TimescaleDB retention policies for asset datapoint tables. Retention policies automatically delete data older than a specified period, helping to manage database size and performance.

### Configuration

Set the following environment variables to configure retention policies:

- **`OR_ASSET_DATAPOINT_RETENTION`** - Retention period for the `asset_datapoint` table (default: "90 days")
- **`OR_ASSET_PREDICTED_DATAPOINT_RETENTION`** - Retention period for the `asset_predicted_datapoint` table (default: "90 days")

The retention period supports flexible PostgreSQL interval syntax with the following time units:
- **hours** - e.g., "48 hours", "72 hours"
- **days** - e.g., "30 days", "180 days"
- **weeks** - e.g., "2 weeks", "8 weeks"
- **months** - e.g., "3 months", "12 months"
- **years** - e.g., "1 year", "2 years"

You can also combine units: "1 year 6 months", "2 weeks 3 days"

### Example Usage

```yaml
# docker-compose.yml
services:
  postgresql:
    image: openremote/postgresql:latest
    environment:
      # Keep asset_datapoint for 6 months
      - OR_ASSET_DATAPOINT_RETENTION=6 months
      # Keep predicted datapoint for only 2 weeks
      - OR_ASSET_PREDICTED_DATAPOINT_RETENTION=2 weeks
```

Additional examples:
```yaml
# Short-term retention (48 hours)
- OR_ASSET_DATAPOINT_RETENTION=48 hours

# Long-term retention (1 year)
- OR_ASSET_DATAPOINT_RETENTION=1 year

# Combined units
- OR_ASSET_DATAPOINT_RETENTION=1 year 6 months
```

### Behavior

- **New databases**: Retention policies are automatically configured during initialization if the tables exist as hypertables
- **Existing databases**: Retention policies are applied/updated on container startup when environment variables are set
- **Changing retention periods**: Simply update the environment variables and restart the container
- **Default value**: If not specified, both tables default to "90 days" retention period
- **Disabling retention**: To disable automatic retention policy configuration, do not set these environment variables

### Notes

- Retention policies only work on tables that have been converted to TimescaleDB hypertables
- If the tables don't exist or aren't hypertables, the configuration will be skipped (no error)
- Data deletion happens automatically in the background via TimescaleDB's retention policy mechanism
- Existing retention policies are replaced when new values are configured
- The interval format follows PostgreSQL's INTERVAL syntax

## Upgrading
***NOTE: If you change the version of container you use then make sure you have backed up your DB first as this container will try to auto upgrade your DB and/or TimescaleDB extension; this auto upgrade functionality can be disabled using `OR_DISABLE_AUTO_UPGRADE=true`***
