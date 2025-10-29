#!/bin/bash

# THIS SCRIPT CONFIGURES TIMESCALEDB RETENTION POLICIES FOR ASSET DATAPOINT TABLES
# The retention policies will automatically delete data older than the specified interval
# This can be run during database initialization or on existing databases

set -e

# Default retention periods (supports flexible time units like "90 days", "6 months", "2 weeks", "48 hours")
OR_ASSET_DATAPOINT_RETENTION=$OR_ASSET_DATAPOINT_RETENTION
OR_ASSET_PREDICTED_DATAPOINT_RETENTION=$OR_ASSET_PREDICTED_DATAPOINT_RETENTION

echo "-----------------------------------------------------------"
echo "Configuring TimescaleDB retention policies..."
echo "-----------------------------------------------------------"

# Function to configure or remove retention policy based on whether interval is set
configure_retention_policy() {
    local table_name=$1
    local retention_interval=$2
    
    echo "Checking if table '$table_name' exists and is a hypertable..."
    
    # Check if table exists and is a hypertable
    # Use docker_process_sql if available (existing DB), otherwise use psql (new DB)
    if declare -f docker_process_sql > /dev/null; then
        TABLE_EXISTS=$(docker_process_sql -X -tAc \
            "SELECT COUNT(*) FROM timescaledb_information.hypertables WHERE hypertable_name = '$table_name';")
    else
        TABLE_EXISTS=$(psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -tAc \
            "SELECT COUNT(*) FROM timescaledb_information.hypertables WHERE hypertable_name = '$table_name';")
    fi
    
    if [ "$TABLE_EXISTS" -gt 0 ]; then
        if [ -n "$retention_interval" ]; then
            # Retention interval is set - configure the policy
            echo "Table '$table_name' is a hypertable. Configuring retention policy of $retention_interval..."
            
            # Remove existing retention policy if any and add new one
            if declare -f docker_process_sql > /dev/null; then
                docker_process_sql -c "SELECT remove_retention_policy('$table_name', if_exists => true);"
                docker_process_sql -c "SELECT add_retention_policy('$table_name', INTERVAL '$retention_interval');"
            else
                psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
                    -- Remove existing retention policy if present
                    SELECT remove_retention_policy('$table_name', if_exists => true);
                    
                    -- Add new retention policy
                    SELECT add_retention_policy('$table_name', INTERVAL '$retention_interval');
EOSQL
            fi
            
            echo "Retention policy configured for '$table_name': data older than $retention_interval will be automatically deleted."
        else
            # Retention interval is not set - remove any existing policy
            echo "Table '$table_name' is a hypertable. No retention interval specified, removing any existing retention policy..."
            
            if declare -f docker_process_sql > /dev/null; then
                docker_process_sql -c "SELECT remove_retention_policy('$table_name', if_exists => true);"
            else
                psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
                    -- Remove existing retention policy if present
                    SELECT remove_retention_policy('$table_name', if_exists => true);
EOSQL
            fi
            
            echo "Retention policy removed for '$table_name': data will be retained indefinitely."
        fi
    else
        echo "Table '$table_name' does not exist or is not a hypertable. Skipping retention policy setup."
        if [ -n "$retention_interval" ]; then
            echo "Note: Retention policy will be applied when the table is created as a hypertable."
        fi
    fi
}

# Remove existing settings if they exist
sed -i -e '/^or.asset_datapoint_retention/d' -e '/^or.asset_predicted_datapoint_retention/d' "$PGDATA/postgresql.conf"

# Add new settings
if [ -n "$OR_ASSET_DATAPOINT_RETENTION" ]; then
    echo "or.asset_datapoint_retention = '$OR_ASSET_DATAPOINT_RETENTION'" >> "$PGDATA/postgresql.conf"
fi
if [ -n "$OR_ASSET_PREDICTED_DATAPOINT_RETENTION" ]; then
    echo "or.asset_predicted_datapoint_retention = '$OR_ASSET_PREDICTED_DATAPOINT_RETENTION'" >> "$PGDATA/postgresql.conf"
fi

# Then configure the actual retention policies
configure_retention_policy "asset_datapoint" "$OR_ASSET_DATAPOINT_RETENTION"
configure_retention_policy "asset_predicted_datapoint" "$OR_ASSET_PREDICTED_DATAPOINT_RETENTION"

echo "-----------------------------------------------------------"
echo "TimescaleDB retention policy configuration complete!"
echo "-----------------------------------------------------------"