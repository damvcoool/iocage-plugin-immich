```sh
#!/bin/sh

set -eu

# Immich Post-Install Script
# Sets up PostgreSQL, Valkey, and Immich services on FreeBSD 15.

: ${immich_data="/var/db/immich"}
: ${immich_config="/usr/local/etc/immich"}
: ${immich_env_file="/usr/local/etc/immich.env"}
: ${immich_upload="/var/db/immich/upload"}
: ${immich_db_name="immich"}
: ${immich_db_user="immich"}

PGDATA="/var/db/postgres/data18"
PGCONF="${PGDATA}/postgresql.conf"

echo "Starting Immich post-installation setup..."

##############################################################################
# 0. Generate or reuse Immich database password
##############################################################################

# Reuse an existing password so that rerunning this script does not change
# the PostgreSQL password without also changing the database user.
immich_db_pass=""

if [ -f "${immich_env_file}" ]; then
    immich_db_pass="$(awk -F= '
        /^DB_PASSWORD=/ {
            sub(/^DB_PASSWORD=/, "", $0)
            print
            exit
        }
    ' "${immich_env_file}")"
fi

if [ -z "${immich_db_pass}" ]; then
    if ! command -v openssl >/dev/null 2>&1; then
        echo "ERROR: openssl is required to generate the Immich database password." >&2
        exit 1
    fi

    immich_db_pass="$(openssl rand -hex 16)"
fi

if [ -z "${immich_db_pass}" ]; then
    echo "ERROR: Unable to generate Immich database password." >&2
    exit 1
fi

##############################################################################
# 1. Enable Valkey (Redis-compatible cache)
##############################################################################

sysrc valkey_enable=YES

if service valkey start >/dev/null 2>&1; then
    echo "Valkey started."
else
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

# Initialize PostgreSQL database if it has not already been initialized.
if [ ! -d "${PGDATA}" ]; then
    echo "Initializing PostgreSQL database..."
    service postgresql initdb
fi

if [ ! -f "${PGCONF}" ]; then
    echo "ERROR: PostgreSQL configuration file not found: ${PGCONF}" >&2
    exit 1
fi

##############################################################################
# Configure PostgreSQL shared_preload_libraries for vchord
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

        # Match active or commented shared_preload_libraries settings:
        #
        #   shared_preload_libraries = ...
        #   #shared_preload_libraries = ...
        #   # shared_preload_libraries = ...
        #
        if (line ~ /^[[:space:]]*#?[[:space:]]*shared_preload_libraries[[:space:]]*=/) {

            found = 1

            # Remove a leading comment marker so the setting becomes active.
            active = line
            sub(/^[[:space:]]*#[[:space:]]*/, "", active)

            # Extract the value after "=".
            value = active
            sub(/^[[:space:]]*shared_preload_libraries[[:space:]]*=[[:space:]]*/, "", value)

            # Preserve an inline comment such as:
            #   # (change requires restart)
            comment = ""

            if (value ~ /[[:space:]]+#/) {
                comment_pos = index(value, "#")
                comment = substr(value, comment_pos)
                value = substr(value, 1, comment_pos - 1)
            }

            # Trim whitespace.
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)

            # Remove surrounding quotes.
            if (value ~ /^'\''.*'\''$/) {
                sub(/^'\''/, "", value)
                sub(/'\''$/, "", value)
            } else if (value ~ /^".*"$/) {
                sub(/^"/, "", value)
                sub(/"$/, "", value)
            }

            # Empty setting.
            if (value == "") {
                print "shared_preload_libraries = '\''vchord.so'\''" \
                      (comment != "" ? " " comment : "")
                next
            }

            # Check whether vchord or vchord.so is already present.
            n = split(value, libs, ",")
            has_vchord = 0

            for (i = 1; i <= n; i++) {
                lib = libs[i]

                gsub(/^[[:space:]]+|[[:space:]]+$/, "", lib)
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
        # Add the setting when it does not exist at all.
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
# Wait for PostgreSQL to become ready
##############################################################################

echo "Waiting for PostgreSQL to become ready..."

pg_ready=0

i=1
while [ "${i}" -le 30 ]; do
    if su -m postgres -c "/usr/local/bin/pg_isready -q" >/dev/null 2>&1; then
        pg_ready=1
        break
    fi

    sleep 1
    i=$((i + 1))
done

if [ "${pg_ready}" -ne 1 ]; then
    echo "ERROR: PostgreSQL did not become ready." >&2
    exit 1
fi

echo "PostgreSQL is ready."

##############################################################################
# 3. Ensure Immich system user exists
##############################################################################

if ! pw user show immich >/dev/null 2>&1; then
    echo "Creating immich system user..."

    pw user add immich \
        -s /bin/nologin \
        -no-password \
        -d /nonexistent \
        -h -
fi

##############################################################################
# 4. Create database and extensions
##############################################################################

echo "Setting up database and extensions..."

# Create/update Immich database user.
#
# Using DO blocks makes the operation idempotent.
su -m postgres -c "psql -v ON_ERROR_STOP=1 -d postgres -c \"
DO \\\$\\$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_roles WHERE rolname = '${immich_db_user}'
    ) THEN
        CREATE ROLE ${immich_db_user} LOGIN SUPERUSER PASSWORD '${immich_db_pass}';
    ELSE
        ALTER ROLE ${immich_db_user} LOGIN PASSWORD '${immich_db_pass}';
    END IF;
END
\\\$\\$;
\"" >/dev/null

# Create the database if necessary.
if ! su -m postgres -c \
    "psql -d postgres -tAc \"SELECT 1 FROM pg_database WHERE datname='${immich_db_name}'\"" \
    2>/dev/null | grep -q '^1$'
then
    su -m postgres -c \
        "createdb -O ${immich_db_user} ${immich_db_name}"
else
    # Ensure the existing database has the correct owner.
    su -m postgres -c \
        "psql -d postgres -v ON_ERROR_STOP=1 -c \
        \"ALTER DATABASE ${immich_db_name} OWNER TO ${immich_db_user};\"" \
        >/dev/null
fi

# Ensure required extensions exist.
su -m postgres -c \
    "psql -d ${immich_db_name} -v ON_ERROR_STOP=1 -c \
    \"CREATE EXTENSION IF NOT EXISTS vector;\"" \
    >/dev/null

su -m postgres -c \
    "psql -d ${immich_db_name} -v ON_ERROR_STOP=1 -c \
    \"CREATE EXTENSION IF NOT EXISTS vchord CASCADE;\"" \
    >/dev/null

su -m postgres -c \
    "psql -d ${immich_db_name} -v ON_ERROR_STOP=1 -c \
    \"CREATE EXTENSION IF NOT EXISTS cube;\"" \
    >/dev/null

su -m postgres -c \
    "psql -d ${immich_db_name} -v ON_ERROR_STOP=1 -c \
    \"CREATE EXTENSION IF NOT EXISTS earthdistance;\"" \
    >/dev/null

su -m postgres -c \
    "psql -d ${immich_db_name} -v ON_ERROR_STOP=1 -c \
    \"CREATE EXTENSION IF NOT EXISTS pg_trgm;\"" \
    >/dev/null

echo "Database setup complete."

##############################################################################
# 5. Create Immich configuration
##############################################################################

mkdir -p "${immich_config}"
mkdir -p "${immich_upload}"

cat > "${immich_env_file}" <<EOF
# Immich Configuration File
# This file is written to the default rc.d service location used by Immich

# Database settings - using localhost for TrueNAS/iocage
DB_HOSTNAME=localhost
DB_PORT=5432
DB_USERNAME=${immich_db_user}
DB_PASSWORD=${immich_db_pass}
DB_DATABASE_NAME=${immich_db_name}

# Redis settings - using localhost for TrueNAS/iocage
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

# The environment file contains a database password and therefore should not
# be world-readable.
chmod 600 "${immich_env_file}"

# Keep the old config directory layout for compatibility.
ln -sf "${immich_env_file}" "${immich_config}/immich.env"

echo "Config file written to: ${immich_env_file}"

##############################################################################
# 6. Configure Immich service
##############################################################################

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

##############################################################################
# 7. Set ownership
##############################################################################

chown -R immich:immich "${immich_config}"
chown -R immich:immich "${immich_upload}"

##############################################################################
# 8. Start Immich
##############################################################################

if service immich_server start >/dev/null 2>&1; then
    echo "Immich server started on port 2283."
else
    echo "WARNING: Unable to start Immich server." >&2
fi

echo "Immich setup complete. Web interface available at port 2283."
```
