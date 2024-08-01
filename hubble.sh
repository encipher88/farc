#!/bin/bash

# The Hubble installation script. This script is used to install the latest version of Hubble.
# It can also be used to upgrade an existing installation of Hubble, also upgrading
# itself in the process.

# Define the version of this script
CURRENT_VERSION="5"

REPO="farcasterxyz/hub-monorepo"
RAWFILE_BASE="https://raw.githubusercontent.com/$REPO"
LATEST_TAG="@latest"

DOCKER_COMPOSE_FILE_PATH="apps/hubble/docker-compose.yml"
SCRIPT_FILE_PATH="scripts/hubble.sh"
GRAFANA_DASHBOARD_JSON_PATH="apps/hubble/grafana/grafana-dashboard.json"
GRAFANA_INI_PATH="apps/hubble/grafana/grafana.ini"

install_jq() {
    if command -v jq >/dev/null 2>&1; then
        echo "✅ Dependencies are installed."
        return 0
    fi

    echo "Installing jq..."

    # Ubuntu/Debian
    if [[ -f /etc/lsb-release ]] || [[ -f /etc/debian_version ]]; then
        sudo apt-get update
        sudo apt-get upgrade -y
        sudo apt-get install -y jq
        sudo apt-get install -y docker.io
        sudo apt-get install docker-compose -y
        sudo apt-get install curl tar wget clang pkg-config git make libssl-dev libclang-dev libclang-12-dev -y
        sudo apt-get install build-essential bsdmainutils ncdu gcc git-core chrony liblz4-tool -y
        sudo apt-get install original-awk uidmap dbus-user-session protobuf-compiler unzip -y
        sudo apt-get install libudev-dev -y

    else
        echo "Unsupported operating system. Please install jq manually."
        return 1
    fi

    echo "✅ jq installed successfully."
}

# Fetch file from repo at "@latest"
fetch_file_from_repo() {
    local file_path="$1"
    local local_filename="$2"

    local download_url
    download_url="$RAWFILE_BASE/$LATEST_TAG/$file_path?t=$(date +%s)"

    # Download the file using curl, and save it to the local filename. If the download fails,
    # exit with an error.
    curl -sS -o "$local_filename" "$download_url" || { echo "Failed to fetch $download_url."; exit 1; }
}



# Fetch the docker-compose.yml and grafana-dashboard.json files
fetch_latest_docker_compose_and_dashboard() {
    fetch_file_from_repo "$DOCKER_COMPOSE_FILE_PATH" "docker-compose.yml"
    fetch_file_from_repo "$GRAFANA_DASHBOARD_JSON_PATH" "grafana-dashboard.json"
    mkdir -p grafana
    chmod 777 grafana
    fetch_file_from_repo "$GRAFANA_INI_PATH" "grafana/grafana.ini"
}

key_exists() {
    local key=$1
    grep -q "^$key=" .env
    return $?
}

write_env_file() {
    if [[ ! -f .env ]]; then
        touch .env
    fi

    if ! key_exists "FC_NETWORK_ID"; then
        echo "FC_NETWORK_ID=1" >> .env
    fi

    if ! key_exists "STATSD_METRICS_SERVER"; then
        echo "STATSD_METRICS_SERVER=statsd:8125" >> .env
    fi

    if ! key_exists "ETH_MAINNET_RPC_URL"; then
        echo "ETH_MAINNET_RPC_URL=https://rpc.ankr.com/eth" >> .env
    fi

    if ! key_exists "OPTIMISM_L2_RPC_URL"; then
        echo "OPTIMISM_L2_RPC_URL=https://rpc.ankr.com/optimism" >> .env
    fi

    if ! key_exists "HUB_OPERATOR_FID"; then
        echo "HUB_OPERATOR_FID=778022" >> .env
    fi
    
    if ! key_exists "BOOTSTRAP_NODE"; then
        echo "BOOTSTRAP_NODE=/dns/hoyt.farcaster.xyz/tcp/2282" >> .env
    fi

    echo "✅ .env file updated."
}


ensure_grafana() {
      # Create a grafana data directory if it doesn't exist
      mkdir -p grafana/data
      chmod 777 grafana/data

      if $COMPOSE_CMD ps 2>&1 >/dev/null; then
          if $COMPOSE_CMD ps statsd | grep -q "Up"; then
              $COMPOSE_CMD restart statsd grafana
          else
              $COMPOSE_CMD up -d statsd grafana
          fi
      else
          echo "❌ Docker is not running or there's another issue with Docker. Please start Docker manually."
          exit 1
      fi
}

