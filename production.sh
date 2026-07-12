#!/usr/bin/env bash
# =============================================================================
# ContentDM — one-shot production installer / launcher (zero interaction)
#
# Put this script next to a contentdm-prod-<tag>[-linux-<arch>].tar.gz and run:
#   bash production.sh
#
# It will: find the archive, load the images, generate compose + nginx + .env
# (fresh random secrets, kept across re-runs), start the stack, wait until
# healthy, and print the URL + admin credentials. Re-running is safe and is
# also how you upgrade to a newer archive.
#
# Subcommands:  production.sh [up|stop|down|restart|logs|status]   (default: up)
# Options:      --port N (default 8080)  --bind ADDR (default 0.0.0.0)
#               --tar PATH  --tag TAG  --reload  --force-env
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

PROJECT="contentdm-prod"
CMD="up"
TAR_PATH=""
TAG="${CDM_TAG:-}"
PORT="${CDM_PORT:-}"
BIND="${CDM_HTTP_BIND:-}"
RELOAD=0
FORCE_ENV=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    up|stop|down|restart|logs|status) CMD="$1"; shift ;;
    --tar)       TAR_PATH="${2:?--tar requires a path}"; shift 2 ;;
    --tag)       TAG="${2:?--tag requires a value}"; shift 2 ;;
    --port)      PORT="${2:?--port requires a number}"; shift 2 ;;
    --bind)      BIND="${2:?--bind requires an address}"; shift 2 ;;
    --reload)    RELOAD=1; shift ;;
    --force-env) FORCE_ENV=1; shift ;;
    -h|--help)   sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $1 (see --help)" >&2; exit 1 ;;
  esac
done

log()  { printf '\033[1m▶ %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m✔ %s\033[0m\n' "$*"; }
die()  { printf '\033[31m✘ %s\033[0m\n' "$*" >&2; exit 1; }

compose() { docker compose -p "${PROJECT}" -f "${SCRIPT_DIR}/docker-compose.yml" "$@"; }

rand_hex() {
  if command -v openssl >/dev/null 2>&1; then openssl rand -hex "$1"
  else od -vN "$1" -An -tx1 /dev/urandom | tr -d ' \n'; fi
}

# ---------------------------------------------------------------------------
# Docker availability (auto-start where possible, never prompt)
# ---------------------------------------------------------------------------
ensure_docker() {
  command -v docker >/dev/null 2>&1 || die "Docker is not installed. Install Docker Engine / Docker Desktop first."
  if docker info >/dev/null 2>&1; then return 0; fi
  case "$(uname -s)" in
    Darwin)
      log "Docker daemon not running — starting Docker Desktop..."
      open -a Docker || die "Could not start Docker Desktop."
      ;;
    Linux)
      if [[ "$(id -u)" -eq 0 ]] && command -v systemctl >/dev/null 2>&1; then
        log "Docker daemon not running — starting via systemctl..."
        systemctl start docker || die "Could not start the Docker service."
      else
        die "Docker daemon is not running. Start it (e.g. 'sudo systemctl start docker') and re-run."
      fi
      ;;
  esac
  for _ in $(seq 1 60); do
    docker info >/dev/null 2>&1 && return 0
    sleep 2
  done
  die "Docker daemon did not become ready within 120s."
}

# ---------------------------------------------------------------------------
# Fast paths for lifecycle subcommands
# ---------------------------------------------------------------------------
if [[ "${CMD}" != "up" ]]; then
  ensure_docker
  [[ -f "${SCRIPT_DIR}/docker-compose.yml" ]] || die "No install found here — run 'bash production.sh' first."
  case "${CMD}" in
    stop)    compose stop; ok "Stack stopped (data kept). Start again with: bash production.sh" ;;
    down)    compose down; ok "Stack removed (volumes/data kept)." ;;
    restart) compose restart; ok "Stack restarted." ;;
    logs)    compose logs -f ;;
    status)  compose ps ;;
  esac
  exit 0
fi

ensure_docker

# ---------------------------------------------------------------------------
# Locate archive + tag
# ---------------------------------------------------------------------------
detect_plat() {
  local arch
  arch="$(docker version --format '{{.Server.Arch}}' 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  case "${arch:-$(uname -m)}" in
    amd64|x86_64)   echo "linux-amd64" ;;
    arm64|aarch64)  echo "linux-arm64" ;;
    *)              echo "" ;;
  esac
}
PLAT="$(detect_plat)"

