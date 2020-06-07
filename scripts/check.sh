#!/usr/bin/env bash

set -xe

export PGPASSWORD=${POSTGRES_PASSWORD:-postgres}

IsInRecovery=$(psql -U postgres -qtAX -c "SELECT pg_is_in_recovery();")

if [[ ${IsInRecovery} == 'f' ]]; then
  # current node is in master mode
  exit 0
elif [[ ${IsInRecovery} == 't' ]]; then
  # current node is in standby mode
  state=$(psql -h "$PRIMARY_HOST" -U postgres -qtAX -c "select state from pg_stat_replication where pg_stat_replication.application_name='$HOSTNAME';")
  if [[ ${state} == 'streaming' ]]; then
    exit 0
  fi
fi

exit 1
