#!/bin/sh

# This script sets up and starts the cron service for scheduled database maintenance
# It handles both Alpine Linux (crond) and Debian/Ubuntu (cron) systems

# Check if VACUUM FULL schedule is set
if [ -n "${OR_VACUUM_FULL_CRON_SCHEDULE}" ]; then
  echo "Setting up VACUUM FULL job with schedule: ${OR_VACUUM_FULL_CRON_SCHEDULE}..."
  
  # Create cron entry
  CRON_ENTRY="${OR_VACUUM_FULL_CRON_SCHEDULE} /var/lib/postgresql/scripts/vacuum_full.sh"
  echo "Using cron schedule: ${OR_VACUUM_FULL_CRON_SCHEDULE}"
  
  if [ -x "$(command -v cron)" ]; then
    # Debian/Ubuntu (standard cron)
    echo "Setting up cron job using standard cron..."
    (crontab -u postgres -l 2>/dev/null || echo "") | echo "$CRON_ENTRY" | crontab -u postgres -
    echo "VACUUM FULL job has been scheduled using standard cron"
    
    echo "Starting cron service for scheduled database maintenance..."
    service cron start
  elif [ -x "$(command -v crond)" ]; then
    # Alpine Linux (dcron)
    echo "Setting up cron job using Alpine's crond (dcron)..."
    mkdir -p /etc/crontabs
    echo "$CRON_ENTRY" > /etc/crontabs/postgres
    chmod 600 /etc/crontabs/postgres
    echo "VACUUM FULL job has been scheduled using dcron"
    
    echo "Starting crond service for scheduled database maintenance..."
    crond -b -L /var/lib/postgresql/cron.log
  else
    echo "WARNING: No cron system found. VACUUM FULL will not be automatically scheduled."
  fi
else
  echo "VACUUM FULL is disabled (OR_VACUUM_FULL_CRON_SCHEDULE is not set). Skipping cron service."
fi