if [[ -z "${TAR_PATH}" ]]; then
  if [[ -n "${PLAT}" ]]; then
    TAR_PATH="$(ls -t contentdm-prod-*-"${PLAT}".tar.gz 2>/dev/null | head -1 || true)"
  fi
  [[ -n "${TAR_PATH}" ]] || TAR_PATH="$(ls -t contentdm-prod-*.tar.gz 2>/dev/null | grep -v -- '-linux-' | head -1 || true)"
  [[ -n "${TAR_PATH}" ]] || TAR_PATH="$(ls -t contentdm-prod-*.tar.gz 2>/dev/null | head -1 || true)"
fi

if [[ -z "${TAG}" ]]; then
  if [[ -n "${TAR_PATH}" ]]; then
    TAG="$(basename "${TAR_PATH}")"
    TAG="${TAG#contentdm-prod-}"; TAG="${TAG%.tar.gz}"
    TAG="${TAG%-linux-amd64}"; TAG="${TAG%-linux-arm64}"
  else
    die "No contentdm-prod-*.tar.gz found next to this script (and no --tar/--tag given)."
  fi
fi

if [[ -n "${TAR_PATH}" && -n "${PLAT}" ]]; then
  base="$(basename "${TAR_PATH}")"
  for p in linux-amd64 linux-arm64; do
    if [[ "${base}" == *"-${p}.tar.gz" && "${p}" != "${PLAT}" ]]; then
      die "Archive is ${p} but this host is ${PLAT}. Use the matching archive."
    fi
  done
fi

# ---------------------------------------------------------------------------
# Load images (skipped when already present, unless --reload)
# ---------------------------------------------------------------------------
have_all_images() {
  local i
  for i in api worker frontend; do
    docker image inspect "contentdm-${i}:${TAG}" >/dev/null 2>&1 || return 1
  done
}

if [[ "${RELOAD}" -eq 0 ]] && have_all_images; then
  ok "Images contentdm-{api,worker,frontend}:${TAG} already loaded."
else
  [[ -n "${TAR_PATH}" && -f "${TAR_PATH}" ]] || die "Images for tag ${TAG} not loaded and no archive found."
  log "Loading images from ${TAR_PATH} (this can take a few minutes)..."
  gunzip -c "${TAR_PATH}" | docker load
  have_all_images || die "Archive did not contain contentdm-{api,worker,frontend}:${TAG}."
  ok "Images loaded."
fi

# ---------------------------------------------------------------------------
# Generate .env (secrets survive re-runs; regenerating breaks encrypted data)
# ---------------------------------------------------------------------------
ENV_FILE="${SCRIPT_DIR}/.env"
if [[ -f "${ENV_FILE}" && "${FORCE_ENV}" -eq 0 ]]; then
  ok "Keeping existing .env (secrets preserved; --force-env to regenerate)."
else
  [[ -f "${ENV_FILE}" ]] && log "Regenerating .env — if a database volume already exists, run 'production.sh down' and remove volumes first."
  DB_PW="$(rand_hex 24)"
  (
    umask 077
    cat > "${ENV_FILE}" <<EOF
# Generated by production.sh — do not commit, do not regenerate casually:
# SECRET_KEY/JWT_SECRET/ENCRYPTION_SALT protect sessions and encrypted
# XSIAM tenant API keys; changing them invalidates existing data.
ENVIRONMENT=production
TAG=${TAG}
CDM_PORT=${PORT:-8080}
CDM_HTTP_BIND=${BIND:-0.0.0.0}

DB_HOST=postgres
DB_PORT=5432
DB_NAME=contentdm_db
DB_USER=contentdm_db
DB_PASSWORD=${DB_PW}

REDIS_HOST=redis
REDIS_PORT=6379
REDIS_PASSWORD=$(rand_hex 24)

SECRET_KEY=$(rand_hex 32)
JWT_SECRET=$(rand_hex 32)
ENCRYPTION_SALT=$(rand_hex 16)

BOOTSTRAP_ADMIN_PASSWORD=$(rand_hex 12)
EOF
  )
  ok "Wrote .env with fresh random secrets (mode 0600)."
fi

# Keep TAG/PORT/BIND in .env current without touching secrets.
update_env_var() {
  local key="$1" value="$2" tmp
  tmp="${ENV_FILE}.tmp.$$"
  ( umask 077; grep -v "^${key}=" "${ENV_FILE}" > "${tmp}" || true
    printf '%s=%s\n' "${key}" "${value}" >> "${tmp}" )
  mv "${tmp}" "${ENV_FILE}"; chmod 0600 "${ENV_FILE}"
}
update_env_var TAG "${TAG}"
[[ -n "${PORT}" ]] && update_env_var CDM_PORT "${PORT}"
[[ -n "${BIND}" ]] && update_env_var CDM_HTTP_BIND "${BIND}"
PORT="$(grep '^CDM_PORT=' "${ENV_FILE}" | tail -1 | cut -d= -f2)"

