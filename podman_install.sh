#!/usr/bin/env bash
set -e

dc="podman-compose -f docker-compose.yml --no-ansi"
dcr="$dc run --rm"

# Thanks to https://unix.stackexchange.com/a/145654/108960
log_file="sentry_install_log-`date +'%Y-%m-%d_%H-%M-%S'`.txt"
exec &> >(tee -a "$log_file")
# https://github.com/containers/podman/issues/6816#issuecomment-652739674
setfacl -Rb ~/.local/share/containers

MIN_RAM=2400 # MB

SENTRY_CONFIG_PY='sentry/sentry.conf.py'
SENTRY_CONFIG_YML='sentry/config.yml'
SYMBOLICATOR_CONFIG_YML='symbolicator/config.yml'
RELAY_CONFIG_YML='relay/config.yml'
RELAY_CREDENTIALS_JSON='relay/credentials.json'
SENTRY_EXTRA_REQUIREMENTS='sentry/requirements.txt'

# Courtesy of https://stackoverflow.com/a/2183063/90297
trap_with_arg() {
    func="$1" ; shift
    for sig ; do
        trap "$func $sig" "$sig"
    done
}

DID_CLEAN_UP=0
# the cleanup function will be the exit point
cleanup () {
  if [ "$DID_CLEAN_UP" -eq 1 ]; then
    return 0;
  fi
  DID_CLEAN_UP=1

  if [ "$1" != "EXIT" ]; then
    echo "An error occurred, caught SIG$1";
    echo "Cleaning up..."
  fi

  $dc stop &> /dev/null
}
trap_with_arg cleanup ERR INT TERM EXIT


echo "Checking minimum requirements..."

RAM_AVAILABLE_IN_DOCKER=$(podman run --rm busybox free -m 2>/dev/null | awk '/Mem/ {print $2}');



# Compare dot-separated strings - function below is inspired by https://stackoverflow.com/a/37939589/808368
function ver () { echo "$@" | awk -F. '{ printf("%d%03d%03d", $1,$2,$3); }'; }

# Thanks to https://stackoverflow.com/a/25123013/90297 for the quick `sed` pattern
function ensure_file_from_example {
  if [ -f "$1" ]; then
    echo "$1 already exists, skipped creation."
  else
    echo "Creating $1..."
    cp -n $(echo "$1" | sed 's/\.[^.]*$/.example&/') "$1"
  fi
}











if [ "$RAM_AVAILABLE_IN_DOCKER" -lt "$MIN_RAM" ]; then
    echo "FAIL: Expected minimum RAM available to Docker to be $MIN_RAM MB but found $RAM_AVAILABLE_IN_DOCKER MB"
    exit -1
fi

#SSE4.2 required by Clickhouse (https://clickhouse.yandex/docs/en/operations/requirements/)
# On KVM, cpuinfo could falsely not report SSE 4.2 support, so skip the check. https://github.com/ClickHouse/ClickHouse/issues/20#issuecomment-226849297
IS_KVM=$(podman run --rm busybox grep -c 'Common KVM processor' /proc/cpuinfo || :)
if (($IS_KVM == 0)); then
  SUPPORTS_SSE42=$(podman run --rm busybox grep -c sse4_2 /proc/cpuinfo || :)
  if (($SUPPORTS_SSE42 == 0)); then
    echo "FAIL: The CPU your machine is running on does not support the SSE 4.2 instruction set, which is required for one of the services Sentry uses (Clickhouse). See https://git.io/JvLDt for more info."
    exit 1
  fi
fi

# Clean up old stuff and ensure nothing is working while we install/update
# This is for older versions of on-premise:
$dc -p onpremise down  # Args are not (yet) supported by podman-compose
# This is for newer versions
$dc down  # Args are not (yet) supported by podman-compose

echo ""
echo "Creating volumes for persistent storage..."
echo "Created $(podman volume create sentry-data)."
echo "Created $(podman volume create sentry-postgres)."
echo "Created $(podman volume create sentry-redis)."
echo "Created $(podman volume create sentry-zookeeper)."
echo "Created $(podman volume create sentry-kafka)."
echo "Created $(podman volume create sentry-clickhouse)."
echo "Created $(podman volume create sentry-symbolicator)."

echo ""
ensure_file_from_example $SENTRY_CONFIG_PY
ensure_file_from_example $SENTRY_CONFIG_YML
ensure_file_from_example $SENTRY_EXTRA_REQUIREMENTS
ensure_file_from_example $SYMBOLICATOR_CONFIG_YML
ensure_file_from_example $RELAY_CONFIG_YML

