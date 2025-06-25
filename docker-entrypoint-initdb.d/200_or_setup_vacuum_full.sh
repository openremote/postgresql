#!/bin/sh

# This script sets up a weekly VACUUM FULL job to clean up database bloat
# VACUUM FULL reclaims more space than regular AUTOVACUUM by rewriting the entire table

# Check if VACUUM FULL is enabled (default is disabled)
if [ "${OR_ENABLE_VACUUM_FULL:-false}" != "true" ]; then
    echo "VACUUM FULL is disabled (OR_ENABLE_VACUUM_FULL is not set to 'true'). Skipping setup."
    exit 0
fi

echo "Setting up VACUUM FULL job (OR_ENABLE_VACUUM_FULL=true)..."

# Create scripts directory if it doesn't exist
mkdir -p /var/lib/postgresql/scripts

# Create the vacuum script that will run VACUUM FULL on all tables in the database
cat > /var/lib/postgresql/scripts/vacuum_full.sh << 'EOF'
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
EOF

# Make the script executable
chmod +x /var/lib/postgresql/scripts/vacuum_full.sh

# Parse the cron schedule from environment variable or use default (Sunday at 12:00 AM)
CRON_SCHEDULE="${OR_VACUUM_FULL_CRON_SCHEDULE:-0 0 * * 0}"
CRON_ENTRY="$CRON_SCHEDULE /var/lib/postgresql/scripts/vacuum_full.sh"

echo "Using cron schedule: $CRON_SCHEDULE"

# Detect which cron system is available
if command -v crond > /dev/null 2>&1; then
    # Alpine Linux (dcron)
    echo "Setting up cron job using Alpine's crond (dcron)..."
    mkdir -p /etc/crontabs
    echo "$CRON_ENTRY" > /etc/crontabs/postgres
    chmod 600 /etc/crontabs/postgres
    echo "VACUUM FULL job has been scheduled using dcron"
    
    # Create a script to start crond when container starts
    cat > /var/lib/postgresql/scripts/start_cron.sh << 'EOF'
#!/bin/sh
if [ -x "$(command -v crond)" ] && [ "${OR_ENABLE_VACUUM_FULL:-false}" = "true" ]; then
  echo "Starting crond service for scheduled database maintenance..."
  crond -b -L /var/lib/postgresql/cron.log
fi
EOF
    chmod +x /var/lib/postgresql/scripts/start_cron.sh
    
elif command -v cron > /dev/null 2>&1; then
    # Debian/Ubuntu (standard cron)
    echo "Setting up cron job using standard cron..."
    (crontab -u postgres -l 2>/dev/null || echo "") | echo "$CRON_ENTRY" | crontab -u postgres -
    echo "VACUUM FULL job has been scheduled using standard cron"
else
    echo "WARNING: No cron system found. VACUUM FULL will not be automatically scheduled."
fi
