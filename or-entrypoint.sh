#!/usr/bin/env bash

# THIS FILE IS FOR MIGRATION OF EXISTING DB TO TIMESCALEDB IMAGE AS TIMESCALE INIT SCRIPTS AREN'T RUN WHEN DB
# ALREADY EXISTS; IT ALSO DOES AN AUTOMATIC REINDEX OF THE DB WHEN OR_REINDEX_COUNTER CHANGES TO SIMPLIFY MIGRATIONS
# IT ALSO AUTOMATICALLY HANDLES UPGRADING OF DATABASE AND DURING MAJOR VERSION CHANGES

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
        echo "timescaledb.telemetry_level=off" >> "$PGDATA/postgresql.conf"
    fi

    ########################################################################################
    # Do upgrade checks - Adapted from https://github.com/pgautoupgrade/docker-pgautoupgrade
    ########################################################################################

    # Get the version of the PostgreSQL data files
    DB_VERSION=$PG_MAJOR
    if [ -s "${PGDATA}/PG_VERSION" ]; then
      DB_VERSION=$(cat "${PGDATA}/PG_VERSION")
    fi

    # Try and upgrade if needed
    if [ "$DB_VERSION" != "$PG_MAJOR" ] && [ "$OR_DISABLE_AUTO_UPGRADE" != "true" ]; then

      echo "----------------------------------------------------------------------"
      echo "Postgres major version is newer than the existing DB, performing auto upgrade..."
      echo "----------------------------------------------------------------------"

      if [ ! -d "/usr/lib/postgresql/${DB_VERSION}" ]; then
        echo "Postgres executable version '$DB_VERSION' is not included in this image so cannot auto upgrade"
        exit 1
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

      # Initialise the new PostgreSQL database directory
      echo "--------------------------------------------------------------------------------------------------------------------"
      echo "Initialising new database directory"
      echo "--------------------------------------------------------------------------------------------------------------------"
      initdb -D $PGDATA/new
      echo "------------------------------------"
      echo "New database directory initialisation complete"
      echo "------------------------------------"

      # Change into the PostgreSQL database directory, to avoid a pg_upgrade error about write permissions
      cd "${PGDATA}"

      # Run the pg_upgrade command itself
      echo "---------------------------------------"
      echo "Running pg_upgrade command, from $(pwd)"
      echo "---------------------------------------"
      pg_upgrade --link -b /usr/lib/postgresql/${DB_VERSION}/bin -B /usr/lib/postgresql/${PG_MAJOR}/bin -d $OLD -D $NEW
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

      # Copy any reindex counter files
      echo "--------------------------------------------------------------"
      echo "Copying reindex files across"
      echo "--------------------------------------------------------------"
      cp -f ${OLD}/OR_REINDEX_* ${PGDATA}
      echo "-------------------------------------------------------------------"
      echo "Copying reindex files is complete"
      echo "-------------------------------------------------------------------"

      # Remove the left over database files
      echo "---------------------------------"
      echo "Removing left over database files"
      echo "---------------------------------"
      set +e
      rm -rf "${OLD}" "${NEW}" delete_old_cluster.sh
      set -e
      echo "---------------------------------------------"
      echo "Removing left over database files is complete"
      echo "---------------------------------------------"

      echo "**********************************************************"
      echo "Automatic upgrade process finished with no errors reported"
      echo "**********************************************************"
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
            echo "REINDEX file '$REINDEX_FILE' doesn't exist"
            docker_temp_server_start "$@"
            echo "Running timescaledb tune script..."
            /docker-entrypoint-initdb.d/001_timescaledb_tune.sh
            echo "Re-indexing the DB..."
            docker_process_sql -c "REINDEX database $POSTGRES_DB;"
            docker_temp_server_stop
            echo 'REINDEX completed!'
            touch "$REINDEX_FILE"
        fi
    fi
fi

exec /docker-entrypoint.sh $@