if grep -xq "system.secret-key: '!!changeme!!'" $SENTRY_CONFIG_YML ; then
    echo ""
    echo "Generating secret key..."
    # This is to escape the secret key to be used in sed below
    # Note the need to set LC_ALL=C due to BSD tr and sed always trying to decode
    # whatever is passed to them. Kudos to https://stackoverflow.com/a/23584470/90297
    SECRET_KEY=$(export LC_ALL=C; head /dev/urandom | tr -dc "a-z0-9@#%^&*(-_=+)" | head -c 50 | sed -e 's/[\/&]/\\&/g')
    sed -i -e 's/^system.secret-key:.*$/system.secret-key: '"'$SECRET_KEY'"'/' $SENTRY_CONFIG_YML
    echo "Secret key written to $SENTRY_CONFIG_YML"
fi

replace_tsdb() {
    if (
        [ -f "$SENTRY_CONFIG_PY" ] &&
        ! grep -xq 'SENTRY_TSDB = "sentry.tsdb.redissnuba.RedisSnubaTSDB"' "$SENTRY_CONFIG_PY"
    ); then
        tsdb_settings="SENTRY_TSDB = \"sentry.tsdb.redissnuba.RedisSnubaTSDB\"

# Automatic switchover 90 days after $(date). Can be removed afterwards.
SENTRY_TSDB_OPTIONS = {\"switchover_timestamp\": $(date +%s) + (90 * 24 * 3600)}"

        if grep -q 'SENTRY_TSDB_OPTIONS = ' "$SENTRY_CONFIG_PY"; then
            echo "Not attempting automatic TSDB migration due to presence of SENTRY_TSDB_OPTIONS"
        else
            echo "Attempting to automatically migrate to new TSDB"
            # Escape newlines for sed
            tsdb_settings="${tsdb_settings//$'\n'/\\n}"
            cp "$SENTRY_CONFIG_PY" "$SENTRY_CONFIG_PY.bak"
            sed -i -e "s/^SENTRY_TSDB = .*$/${tsdb_settings}/g" "$SENTRY_CONFIG_PY" || true

            if grep -xq 'SENTRY_TSDB = "sentry.tsdb.redissnuba.RedisSnubaTSDB"' "$SENTRY_CONFIG_PY"; then
                echo "Migrated TSDB to Snuba. Old configuration file backed up to $SENTRY_CONFIG_PY.bak"
                return
            fi

            echo "Failed to automatically migrate TSDB. Reverting..."
            mv "$SENTRY_CONFIG_PY.bak" "$SENTRY_CONFIG_PY"
            echo "$SENTRY_CONFIG_PY restored from backup."
        fi

        echo "WARN: Your Sentry configuration uses a legacy data store for time-series data. Remove the options SENTRY_TSDB and SENTRY_TSDB_OPTIONS from $SENTRY_CONFIG_PY and add:"
        echo ""
        echo "$tsdb_settings"
        echo ""
        echo "For more information please refer to https://github.com/getsentry/onpremise/pull/430"
    fi
}

replace_tsdb

echo ""
echo "Fetching and updating Docker images..."
echo ""
# We tag locally built images with an '-onpremise-local' suffix. docker-compose pull tries to pull these too and
# shows a 404 error on the console which is confusing and unnecessary. To overcome this, we add the stderr>stdout
# redirection below and pass it through grep, ignoring all lines having this '-onpremise-local' suffix.
$dc pull 2>&1 | grep -v -- -onpremise-local || true

if [ -z "$SENTRY_IMAGE" ]; then
  podman pull getsentry/sentry:${SENTRY_VERSION:-latest}
else
  # We may not have the set image on the repo (local images) so allow fails
  podman pull $SENTRY_IMAGE || true;
fi

echo ""
echo "Building and tagging Docker images..."
echo ""
# Build the sentry onpremise image first as it is needed for the cron image
# $dc build web  # We need to build all services
$dc build --pull-always
echo ""
echo "Docker images built."

ZOOKEEPER_SNAPSHOT_FOLDER_EXISTS=$($dcr zookeeper bash -c 'ls 2>/dev/null -Ubad1 -- /var/lib/zookeeper/data/version-2 | wc -l | tr -d '[:space:]'')
if [ "$ZOOKEEPER_SNAPSHOT_FOLDER_EXISTS" -eq "1" ]; then
  ZOOKEEPER_LOG_FILE_COUNT=$($dcr zookeeper bash -c 'ls 2>/dev/null -Ubad1 -- /var/lib/zookeeper/log/version-2/* | wc -l | tr -d '[:space:]'')
  ZOOKEEPER_SNAPSHOT_FILE_COUNT=$($dcr zookeeper bash -c 'ls 2>/dev/null -Ubad1 -- /var/lib/zookeeper/data/version-2/* | wc -l | tr -d '[:space:]'')
  # This is a workaround for a ZK upgrade bug: https://issues.apache.org/jira/browse/ZOOKEEPER-3056
  if [ "$ZOOKEEPER_LOG_FILE_COUNT" -gt "0" ] && [ "$ZOOKEEPER_SNAPSHOT_FILE_COUNT" -eq "0" ]; then
    $dcr -v $(pwd)/zookeeper:/temp zookeeper bash -c 'cp /temp/snapshot.0 /var/lib/zookeeper/data/version-2/snapshot.0'
    $dc run -d -e ZOOKEEPER_SNAPSHOT_TRUST_EMPTY=true zookeeper
  fi
fi

echo "Bootstrapping and migrating Snuba..."
$dcr snuba-api bootstrap --force
echo ""

# Very naively check whether there's an existing sentry-postgres volume and the PG version in it
if [[ $(podman volume ls -q --filter name=sentry-postgres) && $(podman run --rm -v sentry-postgres:/db busybox cat /db/PG_VERSION 2>/dev/null) == "9.5" ]]; then
    podman volume rm sentry-postgres-new || true
    # If this is Postgres 9.5 data, start upgrading it to 9.6 in a new volume
    podman run --rm \
    -v sentry-postgres:/var/lib/postgresql/9.5/data \
    -v sentry-postgres-new:/var/lib/postgresql/9.6/data \
    tianon/postgres-upgrade:9.5-to-9.6

    # Get rid of the old volume as we'll rename the new one to that
    podman volume rm sentry-postgres
    podman volume create sentry-postgres
    # There's no rename volume in Docker so copy the contents from old to new name
    # Also append the `host all all all trust` line as `tianon/postgres-upgrade:9.5-to-9.6`
    # doesn't do that automatically.
    podman run --rm -v sentry-postgres-new:/from -v sentry-postgres:/to alpine ash -c \
     "cd /from ; cp -av . /to ; echo 'host all all all trust' >> /to/pg_hba.conf"
    # Finally, remove the new old volume as we are all in sentry-postgres now
    podman volume rm sentry-postgres-new
fi

echo ""
echo "Setting up database..."
if [ $CI ]; then
  $dcr web upgrade --noinput
  echo ""
  echo "Did not prompt for user creation due to non-interactive shell."
  echo "Run the following command to create one yourself (recommended):"
  echo ""
  echo "  podman-compose run --rm web createuser"
  echo ""
else
  $dcr web upgrade
fi


SENTRY_DATA_NEEDS_MIGRATION=$(podman run --rm -v sentry-data:/data alpine ash -c "[ ! -d '/data/files' ] && ls -A1x /data | wc -l || true")
if [ "$SENTRY_DATA_NEEDS_MIGRATION" ]; then
  echo "Migrating file storage..."
  # Use the web (Sentry) image so the file owners are kept as sentry:sentry
  # The `\"` escape pattern is to make this compatible w/ Git Bash on Windows. See #329.
  $dcr --entrypoint \"/bin/bash\" web -c \
    "mkdir -p /tmp/files; mv /data/* /tmp/files/; mv /tmp/files /data/files; chown -R sentry:sentry /data"
fi

if [ ! -f "$RELAY_CREDENTIALS_JSON" ]; then
  echo ""
  echo "Generating Relay credentials..."

  # We need the ugly hack below as `relay generate credentials` tries to read the config and the credentials
  # even with the `--stdout` and `--overwrite` flags and then errors out when the credentials file exists but
  # not valid JSON. We hit this case as we redirect output to the same config folder, creating an empty
  # credentials file before relay runs.
  $dcr --no-deps -v $(pwd)/$RELAY_CONFIG_YML:/tmp/config.yml relay --config /tmp credentials generate --stdout > "$RELAY_CREDENTIALS_JSON"
  echo "Relay credentials written to $RELAY_CREDENTIALS_JSON"
fi


echo ""
echo "----------------"
echo "You're all done! Run the following command to get Sentry running:"
echo ""
echo "  podman-compose up -d"
echo ""