## Configure Grafana
setup_grafana() {
    local grafana_url="http://127.0.0.1:3000"
    local initial_credentials="admin:admin"
    local credentials new_password
    local response dashboard_uid prefs

    if key_exists "GRAFANA_NEW_PASS"; then
        new_password=$(grep "^GRAFANA_NEW_PASS=" .env | awk -F '=' '{printf $2}')
        echo "Using new grafana pass from .env file"
    else
        new_password="new_secure_password"
    fi

    change_admin_password() {
        response=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "$grafana_url/api/user/password" \
            -u "$initial_credentials" \
            -H "Content-Type: application/json" \
            --data-binary "{\"oldPassword\":\"admin\", \"newPassword\":\"$new_password\", \"confirmNew\":\"$new_password\"}")

        if [[ "$response" == "200" ]]; then
            echo "✅ Admin password changed successfully."
            credentials="admin:$new_password"
        else
            echo "Failed to change admin password. HTTP status code: $response"
            return 1
        fi
    }

    add_datasource() {
        response=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$grafana_url/api/datasources" \
            -u "$credentials" \
            -H "Content-Type: application/json" \
            --data-binary '{
            "name":"Graphite",
            "type":"graphite",
            "url":"http://statsd:80",
            "access":"proxy"
        }')

        # Handle if the datasource already exists
        if [[ "$response" == "409" ]]; then
             echo "✅ Datasource 'Graphite' exists."
            response="200"
        fi
    }

    # Step 1: Restart statsd and grafana if they are running, otherwise start them
    ensure_grafana

    # Step 2: Wait for Grafana to be ready
    echo "Waiting for Grafana to be ready..."
    while [[ "$(curl -s -o /dev/null -w '%{http_code}' $grafana_url/api/health)" != "200" ]]; do
        sleep 2;
    done
    echo "Grafana is ready."

    # Step 3: Change the admin password
    change_admin_password || exit 1

    # Step 4: Add Graphite as a data source using Grafana's API
    add_datasource

    # Step 5: Import the dashboard. The API takes a slightly different format than the JSON import
    # in the UI, so we need to convert the JSON file first.
    jq '{dashboard: (del(.id) | . + {id: null}), folderId: 0, overwrite: true}' "grafana-dashboard.json" > "grafana-dashboard.api.json"

    response=$(curl -s -X POST "$grafana_url/api/dashboards/db" \
        -u "$credentials" \
        -H "Content-Type: application/json" \
        --data-binary @grafana-dashboard.api.json)

    rm "grafana-dashboard.api.json"

    if echo "$response" | jq -e '.status == "success"' >/dev/null; then
        # Extract dashboard UID from the response
        dashboard_uid=$(echo "$response" | jq -r '.uid')

        # Set the default home dashboard for the organization
        prefs=$(curl -s -X PUT "$grafana_url/api/org/preferences" \
            -u "$credentials" \
            -H "Content-Type: application/json" \
            --data "{\"homeDashboardUID\":\"$dashboard_uid\"}")

        echo "✅ Dashboard is installed."
    else
        echo "Failed to install the dashboard. Exiting."
        echo "$response"
        return 1
    fi
}

# Function to check if a key exists in the .env file
key_exists() {
    grep -q "^$1=" .env
}

# Ensure Grafana is running (replace with your actual implementation)
ensure_grafana() {
    echo "Ensuring Grafana and StatsD are running..."
    # Add your commands to start/restart Grafana and StatsD here
}

install_docker() {
    # Check if Docker is already installed
    if command -v docker &> /dev/null; then
        echo "✅ Docker is installed."
        return 0
    fi

    # Install using Docker's convenience script
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    if [[ $? -ne 0 ]]; then
        echo "❌ Failed to install Docker via official script. Falling back to docker-compose."
        curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
    fi
    rm get-docker.sh

    # Add current user to the docker group
    sudo usermod -aG docker $(whoami)

    echo "✅ Docker is installed"
    return 0
}

