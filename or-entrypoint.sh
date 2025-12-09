#!/usr/bin/env bash

# THIS FILE IS FOR MIGRATION OF EXISTING DB TO TIMESCALEDB IMAGE AS TIMESCALE INIT SCRIPTS AREN'T RUN WHEN DB
# ALREADY EXISTS; IT ALSO DOES AN AUTOMATIC REINDEX OF THE DB WHEN OR_REINDEX_COUNTER CHANGES TO SIMPLIFY MIGRATIONS
# IT ALSO AUTOMATICALLY HANDLES UPGRADING OF DATABASE AND DURING MAJOR VERSION CHANGES
# BASED ON: https://github.com/pgautoupgrade/docker-pgautoupgrade

source /docker-entrypoint.sh
docker_setup_env

# Append max connections arg if needed
if [ $POSTGRES_MAX_CONNECTIONS -gt 0 ]; then
  set -- "$@" -c max_connections=${POSTGRES_MAX_CONNECTIONS}
fi

# Check for presence of old/new directories, indicating a failed previous autoupgrade
echo "----------------------------------------------------------------------"
echo "Checking for left over artifacts from a failed previous autoupgrade..."
echo "----------------------------------------------------------------------"
OLD="${PGDATA}/old"
NEW="${PGDATA}/new"
if [ -d "${OLD}" ]; then
  echo "*****************************************"
  echo "Left over OLD directory found.  Aborting."
  echo "*****************************************"
  exit 10
fi
if [ -d "${NEW}" ]; then
  echo "*****************************************"
  echo "Left over NEW directory found.  Aborting."
  echo "*****************************************"
  exit 11
fi
echo "-------------------------------------------------------------------------------"
echo "No artifacts found from a failed previous autoupgrade.  Continuing the process."
echo "-------------------------------------------------------------------------------"

