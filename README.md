# ContentDM

Content Sync Tool — production distribution.

Manage content across tenants, view dashboards. This repository hosts the installer and the packaged releases; the application ships as pre-built, compiled Docker images.

## Requirements

- Linux or macOS host with [Docker](https://docs.docker.com/engine/install/) (Engine 24+ or Docker Desktop) and Docker Compose v2
- 4 GB RAM and ~8 GB free disk
- Internet access on first run (pulls the `postgres`/`redis`/`nginx` base images)

## Install

1. From the [latest release](../../releases/latest), download:
   - `production.sh`
   - the archive matching your server's CPU:
     - `contentdm-prod-<version>-linux-amd64.tar.gz` — x86_64 servers
     - `contentdm-prod-<version>-linux-arm64.tar.gz` — ARM servers / Apple Silicon
2. Put both files in the same (empty) folder.
3. Run:

   ```
   bash production.sh
   ```

That is all — no prompts, no configuration. The script loads the images, generates all secrets, starts the stack, runs database migrations, creates the first admin account, and prints:

```
✔ ContentDM is up.

   Dashboard:  http://localhost:8080
   Login:      admin / <generated password>
```

Sign in and change the admin password. The generated credentials and secrets live in `.env` next to the script (file mode 0600) — keep that file safe; it also protects the encrypted XSIAM tenant keys.

## Manage

```
bash production.sh status     # container status
bash production.sh logs       # follow logs
bash production.sh stop       # stop (keeps all data)
bash production.sh restart    # restart services
bash production.sh down       # remove containers (keeps data volumes)
```

## Options

```
bash production.sh --port 9090          # serve on another port
bash production.sh --bind 127.0.0.1     # bind to loopback only
bash production.sh --tar /path/to/archive.tar.gz
```

## Upgrade

Download the new release archive into the same folder and re-run `bash production.sh`. Data, users, and secrets are preserved (Docker volumes + existing `.env`).

## Exposing beyond localhost

The stack listens on `0.0.0.0:8080` by default and includes hardened nginx, rate limiting, and JWT auth — but no TLS. To expose it on a network, front it with a TLS-terminating proxy (or keep `--bind 127.0.0.1` and tunnel).
