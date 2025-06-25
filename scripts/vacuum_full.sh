#!/bin/sh

# Log file for vacuum operations
LOG_FILE="/var/lib/postgresql/vacuum_full.log"

echo "$(date): Starting VACUUM FULL operation" >> "$LOG_FILE"

# Get list of all tables in the database
TABLES=$(psql -t -c "SELECT schemaname || '.' || tablename FROM pg_tables WHERE schemaname NOT IN ('pg_catalog', 'information_schema')" "${POSTGRES_DB:-postgres}")

# Run VACUUM FULL on each table
for TABLE in $TABLES; do
    echo "$(date): Running VACUUM FULL on $TABLE" >> "$LOG_FILE"
    psql -c "VACUUM FULL $TABLE" "${POSTGRES_DB:-postgres}"
    echo "$(date): Completed VACUUM FULL on $TABLE" >> "$LOG_FILE"
done

echo "$(date): VACUUM FULL operation completed" >> "$LOG_FILE"
