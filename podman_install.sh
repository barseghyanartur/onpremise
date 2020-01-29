#!/usr/bin/env bash
set -e

dc="podman-compose --no-ansi"
dcr="$dc run --rm"

# Thanks to https://unix.stackexchange.com/a/145654/108960
log_file="sentry_install_log-`date +'%Y-%m-%d_%H-%M-%S'`.txt"
exec &> >(tee -a "$log_file")

MIN_RAM=2400 # MB

SENTRY_CONFIG_PY='sentry/sentry.conf.py'
SENTRY_CONFIG_YML='sentry/config.yml'
SENTRY_EXTRA_REQUIREMENTS='sentry/requirements.txt'

DID_CLEAN_UP=0
# the cleanup function will be the exit point
cleanup () {
  if [ "$DID_CLEAN_UP" -eq 1 ]; then
    return 0;
  fi
  echo "Cleaning up..."
  $dc stop &> /dev/null
  DID_CLEAN_UP=1
}
trap cleanup ERR INT TERM

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

# Clean up old stuff and ensure nothing is working while we install/update
# This is for older versions of on-premise:
$dc -p onpremise down
# This is for newer versions
$dc down

echo ""
echo "Creating volumes for persistent storage..."
echo "Created $(podman volume create --name=sentry-data)."
echo "Created $(podman volume create --name=sentry-postgres)."
echo "Created $(podman volume create --name=sentry-redis)."
echo "Created $(podman volume create --name=sentry-zookeeper)."
echo "Created $(podman volume create --name=sentry-kafka)."
echo "Created $(podman volume create --name=sentry-clickhouse)."
echo "Created $(podman volume create --name=sentry-symbolicator)."

echo ""
ensure_file_from_example $SENTRY_CONFIG_PY
ensure_file_from_example $SENTRY_CONFIG_YML
ensure_file_from_example $SENTRY_EXTRA_REQUIREMENTS

echo ""
echo "Generating secret key..."
# This is to escape the secret key to be used in sed below
# Note the need to set LC_ALL=C due to BSD tr and sed always trying to decode
# whatever is passed to them. Kudos to https://stackoverflow.com/a/23584470/90297
SECRET_KEY=$(export LC_ALL=C; head /dev/urandom | tr -dc "a-z0-9@#%^&*(-_=+)" | head -c 50 | sed -e 's/[\/&]/\\&/g')
sed -i -e 's/^system.secret-key:.*$/system.secret-key: '"'$SECRET_KEY'"'/' $SENTRY_CONFIG_YML
echo "Secret key written to $SENTRY_CONFIG_YML"

echo ""
echo "Building and tagging Docker images..."
echo ""
# Build the sentry onpremise image first as it is needed for the cron image
$dc pull
podman pull ${SENTRY_IMAGE:-getsentry/sentry:latest}
$dc build --pull-always
echo ""
echo "Docker images built."

echo "Bootstrapping Snuba..."
# `bootstrap` is for fresh installs, and `migrate` is for existing installs
# Running them both for both cases is harmless so we blindly run them
$dcr snuba-api bootstrap --force
$dcr snuba-api migrate
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
    podman volume create --name sentry-postgres
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

cleanup

echo ""
echo "----------------"
echo "You're all done! Run the following command to get Sentry running:"
echo ""
echo "  podman-compose up -d"
echo ""
