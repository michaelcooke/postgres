#!/bin/bash
set -eou pipefail

# Ref: https://gist.github.com/sj26/88e1c6584397bb7c13bd11108a579746
function retry {
  # Pass 0 for unlimited retries
  local retries=$1
  shift

  local start=$EPOCHSECONDS
  local count=0
  until "$@"; do
    exit=$?
    # Reset count if service has been running for more than 2 minutes
    local elapsed=$((EPOCHSECONDS - start))
    if [ $elapsed -gt 120 ]; then
      count=0
    fi
    # Exponential backoff up to n tries
    local wait=$((2 ** count))
    count=$((count + 1))
    if [ $count -ge "$retries" ] && [ "$retries" -gt 0 ]; then
      echo "Retry $count/$retries exited $exit, no more retries left."
      return $exit
    fi
    echo "Retry $count/$retries exited $exit, retrying in $wait seconds..."
    sleep $wait
    start=$EPOCHSECONDS
  done
  return 0
}

function configure_services {
  # Start services after migrations are run
  for file in /init/configure-*.sh; do
    retry 0 "$file"
  done
}

PG_CONF=/etc/postgresql/postgresql.conf
SUPERVISOR_CONF=/etc/supervisor/supervisord.conf

function setup_postgres {
  tar -xzvf "$INIT_PAYLOAD_PATH" -C / ./etc/postgresql.schema.sql
  mv /etc/postgresql.schema.sql /docker-entrypoint-initdb.d/migrations/99-schema.sql

  tar -xzvf "$INIT_PAYLOAD_PATH" -C / ./etc/postgresql-custom/pgsodium_root.key
  echo "include = '/etc/postgresql-custom/postgresql-platform-defaults.conf'" >> $PG_CONF

  # TODO (darora): walg enablement is temporarily performed here until changes from https://github.com/supabase/postgres/pull/639 get picked up
  # other things will still be needed in the future (auth_delay config)
  sed -i \
      -e "s|#include = '/etc/postgresql-custom/wal-g.conf'|include = '/etc/postgresql-custom/wal-g.conf'|g" \
      -e "s|shared_preload_libraries = '\(.*\)'|shared_preload_libraries = '\1, auth_delay'|" \
      -e "/# Automatically generated optimizations/i auth_delay.milliseconds = '3000'" \
      "${PG_CONF}"

  # Setup ssl certs
  mkdir -p /etc/ssl/certs/postgres
  tar -xzvf "$INIT_PAYLOAD_PATH" -C /etc/ssl/certs/postgres/ --strip-components 2 ./ssl/server.crt
  tar -xzvf "$INIT_PAYLOAD_PATH" -C /etc/ssl/certs/postgres/ --strip-components 2 ./ssl/ca.crt
  tar -xzvf "$INIT_PAYLOAD_PATH" -C /etc/ssl/private/ --strip-components 2 ./ssl/server.key
  # tar -xzvf "$INIT_PAYLOAD_PATH" -C /etc/ssl/certs/postgres/ ./ssl/server-intermediate.srl

  PGSSLROOTCERT=/etc/ssl/certs/postgres/ca.crt
  PGSSLCERT=/etc/ssl/certs/postgres/server.crt
  PGSSLKEY=/etc/ssl/private/server.key
  chown root:postgres $PGSSLROOTCERT $PGSSLKEY $PGSSLCERT
  chmod 640 $PGSSLROOTCERT $PGSSLKEY $PGSSLCERT

  # Change ssl back to on in postgres.conf
  sed -i -e "s|ssl = off|ssl = on|g" \
    -e "s|ssl_ca_file = ''|ssl_ca_file = '$PGSSLROOTCERT'|g" \
    -e "s|ssl_cert_file = ''|ssl_cert_file = '$PGSSLCERT'|g" \
    -e "s|ssl_key_file = ''|ssl_key_file = '$PGSSLKEY'|g" \
    $PG_CONF

  # TODO: define instance size and type for running optimizations
  # /opt/supabase-admin-api optimize db --destination-config-file-path /etc/postgresql-custom/generated-optimizations.conf
  # /opt/supabase-admin-api optimize pgbouncer --destination-config-file-path /etc/pgbouncer-custom/generated-optimizations.ini
}

