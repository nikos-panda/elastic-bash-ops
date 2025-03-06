#!/bin/bash
set -Eeuo pipefail

# Optionally load environment variables from a file (if it exists)
if [ -f ".env" ]; then
    # shellcheck source=/dev/null
    source ".env"
fi

# -----------------------------------------------------------------------------
# Default configurations – these can be overridden via environment variables
BACKUP=${BACKUP:-false}
REPLACE=${REPLACE:-false}
FORCE=${FORCE:-false}
INTERACTIVE=${INTERACTIVE:-true}     # Set to false using the --noninteractive flag.
SOURCE_INDEX=${SOURCE_INDEX:-""}
DEST_INDEX=${DEST_INDEX:-""}
SETTINGS_FILE=${SETTINGS_FILE:-""}
MAPPINGS_FILE=${MAPPINGS_FILE:-""}
ALIAS=${ALIAS:-""}
ELASTIC_HOST=${ELASTIC_HOST:-""}
USERNAME=${USERNAME:-""}
PASSWORD=${PASSWORD:-""}

# -----------------------------------------------------------------------------
# Logging Functions
log_info() {
    echo "[INFO] $*"
}
log_error() {
    echo "[ERROR] $*" >&2
}

# -----------------------------------------------------------------------------
# Usage function displays help
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --backup              Create a backup of the source index.
  --replace             Delete the source index after operations.
  --force               Force deletion of existing destination index.
  --noninteractive      Run in non-interactive mode.
  --source INDEX        (Required) Specify the source index.
  --dest INDEX          (Required) Specify the destination index.
  --settings FILE       Specify the settings file (if applicable).
  --mappings FILE       Specify the mappings file (if applicable).
  --host URL            (Required) Specify the Elasticsearch host (e.g., http://localhost:9200).
  --alias ALIAS         (Optional) Set an alias for the destination index.
  --username USER       (Optional) Elasticsearch username.
  --password PASS       (Optional) Elasticsearch password.
  -h, --help            Show this help message.
EOF
    exit 1
}

# -----------------------------------------------------------------------------
# Command-line argument parsing
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --backup) BACKUP=true ;;
        --replace) REPLACE=true ;;
        --force) FORCE=true ;;
        --noninteractive) INTERACTIVE=false ;;
        --source) SOURCE_INDEX="$2"; shift ;;
        --dest) DEST_INDEX="$2"; shift ;;
        --settings) SETTINGS_FILE="$2"; shift ;;
        --mappings) MAPPINGS_FILE="$2"; shift ;;
        --host) ELASTIC_HOST="$2"; shift ;;
        --alias) ALIAS="$2"; shift ;;
        --username) USERNAME="$2"; shift ;;
        --password) PASSWORD="$2"; shift ;;
        -h|--help) usage ;;
        *) log_error "Unknown parameter: $1"; usage ;;
    esac
    shift
done

# -----------------------------------------------------------------------------
# Validate required arguments
if [[ -z "$SOURCE_INDEX" || -z "$DEST_INDEX" || -z "$ELASTIC_HOST" ]]; then
    log_error "Missing required arguments: --source, --dest, and --host are mandatory."
    usage
fi

if [[ "$SOURCE_INDEX" == "$DEST_INDEX" ]]; then
    log_error "Error: Source index and destination index cannot be the same."
    exit 1
fi

# -----------------------------------------------------------------------------
# Ensure required dependency 'jq' is installed
if ! command -v jq &>/dev/null; then
    log_error "jq is not installed. Install it (e.g., sudo apt install jq) and try again."
    exit 1
fi

# -----------------------------------------------------------------------------
# run_curl: Execute a curl request with proper error handling.
run_curl() {
    local path=$1
    shift
    local auth_opts=()
    if [[ -n "$USERNAME" && -n "$PASSWORD" ]]; then
        auth_opts=(-u "$USERNAME:$PASSWORD")
    fi
    local url="${ELASTIC_HOST}${path}"
    log_info "Requesting: ${url}"
    local response status_code
    response=$(curl "${auth_opts[@]}" -s -w "\n%{http_code}" "$url" "$@") || exit 1
    status_code=$(echo "$response" | tail -n 1)
    echo "$response" | head -n -1
    if [[ ! "$status_code" =~ ^2 ]]; then
        log_error "Request to $url failed with status code $status_code"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# check_alias: Checks if an alias exists. In interactive mode, ask the user for confirmation.
check_alias() {
    if [[ -z "$ALIAS" ]]; then
        return
    fi
    while true; do
        local alias_status
        alias_status=$(curl -s "${ELASTIC_HOST}/_alias/${ALIAS}" -o /dev/null -w "%{http_code}")
        if [[ "$alias_status" == "200" ]]; then
            if [[ "$INTERACTIVE" == "true" ]]; then
                echo "Alias '$ALIAS' already exists. Options:"
                echo "1. Proceed and reassign alias."
                echo "2. Abort."
                echo "3. Specify a different alias."
                read -rp "Select (1/2/3): " choice
                case "$choice" in
                    1) break ;;
                    2) log_info "User aborted."; exit 1 ;;
                    3) read -rp "Enter new alias: " ALIAS ;;
                    *) echo "Invalid selection, please try again." ;;
                esac
            else
                # In non-interactive mode, default to reassigning the alias.
                log_info "Non-interactive mode: Overwriting alias '$ALIAS'."
                break
            fi
        else
            break
        fi
    done
}

