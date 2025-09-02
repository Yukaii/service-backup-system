#!/bin/bash

# Docker Services Restore Script
# Restores services from S3 backups created by backup-all-services.sh

set -euo pipefail

# Configuration
SERVICES_DIR="${SERVICES_DIR:-$HOME/Services}"
RESTORE_BASE_DIR="${RESTORE_BASE_DIR:-$HOME/restore_temp}"
HOSTNAME=$(hostname)
S3_BUCKET="${S3_BUCKET:-your-backup-bucket-name}"
S3_REMOTE="${S3_REMOTE:-backup-s3}"
LOG_FILE="${LOG_FILE:-$HOME/logs/restore.log}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables
BACKUP_DATE=""
SERVICE_NAME=""
RESTORE_MODE=""
FORCE_RESTORE=false

# Logging function
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
    
    case "$level" in
        "ERROR")
            echo -e "${RED}ERROR: $message${NC}" >&2
            ;;
        "WARN")
            echo -e "${YELLOW}WARNING: $message${NC}" >&2
            ;;
        "SUCCESS")
            echo -e "${GREEN}SUCCESS: $message${NC}"
            ;;
        "INFO")
            echo -e "${BLUE}INFO: $message${NC}"
            ;;
    esac
}

# Show usage information
show_usage() {
    cat << EOF
Docker Services Restore Script

Usage: $0 [OPTIONS]

Options:
    -d, --date BACKUP_DATE      Backup date to restore (YYYYMMDD_HHMMSS format)
    -s, --service SERVICE_NAME  Service to restore (or 'all' for everything)
    -m, --mode MODE            Restore mode: 'config', 'data', or 'full' (default: full)
    -f, --force                Force restore without confirmation prompts
    -l, --list                 List available backups
    -h, --help                 Show this help message

Environment Variables:
    SERVICES_DIR               Services directory (default: \$HOME/Services)
    S3_BUCKET                 S3 bucket name for backups
    S3_REMOTE                 rclone remote name (default: backup-s3)
    LOG_FILE                  Log file location (default: \$HOME/logs/restore.log)

Examples:
    $0 --list                                    # List available backups
    $0 -d 20231215_020000 -s all                # Restore all services from backup
    $0 -d 20231215_020000 -s wordpress          # Restore specific service
    $0 -d 20231215_020000 -s nginx -m config    # Restore only configuration
    $0 -d 20231215_020000 -s database -m data   # Restore only data
    $0 -d 20231215_020000 -s all -f             # Force restore without prompts

EOF
}

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--date)
                BACKUP_DATE="$2"
                shift 2
                ;;
            -s|--service)
                SERVICE_NAME="$2"
                shift 2
                ;;
            -m|--mode)
                RESTORE_MODE="$2"
                shift 2
                ;;
            -f|--force)
                FORCE_RESTORE=true
                shift
                ;;
            -l|--list)
                list_available_backups
                exit 0
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                log "ERROR" "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
    
    # Set defaults
    RESTORE_MODE="${RESTORE_MODE:-full}"
    
    # Validate restore mode
    if [[ ! "$RESTORE_MODE" =~ ^(config|data|full)$ ]]; then
        log "ERROR" "Invalid restore mode: $RESTORE_MODE. Must be 'config', 'data', or 'full'"
        exit 1
    fi
}

# Check prerequisites
check_prerequisites() {
    log "INFO" "Checking prerequisites..."
    
    # Check rclone
    if ! command -v rclone >/dev/null 2>&1; then
        log "ERROR" "rclone is not installed"
        exit 1
    fi
    
    # Check rclone remote
    if ! rclone listremotes | grep -q "^${S3_REMOTE}:$"; then
        log "ERROR" "rclone remote '$S3_REMOTE' is not configured"
        exit 1
    fi
    
    # Check Docker
    if ! command -v docker >/dev/null 2>&1; then
        log "ERROR" "Docker is not installed"
        exit 1
    fi
    
    if ! command -v docker-compose >/dev/null 2>&1; then
        log "ERROR" "docker-compose is not installed"
        exit 1
    fi
    
    # Test S3 access
    if ! rclone lsd "${S3_REMOTE}:${S3_BUCKET}/${HOSTNAME}/" >/dev/null 2>&1; then
        log "ERROR" "Cannot access S3 bucket: ${S3_BUCKET}"
        exit 1
    fi
    
    log "SUCCESS" "Prerequisites check passed"
}

