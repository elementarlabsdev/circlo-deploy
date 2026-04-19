#!/bin/bash

# Environment setup script for the circlo-deploy project
# Run: curl -sSL https://raw.githubusercontent.com/elementarlabsdev/circlo-deploy/main/setup.sh | bash

set -e

REPO_URL="https://github.com/elementarlabsdev/circlo-deploy.git"
INSTALL_DIR="circlo-deploy"

# 1. Update and install necessary packages
echo "--- Updating system and installing dependencies ---"
sudo apt-get update
sudo apt-get install -y git curl apt-transport-https ca-certificates gnupg lsb-release

# 2. Install Docker (if not installed)
if ! command -v docker &> /dev/null; then
    echo "--- Installing Docker ---"
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi

# 3. Clone repository
echo "--- Cloning project ---"
if [ -d "$INSTALL_DIR" ]; then
    echo "Directory $INSTALL_DIR already exists. Updating..."
    cd "$INSTALL_DIR"
    git pull
else
    git clone "$REPO_URL" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
fi

# 4. Setup .env
echo "--- Setting up .env ---"
if [ ! -f .env ]; then
    cp .env.example .env
fi

# Password generation function (minimum 20 characters, no special characters)
generate_password() {
    # [a-zA-Z0-9]
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32
}

JWT_SECRET=$(generate_password)
REDIS_PASSWORD=$(generate_password)
POSTGRES_PASSWORD=$(generate_password)
CAP_ADMIN_KEY=$(generate_password)

# Replace values in .env
# We use sed to update values.
# .env.example also contains REDIS_URL and DATABASE_URL which have old passwords.
# We will update them entirely or replace passwords within them.

sed -i "s/^JWT_SECRET=.*/JWT_SECRET=$JWT_SECRET/" .env
sed -i "s/^REDIS_PASSWORD=.*/REDIS_PASSWORD=$REDIS_PASSWORD/" .env
sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$POSTGRES_PASSWORD/" .env
sed -i "s/^CAP_ADMIN_KEY=.*/CAP_ADMIN_KEY=$CAP_ADMIN_KEY/" .env

# Update URLs if they are present
sed -i "s|redis://:.*@redis:6379|redis://:$REDIS_PASSWORD@redis:6379|" .env
sed -i "s|postgresql://postgres:.*@database:5432/circlo|postgresql://postgres:$POSTGRES_PASSWORD@database:5432/circlo|" .env

echo "--- Installation completed ---"
echo "Project cloned into directory: $INSTALL_DIR"
echo ".env configuration file created and populated with random passwords."
echo "You can now start the project using the command: docker compose up -d"
