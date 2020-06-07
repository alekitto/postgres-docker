#!/usr/bin/env bash

# Copyright The KubeDB Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -xeou pipefail

echo "Running as Replica"

# set password ENV
export PGPASSWORD=${POSTGRES_PASSWORD:-postgres}

export ARCHIVE=${ARCHIVE:-}

gracefully_shutdown_host() {
  echo "Gracefully shutting down database"

  # start postgres server in background
  postgres >/dev/null 2>&1 &

  # Waiting for running Postgres
  while true; do
    echo "Attempting pg_isready on localhost"
    pg_isready --timeout=2 &>/dev/null && break
    sleep 2
  done

  # stop postgres server
  pg_ctl -D "$PGDATA" stop >/dev/null 2>&1
}

take_pg_basebackup() {
  mkdir -p "$PGDATA"
  rm -rf "$PGDATA"/*
  chmod 0700 "$PGDATA"

  echo "Taking base backup."
  pg_basebackup -X fetch --no-password --pgdata "$PGDATA" --username=postgres --host="$PRIMARY_HOST"
}

setup_postgresql_config() {
  # setup recovery.conf
  cp /scripts/replica/recovery.conf /tmp
  echo "recovery_target_timeline = 'latest'" >>/tmp/recovery.conf
  echo "archive_cleanup_command = 'pg_archivecleanup $PGWAL %r'" >>/tmp/recovery.conf

  # primary_conninfo is used for streaming replication
  echo "primary_conninfo = 'application_name=$HOSTNAME host=$PRIMARY_HOST'" >>/tmp/recovery.conf
  mv /tmp/recovery.conf "$PGDATA/recovery.conf"

  # setup postgresql.conf
  cp /scripts/primary/postgresql.conf /tmp
  echo "wal_level = replica" >>/tmp/postgresql.conf
  echo "max_wal_senders = 96" >>/tmp/postgresql.conf
  echo "wal_keep_segments = 32" >>/tmp/postgresql.conf
  echo "wal_log_hints = on" >>/tmp/postgresql.conf

  if [ "$STANDBY" == "hot" ]; then
    echo "hot_standby = on" >>/tmp/postgresql.conf
  fi

  if [ "$STREAMING" == "synchronous" ]; then
    # setup synchronous streaming replication
    echo "synchronous_commit = remote_write" >>/tmp/postgresql.conf
    echo "synchronous_standby_names = '*'" >>/tmp/postgresql.conf
  fi

  mv /tmp/postgresql.conf "$PGDATA/postgresql.conf"
}

# Waiting for running Postgres
while true; do
  echo "Attempting pg_isready on primary"
  pg_isready --host="$PRIMARY_HOST" --timeout=2 &>/dev/null && break
  # check if current pod became leader itself
  if [[ -e "/tmp/pg-failover-trigger" ]]; then
    echo "Postgres promotion trigger_file found. Running primary run script"
    exec /scripts/primary/run.sh
  fi
  sleep 2
done

while true; do
  echo "Attempting query on primary"
  psql -h "$PRIMARY_HOST" --no-password --username=postgres --command="select now();" &>/dev/null && break
  # check if current pod became leader itself
  if [[ -e "/tmp/pg-failover-trigger" ]]; then
    echo "Postgres promotion trigger_file found. Running primary run script"
    exec /scripts/primary/run.sh
  fi
  sleep 2
done

if [[ ! -e "$PGDATA/PG_VERSION" || ! -e "$PGDATA/global/pg_control" ]]; then
  take_pg_basebackup
else
  # Why pg_rewind? refs:
  # - Resolves conflict of different timelines. ref:
  # 1. https://www.postgresql.org/docs/9.6/app-pgrewind.html
  # 2. part(1 of 3) https://blog.2ndquadrant.com/introduction-to-pgrewind/
  # 3. part(2 of 3) https://blog.2ndquadrant.com/pgrewind-and-pg95/
  # 4. part(3 of 3) https://blog.2ndquadrant.com/back-to-the-future-part-3-pg_rewind-with-postgresql-9-6/

  # Why don't just pull all WAL file?
  # - Doesn't solve conflict between different timelines, (mostly, in failover scenario, where a standby node becomes primary)
  # So, after pulling wal files, it is required to run pg_rewind.

  # > pw_rewind. Possible error:
  # 1. target server must be shut down cleanly
  # 2. could not find previous WAL record at 0/30000F8
  # 3. could not find common ancestor of the source and target cluster's timelines
  # 4. target server needs to use either data checksums or "wal_log_hints = on"

  EXIT_CODE=0
  PG_REWIND_OUTPUT=$(pg_rewind --source-server="host=$PRIMARY_HOST user=postgres port=5432 dbname=postgres" --target-pgdata=$PGDATA) || EXIT_CODE=$?
  echo "${PG_REWIND_OUTPUT}"

  # Target database (localhost) must be shutdown cleanly to perform pg_rewind.
  # So, check and if necessary, re-stop the database gracefully.
  if [[ "$EXIT_CODE" != "0" ]] && [[ $(echo $PG_REWIND_OUTPUT | grep -c "target server must be shut down cleanly") -gt 0 ]]; then
    setup_postgresql_config
    gracefully_shutdown_host

    EXIT_CODE=0
    PG_REWIND_OUTPUT=$(pg_rewind --source-server="host=$PRIMARY_HOST user=postgres port=5432 dbname=postgres" --target-pgdata=$PGDATA) || EXIT_CODE=$?
    echo ${PG_REWIND_OUTPUT}
  fi

  if
    ([[ "$EXIT_CODE" != "0" ]] && [[ $(echo $PG_REWIND_OUTPUT | grep -c "could not find previous WAL record") -gt 0 ]]) ||
      # If the server diverged from primary and the diverged WAL doesn't exist anymore,
      # pg_rewind will throw an error similar to "could not find previous WAL record at 0/30000F8".
      # We have to manually fetch WALs starting from the missing point.
      # At this point, we will take pg_basebackup.
      # todo: for wal-g or other kind of wal-archiving, fetch missing WALs from archive storage (may be). Then, run pg_rewind again
    ([[ "$EXIT_CODE" != "0" ]] && [[ $(echo $PG_REWIND_OUTPUT | grep -c "could not find common ancestor") -gt 0 ]]) ||
      # Since 9.6, pg_rewind is very powerful to find common ancestor while running on non-promoted master.
      # ref: https://blog.2ndquadrant.com/back-to-the-future-part-3-pg_rewind-with-postgresql-9-6/
      # Yet, if the error shows up, taking pg_basebackup is a must.
    ([[ "$EXIT_CODE" != "0" ]] && [[ $(echo $PG_REWIND_OUTPUT | grep -c "server needs to use either data checksums") -gt 0 ]])
      # In case of upgrade from previous database version, where 'wal_log_hints' was not turned on, this error may occur.
      # But, will not occur again after adding 'wal_log_hints = on' on config file.
      # We could have skipped here and manually pull WAL files so that this node can redo wal files.
      # But, again, that will not resolve conflict between timelines.
      # So, take base_backup and continue
  then
    take_pg_basebackup

  elif [[ "$EXIT_CODE" != "0" ]]; then
    # In another scenario, pg_rewind is failing and the reason is not 'non-existing WAL' or 'no common ancestor'.
    # The workaround could be deleting $PGDATA directory and taking pg_basebackup again.
    # But, again the reason is not missing WAl. So, safely exit without processing further.
    echo "pg_rewind is failing and the reason is: $PG_REWIND_OUTPUT"
    exit 1
  fi
fi

setup_postgresql_config

exec postgres
