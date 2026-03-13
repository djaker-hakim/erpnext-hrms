# ERPNext + HRMS — Docker Compose Deployment (External Database)

This repository contains the Docker Compose deployment configuration for a self-hosted **ERPNext v16** instance with **Frappe HRMS** pre-installed. It uses a locally built image (`erpnext-hrms:v16`) based on the official `frappe/erpnext:v16` image with HRMS bundled in.

Unlike a standard all-in-one compose setup, **the database runs outside the compose stack** — either as a standalone Docker container (using the provided `db.sh` / `db.bat` scripts) or as an existing MariaDB instance on the host. The application containers reach the database over the host network via `host.docker.internal`. This pattern is useful when you want the database lifecycle to be independent from the application stack, or when connecting to an existing database server.

All configuration is centralized in a single `.env` file. The `docker-compose.yml` contains no hardcoded values — every environment-specific setting is injected via `${VAR_NAME}` substitution at runtime.

---

## Deployment

### Prerequisites

- Docker and Docker Compose installed
- Port `8080` free on the host
- A running MariaDB instance accessible on the host (see step 1)

### 1. Start the database

The repository includes `db.sh` (Linux/macOS) and `db.bat` (Windows) to spin up a standalone MariaDB 10.6 container that simulates an external database server:

**Linux / macOS:**
```bash
bash db.sh
```

**Windows:**
```bat
db.bat
```

Both scripts run the same command under the hood:
```bash
docker run -d \
  --name db \
  -e MYSQL_ROOT_PASSWORD=admin \
  -e MARIADB_ROOT_PASSWORD=admin \
  -p 3306:3306 \
  -v db-data:/var/lib/mysql \
  mariadb:10.6 \
  --character-set-server=utf8mb4 \
  --collation-server=utf8mb4_unicode_ci \
  --skip-character-set-client-handshake \
  --skip-innodb-read-only-compressed
```

This starts a MariaDB container **outside the compose network**, binding to port `3306` on the host. The application stack connects to it via `host.docker.internal:3306`.

> If you already have a MariaDB instance running on the host or on another server, you can skip this step — just point `DB_HOST` in your `.env` to the correct address.

> Data is persisted in the `db-data` Docker volume, which is managed independently from the compose stack.

### 2. Configure the environment

Copy the example environment file and fill in your values:

```bash
cp .env.example .env
```

Then edit `.env`:

```env
# Database — pointing to the external DB via host.docker.internal
DB_HOST=host.docker.internal
DB_PORT=3306
DB_ROOT_USERNAME=root
DB_NAME=your_site_db
MYSQL_ROOT_PASSWORD=changeme
MARIADB_ROOT_PASSWORD=changeme

# Frappe site
FRAPPE_SITE_NAME=frontend
ADMIN_PASSWORD=changeme

# Redis
REDIS_CACHE=redis-cache:6379
REDIS_QUEUE=redis-queue:6379

# Frontend / Nginx
BACKEND=backend:8000
SOCKETIO=websocket:9000
UPSTREAM_REAL_IP_ADDRESS=127.0.0.1
UPSTREAM_REAL_IP_HEADER=X-Forwarded-For
UPSTREAM_REAL_IP_RECURSIVE=off
PROXY_READ_TIMEOUT=120
CLIENT_MAX_BODY_SIZE=50m

# Socket.IO
SOCKETIO_PORT=9000
```

> **Never commit your `.env` file.** It contains database passwords and admin credentials. Only `.env.example` (with placeholder values) should be tracked in version control.

### 3. Start all services

```bash
docker compose up -d
```

### 4. Monitor the one-shot setup containers

```bash
docker compose logs -f configurator
docker compose logs -f create-site
```

`configurator` writes the Frappe site config, then exits. `create-site` waits for it, creates the site, installs ERPNext, installs HRMS, then exits. Both exiting is **expected and normal** — they will not restart.

### 5. Access the application

```
http://localhost:8080
```

Default login credentials:

| Field | Value |
|---|---|
| Username | `Administrator` |
| Password | value of `ADMIN_PASSWORD` in your `.env` |

> Change the admin password immediately after first login.

### Subsequent Starts

The database container is not part of the compose stack, so it must be started separately if it was stopped:

```bash
docker start db
docker compose up -d
```

### Updating the Application

Application code is baked into the image, so updates follow a rebuild workflow:

1. Modify app code or `apps.json`
2. Rebuild the image locally:
   ```bash
   docker build -t erpnext-hrms:v16 .
   ```
3. Redeploy:
   ```bash
   docker compose up -d --force-recreate
   ```
4. Run migrations if the schema changed:
   ```bash
   docker compose exec backend bench --site ${FRAPPE_SITE_NAME} migrate
   ```

> `bench migrate` is non-destructive — it only adds columns/tables and runs patches, never overwrites existing data.

---

## Services

### Stack Overview

