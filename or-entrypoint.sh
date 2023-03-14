#!/usr/bin/env bash

# THIS FILE IS FOR MIGRATION OF EXISTING DB TO TIMESCALEDB IMAGE AS TIMESCALE INIT SCRIPTS AREN'T RUN WHEN DB
# ALREADY EXISTS; IT ALSO DOES AN AUTOMATIC REINDEX OF THE DB WHEN OR_REINDEX_COUNTER changes TO SIMPLIFY MIGRATIONS

source /docker-entrypoint.sh
docker_setup_env

if [ -n "$DATABASE_ALREADY_EXISTS" ]; then

    # Make sure timescaledb library is set to preload (won't work otherwise)
    echo "Existing postgresql.conf found checking for shared_preload_libraries = 'timescaledb'..."       
    RESULT=$(cat "$PGDATA/postgresql.conf" | grep "^shared_preload_libraries = 'timescaledb'" || true)

    if [ -n "$RESULT" ]; then
        echo "Timescale DB library already set to preload"
    else
        echo "Adding shared_preload_libraries = 'timescaledb' to postgresql.conf"
        echo "shared_preload_libraries = 'timescaledb'" >> "$PGDATA/postgresql.conf"
    fi
    
    # Do re-indexing check
    if [ "$OR_DISABLE_REINDEX" == 'true' ] || [ -z "$OR_REINDEX_COUNTER" ]; then
        echo "REINDEX check is disabled"
    else
        echo "Checking whether REINDEX is required..."
        REINDEX_FILE="$PGDATA/OR_REINDEX_COUNTER.$OR_REINDEX_COUNTER"
        if [ -f "$REINDEX_FILE" ]; then
            echo "REINDEX file '$REINDEX_FILE' already exists so no re-indexing required"
        else
            echo "REINDEX file '$REINDEX_FILE' doesn't exist so re-indexing the DB..."
            docker_temp_server_start "$@"
            docker_process_sql -c "REINDEX database $POSTGRES_DB;"
            docker_temp_server_stop
            echo 'REINDEX completed!'
            touch "$REINDEX_FILE"
        fi
    fi
fi

exec /docker-entrypoint.sh $@
