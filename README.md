# iocage-plugin-immich

Unofficial [FreeCORE](https://github.com/freecore-project/) (TrueNAS CORE - continued) plugin to install [Immich](https://immich.app/).

> **Status**: Personal plugin — not affiliated with or supported by Immich Inc.

---

## Installation

Run the following commands on your FreeCORE host:

```shell
BRANCH=master
JSON=/tmp/immich.json

fetch -o "$JSON" "https://raw.githubusercontent.com/damvcoool/iocage-plugin-index/${BRANCH}/immich.json"

iocage fetch -P "$JSON" --branch "$BRANCH" -n Immich
```

---

## Post-Installation

After installation completes, you can access:

- **Web Interface**: `http://[jail-ip]:2283`
- **Default Login**: Set your admin credentials during first-time setup wizard

### Credentials Location

All credentials are stored securely in the jail's `/root` directory:

- `/root/PLUGIN_INFO` — Complete setup information
- `/root/dbname` — PostgreSQL database name
- `/root/dbuser` — PostgreSQL username
- `/root/dbpassword` — PostgreSQL password

Access these files via:

```sh
iocage console Immich
cat /root/PLUGIN_INFO
```

---

## Configuration

### Service Management

```sh
# Start/Stop/Restart Immich
service immich_server start
service immich_server stop
service immich_server restart
service immich_server status

# Valkey (Redis)
service valkey start
service valkey stop
service valkey restart

# PostgreSQL
service postgresql start
service postgresql stop
service postgresql restart
```

### Configuration File

Main environment configuration: `/usr/local/etc/immich.env`

To modify settings, edit this file and restart the Immich service:

```sh
service immich_server restart
```

### Upload Directory

User uploads are stored at: `/var/db/immich/upload`

Ensure sufficient storage is available for your photo/video library.

---

## Architecture

This plugin runs Immich natively (non-Docker) on FreeBSD with:

- **Immich Server** — Node.js-based media platform
- **PostgreSQL 18** — Database with vector extensions for AI-powered search
- **Valkey** — Redis-compatible cache for sessions and file locking
- **Extensions**: `vector`, `vchord`, `cube`, `earthdistance`, `pg_trgm`

---

## Security Best Practices

1. **Change Default Passwords**: Immediately set a strong admin password during first login
2. **Firewall Configuration**: Limit access to port 2283 to trusted networks only
3. **HTTPS Setup**: Consider setting up a reverse proxy (nginx, caddy) with SSL/TLS
4. **Regular Updates**: Keep the jail and packages updated regularly
5. **Backups**: Regularly backup PostgreSQL database and the upload directory

### Setting Up HTTPS (Recommended)

For production use, configure a reverse proxy with SSL certificates:

```sh
# Example using nginx in another jail or on the host
# Forward HTTPS traffic to http://[immich-jail-ip]:2283
```

---

## Database Backup

To backup your Immich database:

```sh
iocage console Immich
su - postgres
pg_dump immich > /root/immich_backup_$(date +%Y%m%d).sql
```

### Upload Directory Backup

```sh
# Archive the upload directory
tar -czf /root/immich_upload_backup_$(date +%Y%m%d).tar.gz /var/db/immich/upload
```

---

## Troubleshooting

### Check Service Status

```sh
iocage console Immich
service immich_server status
service postgresql status
service valkey status
```

### View Logs

```sh
# Immich logs
tail -f /var/log/immich_server.log

# PostgreSQL logs
tail -f /var/db/postgres/data18/log/postgresql-*.log

# Valkey logs
tail -f /var/log/valkey.log
```

### Common Issues

**Immich won't start:**

- Check if PostgreSQL is running: `service postgresql status`
- Verify database exists: `su - postgres -c "psql -l"`
- Check log file for errors: `tail -100 /var/log/immich_server.log`

**Cannot access web interface:**

- Verify jail IP: `iocage get ip4_addr Immich`
- Check if port 2283 is listening: `sockstat -l | grep 2283`
- Ensure firewall rules allow access

**Database connection errors:**

- Verify PostgreSQL credentials in `/root/PLUGIN_INFO`
- Check `immich.env` configuration file
- Ensure vector extensions are loaded: `su - postgres -c "psql -d immich -c '\dx'"`

---

## Version Information

- **FreeBSD**: Compatible with FreeCORE (FreeBSD-based)

---

## Contributing

This is a community project. Issues and pull requests are welcome!

## License

This plugin configuration is provided as-is. Immich itself is licensed under GNU GPL v3.

## Disclaimer

This is an unofficial plugin not affiliated with or supported by Immich Inc. or iXsystems. Use at your own risk.