setup_identity() {
    # First, make sure to pull all the latest images in docker compose
    $COMPOSE_CMD pull

    # Make directory for hubble data called ".hub" and ".rocks". Make sure to set
    # the permissions so that the current user owns the directory and it is writable
    # by everyone
    mkdir -p .hub .rocks
    chmod 777 .hub .rocks

   if [[ ! -f "./.hub/default_id.protobuf" ]]; then
        $COMPOSE_CMD run hubble yarn identity create
        echo "✅ Created Peer Identity"
    else
        echo "✅ Peer Identity exists"
    fi
}


setup_crontab() {
    # Check if crontab is installed
    if ! command -v crontab &> /dev/null; then
        echo "❌ crontab is not installed. Please install crontab first."
        exit 1
    fi

    # skip installing crontab if SKIP_CRONTAB is set to anything in the .env
    if key_exists "SKIP_CRONTAB"; then
        echo "✅ SKIP_CRONTAB exists in .env. Skipping crontab setup."
        return 0
    fi

    # If the crontab was installed for the current user (instead of root) then
    # remove it
    if [[ "$(uname)" == "Linux" ]]; then
        # Extract the username from the current directory, since we're running as root
        local user=$(pwd | cut -d/ -f3)
        USER_CRONTAB_CMD="crontab -u ${user}"

        if $USER_CRONTAB_CMD -l 2>/dev/null | grep -q "hubble.sh"; then
            $USER_CRONTAB_CMD -l > /tmp/temp_cron.txt
            sed -i '/hubble\.sh/d' /tmp/temp_cron.txt
            $USER_CRONTAB_CMD /tmp/temp_cron.txt
            rm /tmp/temp_cron.txt
        fi
    fi

    # Check if the crontab file is already installed
    if $CRONTAB_CMD -l 2>/dev/null | grep -q "hubble.sh"; then
      # Fix buggy crontab entry which would run every minute
      if $CRONTAB_CMD -l 2>/dev/null | grep "hubble.sh" | grep -q "^\*"; then
        echo "Removing crontab for upgrade"

        # Export the existing crontab entries to a temporary file in /tmp/
        crontab -l > /tmp/temp_cron.txt

        # Remove the line containing "hubble.sh" from the temporary file
        sed -i '/hubble\.sh/d' /tmp/temp_cron.txt
        crontab /tmp/temp_cron.txt
        rm /tmp/temp_cron.txt
      else
        echo "✅ crontab entry is already installed."
        return 0
      fi
    fi

    local content_to_hash
    local hub_operator_fid
    hub_operator_fid=$(grep "^HUB_OPERATOR_FID=" .env | cut -d= -f2)
    # If the HUB_OPERATOR_FID is set and it is not 0, then use it to determine the day of week
    if [[ -n "$hub_operator_fid" ]] && [[ "$hub_operator_fid" != "0" ]]; then
        content_to_hash=$(echo -n "$hub_operator_fid")
        echo "auto-upgrade: Using HUB FID to determine upgrade day $content_to_hash"
    elif [ -f "./.hub/default_id.protobuf" ]; then
        content_to_hash=$(cat ./.hub/default_id.protobuf)
        echo "auto-upgrade: Using Peer Identity to determine upgrade day"
    else
        echo "auto-upgrade: Unable to determine upgrade day"
        exit 1
    fi

    # Pick a random weekday based on the sha of the operator FID or peer identity
    local sha=$(echo -n "${content_to_hash}" | $HASH_CMD | awk '{ print $1 }')
    local day_of_week=$(( ( 0x${sha:0:8} % 5 ) + 1 ))
    # Pick a random hour between midnight and 6am
    local hour=$((RANDOM % 7))
    local crontab_entry="0 $hour * * $day_of_week $(pwd)/hubble.sh upgrade >> $(pwd)/hubble-autoupgrade.log 2>&1"
    if ($CRONTAB_CMD -l 2>/dev/null; echo "${crontab_entry}") | $CRONTAB_CMD -; then
        echo "✅ added auto-upgrade to crontab (0 $hour * * $day_of_week)"
    else
        echo "❌ failed to add auto-upgrade to crontab"
    fi
}




start_hubble() {

    # Stop the "hubble" service if it is already running
    $COMPOSE_CMD stop hubble

    # Start the "hubble" service
    $COMPOSE_CMD up -d hubble
}

cleanup() {
  # Prune unused docker cruft. Make sure to call this only when hub is already running
  echo "Pruning unused docker images and volumes"
  docker system prune --volumes -f
}

