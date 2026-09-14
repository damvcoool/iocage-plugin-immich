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

echo "Starting Immich post-installation setup..."

##############################################################################
# 1. Enable Valkey (Redis-compatible cache)
##############################################################################
sysrc valkey_enable=YES

# Start Valkey
if $(service valkey start 2>/dev/null >/dev/null); then
    echo "Starting Valkey..."
fi

##############################################################################
# 2. Enable and configure PostgreSQL
##############################################################################
sysrc postgresql_enable=YES

# Initialize PostgreSQL database if not already done
if [ ! -d /var/db/postgres/data18 ]; then
    echo "Initializing PostgreSQL database..."
    su -m postgres -c 'pg_ctl init -D /var/db/postgres/data18 -A trust -U postgres -W ""'
fi

# Configure PostgreSQL to load vchord.so in shared_preload_libraries.
# This must happen before the server accepts any connections and before Immich
# tries to enable the extension. The value must be active and un-commented.
if grep -Eq "^shared_preload_libraries *= *.*vchord" /var/db/postgres/data18/postgresql.conf; then
    :
elif grep -Eq "^#shared_preload_libraries *= *.*vchord" /var/db/postgres/data18/postgresql.conf; then
    sed -i '' "s|^#shared_preload_libraries *= *.*vchord.*$|shared_preload_libraries = 'vchord.so'|" /var/db/postgres/data18/postgresql.conf
else
    if grep -Eq "^#?shared_preload_libraries *= *" /var/db/postgres/data18/postgresql.conf; then
        sed -i '' "s|^#\?shared_preload_libraries *= *.*$|shared_preload_libraries = 'vchord.so'|" /var/db/postgres/data18/postgresql.conf
    else
        echo "shared_preload_libraries = 'vchord.so'" >> /var/db/postgres/data18/postgresql.conf
    fi
fi

# Restart PostgreSQL so the preload configuration is applied.
service postgresql stop 2>/dev/null || true
if $(service postgresql start 2>/dev/null >/dev/null); then
    echo "Starting PostgreSQL with vchord loaded..."
fi

##############################################################################
# 3. Create database and extensions
##############################################################################
sleep 3  # Wait for PostgreSQL to fully start

echo "Setting up database and extensions..."

su -m postgres -c "psql -c \"CREATE USER ${immich_db_user} WITH SUPERUSER PASSWORD '${immich_db_pass}';\"" 2>/dev/null || true
su -m postgres -c "psql -c \"CREATE DATABASE ${immich_db_name} OWNER ${immich_db_user};\"" 2>/dev/null || true

su -m postgres -c "psql -d ${immich_db_name} -c \"CREATE EXTENSION IF NOT EXISTS vector;\"" 2>/dev/null || true
su -m postgres -c "psql -d ${immich_db_name} -c \"CREATE EXTENSION IF NOT EXISTS vchord CASCADE;\"" 2>/dev/null || true
su -m postgres -c "psql -d ${immich_db_name} -c \"CREATE EXTENSION IF NOT EXISTS cube;\"" 2>/dev/null || true
su -m postgres -c "psql -d ${immich_db_name} -c \"CREATE EXTENSION IF NOT EXISTS earthdistance;\"" 2>/dev/null || true
su -m postgres -c "psql -d ${immich_db_name} -c \"CREATE EXTENSION IF NOT EXISTS pg_trgm;\"" 2>/dev/null || true

echo "Database setup complete."

##############################################################################
# 4. Create Immich configuration file
##############################################################################
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

# Keep the old config directory layout for compatibility
ln -sf "${immich_env_file}" "${immich_config}/immich.env"

# This is the file path the rc.d service expects by default.
echo "Config file written to: ${immich_env_file}"

chown -R immich:immich "${immich_config}" 2>/dev/null || true

##############################################################################
# 5. Enable Immich server service
##############################################################################

# Ensure the immich user exists for the service to run as
if ! pw user show immich >/dev/null 2>&1; then
    echo "Creating immich system user..."
    pw user add immich -s /bin/nologin -no-password -d /nonexistent -h -
fi

# The rc script defines immich_server_env_file but never applies it, so set the
# actual runtime environment explicitly to avoid falling back to the Docker default
# hostname `database`.
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

# Set correct ownership for the service
chown -R immich:immich "${immich_config}"
chown -R immich:immich "${immich_upload}"

# Start Immich server
if $(service immich_server start 2>/dev/null >/dev/null); then
    echo "Starting Immich server on port 2283..."
fi

echo "Immich setup complete. Web interface available at port 2283."
