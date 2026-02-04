#!/bin/bash
# Giulia Thin Client Wrapper for Unix (Linux/macOS)
# This script handles Docker daemon management and path mapping

set -e

GIULIA_CONTAINER="giulia-daemon"
GIULIA_IMAGE="giulia/core:latest"
GIULIA_COOKIE="${GIULIA_COOKIE:-giulia_cluster_secret}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info() { echo -e "${CYAN}$1${NC}"; }
success() { echo -e "${GREEN}✓ $1${NC}"; }
warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
error() { echo -e "${RED}✗ $1${NC}"; }

# Check if Docker is running
check_docker() {
    if ! docker info >/dev/null 2>&1; then
        error "Docker is not running. Please start Docker."
        exit 1
    fi
}

# Check if daemon container is running
daemon_running() {
    docker ps -q -f "name=${GIULIA_CONTAINER}" | grep -q .
}

# Start the daemon container
start_daemon() {
    info "Starting Giulia daemon..."

    # Get projects path - default to parent of current directory
    PROJECTS_PATH="${GIULIA_PROJECTS_PATH:-$(dirname "$(pwd)")}"

    # Determine LM Studio URL based on OS
    if [[ "$OSTYPE" == "darwin"* ]]; then
        LM_STUDIO_URL="http://host.docker.internal:1234/v1/chat/completions"
    else
        # Linux - use host network mode or host.docker.internal
        LM_STUDIO_URL="http://host.docker.internal:1234/v1/chat/completions"
    fi

    docker run -d \
        --name "${GIULIA_CONTAINER}" \
        --hostname giulia-daemon \
        -v giulia_data:/data \
        -v "${PROJECTS_PATH}:/projects" \
        -p 4369:4369 \
        -p 9100-9105:9100-9105 \
        -e "RELEASE_NODE=giulia@giulia-daemon" \
        -e "RELEASE_COOKIE=${GIULIA_COOKIE}" \
        -e "LM_STUDIO_URL=${LM_STUDIO_URL}" \
        "${GIULIA_IMAGE}"

    if [ $? -ne 0 ]; then
        error "Failed to start daemon. Is the image built?"
        echo "Run: docker-compose build"
        exit 1
    fi

    # Wait for daemon to be ready
    sleep 3
    success "Daemon started."
}

# Stop the daemon
stop_daemon() {
    info "Stopping Giulia daemon..."
    docker stop "${GIULIA_CONTAINER}" >/dev/null 2>&1 || true
    docker rm "${GIULIA_CONTAINER}" >/dev/null 2>&1 || true
    success "Daemon stopped."
}

# Get container path from host path
map_path() {
    local host_path="$1"
    local projects_root="${GIULIA_PROJECTS_PATH:-$(dirname "$(pwd)")}"

    # Get relative path from projects root
    local relative_path="${host_path#$projects_root}"

    # Return container path
    echo "/projects${relative_path}"
}

# Main entry point
main() {
    check_docker

    case "$1" in
        /stop|--stop)
            stop_daemon
            exit 0
            ;;
        /logs|--logs)
            docker logs -f "${GIULIA_CONTAINER}"
            exit 0
            ;;
        /rebuild|--rebuild)
            info "Rebuilding Giulia image..."
            docker-compose build
            exit 0
            ;;
        /status|--status)
            if daemon_running; then
                success "Daemon is running"
                docker ps -f "name=${GIULIA_CONTAINER}" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
            else
                warning "Daemon is not running"
            fi
            exit 0
            ;;
        /shell|--shell)
            docker exec -it "${GIULIA_CONTAINER}" /bin/sh
            exit 0
            ;;
    esac

    # Ensure daemon is running
    if ! daemon_running; then
        start_daemon
    fi

    # Map current path to container path
    CONTAINER_PATH=$(map_path "$(pwd)")

    if [ $# -eq 0 ]; then
        # Interactive mode
        docker exec -it \
            -e "GIULIA_PWD=${CONTAINER_PATH}" \
            "${GIULIA_CONTAINER}" \
            /app/bin/giulia remote
    else
        # Command mode
        docker exec -it \
            -e "GIULIA_PWD=${CONTAINER_PATH}" \
            "${GIULIA_CONTAINER}" \
            /app/bin/giulia eval "Giulia.CLI.main(System.argv())" -- "$@"
    fi
}

main "$@"
