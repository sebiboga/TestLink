# TestLink 1.9.20 Docker Installation Guide

**Target:** Raspberry Pi 5 (Debian 12, aarch64, Docker v29.6.2)
**Approach:** Pre-built image `supersqa/testlink:1.9.20` + MySQL 8.3

> **Why pre-built?** The official repo's Dockerfile compiles PHP 7.4 from source
> on aarch64, which takes 20+ minutes and often times out. The `supersqa` image
> is already built for arm64 and works out of the box.

---

## Prerequisites

- Docker & Docker Compose installed and running
- Nginx Proxy Manager running (ports 80/443/81)
- CloudFlare DNS access for `peviitor.ro`
- SSH access to the Pi

---

## Step 1 — Clone the Official Repo

```bash
cd /home/sebi/TestLink
git clone -b testlink_1_9_20_fixed https://github.com/TestLinkOpenSourceTRMS/testlink-code.git
cd testlink-code
```

---

## Step 2 — Create Environment File

```bash
cat > .env << 'EOF'
MYSQL_ROOT_PASSWORD=<generate-with-openssl-rand-hex-16>
MYSQL_DATABASE=testlink
MYSQL_USER=testlink
MYSQL_PASSWORD=<generate-with-openssl-rand-hex-16>
EOF
```

> **Never use default credentials in production.**

---

## Step 3 — Edit docker-compose.yml

Replace the `app` service `build: .` with the pre-built image and fix the
port mapping. The image's Apache listens on **port 8080 internally**, not 80.

```yaml
  app: &app
    image: supersqa/testlink:1.9.20
    restart: unless-stopped
    depends_on:
      db:
        condition: service_started
      maildev:
        condition: service_started
    networks:
    - testlink
    ports:
    - 8090:8080
    volumes:
    - ./php-custom.ini:/usr/local/etc/php/conf.d/custom.ini:ro
```

Also fix the `restore` service (remove the `<<: *app` merge that references build):

```yaml
  restore:
    image: supersqa/testlink:1.9.20
    depends_on:
      app:
        condition: service_started
    restart: no
    ports: []
    profiles:
    - tools
    command: ['/bin/bash', '-c', 'cd ./docs/db_sample && ./restore_sample.sh']
```

---

## Step 4 — Create Custom PHP Config

```bash
cat > php-custom.ini << 'EOF'
max_execution_time = 120
memory_limit = 256M
EOF
```

This fixes the installer warning about `max_execution_time` being too low
for large test suites.

---

## Step 5 — Start the Containers

```bash
docker compose up -d
```

This starts three containers:
- `testlink-code-app-1` — PHP 7.2 + Apache + TestLink (port **8090**)
- `testlink-code-db-1` — MySQL 8.3
- `testlink-code-maildev-1` — MailHog for email testing (port 1080)

Verify they're running:

```bash
docker compose ps
```

TestLink installer should be accessible at `http://localhost:8090`.

---

## Step 6 — Pre-Fix MySQL 8 Auth (CRITICAL)

PHP 7.2 in this image only supports `mysql_native_password`, but MySQL 8
defaults to `caching_sha2_password`. **You MUST fix this BEFORE running
the installer**, or you'll get "authentication method unknown to the client".

Also, the TestLink installer tries to GRANT to both `testlink@db` AND
`testlink@localhost`. MySQL 8 won't auto-create users via GRANT, so both
users must exist beforehand.

Run this **before** opening the installer:

```bash
docker exec testlink-code-db-1 mysql -uroot -pe24a93d9d64466ecc82618576d9f7a7d -e "
-- Switch root and testlink to mysql_native_password
ALTER USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY 'e24a93d9d64466ecc82618576d9f7a7d';
ALTER USER 'testlink'@'%' IDENTIFIED WITH mysql_native_password BY 'a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6';

-- Create users for both host patterns the installer uses
CREATE USER IF NOT EXISTS 'testlink'@'db' IDENTIFIED WITH mysql_native_password BY 'a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6';
CREATE USER IF NOT EXISTS 'testlink'@'localhost' IDENTIFIED WITH mysql_native_password BY 'a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6';

-- Grant privileges
GRANT ALL PRIVILEGES ON testlink.* TO 'testlink'@'db' WITH GRANT OPTION;
GRANT SELECT, UPDATE, DELETE, INSERT ON testlink.* TO 'testlink'@'localhost' WITH GRANT OPTION;

-- Enable UDF function creation (needed for Step 7)
SET GLOBAL log_bin_trust_function_creators = 1;

FLUSH PRIVILEGES;
"
```

> Replace the passwords with your actual `.env` values.

---

## Step 7 — Run the TestLink Installer

Open `http://localhost:8090` in your browser (or `http://192.168.1.135:8090` from LAN).

### Pre-check warnings — what's expected

| Check | Status | Action |
|-------|--------|--------|
| Postgres/MSSQL | Failed | Expected — we use MySQL, safe to ignore |
| GD Library | Failed | Graph rendering disabled — cosmetic only, see Note below |
| LDAP | Failed | Using internal auth — safe to ignore |
| max_execution_time | 120s | Fixed via `php-custom.ini` |
| Session timeout | 24 min | Can adjust later in TestLink settings |

> **Note on GD:** The `supersqa/testlink` image is based on Debian Buster (EOL)
> and the GD extension was not compiled in. Graph/chart rendering will be disabled.
> This does not affect test case management, execution, or reporting.

### Database configuration

Enter these values in the installer:

| Field | Value |
|-------|-------|
| Database type | MySQL/MariaDB |
| Database host | `db` |
| Database name | `testlink` |
| Database admin login | `root` |
| Database admin password | *(from `.env` MYSQL_ROOT_PASSWORD)* |
| TestLink DB login | `testlink` |
| TestLink DB password | *(from `.env` MYSQL_PASSWORD)* |