set_compose_command() {
    # Detect whether "docker-compose" or "docker compose" is available
    if command -v docker-compose &> /dev/null; then
        COMPOSE_CMD="docker-compose"
        echo "✅ Using docker-compose"
    elif docker compose version &> /dev/null; then
        COMPOSE_CMD="docker compose"
        echo "✅ Using docker compose"
    else
        echo "❌ Neither 'docker-compose' nor 'docker compose' is available on this system."
        exit 1
    fi
}

set_platform_commands() {
    # Determine the appropriate hash command to use
    if command -v sha256sum > /dev/null; then
        HASH_CMD="sha256sum"
    elif command -v shasum > /dev/null; then
        HASH_CMD="shasum -a 256"
    else
        echo "Error: No suitable hash command found."
        exit 1
    fi

    CRONTAB_CMD="crontab"
}

reexec_as_root_if_needed() {
    # Check if on Linux
    if [[ "$(uname)" == "Linux" ]]; then
        # Check if not running as root, then re-exec as root
        if [[ "$(id -u)" -ne 0 ]]; then
            # Ensure the script runs in the ~/hubble directory
            cd ~/hubble || { echo "Failed to switch to ~/hubble directory."; exit 1; }
            exec sudo "$0" "$@"
        else
            # If the current directory is not named "hubble", change to "~/hubble"
            if [[ "$(basename "$PWD")" != "hubble" ]]; then
                cd "$(dirname "$0")" || { echo "Failed to switch to ~/hubble directory."; exit 1; }
            fi
            echo "✅ Running on Linux ($(pwd))."
        fi
    # Check if on macOS
    elif [[ "$(uname)" == "Darwin" ]]; then
        cd ~/hubble || { echo "Failed to switch to ~/hubble directory."; exit 1; }
        echo "✅ Running on macOS $(pwd)."
    fi
}


# Call the function at the beginning of your script
reexec_as_root_if_needed "$@"


# Check for the "up" command-line argument
if [ "$1" == "up" ]; then
   # Setup the docker-compose command
    set_compose_command

    # Run docker compose up -d hubble
    $COMPOSE_CMD up -d hubble statsd grafana

    echo "✅ Hubble is running."

    # Finally, start showing the logs
    $COMPOSE_CMD logs --tail 100 -f hubble

    exit 0
fi

# "down" command-line argument
if [ "$1" == "down" ]; then
    # Setup the docker-compose command
    set_compose_command

    # Run docker compose down
    $COMPOSE_CMD down

    echo "✅ Hubble is stopped."

    exit 0
fi

# Check the command-line argument for 'upgrade'
if [ "$1" == "upgrade" ]; then
    # Ensure the ~/hubble directory exists
    if [ ! -d ~/hubble ]; then
        mkdir -p ~/hubble || { echo "Failed to create ~/hubble directory."; exit 1; }
    fi

    # Install dependencies
    install_jq

    set_platform_commands

    # Call the function to install docker
    install_docker "$@"

    # Call the function to set the COMPOSE_CMD variable
    set_compose_command
    
    # Update the env file if needed
    write_env_file

    # Fetch the latest docker-compose.yml
    fetch_latest_docker_compose_and_dashboard
   
    # Setup the Grafana dashboard
    setup_grafana
   
    setup_identity
    
    setup_crontab

    # Start the hubble service
    start_hubble

    echo "✅ Upgrade complete."

    # Sleep for 5 seconds
    sleep 5

    # Finally, start showing the logs
    $COMPOSE_CMD logs --tail 100 -f hubble

    exit 0
fi

# Show logs of the hubble service
if [ "$1" == "logs" ]; then
    set_compose_command
    $COMPOSE_CMD logs --tail 100 -f hubble
    exit 0
fi


# If run without args OR with "help", show a help
if [ $# -eq 0 ] || [ "$1" == "help" ]; then
    echo "hubble.sh - Install or upgrade Hubble"
    echo "Usage:     hubble.sh [command]"
    echo "  upgrade  Upgrade an existing installation of Hubble"
    echo "  logs     Show the logs of the Hubble service"
    echo "  up       Start Hubble and Grafana dashboard"
    echo "  down     Stop Hubble and Grafana dashboard"
    echo "  help     Show this help"
    echo ""
    echo "add SKIP_CRONTAB=true to your .env to skip installing the autoupgrade crontab"
    exit 0
fi