function setup_credentials {
  # Load credentials from init json
  tar -xzvf "$INIT_PAYLOAD_PATH" -C / ./tmp/init.json
  export ANON_KEY=${ANON_KEY:-$(jq -r '.["anon_key"]' /tmp/init.json)}
  export SERVICE_ROLE_KEY=${SERVICE_ROLE_KEY:-$(jq -r '.["service_key"]' /tmp/init.json)}
  export ADMIN_API_KEY=${ADMIN_API_KEY:-$(jq -r '.["supabase_admin_key"]' /tmp/init.json)}
  export JWT_SECRET=${JWT_SECRET:-$(jq -r '.["jwt_secret"]' /tmp/init.json)}
}

function report_health {
  if [ -z "${REPORTING_TOKEN:-}" ]; then
    echo "Skipped health reporting: missing REPORTING_TOKEN"
    exit 0
  fi
  if [ -d "$ADMIN_API_CERT_DIR" ]; then
    retry 10 curl -sSkf "https://localhost:$ADMIN_API_PORT/health-reporter/send" -X POST -H "apikey: $ADMIN_API_KEY"
  else
    retry 10 curl -sSf "http://localhost:$ADMIN_API_PORT/health-reporter/send" -X POST -H "apikey: $ADMIN_API_KEY"
  fi
}

function start_supervisor {
  # Start health reporting 
  report_health &

  # Start supervisord
  /usr/bin/supervisord -c $SUPERVISOR_CONF
}

# Increase max number of open connections
ulimit -n 65536

# Update pgsodium root key
if [ "${PGSODIUM_ROOT_KEY:-}" ]; then
  echo "${PGSODIUM_ROOT_KEY}" > /etc/postgresql-custom/pgsodium_root.key
fi

# Update pgdata directory
if [ "${PGDATA_REAL:-}" ]; then
  mkdir -p "${PGDATA_REAL}"
  chown -R postgres:postgres "${PGDATA_REAL}"
fi

if [ "${PGDATA:-}" ]; then
  if [ "${PGDATA_REAL:-}" ]; then
    mkdir -p "$(dirname "${PGDATA}")"
    ln -s "${PGDATA}" "${PGDATA_REAL}"
  else
    mkdir -p "$PGDATA"
    chown postgres:postgres "$PGDATA"
  fi
  sed -i "s|data_directory = '.*'|data_directory = '$PGDATA'|g" $PG_CONF
fi

# Download and extract init payload from s3
export INIT_PAYLOAD_PATH=${INIT_PAYLOAD_PATH:-/tmp/payload.tar.gz}
export CONFIGURED_FLAG_PATH=${CONFIGURED_FLAG_PATH:-$PGDATA/../machine.configured}

if [ "${INIT_PAYLOAD_PRESIGNED_URL:-}" ]; then
  curl -sSL "$INIT_PAYLOAD_PRESIGNED_URL" -o "$INIT_PAYLOAD_PATH"
fi

# Process init payload
if [ -f "$INIT_PAYLOAD_PATH" ]; then
  setup_credentials
  setup_postgres
else
  echo "Skipped extracting init payload: $INIT_PAYLOAD_PATH does not exist"
fi

mkdir /var/log/services

SUPERVISOR_CONF=/etc/supervisor/supervisord.conf
find /etc/supervisor/ -type d -exec chmod 0770 {} +
find /etc/supervisor/ -type f -exec chmod 0660 {} +

# Start services in the background
if [ -z "${POSTGRES_ONLY:-}" ]; then
  sed -i "s|  #  - postgrest|    - postgrest|g" /etc/adminapi/adminapi.yaml
  sed -i "s|files = db-only/\*.conf|files = services/\*.conf db-only/\*.conf|g" $SUPERVISOR_CONF
  configure_services
else
  sed -i "s|    - postgrest|  #  - postgrest|g" /etc/adminapi/adminapi.yaml
  sed -i "s|files = services/\*.conf db-only/\*.conf|files = db-only/\*.conf|g" $SUPERVISOR_CONF
  /init/configure-adminapi.sh
fi


touch "$CONFIGURED_FLAG_PATH"
start_supervisor