### After installer completes

The installer will ask you to manually run a UDF SQL script. See Step 8.

Default admin credentials:
- **Username:** `admin`
- **Password:** `admin`

> **Change the admin password immediately** via Users > Change Password.

---

## Step 8 — Run UDF Script (After Installer)

The installer finishes with a message to run `testlink_create_udf0.sql`.
This script has hardcoded `YOUR_TL_DBNAME` placeholders that must be
replaced. Run this:

```bash
docker exec testlink-code-app-1 cat /var/www/html/install/sql/mysql/testlink_create_udf0.sql \
  | sed 's/YOUR_TL_DBNAME/testlink/g' \
  | docker exec -i testlink-code-db-1 mysql -uroot -pe24a93d9d64466ecc82618576d9f7a7d testlink
```

This creates the `UDFStripHTMLTags` function used for stripping HTML
from test case content.

---

## Step 9 — Delete Install Directory

```bash
docker exec testlink-code-app-1 rm -rf /var/www/html/install
```

---

## Step 10 — CloudFlare DNS

In the CloudFlare dashboard for `peviitor.ro`:

1. Go to **DNS > Records**
2. Add a new **A record**:
   - **Name:** `testlink`
   - **Content:** *(your Pi's public IP)*
   - **Proxy status:** DNS only (gray cloud) — NPM handles SSL
   - **TTL:** Auto

Verify:

```bash
dig testlink.peviitor.ro +short
```

---

## Step 11 — Nginx Proxy Manager Setup

1. Open NPM admin UI at `http://192.168.1.135:81`
2. Go to **Proxy Hosts > Add New Proxy Host**
3. Fill in:
   - **Domain Names:** `testlink.peviitor.ro`
   - **Scheme:** `http`
   - **Forward Hostname / IP:** `testlink-code-app-1`
   - **Forward Port:** `8080`
4. Enable **Block Common Exploits**
5. Go to the **SSL** tab:
   - Select **Request a new SSL Certificate**
   - Enable **Force SSL**
   - Enable **HTTP/2 Support**
   - Enter your email
   - Agree to Let's Encrypt TOS
6. Click **Save**

> DNS must be resolving before requesting SSL (Step 10 first).

---

## Step 12 — Verify Everything

| Check | Expected |
|-------|----------|
| `docker compose ps` | 3 containers running |
| `curl -s -o /dev/null -w "%{http_code}" http://localhost:8090` | `200` |
| `https://testlink.peviitor.ro` | TestLink login page |
| `https://api.peviitor.ro` | Unchanged, still works |
| NPM Dashboard > Proxy Hosts | Entries for api + testlink |

---

## After-Install Cleanup

### Remove leftover build files

Since we use a pre-built image, these files from the repo are unused:

```bash
rm -f Dockerfile
```

> **Keep** `docker-compose.yml`, `.env`, `php-custom.ini`, `.env.example`,
> and `config_db.inc.php` (auto-generated by installer) — these are needed
> to run and manage the stack.

### Optional: Remove maildev

If you don't need the mail testing server, remove it from `docker-compose.yml`
and recreate. This saves ~150MB RAM:

```bash
# Remove the maildev service block from docker-compose.yml, then:
docker compose up -d --force-recreate
```

---

## Troubleshooting

### "authentication method unknown to the client"

MySQL 8 uses `caching_sha2_password` by default. PHP 7.2 only supports
`mysql_native_password`. Run the auth fix from Step 6.

### "You are not allowed to create a user with GRANT"

The installer tries to GRANT to `testlink@localhost` which doesn't exist.
MySQL 8 won't auto-create users via GRANT. Create the user first — see Step 6.

### "This function has none of DETERMINISTIC, NO SQL..."

The UDF script needs `log_bin_trust_function_creators` enabled. Already
handled in Step 6. If it still fails:

```bash
docker exec testlink-code-db-1 mysql -uroot -p<password> -e "SET GLOBAL log_bin_trust_function_creators = 1;"
```

### DB Access Error during installer

If the user already exists with wrong auth, drop and recreate:

```bash
docker exec testlink-code-db-1 mysql -uroot -p<password> -e "
DROP USER IF EXISTS 'testlink'@'db';
DROP USER IF EXISTS 'testlink'@'localhost';
DROP USER IF EXISTS 'testlink'@'%';
FLUSH PRIVILEGES;"
```

Then re-run Step 6.

### Connection reset by peer / blank page

The image's Apache listens on **port 8080**, not 80. Ensure compose has:

```yaml
ports:
  - 8090:8080
```

### SSL certificate fails

- Confirm DNS resolves: `dig testlink.peviitor.ro +short`
- Ensure port 80 is reachable from the internet
- Check NPM logs: `docker logs npm-app`

### Reset everything (fresh start)

```bash
docker compose down
docker volume rm testlink-code_mysql
rm -f config_db.inc.php
docker compose up -d
```

---

## Port Map Summary

| Port | Service | Status |
|------|---------|--------|
| 22 | SSH | Existing |
| 80/443 | Nginx Proxy Manager | Existing |
| 81 | NPM Admin UI | Existing |
| 8080 | peviitor-api | Existing (unchanged) |
| **8090** | **TestLink** | **New** |
| 1080 | Maildev (email testing) | New (optional) |
| 5900 | VNC | Existing |
| 19999 | Netdata | Existing |

---

## Resource Impact

| Metric | Before | After |
|--------|--------|-------|
| RAM used | ~1.7 GB | ~2.1 GB |
| RAM available | ~2.3 GB | ~1.9 GB |
| Disk used | ~27 GB | ~28 GB |
| Running containers | 2 | 5 (3 testlink + 2 existing) |
