#!/usr/bin/env bash

set -euo pipefail

# Circlo update script: pulls latest code, pulls pre-built images, runs migrations, and restarts the stack
# Usage:
#   ./update.sh                 # standard update flow
#   ./update.sh no-git          # skip git pull (e.g., when using volume bind to different source)

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

# Detect docker compose command
if command -v docker &>/dev/null && docker compose version &>/dev/null; then
  COMPOSE_CMD=(docker compose -f docker-compose.yml)
elif command -v docker-compose &>/dev/null; then
  COMPOSE_CMD=(docker-compose -f docker-compose.yml)
else
  echo "Error: docker compose (or docker-compose) not found." >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "Error: Docker daemon doesn't seem to be running." >&2
  exit 1
fi

# Ensure .env exists (required for configuration)
if [[ ! -f .env ]]; then
  echo "Error: .env file not found in project root ($(pwd))." >&2
  if [[ -f .env.example ]]; then
    echo "Hint: copy .env.example to .env and adjust values." >&2
  else
    echo "Please create a .env file with required environment variables." >&2
  fi
  exit 1
fi

# Function to generate a random secret
generate_secret() {
  LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 32 || true
}

# Function to update or set a variable in .env
update_env_var() {
  local var_name=$1
  local current_val=$(grep "^${var_name}=" .env | cut -d'=' -f2- || true)

  # For updates, only generate if it's completely missing or empty.
  # Do not change existing passwords even if they are "insecure" defaults,
  # as changing them will break connection to existing databases/redis.
  if [[ -z "$current_val" ]]; then
    local new_val=$(generate_secret)
    echo "Generating new value for $var_name..."
    if grep -q "^${var_name}=" .env; then
      # Update existing empty
      if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "s/^${var_name}=.*/${var_name}=${new_val}/" .env
      else
        sed -i "s/^${var_name}=.*/${var_name}=${new_val}/" .env
      fi
    else
      # Append new
      echo "${var_name}=${new_val}" >> .env
    fi
  fi
}

# Update security keys if needed
update_env_var "JWT_SECRET"
update_env_var "REDIS_PASSWORD"
update_env_var "POSTGRES_PASSWORD"
update_env_var "CAP_ADMIN_KEY"

# Special case for DATABASE_URL and REDIS_URL if they contain default passwords
# This only runs if the password was just updated from empty to something else
# OR if the user manually changed passwords but didn't update the URLs.
# For safety, we only replace if it exactly matches the default pattern with "password".
PG_PASS=$(grep '^POSTGRES_PASSWORD=' .env | cut -d'=' -f2-)
RD_PASS=$(grep '^REDIS_PASSWORD=' .env | cut -d'=' -f2-)

if [[ "$(uname)" == "Darwin" ]]; then
  sed -i '' "s/postgresql:\/\/postgres:password@database:5432\/circlo/postgresql:\/\/postgres:${PG_PASS}@database:5432\/circlo/" .env
  sed -i '' "s/redis:\/\/default:password@redis:6379/redis:\/\/default:${RD_PASS}@redis:6379/" .env
else
  sed -i "s/postgresql:\/\/postgres:password@database:5432\/circlo/postgresql:\/\/postgres:${PG_PASS}@database:5432\/circlo/" .env
  sed -i "s/redis:\/\/default:password@redis:6379/redis:\/\/default:${RD_PASS}@redis:6379/" .env
fi

# Check and fix Redis memory overcommit (Linux only)
if [[ "$(uname)" == "Linux" ]]; then
  if [[ -f /proc/sys/vm/overcommit_memory ]] && [[ $(cat /proc/sys/vm/overcommit_memory) != "1" ]]; then
    echo "Fixing Redis memory overcommit (requires sudo)..."
    sudo sysctl vm.overcommit_memory=1
    if ! grep -q "vm.overcommit_memory" /etc/sysctl.conf; then
      echo 'vm.overcommit_memory = 1' | sudo tee -a /etc/sysctl.conf > /dev/null
    else
      sudo sed -i 's/^#*vm.overcommit_memory.*/vm.overcommit_memory = 1/' /etc/sysctl.conf
    fi
    echo "Redis memory overcommit fixed."
    echo ""
  fi
fi

# Load .env notice (docker compose will read it automatically)
echo "Using environment from .env"

# Validate required environment variables
REQUIRED_VARS=(
  "REDIS_PASSWORD"
  "POSTGRES_DB"
  "POSTGRES_USER"
  "POSTGRES_PASSWORD"
  "JWT_SECRET"
  "DOMAIN"
  "DATABASE_URL"
  "REDIS_URL"
  "CAP_ADMIN_KEY"
)

missing_vars=()
for var in "${REQUIRED_VARS[@]}"; do
  val=$(grep "^${var}=" .env | cut -d'=' -f2- || true)
  if [[ -z "$val" ]]; then
    missing_vars+=("$var")
  fi
done

if [[ ${#missing_vars[@]} -gt 0 ]]; then
  echo "Error: The following mandatory environment variables are missing or empty in .env:" >&2
  for var in "${missing_vars[@]}"; do
    echo "  - $var" >&2
  done
  exit 1
fi

MODE="standard"
if [[ ${1:-} == "no-git" ]]; then
  MODE="no-git"
fi

# 1) Pull latest code (if repo and not skipped)
if [[ "$MODE" != "no-git" ]] && command -v git &>/dev/null && [[ -d .git ]]; then
  echo "Fetching latest changes ..."
  git fetch --all --prune
  echo "Pulling ..."
  git pull --rebase --autostash
  # If submodules are present
  if git config --file .gitmodules --get-regexp path >/dev/null 2>&1; then
    git submodule update --init --recursive
    git submodule foreach --recursive git pull origin HEAD || true
  fi
else
  echo "Skipping git pull (mode: $MODE or not a git repo)."
fi

# 2) Pull latest images
echo "Pulling latest images from registry ..."
"${COMPOSE_CMD[@]}" pull

# 3) Apply database migrations if Prisma is used
# We'll run prisma migrate deploy in the api container context.
echo "Starting dependent services to run migrations ..."

# Ensure data directories exist with proper permissions (to avoid SQLite SQLITE_CANTOPEN errors)
mkdir -p ./data/redis ./data/db ./data/cap ./data/caddy/data ./data/caddy/config ./data/public
chmod -R 777 ./data # Simplest for cross-platform/docker setups

"${COMPOSE_CMD[@]}" up -d database redis

# Give DB a moment if needed
sleep 2 || true

# Ensure api image is built for running prisma
"${COMPOSE_CMD[@]}" up -d --no-deps api

echo "Running Prisma migrations (if any) ..."
# Try several common npm/yarn/pnpm invocations
if "${COMPOSE_CMD[@]}" exec -T api npx prisma migrate deploy 2>/dev/null; then
  echo "Prisma migrations applied."
elif "${COMPOSE_CMD[@]}" exec -T api npm run prisma:migrate --silent 2>/dev/null; then
  echo "Prisma migrations applied via npm script."
else
  echo "Note: Prisma migrate command not found or not needed. Skipping."
fi

# 4) Restart full stack with updated images
echo "Restarting stack ..."
"${COMPOSE_CMD[@]}" up -d

# 5) Optional: remove dangling images (safe)
if command -v docker &>/dev/null; then
  docker image prune -f >/dev/null 2>&1 || true
fi

# 6) Show status and recent logs for critical services
"${COMPOSE_CMD[@]}" ps

echo "Recent logs (api and webserver):"
"${COMPOSE_CMD[@]}" logs --since=5m api webserver || true

echo "Update complete. Visit: http://localhost"
