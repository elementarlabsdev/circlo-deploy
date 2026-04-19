#!/usr/bin/env bash
set -euo pipefail

# Circlo run script: pulls and starts the stack via Docker Compose
# Usage:
#   ./install.sh                 # pull and start in detached mode
#   ./install.sh logs            # follow logs after start

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

# Detect docker compose command
if command -v docker &>/dev/null && docker compose version &>/dev/null; then
  COMPOSE_CMD=(docker compose -f docker-compose.yml)
elif command -v docker-compose &>/dev/null; then
  COMPOSE_CMD=(docker-compose -f docker-compose.yml)
else
  echo "Error: docker compose (or docker-compose) not found. Please install Docker Desktop or docker-compose." >&2
  exit 1
fi

# Ensure Docker is running (best-effort)
if ! docker info >/dev/null 2>&1; then
  echo "Error: Docker daemon doesn't seem to be running." >&2
  exit 1
fi

# Ensure .env exists (required for configuration)
if [[ ! -f .env ]]; then
  if [[ -f .env.example ]]; then
    echo "Creating .env from .env.example..."
    cp .env.example .env
  else
    echo "Error: .env and .env.example files not found in project root ($(pwd))." >&2
    echo "Please create a .env file with required environment variables." >&2
    exit 1
  fi
fi

# Ask for configuration values
# These are only asked if not already set to something other than defaults
read_config() {
  local var_name=$1
  local prompt_text=$2
  local default_val=$3

  local current_val=$(grep "^${var_name}=" .env | cut -d'=' -f2- || true)

  # Only prompt if current value is default or empty
  if [[ -z "$current_val" ]] || [[ "$current_val" == "$default_val" ]]; then
    read -rp "$prompt_text [$current_val]: " input
    if [[ -n "$input" ]]; then
      if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "s/^${var_name}=.*/${var_name}=${input}/" .env
      else
        sed -i "s/^${var_name}=.*/${var_name}=${input}/" .env
      fi
    fi
  fi
}

read_config "LOCALE" "Enter locale (e.g. en, es, de)" "en"
read_config "DOMAIN" "Enter domain (e.g. example.com)" "example.loc"
read_config "CERT_MAIL" "Enter certificate email" "admin@example.com"

# Function to generate a random secret
generate_secret() {
  LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 32 || true
}

# Function to update or set a variable in .env
update_env_var() {
  local var_name=$1
  local default_vals=("secret" "password" "")
  local current_val=$(grep "^${var_name}=" .env | cut -d'=' -f2- || true)

  # Check if the current value is one of the "insecure" defaults or empty
  local is_default=false
  for def in "${default_vals[@]}"; do
    if [[ "$current_val" == "$def" ]]; then
      is_default=true
      break
    fi
  done

  # For updates, only generate if it's a default value or empty.
  if [[ "$is_default" == true ]]; then
    local new_val=$(generate_secret)
    echo "Generating new value for $var_name..."
    if grep -q "^${var_name}=" .env; then
      # Update existing
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
  sed -i '' "s/redis:\/\/:password@redis:6379/redis:\/\/:${RD_PASS}@redis:6379/" .env
else
  sed -i "s/postgresql:\/\/postgres:password@database:5432\/circlo/postgresql:\/\/postgres:${PG_PASS}@database:5432\/circlo/" .env
  sed -i "s/redis:\/\/:password@redis:6379/redis:\/\/:${RD_PASS}@redis:6379/" .env
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
  "CERT_MAIL"
  "DATABASE_URL"
  "REDIS_URL"
  "CAP_ADMIN_KEY"
)

missing_vars=()
for var in "${REQUIRED_VARS[@]}"; do
  # Read value from .env or environment
  # We use grep/sed to read from .env because the script might not have exported them yet
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

follow_logs=false
if [[ ${1:-} == "logs" ]]; then
  follow_logs=true
fi

# Pull images
echo "Pulling latest images from registry ..."
"${COMPOSE_CMD[@]}" pull

# Start stack
echo "Starting containers in detached mode ..."

# Ensure data directories exist with proper permissions (to avoid SQLite SQLITE_CANTOPEN errors)
mkdir -p ./data/redis ./data/db ./data/cap ./data/caddy/data ./data/caddy/config ./data/public
chmod -R 777 ./data # Simplest for cross-platform/docker setups, or use specific UID if known

"${COMPOSE_CMD[@]}" up -d

# Show status
"${COMPOSE_CMD[@]}" ps

if [[ "$follow_logs" == true ]]; then
  echo "Following logs (Ctrl+C to stop tailing, containers keep running) ..."
  "${COMPOSE_CMD[@]}" logs -f
else
  echo "Stack is up. Visit: http://localhost"
  echo "Use: ${COMPOSE_CMD[*]} logs -f  to follow logs"
fi
