#!/bin/sh

set -eu

# Immich Post-Install Script
# Sets up PostgreSQL, Valkey, and Immich services

: ${immich_data="/var/db/immich"}
: ${immich_config="/usr/local/etc/immich"}
: ${immich_env_file="/usr/local/etc/immich.env"}
: ${immich_upload="/var/db/immich/upload"}
: ${immich_db_name="immich"}
: ${immich_db_user="immich"}
: ${immich_db_pass="$(pw -g cryptsecret 2>/dev/null | head -c 32)"}

PGDATA="/var/db/postgres/data18"
PGCONF="${PGDATA}/postgresql.conf"

echo "Starting Immich post-installation setup..."

##############################################################################
# 1. Enable Valkey (Redis-compatible cache)
##############################################################################

sysrc valkey_enable=YES

if service valkey start >/dev/null 2>&1; then
    echo "Valkey started."
else
    # It may already be running.
    if service valkey status >/dev/null 2>&1; then
        echo "Valkey is already running."
    else
        echo "WARNING: Unable to start Valkey." >&2
    fi
fi

##############################################################################
# 2. Enable and configure PostgreSQL
##############################################################################

sysrc postgresql_enable=YES
sysrc postgresql_data="${PGDATA}"

# Initialize PostgreSQL database if not already done.
#
# The FreeBSD PostgreSQL rc.d script supports:
#
#   service postgresql initdb
#
# and runs initdb as the postgres user using postgresql_data.
if [ ! -d "${PGDATA}" ]; then
    echo "Initializing PostgreSQL database..."
    service postgresql initdb
fi

if [ ! -f "${PGCONF}" ]; then
    echo "ERROR: PostgreSQL configuration file not found: ${PGCONF}" >&2
    exit 1
fi

##############################################################################
# Configure shared_preload_libraries for vchord
##############################################################################