# List available backups
list_available_backups() {
    log "INFO" "Listing available backups from S3..."
    
    echo ""
    echo "Available backups for hostname: $HOSTNAME"
    echo "========================================"
    
    local backups
    backups=$(rclone lsf "${S3_REMOTE}:${S3_BUCKET}/${HOSTNAME}/" --dirs-only 2>/dev/null | sort -r) || {
        log "ERROR" "Failed to list backups from S3"
        return 1
    }
    
    if [[ -z "$backups" ]]; then
        log "WARN" "No backups found for hostname: $HOSTNAME"
        return 0
    fi
    
    local count=0
    while IFS= read -r backup_dir; do
        if [[ -n "$backup_dir" ]]; then
            backup_dir=${backup_dir%/}  # Remove trailing slash
            count=$((count + 1))
            
            # Get backup size and file count
            local backup_info
            backup_info=$(rclone size "${S3_REMOTE}:${S3_BUCKET}/${HOSTNAME}/${backup_dir}/" 2>/dev/null) || backup_info="Size: Unknown"
            
            echo "[$count] $backup_dir"
            echo "    $backup_info"
            
            # List services in backup
            local services
            services=$(rclone lsf "${S3_REMOTE}:${S3_BUCKET}/${HOSTNAME}/${backup_dir}/" --dirs-only 2>/dev/null | grep -v "services-config" | head -5) || services=""
            
            if [[ -n "$services" ]]; then
                echo "    Services: $(echo "$services" | tr '\n' ' ' | sed 's|/||g' | xargs)"
            fi
            echo ""
        fi
    done <<< "$backups"
    
    echo "Total backups found: $count"
    echo ""
}

# Interactive backup selection
select_backup_interactively() {
    if [[ -n "$BACKUP_DATE" ]]; then
        return 0
    fi
    
    echo "Please select a backup to restore:"
    echo ""
    
    local backups_array=()
    local backups
    backups=$(rclone lsf "${S3_REMOTE}:${S3_BUCKET}/${HOSTNAME}/" --dirs-only 2>/dev/null | sort -r) || {
        log "ERROR" "Failed to list backups from S3"
        exit 1
    }
    
    if [[ -z "$backups" ]]; then
        log "ERROR" "No backups found for hostname: $HOSTNAME"
        exit 1
    fi
    
    local count=0
    while IFS= read -r backup_dir; do
        if [[ -n "$backup_dir" ]]; then
            backup_dir=${backup_dir%/}  # Remove trailing slash
            backups_array+=("$backup_dir")
            count=$((count + 1))
            echo "[$count] $backup_dir"
        fi
    done <<< "$backups"
    
    echo ""
    read -p "Enter backup number [1-$count]: " selection
    
    if [[ ! "$selection" =~ ^[0-9]+$ ]] || [[ $selection -lt 1 ]] || [[ $selection -gt $count ]]; then
        log "ERROR" "Invalid selection: $selection"
        exit 1
    fi
    
    BACKUP_DATE="${backups_array[$((selection - 1))]}"
    log "INFO" "Selected backup: $BACKUP_DATE"
}

# Interactive service selection
select_service_interactively() {
    if [[ -n "$SERVICE_NAME" ]]; then
        return 0
    fi
    
    echo ""
    echo "Available services in backup $BACKUP_DATE:"
    echo "=========================================="
    
    local services_array=("all")
    local services
    services=$(rclone lsf "${S3_REMOTE}:${S3_BUCKET}/${HOSTNAME}/${BACKUP_DATE}/" --dirs-only 2>/dev/null | grep -v "services-config" | sort) || {
        log "ERROR" "Failed to list services in backup"
        exit 1
    }
    
    echo "[1] all (restore everything)"
    
    local count=1
    while IFS= read -r service_dir; do
        if [[ -n "$service_dir" ]]; then
            service_dir=${service_dir%/}  # Remove trailing slash
            services_array+=("$service_dir")
            count=$((count + 1))
            echo "[$count] $service_dir"
        fi
    done <<< "$services"
    
    echo ""
    read -p "Enter service number [1-$count]: " selection
    
    if [[ ! "$selection" =~ ^[0-9]+$ ]] || [[ $selection -lt 1 ]] || [[ $selection -gt $count ]]; then
        log "ERROR" "Invalid selection: $selection"
        exit 1
    fi
    
    SERVICE_NAME="${services_array[$((selection - 1))]}"
    log "INFO" "Selected service: $SERVICE_NAME"
}

