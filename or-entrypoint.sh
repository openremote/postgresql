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

    # Check and update autovacuum_vacuum_scale_factor if needed
    echo "--------------------------------------------------------------------"
    echo "Checking autovacuum_vacuum_scale_factor setting..."
    echo "--------------------------------------------------------------------"
    
    # Extract current setting if it exists (commented or uncommented)
    CURRENT_AUTOVAC_SETTING=$(grep -E "^[#]*autovacuum_vacuum_scale_factor" "$PGDATA/postgresql.conf" | grep -oE "[0-9]\.[0-9]+" || echo "")
    
    if [ -z "$CURRENT_AUTOVAC_SETTING" ] || [ "$CURRENT_AUTOVAC_SETTING" != "$OR_AUTOVACUUM_VACUUM_SCALE_FACTOR" ]; then
      echo "------------------------------------------------------------------------"
      echo "Setting autovacuum_vacuum_scale_factor to $OR_AUTOVACUUM_VACUUM_SCALE_FACTOR"
      echo "------------------------------------------------------------------------"
      
      # Remove any existing setting (commented or uncommented)
      sed -i "/^[#]*autovacuum_vacuum_scale_factor/d" "$PGDATA/postgresql.conf"
      
      # Add the new setting
      echo "autovacuum_vacuum_scale_factor = $OR_AUTOVACUUM_VACUUM_SCALE_FACTOR" >> "$PGDATA/postgresql.conf"
    else
      echo "-----------------------------------------------------------------------"
      echo "autovacuum_vacuum_scale_factor already set to $CURRENT_AUTOVAC_SETTING"
      echo "-----------------------------------------------------------------------"
    fi

    # Check and update autovacuum_analyze_scale_factor if needed
    echo "--------------------------------------------------------------------"
    echo "Checking autovacuum_analyze_scale_factor setting..."
    echo "--------------------------------------------------------------------"
    
    # Extract current setting if it exists (commented or uncommented)
    CURRENT_AUTOVAC_ANALYZE_SETTING=$(grep -E "^[#]*autovacuum_analyze_scale_factor" "$PGDATA/postgresql.conf" | grep -oE "[0-9]\.[0-9]+" || echo "")
    
    if [ -z "$CURRENT_AUTOVAC_ANALYZE_SETTING" ] || [ "$CURRENT_AUTOVAC_ANALYZE_SETTING" != "$OR_AUTOVACUUM_ANALYZE_SCALE_FACTOR" ]; then
      echo "------------------------------------------------------------------------"
      echo "Setting autovacuum_analyze_scale_factor to $OR_AUTOVACUUM_ANALYZE_SCALE_FACTOR"
      echo "------------------------------------------------------------------------"
      
      # Remove any existing setting (commented or uncommented)
      sed -i "/^[#]*autovacuum_analyze_scale_factor/d" "$PGDATA/postgresql.conf"
      
      # Add the new setting
      echo "autovacuum_analyze_scale_factor = $OR_AUTOVACUUM_ANALYZE_SCALE_FACTOR" >> "$PGDATA/postgresql.conf"
    else
      echo "------------------------------------------------------------------------"
      echo "autovacuum_analyze_scale_factor already set to $CURRENT_AUTOVAC_ANALYZE_SETTING"
      echo "------------------------------------------------------------------------"
    fi

    ########################################################################################
    # Do upgrade checks - Adapted from https://github.com/pgautoupgrade/docker-pgautoupgrade
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

    # Try and upgrade if needed
    if [ "$DB_VERSION" != "$PG_MAJOR" ] && [ "$OR_DISABLE_AUTO_UPGRADE" != "true" ]; then

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

      echo "**********************************************************"
      echo "Automatic upgrade process finished with no errors reported"
      echo "**********************************************************"

      # Return the error handling back to automatically aborting on non-0 exit status
      set -e
    fi

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

    if [ "$DO_TS_UPGRADE" == "true" ]  && [ "$OR_DISABLE_AUTO_UPGRADE" == "true" ]; then
      echo "----------------------------------------------------------------------------------"
      echo "TimescaleDB upgrade can be performed but OR_DISABLE_AUTO_UPGRADE=true so skipping!"
      echo "----------------------------------------------------------------------------------"
    fi

    if [ "${OR_DISABLE_AUTO_UPGRADE}" == "true" ]; then
      DO_TS_UPGRADE=false
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

      # Cannot do this on a running DB as the extension is configured to preload
      if [ "$DO_TS_UPGRADE" == "true" ]; then
        echo "------------------------"
        echo "Performing TS upgrade..."
        echo "------------------------"

        # Don't automatically abort on non-0 exit status, just in case timescaledb extension isn't installed on the DB
		set +e
        docker_process_sql -X -c "ALTER EXTENSION timescaledb UPDATE;"
		
		if [ $? -eq 0 ]; then
           docker_process_sql -c "CREATE EXTENSION IF NOT EXISTS timescaledb_toolkit; ALTER EXTENSION timescaledb_toolkit UPDATE;"
		fi
		
		# Return the error handling back to automatically aborting on non-0 exit status
        set -e

        echo "-------------------"
        echo "TS upgrade complete"
        echo "-------------------"
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

exec /docker-entrypoint.sh $@