if [ -n "$DATABASE_ALREADY_EXISTS" ]; then

    echo "-----------------------------------------"
    echo "Performing checks on existing database..."
    echo "-----------------------------------------"

    # Make sure timescaledb library is set to preload (won't work otherwise)
    echo "---------------------------------------------------------------------------------------"
    echo "Existing postgresql.conf found checking for shared_preload_libraries = 'timescaledb'..."
    echo "---------------------------------------------------------------------------------------"
    RESULT=$(cat "$PGDATA/postgresql.conf" | grep "^shared_preload_libraries = 'timescaledb'" || true)

    if [ -n "$RESULT" ]; then
      echo "-------------------------------------------"
      echo "Timescale DB library already set to preload"
      echo "-------------------------------------------"
    else
      echo "------------------------------------------------------------------"
      echo "Adding shared_preload_libraries = 'timescaledb' to postgresql.conf"
      echo "------------------------------------------------------------------"
      echo "shared_preload_libraries = 'timescaledb'" >> "$PGDATA/postgresql.conf"
      echo "timescaledb.telemetry_level=off" >> "$PGDATA/postgresql.conf"
    fi

    ########################################################################################
    # Do upgrade checks - Adapted from https://github.com/pgautoupgrade/docker-pgautoupgrade
    # IMPORTANT: TimescaleDB must be upgraded BEFORE PostgreSQL upgrade
    # See: https://docs.tigerdata.com/self-hosted/latest/upgrades/major-upgrade/
    ########################################################################################

    # Get the version of the PostgreSQL data files
    DB_VERSION=$PG_MAJOR
    if [ -s "${PGDATA}/PG_VERSION" ]; then
      DB_VERSION=$(cat "${PGDATA}/PG_VERSION")
    fi

    if [ "$DB_VERSION" != "$PG_MAJOR" ]  && [ "$OR_DISABLE_AUTO_UPGRADE" == "true" ]; then
      echo "---------------------------------------------------------------------------------"
      echo "Postgres major version has changed but OR_DISABLE_AUTO_UPGRADE=true so container will likely fail to start!"
      echo "---------------------------------------------------------------------------------"
    fi

    # STEP 1: Upgrade TimescaleDB on OLD PostgreSQL version (if needed)
    # This must happen BEFORE pg_upgrade so both old and new PG have the same TS version
    if [ "$DB_VERSION" != "$PG_MAJOR" ] && [ "$OR_DISABLE_AUTO_UPGRADE" != "true" ]; then
      echo "================================================================================="
      echo "STEP 1: Upgrading TimescaleDB on PostgreSQL ${DB_VERSION} before PG upgrade..."
      echo "================================================================================="
      
      # Start temporary server on OLD PostgreSQL version
      echo "Starting temporary PostgreSQL ${DB_VERSION} server..."
      
      # Temporarily update PATH to use old PostgreSQL version
      OLD_PATH=$PATH
      export PATH="/usr/lib/postgresql/${DB_VERSION}/bin:$PATH"
      
      docker_temp_server_start "$@"
      
      # Don't automatically abort on non-0 exit status, just in case timescaledb extension isn't installed
      set +e
      
      # Get the latest TimescaleDB version available for the OLD PostgreSQL version
      # We must use DB_VERSION here since we're running on the old server
      TS_VERSION_REGEX="\-\-([0-9|\.]+)\."
      TS_SCRIPT_NAME=$(find /usr/share/postgresql/${DB_VERSION}/extension/ -type f -name "timescaledb--*.sql" | sort | tail -n 1)
      if [ "$TS_SCRIPT_NAME" != "" ] && [[ $TS_SCRIPT_NAME =~ $TS_VERSION_REGEX ]]; then
        TARGET_TS_VERSION=${BASH_REMATCH[1]}
        echo "Target TimescaleDB version available: ${TARGET_TS_VERSION}"
        
        # Upgrade TimescaleDB in ALL databases that have it installed
        # This is critical because template1, postgres, and user databases may all have TimescaleDB
        # We must include template databases because template1 often has TimescaleDB installed
        echo "Finding all databases with TimescaleDB extension..."
        DATABASES=$(docker_process_sql -X -t -c "SELECT datname FROM pg_database WHERE datallowconn;" | grep -v "^$")
        
        for DB in $DATABASES; do
          echo "Checking database: $DB"
          HAS_TS=$(docker_process_sql -X -d "$DB" -c "SELECT 1 FROM pg_extension WHERE extname='timescaledb';" | grep -v "^$" | wc -l)
          
          if [ "$HAS_TS" -gt 0 ]; then
            CURRENT_TS_VERSION=$(docker_process_sql -X -d "$DB" -c "SELECT extversion FROM pg_extension WHERE extname='timescaledb';" | grep -v extversion | grep -v row | tr -d ' ')
            echo "  Database $DB has TimescaleDB ${CURRENT_TS_VERSION}, upgrading..."
            docker_process_sql -X -d "$DB" -c "ALTER EXTENSION timescaledb UPDATE;"
            NEW_TS_VERSION=$(docker_process_sql -X -d "$DB" -c "SELECT extversion FROM pg_extension WHERE extname='timescaledb';" | grep -v extversion | grep -v row | tr -d ' ')
            echo "  Upgraded: ${CURRENT_TS_VERSION} -> ${NEW_TS_VERSION}"
            
            # Also upgrade toolkit if present
            HAS_TOOLKIT=$(docker_process_sql -X -d "$DB" -c "SELECT 1 FROM pg_extension WHERE extname='timescaledb_toolkit';" | grep -v "^$" | wc -l)
            if [ "$HAS_TOOLKIT" -gt 0 ]; then
              echo "  Upgrading timescaledb_toolkit in $DB..."
              docker_process_sql -X -d "$DB" -c "ALTER EXTENSION timescaledb_toolkit UPDATE;"
            fi
          fi
        done
        
        echo "TimescaleDB upgrade complete in all databases"
      fi
      
      # Return error handling back to automatically aborting on non-0 exit status
      set -e
      
      docker_temp_server_stop
      
      # Restore PATH
      export PATH=$OLD_PATH
      
      echo "================================================================================="
      echo "STEP 1 Complete: TimescaleDB upgraded on PostgreSQL ${DB_VERSION}"
      echo "================================================================================="
    fi

    # STEP 2: Upgrade PostgreSQL if needed
    if [ "$DB_VERSION" != "$PG_MAJOR" ] && [ "$OR_DISABLE_AUTO_UPGRADE" != "true" ]; then
      echo "================================================================================="
      echo "STEP 2: Upgrading PostgreSQL from ${DB_VERSION} to ${PG_MAJOR}..."
      echo "================================================================================="

      echo "---------------------------------------------------------------------------------"
      echo "Postgres major version is newer than the existing DB, performing auto upgrade..."
      echo "---------------------------------------------------------------------------------"

      if [ -f "${PGDATA}/postmaster.pid" ]; then
        echo "-----------------------------------------------------------------------------------------------------"
        echo "Looks like the server did not previously shutdown properly which will prevent pg_upgrade from working"
        echo "try stopping the whole stack, bringing only the postgresql container up and then stopping it again"
        echo "-----------------------------------------------------------------------------------------------------"
        exit 1
      fi

      if [ ! -d "/usr/lib/postgresql/${DB_VERSION}" ]; then
        echo "--------------------------------------------------------------------------------------------------"
        echo "Postgres executable version '$DB_VERSION' is not included in this image so cannot auto upgrade"
        echo "--------------------------------------------------------------------------------------------------"
        exit 1
      fi

      # Don't automatically abort on non-0 exit status, as that messes with these upcoming mv commands
      set +e

      # Move the PostgreSQL data files into a subdirectory of the mount point
      echo "---------------------------------------"
      echo "Creating OLD temporary directory ${OLD}"
      echo "---------------------------------------"
      mkdir "${OLD}"
      if [ ! -d "${OLD}" ]; then
        echo "*********************************************************************"
        echo "Creation of temporary directory '${OLD}' failed.  Aborting completely"
        echo "*********************************************************************"
        exit 7
      fi
      echo "--------------------------------------------"
      echo "Creating OLD temporary directory is complete"
      echo "--------------------------------------------"

      echo "-------------------------------------------------------"
      echo "Moving existing data files into OLD temporary directory"
      echo "-------------------------------------------------------"
      mv -v "${PGDATA}"/* "${OLD}"
      echo "-------------------------------------------------------------------"
      echo "Moving existing data files into OLD temporary directory is complete"
      echo "-------------------------------------------------------------------"

      echo "---------------------------------------"
      echo "Creating NEW temporary directory ${NEW}"
      echo "---------------------------------------"
      mkdir "${NEW}"
      if [ ! -d "${NEW}" ]; then
        echo "********************************************************************"
        echo "Creation of temporary directory '${NEW}' failed. Aborting completely"
        echo "********************************************************************"
        # With a failure at this point we should be able to move the old data back
        # to its original location
        mv -v "${OLD}"/* "${PGDATA}"
        exit 8
      fi
      echo "--------------------------------------------"
      echo "Creating NEW temporary directory is complete"
      echo "--------------------------------------------"

      echo "-----------------------------------------------------"
      echo "Changing permissions of temporary directories to 0700"
      echo "-----------------------------------------------------"
      chmod 0700 "${OLD}" "${NEW}"
      echo "---------------------------------------------------------"
      echo "Changing permissions of temporary directories is complete"
      echo "---------------------------------------------------------"

      # Return the error handling back to automatically aborting on non-0 exit status
      set -e

      # If no initdb arguments were passed to us from the environment, then work out something valid ourselves
      if [ "x${POSTGRES_INITDB_ARGS}" != "x" ]; then
         echo "------------------------------------------------------------------------------"
         echo "Using initdb arguments passed in from the environment: ${POSTGRES_INITDB_ARGS}"
         echo "------------------------------------------------------------------------------"
      else
         echo "-------------------------------------------------"
         echo "Remove postmaster.pid file from PG data directory"
         echo "-------------------------------------------------"
         rm -f "${OLD}"/postmaster.pid

         echo "------------------------------------"
         echo "Determining our own initdb arguments"
         echo "------------------------------------"
         COLLATE=unset
         CTYPE=unset
         ENCODING=unset
         COLLATE=$(echo 'SHOW LC_COLLATE' | "/usr/lib/postgresql/${DB_VERSION}/bin/postgres" --single -D "${OLD}" "${POSTGRES_DB}" | grep 'lc_collate = "' | cut -d '"' -f 2)
         CTYPE=$(echo 'SHOW LC_CTYPE' | "/usr/lib/postgresql/${DB_VERSION}/bin/postgres" --single -D "${OLD}" "${POSTGRES_DB}" | grep 'lc_ctype = "' | cut -d '"' -f 2)
         ENCODING=$(echo 'SHOW SERVER_ENCODING' | "/usr/lib/postgresql/${DB_VERSION}/bin/postgres" --single -D "${OLD}" "${POSTGRES_DB}" | grep 'server_encoding = "' | cut -d '"' -f 2)
         POSTGRES_INITDB_ARGS="--locale=${COLLATE} --lc-collate=${COLLATE} --lc-ctype=${CTYPE} --encoding=${ENCODING}"
         echo "---------------------------------------------------------------"
         echo "The initdb arguments we determined are: ${POSTGRES_INITDB_ARGS}"
         echo "---------------------------------------------------------------"
      fi

      # Initialise the new PostgreSQL database directory
      echo "--------------------------------------------------------------------------------------------------------------------"
      echo "Old database using collation settings: '${POSTGRES_INITDB_ARGS}'.  Initialising new database with those settings too"
      echo "--------------------------------------------------------------------------------------------------------------------"
      initdb --username="${POSTGRES_USER}" ${POSTGRES_INITDB_ARGS} ${PGDATA}/new/
      echo "------------------------------------"
      echo "New database initialisation complete"
      echo "------------------------------------"

      # Change into the PostgreSQL database directory, to avoid a pg_upgrade error about write permissions
      cd "${PGDATA}"

      # Run the pg_upgrade command itself
      echo "---------------------------------------"
      echo "Running pg_upgrade command, from $(pwd)"
      echo "---------------------------------------"
      # Specify socket directories for both old and new clusters
      # Use --check first to see what issues exist
      echo "Running pg_upgrade --check first..."
      pg_upgrade --check \
        -b /usr/lib/postgresql/${DB_VERSION}/bin \
        -B /usr/lib/postgresql/${PG_MAJOR}/bin \
        -d $OLD \
        -D $NEW \
        -o "-c unix_socket_directories='${PGSOCKET}'" \
        -O "-c unix_socket_directories='${PGSOCKET}'" || true
      
      echo "Running actual pg_upgrade with --link..."
      pg_upgrade --link \
        -b /usr/lib/postgresql/${DB_VERSION}/bin \
        -B /usr/lib/postgresql/${PG_MAJOR}/bin \
        -d $OLD \
        -D $NEW \
        -o "-c unix_socket_directories='${PGSOCKET}'" \
        -O "-c unix_socket_directories='${PGSOCKET}'"
      echo "--------------------------------------"
      echo "Running pg_upgrade command is complete"
      echo "--------------------------------------"

      # Move the new database files into place
      echo "-----------------------------------------------------"
      echo "Moving the upgraded database files to the active directory"
      echo "-----------------------------------------------------"
      mv -v "${NEW}"/* "${PGDATA}"
      echo "-----------------------------------------"
      echo "Moving the upgraded database files is complete"
      echo "-----------------------------------------"

      # Re-use the pg_hba.conf and pg_ident.conf from the old data directory
      echo "--------------------------------------------------------------"
      echo "Copying the old pg_hba and pg_ident configuration files across"
      echo "--------------------------------------------------------------"
      cp -f "${OLD}/pg_hba.conf" "${OLD}/pg_ident.conf" "${PGDATA}"
      echo "-------------------------------------------------------------------"
      echo "Copying the old pg_hba and pg_ident configuration files is complete"
      echo "-------------------------------------------------------------------"

      # Don't automatically abort on non-0 exit status
      set +e

      # Copy any reindex counter files
      echo "--------------------------------------------------------------"
      echo "Copying reindex and TS version files across"
      echo "--------------------------------------------------------------"
      cp -f ${OLD}/OR_REINDEX_* ${PGDATA}
      cp -f ${OLD}/OR_TS_VERSION ${PGDATA}
      echo "-------------------------------------------------------------------"
      echo "Copying reindex files is complete"
      echo "-------------------------------------------------------------------"

      # Remove the left over database files
      echo "---------------------------------"
      echo "Removing left over database files"
      echo "---------------------------------"
      rm -rf "${OLD}" "${NEW}" delete_old_cluster.sh
      echo "---------------------------------------------"
      echo "Removing left over database files is complete"
      echo "---------------------------------------------"

      echo "================================================================================="
      echo "STEP 2 Complete: PostgreSQL upgraded from ${DB_VERSION} to ${PG_MAJOR}"
      echo "================================================================================="

      # Return the error handling back to automatically aborting on non-0 exit status
      set -e
    fi

    # STEP 3: Upgrade TimescaleDB on NEW PostgreSQL version (if needed)
    # Do timescale upgrade if needed - First look for latest extension version number in extension files
    echo "----------------------------------------------------------"
    echo "Checking latest available TimescaleDB extension version..."
    echo "----------------------------------------------------------"
    TS_VERSION_REGEX="\-\-([0-9|\.]+)\."
    TS_SCRIPT_NAME=$(find /usr/share/postgresql/$PG_MAJOR/extension/ -type f -name "timescaledb--*.sql" | sort | tail -n 1)
    TS_VERSION=""
    TS_VERSION_FILE="${PGDATA}/OR_TS_VERSION"

    if [ "$TS_SCRIPT_NAME" == "" ] || ! [[ $TS_SCRIPT_NAME =~ $TS_VERSION_REGEX ]]; then
      echo "------------------------------------------------------"
      echo "Cannot determine current TimescaleDB extension version"
      echo "------------------------------------------------------"
      exit 15
    else
      TS_VERSION=${BASH_REMATCH[1]}
    fi

    if [ "$TS_VERSION" == "" ]; then
      echo "------------------------------------------------------"
      echo "Cannot determine current TimescaleDB extension version"
      echo "------------------------------------------------------"
      exit 15
    fi

    DO_TS_UPGRADE=false
    echo "Checking whether Timescale needs upgrading..."
    if [ ! -f "${TS_VERSION_FILE}" ]; then
      echo "-----------------------------------------------------"
      echo "No OR_TS_VERSION file so assuming upgrade is required"
      echo "-----------------------------------------------------"
      DO_TS_UPGRADE=true
    else
      echo "-------------------------------------------------------"
      echo "Getting version number from existing OR_TS_VERSION file"
      echo "-------------------------------------------------------"
      PREVIOUS_TS_VERSION=$(cat "$TS_VERSION_FILE")
      if [ "${PREVIOUS_TS_VERSION}" != "${TS_VERSION}" ]; then
        echo "------------------------------------------------------------------------------"
        echo "TimescaleDB extension upgrade required ${PREVIOUS_TS_VERSION} -> ${TS_VERSION}"
        echo "------------------------------------------------------------------------------"
        DO_TS_UPGRADE=true
      else
        echo "----------------------------------------------------"
        echo "TimescaleDB extension is up to date at: ${TS_VERSION}"
        echo "----------------------------------------------------"
      fi
    fi

    # Check if auto-upgrade is disabled
    if [ "$DO_TS_UPGRADE" == "true" ] && [ "$OR_DISABLE_AUTO_UPGRADE" == "true" ]; then
      echo "----------------------------------------------------------------------------------"
      echo "TimescaleDB upgrade can be performed but OR_DISABLE_AUTO_UPGRADE=true so skipping!"
      echo "----------------------------------------------------------------------------------"
      DO_TS_UPGRADE=false
    fi

    # If we just did a PostgreSQL upgrade, we MUST upgrade TimescaleDB on the new cluster
    # pg_upgrade copies extension metadata but doesn't upgrade extensions
    # STEP 1 upgraded TS on the OLD cluster, but pg_upgrade created a NEW cluster
    if [ "$DB_VERSION" != "$PG_MAJOR" ] && [ "$OR_DISABLE_AUTO_UPGRADE" != "true" ]; then
      echo "PostgreSQL was just upgraded - forcing TimescaleDB upgrade on new cluster"
      DO_TS_UPGRADE=true
    fi


    # Do re-indexing check
    DO_REINDEX=false
    if [ "$OR_DISABLE_REINDEX" == 'true' ] || [ -z "$OR_REINDEX_COUNTER" ]; then
      echo "----------------------------"
      echo "OR_REINDEX check is disabled"
      echo "----------------------------"
    else
      echo "---------------------------------------"
      echo "Checking whether REINDEX is required..."
      echo "---------------------------------------"
      REINDEX_FILE="$PGDATA/OR_REINDEX_COUNTER.$OR_REINDEX_COUNTER"
      if [ -f "$REINDEX_FILE" ]; then
        echo "-------------------------------------------------------------------------"
        echo "REINDEX file '$REINDEX_FILE' already exists so no re-indexing required"
        echo "-------------------------------------------------------------------------"
      else
        echo "-------------------------------------------------------------------------"
        echo "REINDEX file '$REINDEX_FILE' doesn't exist so re-indexing required"
        echo "-------------------------------------------------------------------------"
        DO_REINDEX=true
      fi
    fi

    if [ "$DO_REINDEX" == "true" ] || [ "$DO_TS_UPGRADE" == "true" ]; then
      echo "-------------------------"
      echo "Starting temporary server"
      echo "-------------------------"
      docker_temp_server_start "$@"

      # STEP 3: Upgrade TimescaleDB on new PostgreSQL version (if needed)
      # Cannot do this on a running DB as the extension is configured to preload
      if [ "$DO_TS_UPGRADE" == "true" ]; then
        echo "================================================================================="
        echo "STEP 3: Upgrading TimescaleDB on PostgreSQL ${PG_MAJOR}..."
        echo "================================================================================="
        echo "Target TimescaleDB version: ${TS_VERSION}"

        # Don't automatically abort on non-0 exit status, just in case timescaledb extension isn't installed
        set +e

        # Upgrade TimescaleDB in ALL databases that have it installed
        # This is critical after pg_upgrade which copies extension metadata but doesn't upgrade
        echo "Finding all databases with TimescaleDB extension..."
        DATABASES=$(docker_process_sql -X -t -c "SELECT datname FROM pg_database WHERE datallowconn;" | grep -v "^$")

        for DB in $DATABASES; do
          echo "Checking database: $DB"
          HAS_TS=$(docker_process_sql -X -d "$DB" -c "SELECT 1 FROM pg_extension WHERE extname='timescaledb';" | grep -v "^$" | wc -l)

          if [ "$HAS_TS" -gt 0 ]; then
            CURRENT_TS_VERSION=$(docker_process_sql -X -d "$DB" -c "SELECT extversion FROM pg_extension WHERE extname='timescaledb';" | grep -v extversion | grep -v row | tr -d ' ')
            echo "  Database $DB has TimescaleDB ${CURRENT_TS_VERSION}, upgrading..."
            docker_process_sql -X -d "$DB" -c "ALTER EXTENSION timescaledb UPDATE;"
            NEW_TS_VERSION=$(docker_process_sql -X -d "$DB" -c "SELECT extversion FROM pg_extension WHERE extname='timescaledb';" | grep -v extversion | grep -v row | tr -d ' ')
            echo "  Upgraded: ${CURRENT_TS_VERSION} -> ${NEW_TS_VERSION}"

            # Also upgrade toolkit if present
            HAS_TOOLKIT=$(docker_process_sql -X -d "$DB" -c "SELECT 1 FROM pg_extension WHERE extname='timescaledb_toolkit';" | grep -v "^$" | wc -l)
            if [ "$HAS_TOOLKIT" -gt 0 ]; then
              echo "  Upgrading timescaledb_toolkit in $DB..."
              docker_process_sql -X -d "$DB" -c "ALTER EXTENSION timescaledb_toolkit UPDATE;"
            else
              echo "  Creating timescaledb_toolkit in $DB..."
              docker_process_sql -d "$DB" -c "CREATE EXTENSION IF NOT EXISTS timescaledb_toolkit;"
            fi
          fi
        done

        echo "TimescaleDB upgrade complete in all databases"

        # Return the error handling back to automatically aborting on non-0 exit status
        set -e

        echo "================================================================================="
        echo "STEP 3 Complete: TimescaleDB upgraded on PostgreSQL ${PG_MAJOR}"
        echo "================================================================================="
        echo "$TS_VERSION" > "${PGDATA}/OR_TS_VERSION"
      fi

      if [ "$DO_REINDEX" == "true" ]; then
        echo "----------------------------------"
        echo "Running timescaledb tune script..."
        echo "----------------------------------"
        /docker-entrypoint-initdb.d/001_timescaledb_tune.sh
        echo "---------------------"
        echo "Re-indexing the DB..."
        echo "---------------------"
        docker_process_sql -c "REINDEX database $POSTGRES_DB;"
        echo "------------------"
        echo "REINDEX completed!"
        echo "------------------"
        touch "$REINDEX_FILE"
      fi

      docker_temp_server_stop
    fi
fi

exec /usr/local/bin/docker-entrypoint.sh $@