# ---------------------------------------------------------------------------
# Generate nginx config + compose file
# ---------------------------------------------------------------------------
mkdir -p "${SCRIPT_DIR}/nginx"
cat > "${SCRIPT_DIR}/nginx/default.conf" <<'NGINX'
upstream api_backend { server api:8000; keepalive 32; }
upstream frontend_app { server frontend:3000; keepalive 16; }

limit_req_zone $binary_remote_addr zone=api_limit:10m rate=30r/s;
limit_req_zone $binary_remote_addr zone=auth_limit:10m rate=5r/s;

server {
    listen 80;
    listen [::]:80;
    server_name _;
    server_tokens off;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=(), display-capture=()" always;
    add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; img-src 'self' data: blob:; font-src 'self' data: https://fonts.gstatic.com https://fonts.googleapis.com; connect-src 'self'; frame-ancestors 'self'; base-uri 'self'; form-action 'self';" always;
    add_header X-DNS-Prefetch-Control "off" always;
    add_header Cross-Origin-Opener-Policy "same-origin" always;
    add_header Cross-Origin-Resource-Policy "same-origin" always;

    location ~* \.(py|pyc|pyo|pyd|so|map|ts|tsx|jsx|env|git|sql|log|bak|swp)$ { return 404; }
    location ~ /\. { return 404; }

    proxy_hide_header X-Powered-By;
    proxy_hide_header Server;

    client_max_body_size 50M;
    client_body_timeout 30s;
    client_header_timeout 30s;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml text/javascript image/svg+xml;

    location = /health {
        access_log off;
        proxy_pass http://api_backend/health;
    }

    location = /api/v1/auth/login {
        limit_req zone=auth_limit burst=5 nodelay;
        proxy_pass http://api_backend/api/v1/auth/login;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection "";
        proxy_connect_timeout 10s;
        proxy_send_timeout 10s;
        proxy_read_timeout 10s;
    }

    location = /api/v1/auth/register {
        limit_req zone=auth_limit burst=5 nodelay;
        proxy_pass http://api_backend/api/v1/auth/register;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection "";
        proxy_connect_timeout 10s;
        proxy_send_timeout 10s;
        proxy_read_timeout 10s;
    }

    location ~ ^/api/v1/(alerts/sync|content/cache/sync|content/sync/execute|logs/download) {
        limit_req zone=api_limit burst=10 nodelay;
        proxy_pass http://api_backend;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection "";
        proxy_connect_timeout 10s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
        proxy_buffering off;
    }

    location /api/ {
        limit_req zone=api_limit burst=50 nodelay;
        proxy_pass http://api_backend/api/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection "";
        proxy_connect_timeout 10s;
        proxy_send_timeout 30s;
        proxy_read_timeout 60s;
        proxy_buffering off;
    }

    location /_next/static/ {
        proxy_pass http://frontend_app;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        add_header Cache-Control "public, max-age=31536000, immutable";
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header Referrer-Policy "strict-origin-when-cross-origin" always;
        add_header Cross-Origin-Opener-Policy "same-origin" always;
        add_header Cross-Origin-Resource-Policy "same-origin" always;
    }

    location / {
        proxy_pass http://frontend_app;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    access_log /var/log/nginx/access.log combined buffer=16k flush=5s;
    error_log /var/log/nginx/error.log warn;
}
NGINX

cat > "${SCRIPT_DIR}/docker-compose.yml" <<'COMPOSE'
# Generated by production.sh — ContentDM production stack (tarball images).
name: contentdm-prod

services:
  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${DB_USER}
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_DB: ${DB_NAME}
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_USER}"]
      interval: 5s
      timeout: 3s
      retries: 10
      start_period: 10s
    networks: [internal]

  redis:
    image: redis:7-alpine
    restart: unless-stopped
    command: >
      redis-server
      --requirepass ${REDIS_PASSWORD}
      --appendonly yes
      --maxmemory 1gb
      --maxmemory-policy allkeys-lru
      --save 300 100
      --rename-command DEBUG ""
      --rename-command FLUSHALL ""
      --rename-command FLUSHDB ""
    volumes:
      - redisdata:/data
    read_only: true
    tmpfs:
      - /tmp:size=64M
    healthcheck:
      test: ["CMD-SHELL", "REDISCLI_AUTH=$${REDIS_PASSWORD} redis-cli ping"]
      interval: 5s
      timeout: 3s
      retries: 10
      start_period: 5s
    networks: [internal]

  api:
    image: contentdm-api:${TAG}
    restart: unless-stopped
    env_file: .env
    environment:
      ENVIRONMENT: production
    security_opt:
      - no-new-privileges:true
    tmpfs:
      - /tmp:size=256M
      - /tmp/app:size=64M
      - /app/logs:size=128M,uid=999,gid=999
    volumes:
      - cdm-settings:/app/settings
      - cdm-uploads:/app/uploads
    depends_on:
      postgres: { condition: service_healthy }
      redis: { condition: service_healthy }
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 15s
    networks: [internal]

  worker:
    image: contentdm-worker:${TAG}
    restart: unless-stopped
    env_file: .env
    environment:
      ENVIRONMENT: production
    security_opt:
      - no-new-privileges:true
    tmpfs:
      - /tmp:size=512M
      - /tmp/app:size=128M
      - /app/logs:size=128M,uid=999,gid=999
    volumes:
      - cdm-settings:/app/settings
      - cdm-uploads:/app/uploads
    depends_on:
      postgres: { condition: service_healthy }
      redis: { condition: service_healthy }
    networks: [internal]

  beat:
    image: contentdm-worker:${TAG}
    restart: unless-stopped
    env_file: .env
    environment:
      ENVIRONMENT: production
    command: ["python", "-O", "-m", "celery", "-A", "worker.app", "beat",
              "--loglevel=info", "--schedule=/tmp/celerybeat-schedule"]
    security_opt:
      - no-new-privileges:true
    read_only: true
    tmpfs:
      - /tmp:size=64M
    volumes:
      - cdm-settings:/app/settings
    depends_on:
      postgres: { condition: service_healthy }
      redis: { condition: service_healthy }
    networks: [internal]

  frontend:
    image: contentdm-frontend:${TAG}
    restart: unless-stopped
    environment:
      NEXT_PUBLIC_API_URL: ""
    security_opt:
      - no-new-privileges:true
    read_only: true
    tmpfs:
      - /tmp:size=64M
    depends_on:
      - api
    networks: [internal]

  nginx:
    image: nginx:alpine
    restart: unless-stopped
    ports:
      - "${CDM_HTTP_BIND:-0.0.0.0}:${CDM_PORT:-8080}:80"
    volumes:
      - ./nginx/default.conf:/etc/nginx/conf.d/default.conf:ro
    read_only: true
    tmpfs:
      - /tmp:size=32M
      - /var/cache/nginx:size=64M
      - /var/run:size=1M
    security_opt:
      - no-new-privileges:true
    depends_on:
      api: { condition: service_healthy }
      frontend: { condition: service_started }
    healthcheck:
      test: ["CMD-SHELL", "curl -fs http://localhost/health || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
    networks: [internal]

volumes:
  pgdata:
  redisdata:
  cdm-settings:
  cdm-uploads:

networks:
  internal:
    driver: bridge
COMPOSE

# ---------------------------------------------------------------------------
# Start + wait for health
# ---------------------------------------------------------------------------
log "Starting ContentDM (tag ${TAG}, port ${PORT})..."
compose --env-file "${ENV_FILE}" up -d

log "Waiting for the stack to become healthy..."
DEADLINE=$(( $(date +%s) + 300 ))
until curl -fs "http://localhost:${PORT}/health" >/dev/null 2>&1; do
  if [[ $(date +%s) -ge ${DEADLINE} ]]; then
    echo "" >&2
    compose ps >&2 || true
    die "Stack did not become healthy within 5 minutes. Inspect with: bash production.sh logs"
  fi
  sleep 3
done

ADMIN_PW="$(grep '^BOOTSTRAP_ADMIN_PASSWORD=' "${ENV_FILE}" | tail -1 | cut -d= -f2)"
echo ""
ok "ContentDM is up."
echo ""
echo "   Dashboard:  http://localhost:${PORT}"
echo "   Login:      admin / ${ADMIN_PW}"
echo "               (change it after first login; it is also stored in ${ENV_FILE})"
echo ""
echo "   Status:     bash production.sh status"
echo "   Logs:       bash production.sh logs"
echo "   Stop:       bash production.sh stop"
