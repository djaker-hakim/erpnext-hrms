# ERPNext + HRMS — Docker Compose Deployment

This repository contains the Docker Compose deployment configuration for a self-hosted **ERPNext v16** instance with **Frappe HRMS** pre-installed. It uses a custom image (`djakerhakim/erpnext-hrms:v16`) built on top of the official `frappe/erpnext:v16` base image with HRMS bundled in, eliminating the need to install it separately at runtime.

The stack includes the full Frappe ecosystem: application server, Nginx reverse proxy, Socket.IO websocket server, background job workers, a scheduler, MariaDB, and Redis — everything needed to run ERPNext in production out of the box.

All configuration is centralized in a single `.env` file. The `docker-compose.yml` contains no hardcoded values — every environment-specific setting is injected via `${VAR_NAME}` substitution at runtime.

---

## Deployment

### Prerequisites

- Docker and Docker Compose installed
- Port `8080` free on the host

### 1. Configure the environment

Copy the example environment file and fill in your values:

```bash
cp .env.example .env
```

Then edit `.env`:

```env
# Database
DB_HOST=db
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

### 2. Start all services

```bash
docker compose up -d
```

### 3. Monitor the one-shot setup containers

```bash
docker compose logs -f configurator
docker compose logs -f create-site
```

`configurator` writes the Frappe site config, then exits. `create-site` waits for it, creates the site, installs ERPNext and HRMS, then exits. Both exiting is **expected and normal** — they will not restart.

### 4. Access the application

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

```bash
docker compose up -d
```

### Updating the Application

Application code is baked into the image, so updates follow a rebuild workflow:

1. Modify app code or `apps.json`
2. Rebuild and push the image:
   ```bash
   docker build -t djakerhakim/erpnext-hrms:v16 .
   docker push djakerhakim/erpnext-hrms:v16
   ```
3. Redeploy:
   ```bash
   docker compose pull
   docker compose up -d
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
| `backend` | `djakerhakim/erpnext-hrms:v16` | Gunicorn application server |
| `frontend` | `djakerhakim/erpnext-hrms:v16` | Nginx reverse proxy (exposed on port 8080) |
| `websocket` | `djakerhakim/erpnext-hrms:v16` | Socket.IO real-time server |
| `configurator` | `djakerhakim/erpnext-hrms:v16` | One-shot: writes `common_site_config.json` |
| `create-site` | `djakerhakim/erpnext-hrms:v16` | One-shot: creates the Frappe site and installs apps |
| `scheduler` | `djakerhakim/erpnext-hrms:v16` | Background job scheduler (`bench schedule`) |
| `queue-long` | `djakerhakim/erpnext-hrms:v16` | Worker for long, default, and short queues |
| `queue-short` | `djakerhakim/erpnext-hrms:v16` | Worker for short and default queues |
| `db` | `mariadb:10.6` | MariaDB database |
| `redis-cache` | `redis:6.2-alpine` | In-memory cache |
| `redis-queue` | `redis:6.2-alpine` | Job queue broker (data persisted to volume) |

All services share a single bridge network: `frappe_network`.

---

### `backend`
Runs the Frappe/ERPNext Gunicorn WSGI server. Restarts automatically on failure. Receives `DB_HOST`, `DB_PORT`, and database credentials from the `.env` file.

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
Runs once on first deploy. Writes global Frappe configuration into `sites/common_site_config.json` using values from `.env`: database host/port, Redis URLs, and the Socket.IO port.

> Configuration is written by directly manipulating `common_site_config.json` via Python rather than using `bench set-config`, which is unreliable in Docker Compose environments due to shell quoting behavior.

### `create-site` *(one-shot)*
Runs once on first deploy. Waits for `DB_HOST:DB_PORT` and both Redis instances to be ready, then polls until `configurator` has written `common_site_config.json`. Once confirmed, it creates the Frappe site using `FRAPPE_SITE_NAME`, `ADMIN_PASSWORD`, `DB_NAME`, and database credentials — all sourced from `.env` — then installs ERPNext and HRMS in a single step.

### `db`
MariaDB 10.6 with `utf8mb4_unicode_ci` charset enforced. The `--skip-innodb-read-only-compressed` flag is a temporary workaround for a known MariaDB 10.6 issue. Health-checked via `mysqladmin ping` using `MYSQL_ROOT_PASSWORD`. Data is persisted in the `db-data` named volume.

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

| Volume | Purpose |
|---|---|
| `sites` | Frappe site files, configuration, and uploaded assets |
| `logs` | Application and access logs |
| `db-data` | MariaDB data directory |
| `redis-queue-data` | RQ job queue persistence |

> Volumes hold runtime data only. Application code and installed apps are baked into the image at build time — never mounted via volumes.

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

Verify that `DB_HOST` and `DB_PORT` in your `.env` match your actual database service name and port. If pointing to an external (host-installed) database instead of the containerized `db` service, ensure `host.docker.internal` is resolvable and the MariaDB instance allows connections from the Docker network.