| Service | Image | Role |
|---|---|---|
| `backend` | `erpnext-hrms:v16` | Gunicorn application server |
| `frontend` | `erpnext-hrms:v16` | Nginx reverse proxy (exposed on port 8080) |
| `websocket` | `erpnext-hrms:v16` | Socket.IO real-time server |
| `configurator` | `erpnext-hrms:v16` | One-shot: writes `common_site_config.json` |
| `create-site` | `erpnext-hrms:v16` | One-shot: creates the Frappe site and installs apps |
| `scheduler` | `erpnext-hrms:v16` | Background job scheduler (`bench schedule`) |
| `queue-long` | `erpnext-hrms:v16` | Worker for long, default, and short queues |
| `queue-short` | `erpnext-hrms:v16` | Worker for short and default queues |
| `redis-cache` | `redis:6.2-alpine` | In-memory cache |
| `redis-queue` | `redis:6.2-alpine` | Job queue broker (data persisted to volume) |

> There is no `db` service in this compose file. The database runs as a standalone container or existing host service, outside the compose network.

All services share a single bridge network: `frappe_network`.

---

### `backend`
Runs the Frappe/ERPNext Gunicorn WSGI server. Restarts automatically on failure. Receives database connection details from `.env`. Uses `extra_hosts: host.docker.internal:host-gateway` to resolve the host machine's IP, enabling it to reach the external database.

### `frontend`
Nginx reverse proxy that exposes the application on **`http://localhost:8080`**. Before starting Nginx, it creates the symlink required to serve HRMS static assets:

```
ln -sfn /home/frappe/frappe-bench/apps/hrms/hrms/public \
         /home/frappe/frappe-bench/sites/assets/hrms
```

All Nginx behavior is controlled by `.env` variables (`BACKEND`, `SOCKETIO`, `PROXY_READ_TIMEOUT`, `CLIENT_MAX_BODY_SIZE`, etc.).

> **Important:** The `frontend` container must use the custom image — not the base `frappe/erpnext` image — otherwise HRMS assets get overwritten during the Nginx entrypoint asset rebuild.

Depends on `websocket` being up before it starts.

### `websocket`
Runs the Frappe Socket.IO server for real-time push events. Connects to both Redis instances using `REDIS_CACHE` and `REDIS_QUEUE` from `.env`.

### `configurator` *(one-shot)*
Runs once on first deploy. Writes global Frappe configuration into `sites/common_site_config.json` using values from `.env`: database host/port, Redis URLs, and the Socket.IO port. Has `host.docker.internal` mapped so it can verify database reachability.

> Configuration is written by directly manipulating `common_site_config.json` via Python rather than using `bench set-config`, which is unreliable in Docker Compose environments due to shell quoting behavior.

### `create-site` *(one-shot)*
Runs once on first deploy. Waits for `DB_HOST:DB_PORT` and both Redis instances to be ready, then polls until `configurator` has written `common_site_config.json`. Once confirmed, it creates the Frappe site using `FRAPPE_SITE_NAME`, `ADMIN_PASSWORD`, `DB_NAME`, and database credentials — all sourced from `.env`. It then installs ERPNext, installs HRMS as a separate step, and sets the site as default. Has `host.docker.internal` mapped to reach the external database.

### `queue-long` / `queue-short`
Frappe RQ workers consuming job queues. `queue-long` handles long-running, default, and short jobs. `queue-short` handles short and default jobs. Both connect to Redis using `REDIS_CACHE` and `REDIS_QUEUE` from `.env`.

### `scheduler`
Runs `bench schedule` to trigger periodic background tasks (cron-like behavior).

### `redis-cache`
Ephemeral Redis instance used for application-level caching. Not persisted — data is intentionally volatile.

### `redis-queue`
Redis instance used as the RQ job broker. Persisted to the `redis-queue-data` volume so queued jobs survive container restarts.

---

### Volumes

| Volume | Managed by | Purpose |
|---|---|---|
| `sites` | compose | Frappe site files, configuration, and uploaded assets |
| `logs` | compose | Application and access logs |
| `redis-queue-data` | compose | RQ job queue persistence |
| `db-data` | `db.sh` / `db.bat` | MariaDB data directory (outside compose stack) |

> `db-data` is created and owned by the standalone database container. It is intentionally not declared in `docker-compose.yml` to keep the database lifecycle independent.

---

## Troubleshooting

**`Module Core not found` after redeployment**

Stale Redis cache or `apps.txt` mismatch. Fix by re-running the configurator and clearing the cache:
```bash
docker compose run --rm configurator
docker compose exec backend bench --site ${FRAPPE_SITE_NAME} clear-cache
```

**HRMS assets returning 404**

The HRMS symlink in the `frontend` container is missing. Restart the service:
```bash
docker compose restart frontend
```

**`create-site` times out waiting for `common_site_config.json`**

The `configurator` container didn't complete successfully. Check its logs:
```bash
docker compose logs configurator
```

**Database connection refused**

Ensure the `db` container is running and healthy:
```bash
docker ps --filter name=db
docker logs db
```

Verify that `DB_HOST=host.docker.internal` and `DB_PORT=3306` in your `.env` match the port the database container is bound to. On Linux, also confirm that `host-gateway` resolves correctly — it requires Docker Engine 20.10+.