# -----------------------------------------------------------------------------
# Fetch current indices
existing_indices=$(run_curl "/_cat/indices?format=json" | jq -r '.[].index')

if ! echo "$existing_indices" | grep -qw "$SOURCE_INDEX"; then
    log_error "Source index '$SOURCE_INDEX' does not exist."
    exit 1
fi

if echo "$existing_indices" | grep -qw "$DEST_INDEX"; then
    if [[ "$FORCE" == "true" ]]; then
        log_info "Forcing deletion of existing destination index '$DEST_INDEX'."
        run_curl "/${DEST_INDEX}" -X DELETE
    else
        log_error "Destination index '$DEST_INDEX' already exists. Use --force to delete it."
        exit 1
    fi
fi

# -----------------------------------------------------------------------------
# Create a backup of the source index (if requested)
if [[ "$BACKUP" == "true" ]]; then
    backup_index="${SOURCE_INDEX}-backup-$(date '+%Y%m%d')"
    log_info "Creating backup index '$backup_index'."
    run_curl "/_reindex?pretty" -X POST -H "Content-Type: application/json" -d "
{
  \"source\": { \"index\": \"$SOURCE_INDEX\" },
  \"dest\": { \"index\": \"$backup_index\" }
}"
fi

# -----------------------------------------------------------------------------
# Create a new destination index and configure it
log_info "Creating destination index '$DEST_INDEX'."
run_curl "/${DEST_INDEX}" -X PUT

log_info "Closing index '$DEST_INDEX' for configuration."
run_curl "/${DEST_INDEX}/_close" -X POST

# Apply new settings if a settings file is provided
if [[ -n "$SETTINGS_FILE" ]]; then
    if [[ ! -f "$SETTINGS_FILE" ]]; then
        log_error "Settings file '$SETTINGS_FILE' not found."
        exit 1
    fi
    log_info "Updating settings from '$SETTINGS_FILE'."
    run_curl "/${DEST_INDEX}/_settings?pretty" -X PUT -H "Content-Type: application/json" --data-binary "@${SETTINGS_FILE}"
fi

# Apply new mappings if a mappings file is provided
if [[ -n "$MAPPINGS_FILE" ]]; then
    if [[ ! -f "$MAPPINGS_FILE" ]]; then
        log_error "Mappings file '$MAPPINGS_FILE' not found."
        exit 1
    fi
    log_info "Updating mappings from '$MAPPINGS_FILE'."
    run_curl "/${DEST_INDEX}/_mapping?pretty" -X PUT -H "Content-Type: application/json" --data-binary "@${MAPPINGS_FILE}"
fi

# Reopen the destination index
log_info "Reopening index '$DEST_INDEX'."
run_curl "/${DEST_INDEX}/_open" -X POST

# Reindex backup into the new destination if a backup was taken
if [[ "$BACKUP" == "true" ]]; then
    log_info "Reindexing data from backup '$backup_index' to '$DEST_INDEX'."
    run_curl "/_reindex?pretty" -X POST -H "Content-Type: application/json" -d "
{
  \"source\": { \"index\": \"$backup_index\" },
  \"dest\": { \"index\": \"$DEST_INDEX\" }
}"
fi

# Optionally delete the source index if --replace is specified
if [[ "$REPLACE" == "true" ]]; then
    log_info "Deleting source index '$SOURCE_INDEX'."
    run_curl "/${SOURCE_INDEX}" -X DELETE
fi

# -----------------------------------------------------------------------------
# Check and assign alias if provided
check_alias
if [[ -n "$ALIAS" ]]; then
    log_info "Assigning alias '$ALIAS' to destination index '$DEST_INDEX'."
    run_curl "/_aliases" -X POST -H "Content-Type: application/json" -d "
{
  \"actions\": [
    { \"add\": { \"alias\": \"$ALIAS\", \"index\": \"$DEST_INDEX\" } }
  ]
}"
fi

log_info "Index modification completed successfully."
