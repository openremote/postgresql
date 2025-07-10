#!/bin/bash
set -e

echo "-------------------------------------------------------------------------------------"
echo "Setting autovacuum parameters during initialization..."
echo "-------------------------------------------------------------------------------------"

# Set vacuum parameters
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
  ALTER SYSTEM SET autovacuum_vacuum_scale_factor = $OR_AUTOVACUUM_VACUUM_SCALE_FACTOR;
  ALTER SYSTEM SET autovacuum_analyze_scale_factor = $OR_AUTOVACUUM_ANALYZE_SCALE_FACTOR;
  SELECT pg_reload_conf();
EOSQL

echo "-----------------------------------------------------------------------------------"
echo "Autovacuum parameters set: "
echo "  - autovacuum_vacuum_scale_factor = $OR_AUTOVACUUM_VACUUM_SCALE_FACTOR"
echo "  - autovacuum_analyze_scale_factor = $OR_AUTOVACUUM_ANALYZE_SCALE_FACTOR"
echo "-----------------------------------------------------------------------------------"
