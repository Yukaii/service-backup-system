#!/bin/bash

# Enhanced Docker Compose Services Backup Script
# This script backs up all Docker services and uploads to S3 via rclone
# Compatible with multiple Linux distributions

set -euo pipefail

# Load environment overrides from user config files (if present)
for envfile in "$HOME/.backup-env" "$HOME/.config/service-backup/.env"; do
    if [[ -f "$envfile" ]]; then
        # shellcheck source=/dev/null
        . "$envfile"
    fi
done

# Configuration
SERVICES_DIR="${SERVICES_DIR:-$HOME/Services}"
BACKUP_BASE_DIR="${BACKUP_BASE_DIR:-$HOME/backups}"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="$BACKUP_BASE_DIR/$DATE"
HOSTNAME=$(hostname)
S3_BUCKET="${S3_BUCKET:-your-backup-bucket-name}"
S3_REMOTE="${S3_REMOTE:-backup-s3}"
LOG_FILE="${LOG_FILE:-$HOME/logs/backup.log}"
MAX_RETRIES=3
RETRY_DELAY=10

# Service ignore list (can be set via environment variable or config file)
# Format: comma-separated service names (e.g., "service1,service2,service3")
BACKUP_IGNORE_SERVICES="${BACKUP_IGNORE_SERVICES:-}"
BACKUP_CONFIG_FILE="${BACKUP_CONFIG_FILE:-$HOME/.backup-ignore}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging function
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
    
    if [[ "$level" == "ERROR" ]]; then
        echo -e "${RED}ERROR: $message${NC}" >&2
    elif [[ "$level" == "WARN" ]]; then
        echo -e "${YELLOW}WARNING: $message${NC}" >&2
    elif [[ "$level" == "SUCCESS" ]]; then
        echo -e "${GREEN}SUCCESS: $message${NC}"
    fi
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Load ignore list from config file and environment variable
load_ignore_list() {
    local ignore_list=""
    
    # Load from config file if it exists
    if [[ -f "$BACKUP_CONFIG_FILE" ]]; then
        log "INFO" "Loading ignore list from config file: $BACKUP_CONFIG_FILE"
        while IFS= read -r line || [[ -n "$line" ]]; do
            # Skip empty lines and comments
            if [[ -n "$line" ]] && [[ ! "$line" =~ ^[[:space:]]*# ]]; then
                # Remove leading/trailing whitespace
                line=$(echo "$line" | xargs)
                if [[ -n "$ignore_list" ]]; then
                    ignore_list="$ignore_list,$line"
                else
                    ignore_list="$line"
                fi
            fi
        done < "$BACKUP_CONFIG_FILE"
    fi
    
    # Add from environment variable
    if [[ -n "$BACKUP_IGNORE_SERVICES" ]]; then
        if [[ -n "$ignore_list" ]]; then
            ignore_list="$ignore_list,$BACKUP_IGNORE_SERVICES"
        else
            ignore_list="$BACKUP_IGNORE_SERVICES"
        fi
    fi
    
    # Convert to global array
    if [[ -n "$ignore_list" ]]; then
        IFS=',' read -ra IGNORE_SERVICES <<< "$ignore_list"
        # Trim whitespace from each service name
        for i in "${!IGNORE_SERVICES[@]}"; do
            IGNORE_SERVICES[i]=$(echo "${IGNORE_SERVICES[i]}" | xargs)
        done
        log "INFO" "Services to ignore: ${IGNORE_SERVICES[*]}"
    else
        IGNORE_SERVICES=()
    fi
}

# Check if a service should be ignored
is_service_ignored() {
    local service_name="$1"
    
    for ignored_service in "${IGNORE_SERVICES[@]}"; do
        if [[ "$service_name" == "$ignored_service" ]]; then
            return 0  # Service should be ignored
        fi
    done
    
    return 1  # Service should not be ignored
}

# Check rclone availability and configuration
check_rclone() {
    log "INFO" "Checking rclone availability..."
    
    if ! command_exists rclone; then
        log "ERROR" "rclone is not installed. Please install it first:"
        log "ERROR" "  curl https://rclone.org/install.sh | sudo bash"
        exit 1
    fi
    
    log "SUCCESS" "rclone is installed: $(rclone version --check=false | head -n1)"
    
    # Check if remote is configured
    if ! rclone listremotes | grep -q "^${S3_REMOTE}:$"; then
        log "ERROR" "rclone remote '$S3_REMOTE' is not configured"
        log "ERROR" "Please run: rclone config"
        log "ERROR" "Or set S3_REMOTE environment variable to your configured remote name"
        exit 1
    fi
    
    log "SUCCESS" "rclone remote '$S3_REMOTE' is configured"
}

# Check S3 bucket accessibility
check_s3_access() {
    log "INFO" "Testing S3 bucket accessibility..."
    
    local retry=0
    while [ $retry -lt $MAX_RETRIES ]; do
        if rclone lsd "${S3_REMOTE}:${S3_BUCKET}/" >/dev/null 2>&1; then
            log "SUCCESS" "S3 bucket '${S3_BUCKET}' is accessible"
            return 0
        fi
        
        retry=$((retry + 1))
        if [ $retry -lt $MAX_RETRIES ]; then
            log "WARN" "S3 access attempt $retry failed, retrying in ${RETRY_DELAY}s..."
            sleep $RETRY_DELAY
        fi
    done
    
    log "ERROR" "Cannot access S3 bucket '${S3_BUCKET}' after $MAX_RETRIES attempts"
    log "ERROR" "Please check:"
    log "ERROR" "  1. Bucket name is correct"
    log "ERROR" "  2. AWS credentials are valid"
    log "ERROR" "  3. Network connectivity"
    log "ERROR" "  4. Bucket permissions"
    exit 1
}

# Check Docker availability
check_docker() {
    log "INFO" "Checking Docker availability..."
    
    if ! command_exists docker; then
        log "ERROR" "Docker is not installed"
        exit 1
    fi
    
    if ! docker info >/dev/null 2>&1; then
        log "ERROR" "Cannot connect to Docker daemon. Please check:"
        log "ERROR" "  1. Docker service is running"
        log "ERROR" "  2. User has Docker permissions"
        exit 1
    fi
    
    # Check for docker compose (new subcommand) or docker-compose (legacy)
    if docker compose version >/dev/null 2>&1; then
        log "SUCCESS" "Docker with compose plugin is available"
        DOCKER_COMPOSE_CMD="docker compose"
    elif command_exists docker-compose; then
        log "SUCCESS" "Docker Compose (legacy) is available"
        DOCKER_COMPOSE_CMD="docker-compose"
    else
        log "ERROR" "Neither 'docker compose' nor 'docker-compose' is available"
        exit 1
    fi
    
    log "SUCCESS" "Docker and compose are available"
}

# Create necessary directories
setup_directories() {
    log "INFO" "Setting up directories..."
    
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$(dirname "$LOG_FILE")"
    
    if [[ ! -d "$SERVICES_DIR" ]]; then
        log "WARN" "Services directory '$SERVICES_DIR' does not exist"
        log "WARN" "Creating directory structure..."
        mkdir -p "$SERVICES_DIR"
    fi
    
    log "SUCCESS" "Directory setup complete"
}

# Backup service configurations
backup_configurations() {
    log "INFO" "Backing up service configurations..."
    
    if [[ ! -d "$SERVICES_DIR" ]] || [[ -z "$(ls -A "$SERVICES_DIR" 2>/dev/null)" ]]; then
        log "WARN" "No services found in '$SERVICES_DIR'"
        return 0
    fi
    
    local config_backup="$BACKUP_DIR/services-config.tar.gz"
    
    # Build exclude list for ignored services
    local tar_excludes=(
        --exclude='Services/*/data'
        --exclude='Services/*/logs'
        --exclude='Services/*/.git'
        --exclude='Services/*/node_modules'
        --exclude='Services/*/vendor'
        --exclude='Services/*/postgres'
        --exclude='Services/*/library'
        --warning=no-file-removed
        --warning=no-file-changed
    )
    
    # Add ignored services to exclude list
    for ignored_service in "${IGNORE_SERVICES[@]}"; do
        tar_excludes+=(--exclude="Services/$ignored_service")
    done
    
    tar -czf "$config_backup" \
        -C "$HOME" \
        "${tar_excludes[@]}" \
        Services/ 2>/dev/null || {
        log "WARN" "Configuration backup completed with warnings (some files may be inaccessible)"
    }
    
    log "SUCCESS" "Configuration backup created: $(du -h "$config_backup" | cut -f1)"
}

# Process individual service
backup_service() {
    local service_path="$1"
    local service_name=$(basename "$service_path")
    
    log "INFO" "Processing service: $service_name"
    
    cd "$service_path"
    
    # Check if docker-compose.yml exists
    if [[ ! -f "docker-compose.yml" ]]; then
        log "WARN" "No docker-compose.yml found in $service_name, skipping"
        return 0
    fi
    
    # Run service-specific backup if exists
    if [[ -f "backup.sh" && -x "backup.sh" ]]; then
        log "INFO" "Running custom backup for $service_name"
        if timeout 300 bash backup.sh "$BACKUP_DIR/${service_name}"; then
            log "SUCCESS" "Custom backup completed for $service_name"
        else
            log "ERROR" "Custom backup failed for $service_name"
            return 1
        fi
    else
        # Default backup: export volumes
        log "INFO" "Performing default volume backup for $service_name"
        backup_service_volumes "$service_name"
    fi
}

# Backup service volumes
backup_service_volumes() {
    local service_name="$1"
    local service_backup_dir="$BACKUP_DIR/${service_name}"
    
    mkdir -p "$service_backup_dir"
    
    # Get all volumes for this service
    local volumes
    volumes=$($DOCKER_COMPOSE_CMD config --volumes 2>/dev/null || echo "")
    
    if [[ -z "$volumes" ]]; then
        log "INFO" "No volumes found for $service_name"
        return 0
    fi
    
    for volume in $volumes; do
        local full_volume_name="${service_name}_${volume}"
        local backup_file="$service_backup_dir/${volume}.tar.gz"
        
        log "INFO" "Backing up volume: $full_volume_name"
        
        if docker volume inspect "$full_volume_name" >/dev/null 2>&1; then
            docker run --rm \
                -v "${full_volume_name}:/data:ro" \
                -v "$service_backup_dir:/backup" \
                alpine:latest \
                tar -czf "/backup/${volume}.tar.gz" -C /data . 2>/dev/null || {
                log "WARN" "Failed to backup volume: $full_volume_name"
                continue
            }
            
            log "SUCCESS" "Volume backed up: $volume ($(du -h "$backup_file" | cut -f1))"
        else
            log "WARN" "Volume not found: $full_volume_name"
        fi
    done
}

# Upload to S3
upload_to_s3() {
    log "INFO" "Uploading backup to S3..."
    
    local s3_path="${S3_REMOTE}:${S3_BUCKET}/${HOSTNAME}/${DATE}/"
    local total_size=$(du -sh "$BACKUP_DIR" | cut -f1)
    
    log "INFO" "Upload size: $total_size"
    log "INFO" "Destination: $s3_path"
    
    local retry=0
    while [ $retry -lt $MAX_RETRIES ]; do
        if rclone copy "$BACKUP_DIR" "$s3_path" \
            --transfers 4 \
            --checkers 8 \
            --retries 3 \
            --low-level-retries 10 \
            --stats 30s \
            --progress \
            --log-file="$LOG_FILE" \
            --log-level INFO; then
            log "SUCCESS" "Backup uploaded successfully"
            return 0
        fi
        
        retry=$((retry + 1))
        if [ $retry -lt $MAX_RETRIES ]; then
            log "WARN" "Upload attempt $retry failed, retrying in ${RETRY_DELAY}s..."
            sleep $RETRY_DELAY
        fi
    done
    
    log "ERROR" "Failed to upload backup after $MAX_RETRIES attempts"
    return 1
}

# Clean up old local backups
cleanup_local_backups() {
    log "INFO" "Cleaning up old local backups (>3 days)..."
    
    local deleted_count=0
    while IFS= read -r -d '' backup_dir; do
        rm -rf "$backup_dir"
        deleted_count=$((deleted_count + 1))
        log "INFO" "Deleted old backup: $(basename "$backup_dir")"
    done < <(find "$BACKUP_BASE_DIR" -maxdepth 1 -type d -name "*_*" -mmin +4320 -print0 2>/dev/null)
    
    if [ $deleted_count -eq 0 ]; then
        log "INFO" "No old backups to clean up"
    else
        log "SUCCESS" "Cleaned up $deleted_count old backup(s)"
    fi
}

# Generate backup report
generate_report() {
    local end_time=$(date '+%Y-%m-%d %H:%M:%S')
    local backup_size=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1 || echo "Unknown")
    local service_count=$(find "$SERVICES_DIR" -maxdepth 1 -type d -name "*" | wc -l)
    service_count=$((service_count - 1)) # Subtract parent directory
    
    log "INFO" "=== BACKUP REPORT ==="
    log "INFO" "Backup completed: $end_time"
    log "INFO" "Total backup size: $backup_size"
    log "INFO" "Services processed: $service_count"
    log "INFO" "Backup location: S3://${S3_BUCKET}/${HOSTNAME}/${DATE}/"
    log "INFO" "Local backup: $BACKUP_DIR"
    log "INFO" "===================="
}

# Main execution
main() {
    local start_time=$(date '+%Y-%m-%d %H:%M:%S')
    log "INFO" "Starting backup process at $start_time"
    log "INFO" "Hostname: $HOSTNAME"
    log "INFO" "Services directory: $SERVICES_DIR"
    log "INFO" "S3 bucket: $S3_BUCKET"
    
    # Pre-flight checks
    check_rclone
    check_s3_access
    check_docker
    
    # Load ignore list
    load_ignore_list
    
    # Reclaim expired local backups before creating a new backup directory.
    cleanup_local_backups
    
    # Setup
    setup_directories
    
    # Backup configurations
    backup_configurations
    
    # Process each service
    local success_count=0
    local total_count=0
    
    for service_path in "$SERVICES_DIR"/*; do
        if [[ -d "$service_path" ]]; then
            local service_name=$(basename "$service_path")
            
            # Check if service should be ignored
            if is_service_ignored "$service_name"; then
                log "INFO" "Skipping ignored service: $service_name"
                continue
            fi
            
            total_count=$((total_count + 1))
            if backup_service "$service_path"; then
                success_count=$((success_count + 1))
            fi
        fi
    done
    
    if [ $total_count -eq 0 ]; then
        log "WARN" "No services found to backup"
    else
        log "INFO" "Processed $success_count/$total_count services successfully"
    fi
    
    # Upload to S3
    if upload_to_s3; then
        log "SUCCESS" "Backup process completed successfully"
    else
        log "ERROR" "Backup process completed with upload errors"
        exit 1
    fi
    
    # Reporting
    generate_report
    
    log "SUCCESS" "All backup operations completed"
}

# Trap for cleanup on script interruption
cleanup_on_exit() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        log "ERROR" "Backup script interrupted or failed with exit code: $exit_code"
        if [[ -d "$BACKUP_DIR" ]]; then
            log "INFO" "Cleaning up incomplete backup directory: $BACKUP_DIR"
            rm -rf "$BACKUP_DIR"
        fi
    fi
}

trap cleanup_on_exit EXIT

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi