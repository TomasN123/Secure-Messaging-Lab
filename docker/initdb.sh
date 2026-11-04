#!/bin/bash

set -e

echo "Creating Keycloak role..."

psql -v ON_ERROR_STOP=1 \
     --username "$POSTGRES_USER" \
     -v kpw="$KEYCLOAK_DB_PASSWORD" <<'EOSQL'
CREATE ROLE keycloak LOGIN PASSWORD :'kpw';
EOSQL

echo "Creating Keycloak database..."

psql -v ON_ERROR_STOP=1 \
     --username "$POSTGRES_USER" <<'EOSQL'
CREATE DATABASE keycloak OWNER keycloak;
EOSQL

echo "Keycloak database initialization completed."