ensure_vchord_preload()
{
    conf="$1"
    tmp="${conf}.tmp.$$"

    awk '
    BEGIN {
        found = 0
    }

    {
        line = $0

        # Match:
        #
        #   shared_preload_libraries = ...
        #   #shared_preload_libraries = ...
        #   # shared_preload_libraries = ...
        #
        # but not similarly named settings.
        if (line ~ /^[[:space:]]*#?[[:space:]]*shared_preload_libraries[[:space:]]*=/) {

            found = 1

            # Remove leading comment marker and whitespace so that
            # the resulting setting is always active.
            active = line
            sub(/^[[:space:]]*#[[:space:]]*/, "", active)

            # Extract everything after "=".
            value = active
            sub(/^[[:space:]]*shared_preload_libraries[[:space:]]*=[[:space:]]*/, "", value)

            # Preserve PostgreSQL inline comments, e.g.
            #
            #   # (change requires restart)
            #
            # while keeping them out of the library value.
            comment = ""
            comment_pos = 0

            # The standard PostgreSQL generated line has its comment
            # after the library value.
            if (value ~ /[[:space:]]+#/) {
                comment_pos = index(value, "#")
                comment = substr(value, comment_pos)
                value = substr(value, 1, comment_pos - 1)
            }

            # Trim surrounding whitespace.
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)

            # Remove surrounding single or double quotes.
            if (value ~ /^'\''.*'\''$/) {
                sub(/^'\''/, "", value)
                sub(/'\''$/, "", value)
            } else if (value ~ /^".*"$/) {
                sub(/^"/, "", value)
                sub(/"$/, "", value)
            }

            # Empty setting:
            #
            #   shared_preload_libraries = ''
            #
            # becomes:
            #
            #   shared_preload_libraries = '\''vchord.so'\''
            if (value == "") {
                print "shared_preload_libraries = '\''vchord.so'\''" \
                      (comment != "" ? " " comment : "")
                next
            }

            # Check whether vchord.so is already present.
            # Accept both vchord and vchord.so.
            n = split(value, libs, ",")

            has_vchord = 0

            for (i = 1; i <= n; i++) {
                lib = libs[i]

                # Trim whitespace.
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", lib)

                # Remove optional quotes.
                gsub(/^'\''|'\''$/, "", lib)
                gsub(/^"|"$/, "", lib)

                if (lib == "vchord" || lib == "vchord.so") {
                    has_vchord = 1
                }
            }

            if (!has_vchord) {
                value = value ", vchord.so"
            }

            print "shared_preload_libraries = '\''" value "'\''" \
                  (comment != "" ? " " comment : "")

            next
        }

        print
    }

    END {
        # The parameter did not exist at all.
        if (!found) {
            print "shared_preload_libraries = '\''vchord.so'\''"
        }
    }
    ' "${conf}" > "${tmp}"

    if ! mv "${tmp}" "${conf}"; then
        rm -f "${tmp}"
        echo "ERROR: Could not update ${conf}" >&2
        return 1
    fi
}

echo "Configuring PostgreSQL shared_preload_libraries..."
ensure_vchord_preload "${PGCONF}"

##############################################################################
# Restart PostgreSQL so the preload configuration is applied.
##############################################################################

service postgresql stop >/dev/null 2>&1 || true

if service postgresql start >/dev/null 2>&1; then
    echo "PostgreSQL started with vchord preload configuration."
else
    echo "ERROR: PostgreSQL failed to start." >&2
    exit 1
fi

##############################################################################
# Wait for PostgreSQL to become ready.
##############################################################################

echo "Waiting for PostgreSQL to become ready..."

pg_ready=0

for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if su -m postgres -c "/usr/local/bin/pg_isready -q" >/dev/null 2>&1; then
        pg_ready=1
        break
    fi

    sleep 1
done

if [ "${pg_ready}" -ne 1 ]; then
    echo "ERROR: PostgreSQL did not become ready." >&2
    exit 1
fi

echo "PostgreSQL is ready."

##############################################################################
# 3. Create database and extensions
##############################################################################

echo "Setting up database and extensions..."

su -m postgres -c \
    "psql -c \"CREATE USER ${immich_db_user} WITH SUPERUSER PASSWORD '${immich_db_pass}';\"" \
    2>/dev/null || true

su -m postgres -c \
    "psql -c \"CREATE DATABASE ${immich_db_name} OWNER ${immich_db_user};\"" \
    2>/dev/null || true

su -m postgres -c \
    "psql -d ${immich_db_name} -c \"CREATE EXTENSION IF NOT EXISTS vector;\"" \
    2>/dev/null || true

su -m postgres -c \
    "psql -d ${immich_db_name} -c \"CREATE EXTENSION IF NOT EXISTS vchord CASCADE;\"" \
    2>/dev/null || true

su -m postgres -c \
    "psql -d ${immich_db_name} -c \"CREATE EXTENSION IF NOT EXISTS cube;\"" \
    2>/dev/null || true

su -m postgres -c \
    "psql -d ${immich_db_name} -c \"CREATE EXTENSION IF NOT EXISTS earthdistance;\"" \
    2>/dev/null || true

su -m postgres -c \
    "psql -d ${immich_db_name} -c \"CREATE EXTENSION IF NOT EXISTS pg_trgm;\"" \
    2>/dev/null || true

echo "Database setup complete."

##############################################################################
# 4. Create Immich user and configuration
##############################################################################

# Ensure the immich user exists before chown operations.
if ! pw user show immich >/dev/null 2>&1; then
    echo "Creating immich system user..."
    pw user add immich \
        -s /bin/nologin \
        -no-password \
        -d /nonexistent \
        -h -
fi

mkdir -p "${immich_config}"
mkdir -p "${immich_upload}"

cat > "${immich_env_file}" <<EOF
# Immich Configuration File
# This file is written to the default rc.d service location used by Immich

# Database settings - using localhost for TrueNAS/iocage (not Docker)
DB_HOSTNAME=localhost
DB_PORT=5432
DB_USERNAME=${immich_db_user}
DB_PASSWORD=${immich_db_pass}
DB_DATABASE_NAME=${immich_db_name}

# Redis settings - using localhost for TrueNAS/iocage (not Docker)
REDIS_HOSTNAME=localhost
REDIS_PORT=6379

# Upload location
UPLOAD_LOCATION=${immich_upload}

# Logging
IMMICH_LOG_LEVEL=log
IMMICH_LOG_FORMAT=console

# Ports
IMMICH_HOST=0.0.0.0
IMMICH_PORT=2283
EOF

# Keep the old config directory layout for compatibility.
ln -sf "${immich_env_file}" "${immich_config}/immich.env"

echo "Config file written to: ${immich_env_file}"

##############################################################################
# 5. Enable Immich server service
##############################################################################

# The rc script defines immich_server_env_file but never applies it, so set the
# actual runtime environment explicitly to avoid falling back to the Docker
# default hostname "database".
sysrc immich_server_env_file="${immich_env_file}"

sysrc immich_server_env="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        HOME=${immich_data} \
        NODE_ENV=production \
        IMMICH_BUILD_DATA=/usr/local/www/immich/build-data \
        IMMICH_MEDIA_LOCATION=${immich_upload} \
        IMMICH_PORT=2283 \
        DB_HOSTNAME=localhost \
        DB_PORT=5432 \
        DB_USERNAME=${immich_db_user} \
        DB_PASSWORD=${immich_db_pass} \
        DB_DATABASE_NAME=${immich_db_name} \
        REDIS_HOSTNAME=localhost \
        REDIS_PORT=6379"

sysrc immich_server_enable=YES

# Set correct ownership for the service.
chown -R immich:immich "${immich_config}"
chown -R immich:immich "${immich_upload}"

##############################################################################
# 6. Start Immich
##############################################################################

if service immich_server start >/dev/null 2>&1; then
    echo "Immich server started on port 2283."
else
    echo "WARNING: Unable to start Immich server." >&2
fi

echo "Immich setup complete. Web interface available at port 2283."