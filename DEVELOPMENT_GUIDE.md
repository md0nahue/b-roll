# Dockerized Development Environment Guide for Jules

This guide explains how to set up and use the Dockerized development environment for this application. Docker provides a consistent and isolated environment for development, ensuring all dependencies are managed.

## Prerequisites

*   **Docker Desktop:** Install Docker Desktop (which includes Docker Engine and Docker Compose) from [https://www.docker.com/products/docker-desktop](https://www.docker.com/products/docker-desktop).
*   **Git:** For cloning the repository.

## Initial Setup

1.  **Clone the Repository:**
    ```bash
    git clone <repository_url>
    cd <repository_directory>
    ```

2.  **Environment Variables (.env file - Optional but Recommended):**
    While many configuration variables are set in `docker-compose.yml` with defaults, you might need to provide sensitive credentials (e.g., for external services like AWS S3, Google/GitHub OmniAuth) or override defaults.

    Create a `.env` file in the project root (it's included in `.gitignore` and `.dockerignore`):
    ```bash
    touch .env
    ```

    Add necessary variables to your `.env` file. `docker-compose.yml` is configured to load it if it exists (`env_file: .env`). Here are some examples of variables you might need, especially if you plan to test features using these services:

    ```env
    # .env example (use your actual or dummy development keys)

    # For PostgreSQL (these override defaults in docker-compose.yml if needed, but usually not necessary)
    # POSTGRES_DB=jules_dev_db
    # POSTGRES_USER=jules_user
    # POSTGRES_PASSWORD=jules_password

    # For Active Storage with AWS S3 (if you use S3 in development)
    # AWS_ACCESS_KEY_ID=your_dev_access_key_id
    # AWS_SECRET_ACCESS_KEY=your_dev_secret_access_key
    # AWS_REGION=your_dev_aws_region
    # AWS_S3_BUCKET=your_dev_s3_bucket_name

    # For OmniAuth Google
    # GOOGLE_CLIENT_ID=your_dev_google_client_id
    # GOOGLE_CLIENT_SECRET=your_dev_google_client_secret

    # For OmniAuth GitHub
    # GITHUB_CLIENT_ID=your_dev_github_client_id
    # GITHUB_CLIENT_SECRET=your_dev_github_client_secret
    ```
    **Note:** For local development without connecting to actual external services, you can often use dummy values or ensure the application handles their absence gracefully. The `docker-compose.yml` already has placeholders commented out.

## Building and Running the Environment

1.  **Build the Docker Images:**
    This command builds the `app` service image based on `Dockerfile.dev`.
    ```bash
    docker-compose build
    ```
    This might take some time on the first run as it downloads base images and installs dependencies.

2.  **Start the Services:**
    This command starts the `app` and `db` services.
    ```bash
    docker-compose up
    ```
    You should see logs from the Rails application and PostgreSQL database. The Rails app will be accessible at [http://localhost:3000](http://localhost:3000).

3.  **Stopping the Services:**
    To stop the services, press `Ctrl+C` in the terminal where `docker-compose up` is running. Then, to ensure they are fully stopped and remove the containers (but not persistent volumes):
    ```bash
    docker-compose down
    ```
    To stop and remove volumes (e.g., to reset the database):
    ```bash
    docker-compose down -v
    ```

## Common Development Tasks

All `docker-compose exec app` commands should be run from your project root in a separate terminal window while the services are running (`docker-compose up`).

*   **Database Setup (First time or if reset):**
    The `docker-entrypoint` script attempts to run `bin/rails db:prepare` on server start. If you need to do this manually or seed data:
    ```bash
    docker-compose exec app bin/rails db:create  # If not already created by entrypoint
    docker-compose exec app bin/rails db:migrate
    docker-compose exec app bin/rails db:seed    # If you have a seeds.rb file
    ```
    Alternatively, `db:prepare` handles create, migrate, and setup if needed:
    ```bash
    docker-compose exec app bin/rails db:prepare
    ```

*   **Running Tests:**
    ```bash
    # Run all tests
    docker-compose exec app bin/rails test

    # Run system tests (ensure your Dockerfile.dev has headless browser dependencies if needed)
    docker-compose exec app bin/rails test:system

    # Run a specific test file
    docker-compose exec app bin/rails test test/models/user_test.rb
    ```

*   **Rails Console:**
    ```bash
    docker-compose exec app bin/rails console
    ```

*   **Viewing Logs:**
    ```bash
    # View logs for all services (follow mode)
    docker-compose logs -f

    # View logs for a specific service (e.g., app)
    docker-compose logs -f app
    ```

*   **Connecting to the Database (from host):**
    The PostgreSQL port `5432` is mapped to the host in `docker-compose.yml`. You can use any SQL client to connect with the following details (matching `docker-compose.yml` or your `.env`):
    *   Host: `localhost`
    *   Port: `5432`
    *   User: `jules_user` (or your configured user)
    *   Password: `jules_password` (or your configured password)
    *   Database: `jules_dev_db` (or your configured database)

## Code Changes and Live Reloading

The application code in your local directory is mounted into the `app` container at `/rails`. Changes you make to your local files will be reflected immediately in the container. Rails should automatically reload most code changes in development mode. For changes that require a server restart (e.g., initializers), you might need to stop (`Ctrl+C`) and restart `docker-compose up`.

## Gem Management (Bundle Cache)

The `docker-compose.yml` defines a volume `bundle_cache` which is intended to persist installed gems. If you modify your `Gemfile` (add, remove, or update gems):
1.  Rebuild the application image to install the new gems:
    ```bash
    docker-compose build app
    ```
2.  Then restart your services:
    ```bash
    docker-compose up
    ```
    The `bundle install` step in `Dockerfile.dev` will run, and the `bundle_cache` volume helps speed this up if only minor changes were made. For `Dockerfile.dev` to effectively use this cache at `/usr/local/bundle`, it's best if `GEM_HOME` is set to this path in `Dockerfile.dev`. (This guide assumes it's configured correctly or that the default gem path is being cached).

## Troubleshooting

*   **Port Conflicts:** If port `3000` or `5432` is already in use on your host machine, `docker-compose up` will fail. You can either stop the conflicting service or change the host-side port mapping in `docker-compose.yml` (e.g., `ports: - "3001:3000"`).
*   **"Docker daemon is not running":** Ensure Docker Desktop is started.
*   **Permission Issues (Volume Mounts):** On some systems, file ownership/permissions for mounted volumes can cause issues. This is less common with Docker Desktop on Mac/Windows but can occur on Linux. Ensure your user has appropriate permissions for the project directory.
*   **Resetting the Database:**
    ```bash
    docker-compose down -v  # Stops containers and removes volumes (including database data)
    docker-compose up --build # Start fresh, rebuilding if necessary
    # Then run database setup commands.
    ```

This guide should help you get started. Happy coding!