# Confirm restoration
confirm_restore() {
    if [[ "$FORCE_RESTORE" == true ]]; then
        return 0
    fi
    
    echo ""
    echo "=== RESTORE CONFIRMATION ==="
    echo "Backup date: $BACKUP_DATE"
    echo "Service: $SERVICE_NAME"
    echo "Restore mode: $RESTORE_MODE"
    echo "Target directory: $SERVICES_DIR"
    echo ""
    
    if [[ "$SERVICE_NAME" != "all" ]]; then
        echo "WARNING: This will stop the '$SERVICE_NAME' service and restore it from backup."
    else
        echo "WARNING: This will stop ALL services and restore them from backup."
    fi
    
    echo "WARNING: Current data will be backed up before restoration."
    echo ""
    
    read -p "Do you want to proceed? (yes/no): " confirmation
    
    if [[ "$confirmation" != "yes" ]]; then
        log "INFO" "Restoration cancelled by user"
        exit 0
    fi
}

# Download backup from S3
download_backup() {
    local restore_dir="$RESTORE_BASE_DIR/$BACKUP_DATE"
    
    log "INFO" "Downloading backup from S3..."
    log "INFO" "Source: ${S3_REMOTE}:${S3_BUCKET}/${HOSTNAME}/${BACKUP_DATE}/"
    log "INFO" "Destination: $restore_dir"
    
    mkdir -p "$restore_dir"
    
    if rclone copy "${S3_REMOTE}:${S3_BUCKET}/${HOSTNAME}/${BACKUP_DATE}/" "$restore_dir/" \
        --transfers 4 \
        --checkers 8 \
        --stats 10s \
        --progress; then
        log "SUCCESS" "Backup downloaded successfully"
        echo "$restore_dir"
    else
        log "ERROR" "Failed to download backup"
        exit 1
    fi
}

# Create pre-restore backup
create_pre_restore_backup() {
    local service_path="$1"
    local service_name=$(basename "$service_path")
    local backup_dir="$RESTORE_BASE_DIR/pre-restore-$(date +%Y%m%d_%H%M%S)"
    
    if [[ ! -d "$service_path" ]]; then
        return 0
    fi
    
    log "INFO" "Creating pre-restore backup for $service_name..."
    
    mkdir -p "$backup_dir"
    
    cd "$service_path"
    
    # Export current docker-compose configuration
    docker-compose config > "$backup_dir/${service_name}-docker-compose.yml" 2>/dev/null || true
    
    # Backup current volumes
    local volumes
    volumes=$(docker-compose config --volumes 2>/dev/null || echo "")
    
    if [[ -n "$volumes" ]]; then
        mkdir -p "$backup_dir/$service_name"
        for volume in $volumes; do
            local full_volume_name="${service_name}_${volume}"
            if docker volume inspect "$full_volume_name" >/dev/null 2>&1; then
                docker run --rm \
                    -v "${full_volume_name}:/data:ro" \
                    -v "$backup_dir/$service_name:/backup" \
                    alpine:latest \
                    tar -czf "/backup/${volume}-pre-restore.tar.gz" -C /data . 2>/dev/null || true
            fi
        done
    fi
    
    log "SUCCESS" "Pre-restore backup created: $backup_dir"
}

# Stop service
stop_service() {
    local service_path="$1"
    local service_name=$(basename "$service_path")
    
    if [[ ! -d "$service_path" ]] || [[ ! -f "$service_path/docker-compose.yml" ]]; then
        log "WARN" "Service not found or no docker-compose.yml: $service_name"
        return 0
    fi
    
    log "INFO" "Stopping service: $service_name"
    
    cd "$service_path"
    
    if docker-compose down --remove-orphans; then
        log "SUCCESS" "Service stopped: $service_name"
    else
        log "WARN" "Failed to stop service cleanly: $service_name"
    fi
}

# Restore service configuration
restore_service_config() {
    local service_name="$1"
    local restore_dir="$2"
    
    log "INFO" "Restoring configuration for service: $service_name"
    
    # Extract services configuration if restoring all services
    if [[ "$service_name" == "all" ]] && [[ -f "$restore_dir/services-config.tar.gz" ]]; then
        log "INFO" "Extracting services configuration..."
        tar -xzf "$restore_dir/services-config.tar.gz" -C "$HOME" || {
            log "ERROR" "Failed to extract services configuration"
            return 1
        }
        log "SUCCESS" "Services configuration restored"
    elif [[ "$service_name" != "all" ]]; then
        # For individual services, we assume configuration is already in place
        # or was restored as part of the services-config.tar.gz
        log "INFO" "Individual service configuration restore completed"
    fi
}

# Restore service data
restore_service_data() {
    local service_name="$1"
    local restore_dir="$2"
    local service_path="$SERVICES_DIR/$service_name"
    
    if [[ ! -d "$restore_dir/$service_name" ]]; then
        log "WARN" "No data backup found for service: $service_name"
        return 0
    fi
    
    log "INFO" "Restoring data for service: $service_name"
    
    cd "$service_path"
    
    # Restore database dumps
    if [[ -f "$restore_dir/$service_name/postgres-dump.sql.gz" ]]; then
        log "INFO" "Restoring PostgreSQL database..."
        
        # Start only the database service for restoration
        docker-compose up -d postgres || {
            log "ERROR" "Failed to start PostgreSQL service"
            return 1
        }
        
        # Wait for database to be ready
        sleep 10
        
        # Restore database
        gunzip < "$restore_dir/$service_name/postgres-dump.sql.gz" | \
            docker-compose exec -T postgres psql -U postgres || {
            log "ERROR" "Failed to restore PostgreSQL database"
            return 1
        }
        
        log "SUCCESS" "PostgreSQL database restored"
    fi
    
    # Restore MySQL dumps
    if [[ -f "$restore_dir/$service_name/mysql-dump.sql.gz" ]]; then
        log "INFO" "Restoring MySQL database..."
        
        docker-compose up -d mysql || docker-compose up -d mariadb || {
            log "ERROR" "Failed to start MySQL/MariaDB service"
            return 1
        }
        
        sleep 10
        
        gunzip < "$restore_dir/$service_name/mysql-dump.sql.gz" | \
            docker-compose exec -T mysql mysql -u root || {
            log "ERROR" "Failed to restore MySQL database"
            return 1
        }
        
        log "SUCCESS" "MySQL database restored"
    fi
    
    # Restore MongoDB
    if [[ -d "$restore_dir/$service_name/mongodb" ]]; then
        log "INFO" "Restoring MongoDB database..."
        
        docker-compose up -d mongo || {
            log "ERROR" "Failed to start MongoDB service"
            return 1
        }
        
        sleep 10
        
        # Copy backup to container
        local mongo_container=$(docker-compose ps -q mongo)
        docker cp "$restore_dir/$service_name/mongodb" "$mongo_container:/tmp/"
        
        # Restore MongoDB
        docker-compose exec -T mongo mongorestore --drop --gzip /tmp/mongodb/ || {
            log "ERROR" "Failed to restore MongoDB database"
            return 1
        }
        
        log "SUCCESS" "MongoDB database restored"
    fi
    
    # Restore Redis
    if [[ -f "$restore_dir/$service_name/redis-dump.rdb" ]]; then
        log "INFO" "Restoring Redis data..."
        
        # Copy dump file to Redis data volume
        local redis_container=$(docker-compose ps -q redis)
        if [[ -n "$redis_container" ]]; then
            docker cp "$restore_dir/$service_name/redis-dump.rdb" "$redis_container:/data/dump.rdb"
            log "SUCCESS" "Redis data restored"
        fi
    fi
    
    # Restore volume backups
    for volume_backup in "$restore_dir/$service_name"/*.tar.gz; do
        if [[ -f "$volume_backup" ]] && [[ ! "$volume_backup" =~ (postgres|mysql|mongodb|redis) ]]; then
            local volume_name=$(basename "$volume_backup" .tar.gz)
            local full_volume_name="${service_name}_${volume_name}"
            
            log "INFO" "Restoring volume: $full_volume_name"
            
            # Create volume if it doesn't exist
            docker volume create "$full_volume_name" >/dev/null 2>&1 || true
            
            # Restore volume data
            docker run --rm \
                -v "${full_volume_name}:/data" \
                -v "$restore_dir/$service_name:/backup:ro" \
                alpine:latest \
                sh -c "cd /data && rm -rf ./* && tar -xzf /backup/$(basename "$volume_backup")" || {
                log "ERROR" "Failed to restore volume: $full_volume_name"
                continue
            }
            
            log "SUCCESS" "Volume restored: $full_volume_name"
        fi
    done
    
    # Restore file system backups
    for file_backup in "$restore_dir/$service_name"/{uploads,static,media,data}.tar.gz; do
        if [[ -f "$file_backup" ]]; then
            local backup_type=$(basename "$file_backup" .tar.gz)
            
            log "INFO" "Restoring $backup_type files..."
            
            if [[ -d "./$backup_type" ]]; then
                rm -rf "./$backup_type.backup"
                mv "./$backup_type" "./$backup_type.backup"
            fi
            
            tar -xzf "$file_backup" || {
                log "ERROR" "Failed to restore $backup_type files"
                continue
            }
            
            log "SUCCESS" "Restored $backup_type files"
        fi
    done
}

# Start service after restoration
start_service() {
    local service_path="$1"
    local service_name=$(basename "$service_path")
    
    log "INFO" "Starting service: $service_name"
    
    cd "$service_path"
    
    if docker-compose up -d --remove-orphans; then
        log "SUCCESS" "Service started: $service_name"
        
        # Wait for services to stabilize
        sleep 10
        
        # Check service health
        if docker-compose ps | grep -q "Up"; then
            log "SUCCESS" "Service is running: $service_name"
        else
            log "WARN" "Service may have issues: $service_name"
            docker-compose ps | while IFS= read -r line; do
                log "WARN" "  $line"
            done
        fi
    else
        log "ERROR" "Failed to start service: $service_name"
        return 1
    fi
}

# Restore single service
restore_single_service() {
    local service_name="$1"
    local restore_dir="$2"
    local service_path="$SERVICES_DIR/$service_name"
    
    log "INFO" "=== RESTORING SERVICE: $service_name ==="
    
    # Create pre-restore backup
    create_pre_restore_backup "$service_path"
    
    # Stop service
    stop_service "$service_path"
    
    # Restore based on mode
    case "$RESTORE_MODE" in
        "config")
            restore_service_config "$service_name" "$restore_dir"
            ;;
        "data")
            restore_service_data "$service_name" "$restore_dir"
            ;;
        "full")
            restore_service_config "$service_name" "$restore_dir"
            restore_service_data "$service_name" "$restore_dir"
            ;;
    esac
    
    # Start service
    start_service "$service_path"
    
    log "SUCCESS" "Service restoration completed: $service_name"
}

# Main restoration logic
perform_restore() {
    local restore_dir
    restore_dir=$(download_backup)
    
    if [[ "$SERVICE_NAME" == "all" ]]; then
        log "INFO" "=== RESTORING ALL SERVICES ==="
        
        # First restore configurations
        if [[ "$RESTORE_MODE" =~ ^(config|full)$ ]]; then
            restore_service_config "all" "$restore_dir"
        fi
        
        # Then restore each service's data
        for service_path in "$SERVICES_DIR"/*; do
            if [[ -d "$service_path" ]] && [[ -f "$service_path/docker-compose.yml" ]]; then
                local service_name=$(basename "$service_path")
                
                if [[ "$RESTORE_MODE" =~ ^(data|full)$ ]]; then
                    restore_single_service "$service_name" "$restore_dir"
                else
                    # Just start the service if only config was restored
                    start_service "$service_path"
                fi
            fi
        done
        
        log "SUCCESS" "All services restoration completed"
    else
        # Restore single service
        restore_single_service "$SERVICE_NAME" "$restore_dir"
    fi
    
    # Cleanup
    log "INFO" "Cleaning up temporary files..."
    rm -rf "$restore_dir"
    log "SUCCESS" "Cleanup completed"
}

# Generate restore report
generate_restore_report() {
    local end_time=$(date '+%Y-%m-%d %H:%M:%S')
    
    log "INFO" "=== RESTORE REPORT ==="
    log "INFO" "Completed at: $end_time"
    log "INFO" "Backup date: $BACKUP_DATE"
    log "INFO" "Service: $SERVICE_NAME"
    log "INFO" "Restore mode: $RESTORE_MODE"
    log "INFO" "=================="
}

# Main execution
main() {
    local start_time=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Setup
    mkdir -p "$(dirname "$LOG_FILE")"
    
    log "INFO" "Starting restore process at $start_time"
    
    # Parse arguments
    parse_arguments "$@"
    
    # Check prerequisites
    check_prerequisites
    
    # Interactive selection if needed
    select_backup_interactively
    select_service_interactively
    
    # Confirm restoration
    confirm_restore
    
    # Perform restoration
    perform_restore
    
    # Generate report
    generate_restore_report
    
    log "SUCCESS" "Restore process completed successfully"
}

# Cleanup on script interruption
cleanup_on_exit() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log "ERROR" "Restore script interrupted or failed with exit code: $exit_code"
        
        # Cleanup temporary files
        if [[ -d "$RESTORE_BASE_DIR" ]]; then
            log "INFO" "Cleaning up temporary restore files..."
            rm -rf "$RESTORE_BASE_DIR"
        fi
    fi
}

trap cleanup_on_exit EXIT

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi