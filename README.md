# Circlo Deploy

## Live Demo

Demo link: [https://circlodemo.com](https://circlodemo.com)

For admin:

* Admin login: demo@example.com
* Admin password: 11111111

For user:

* User login: user@example.com
* User password: 11111111

Automated deployment scripts for the Circlo project.

The installation takes about 10 minutes and is divided into 2 steps to begin:

1.  Create a server and copy your server's IP address.
2.  Create a domain where you want to install Circlo, then add a type **A** DNS record, **@** pointing to your server's IP address. Also add another type **A** DNS record, **\*** pointing to your server's IP address.

## Quick Start (Remote Server)

To set up the environment (Docker, Git) and deploy the project on a clean Ubuntu/Debian server, run:

We recommend using instances with at least 4 GB of memory; for example, we tested on:

1. DigitalOcean: 4 GB Memory / 2 Intel vCPUs / 120 GB Disk
2. Hetzner: CX33 | x86 | 80 GB (8GB memory) - **we recommend**

```bash
curl -sSL https://raw.githubusercontent.com/elementarlabsdev/circlo-deploy/main/setup.sh | bash
```

This script will:
1.  Update the system and install Docker & Git.
2.  Clone this repository to `circlo-deploy`.
3.  Generate secure random passwords for `.env`.
4.  Provide instructions to start the containers.

## Manual Installation

Before proceeding, ensure you have the following installed:
- **Git**
- **Docker**
- **Docker Compose**

### Installing Prerequisites (Ubuntu/Debian)

If you need to install these tools manually:

1.  **Install Git:**
    ```bash
    sudo apt update && sudo apt install -y git
    ```

2.  **Install Docker & Docker Compose V2:**
    ```bash
    # Add Docker's official GPG key:
    sudo apt-get update
    sudo apt-get install ca-certificates curl gnupg
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    # Add the repository to Apt sources:
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update

    # Install Docker packages:
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    ```

3.  **Manage Docker as a non-root user (optional):**
    ```bash
    sudo usermod -aG docker $USER
    # Log out and log back in for changes to take effect.
    ```

### Project Deployment

1.  **Clone the repository:**
    ```bash
    git clone https://github.com/elementarlabsdev/circlo-deploy.git
    cd circlo-deploy
    ```

2.  **Run the installation script:**
    ```bash
    ./install.sh
    ```
    This script will:
    - Create `.env` from `.env.example` if it doesn't exist.
    - Generate random secrets for JWT and database passwords.
    - Ask for configuration (Domain, Locale, Email).
    - Pull images and start the stack.

## Updating

To update the project to the latest version and apply migrations:

```bash
./update.sh
```

## Management

-   **View logs:** `docker compose logs -f`
-   **Stop the stack:** `docker compose down`
-   **Start the stack:** `docker compose up -d`
-   **Check status:** `docker compose ps`

## Environment Configuration

Configuration is stored in the `.env` file. Key variables:

-   `DOMAIN`: Your domain name (e.g., `example.com`).
-   `CERT_MAIL`: Email for SSL certificate (Caddy).
-   `LOCALE`: System language (`en`, `pl`, etc.).
-   `JWT_SECRET`, `REDIS_PASSWORD`, `POSTGRES_PASSWORD`, `CAP_ADMIN_KEY`: Generated automatically.
