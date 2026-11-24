#!/bin/sh
# Runs once, when Postgres creates the database (after the schema in init.sql).
# Creates the login the API uses: it can read the three tables it needs and
# nothing else - no writes, no DDL, no other databases, not a superuser.
# The password comes from a secret file, never from this repo.
# (The Postgres image sources this file, so no `set -e`/`exit` here.)
if [ -z "${APP_DB_PASSWORD_FILE:-}" ] || [ ! -r "$APP_DB_PASSWORD_FILE" ]; then
  echo "app-role.sh: APP_DB_PASSWORD_FILE is not readable; the API login was not created" >&2
  false
else
  psql -v ON_ERROR_STOP=1 \
       -v app_user="${APP_DB_USER:-token_api}" \
       -v app_pw="$(cat "$APP_DB_PASSWORD_FILE")" \
       -v db="$POSTGRES_DB" \
       --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<'SQL'
CREATE ROLE :"app_user" LOGIN PASSWORD :'app_pw'
  NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION CONNECTION LIMIT 50;
REVOKE ALL ON DATABASE :"db" FROM PUBLIC;
GRANT CONNECT ON DATABASE :"db" TO :"app_user";
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO :"app_user";
GRANT SELECT ON users, memberships, group_permissions TO :"app_user";
ALTER ROLE :"app_user" SET statement_timeout = '2s';
SQL
fi
