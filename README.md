# ERPNext + HRMS — Docker Compose Deployment

This repository contains the Docker Compose deployment configuration for a self-hosted **ERPNext v16** instance with **Frappe HRMS** pre-installed. It uses a custom image (`djakerhakim/erpnext-hrms:v16`) built on top of the official `frappe/erpnext:v16` base image with HRMS bundled in, eliminating the need to install it separately at runtime.

The stack includes the full Frappe ecosystem: application server, Nginx reverse proxy, Socket.IO websocket server, background job workers, a scheduler, MariaDB, and Redis — everything needed to run ERPNext in production out of the box.

---

## Deployment

### Prerequisites

- Docker and Docker Compose installed
- Port `8080` free on the host

### First-Time Setup

```bash
# 1. Start all services
docker compose up -d

# 2. Monitor the one-shot setup containers
docker compose logs -f configurator
docker compose logs -f create-site

# 3. Once create-site completes, open the app
open http://localhost:8080
```

Default login credentials:

| Field | Value |
|---|---|
| Username | `Administrator` |
| Password | `admin` |

> Change the admin password immediately after first login.

The `configurator` and `create-site` containers will exit automatically once their work is done — this is expected. They will not restart.

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
   docker compose exec backend bench --site frontend migrate
   ```

> `bench migrate` is non-destructive — it only adds columns/tables and runs patches, never overwrites existing data.

---

## Services

### Stack Overview

| Service | Image | Role |
|---|---|---|
| `backend` | `djakerhakim/erpnext-hrms:v16` | Gunicorn application server (port 8000) |
| `frontend` | `djakerhakim/erpnext-hrms:v16` | Nginx reverse proxy (exposed on port 8080) |
| `websocket` | `djakerhakim/erpnext-hrms:v16` | Socket.IO real-time server (port 9000) |
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
Runs the Frappe/ERPNext Gunicorn WSGI server. Restarts automatically on failure. Mounts the `sites` and `logs` volumes shared across all application containers.

### `frontend`
Nginx reverse proxy that exposes the application on **`http://localhost:8080`**. Before starting Nginx, it creates the symlink required to serve HRMS static assets:

```
ln -sfn /home/frappe/frappe-bench/apps/hrms/hrms/public \
         /home/frappe/frappe-bench/sites/assets/hrms
```

> **Important:** The `frontend` container must use the custom image — not the base `frappe/erpnext` image — otherwise HRMS assets get overwritten during the Nginx entrypoint asset rebuild.

Depends on `websocket` being up before it starts.

| Variable | Value | Description |
|---|---|---|
| `BACKEND` | `backend:8000` | Upstream app server |
| `FRAPPE_SITE_NAME_HEADER` | `frontend` | Site name passed in the request header |
| `SOCKETIO` | `websocket:9000` | WebSocket upstream |
| `PROXY_READ_TIMEOUT` | `120` | Nginx proxy read timeout (seconds) |
| `CLIENT_MAX_BODY_SIZE` | `50m` | Maximum upload size |

### `websocket`
Runs the Frappe Socket.IO server for real-time push events. Connects to both Redis instances.

### `configurator` *(one-shot)*
Runs once on first deploy. Writes global Frappe configuration into `sites/common_site_config.json`, setting the database host/port, Redis URLs, and the Socket.IO port.

> Configuration is written by directly manipulating `common_site_config.json` via Python rather than using `bench set-config`, which is unreliable in Docker Compose environments due to shell quoting behavior.

### `create-site` *(one-shot)*
Runs once on first deploy. Waits for the database and both Redis instances to be ready, then polls until `configurator` has written `common_site_config.json`. Once confirmed, it creates the Frappe site named `frontend`, installs ERPNext, and installs HRMS.

### `db`
MariaDB 10.6 with `utf8mb4_unicode_ci` charset enforced. The `--skip-innodb-read-only-compressed` flag is a temporary workaround for a known MariaDB 10.6 issue. Health-checked via `mysqladmin ping`. Data is persisted in the `db-data` named volume.

### `queue-long` / `queue-short`
Frappe RQ workers consuming job queues. `queue-long` handles long-running, default, and short jobs. `queue-short` handles short and default jobs.

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
docker compose exec backend bench --site frontend clear-cache
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