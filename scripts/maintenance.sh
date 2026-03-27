#!/bin/bash

# Docker Services Maintenance Script
# Performs system cleanup, updates, and health monitoring

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
LOG_FILE="${LOG_FILE:-$HOME/logs/maintenance.log}"
HOSTNAME=$(hostname)
MAX_LOG_SIZE="100M"
DISCORD_WEBHOOK="${DISCORD_WEBHOOK:-}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Log to file
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    
    # Log to console with colors
    case "$level" in
        "ERROR")
            echo -e "${RED}[$timestamp] ERROR: $message${NC}" >&2
            ;;
        "WARN")
            echo -e "${YELLOW}[$timestamp] WARN: $message${NC}" >&2
            ;;
        "SUCCESS")
            echo -e "${GREEN}[$timestamp] SUCCESS: $message${NC}"
            ;;
        "INFO")
            echo -e "${BLUE}[$timestamp] INFO: $message${NC}"
            ;;
        *)
            echo "[$timestamp] $level: $message"
            ;;
    esac
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Send notification to external services
send_notification() {
    local message="$1"
    local level="${2:-INFO}"
    local hostname="$HOSTNAME"
    
    # Discord notification
    if [[ -n "$DISCORD_WEBHOOK" ]]; then
        local color="3447003"  # Blue
        case "$level" in
            "ERROR") color="15158332" ;;  # Red
            "WARN") color="16776960" ;;   # Yellow
            "SUCCESS") color="3066993" ;; # Green
        esac
        
        curl -sS -H "Content-Type: application/json" \
             -X POST \
             -d "{
                \"embeds\": [{
                    \"title\": \"Maintenance Report - $hostname\",
                    \"description\": \"$message\",
                    \"color\": $color,
                    \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\"
                }]
             }" \
             "$DISCORD_WEBHOOK" >/dev/null 2>&1 || true
    fi
    
    # Slack notification
    if [[ -n "$SLACK_WEBHOOK" ]]; then
        local emoji=":information_source:"
        case "$level" in
            "ERROR") emoji=":x:" ;;
            "WARN") emoji=":warning:" ;;
            "SUCCESS") emoji=":white_check_mark:" ;;
        esac
        
        curl -sS -X POST -H 'Content-type: application/json' \
             --data "{\"text\": \"$emoji *Maintenance Report - $hostname*\n$message\"}" \
             "$SLACK_WEBHOOK" >/dev/null 2>&1 || true
    fi
}

# Setup directories and log rotation
setup_logging() {
    mkdir -p "$(dirname "$LOG_FILE")"
    
    # Rotate log if it's too large
    if [[ -f "$LOG_FILE" ]]; then
        local log_size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
        local max_size_bytes=$(echo "$MAX_LOG_SIZE" | sed 's/M/*1024*1024/; s/K/*1024/' | bc 2>/dev/null || echo 104857600)
        
        if [[ $log_size -gt $max_size_bytes ]]; then
            mv "$LOG_FILE" "${LOG_FILE}.old"
            log "INFO" "Log rotated due to size limit"
        fi
    fi
}

# Check Docker availability
check_docker() {
    if ! command_exists docker; then
        log "ERROR" "Docker is not installed"
        return 1
    fi
    
    if ! docker info >/dev/null 2>&1; then
        log "ERROR" "Cannot connect to Docker daemon"
        return 1
    fi
    
    if ! command_exists docker-compose; then
        log "ERROR" "docker-compose is not installed"
        return 1
    fi
    
    log "SUCCESS" "Docker system is available"
    return 0
}

# Get system information
get_system_info() {
    log "INFO" "=== SYSTEM INFORMATION ==="
    log "INFO" "Hostname: $HOSTNAME"
    log "INFO" "Date: $(date)"
    log "INFO" "Uptime: $(uptime)"
    log "INFO" "Load average: $(cat /proc/loadavg 2>/dev/null || echo 'N/A')"
    
    # Memory information
    if command_exists free; then
        log "INFO" "Memory usage:"
        free -h | while read -r line; do
            log "INFO" "  $line"
        done
    fi
    
    # Docker system info
    log "INFO" "Docker version: $(docker --version 2>/dev/null || echo 'N/A')"
    log "INFO" "Docker Compose version: $(docker-compose --version 2>/dev/null || echo 'N/A')"
    log "INFO" "=========================="
}

# Clean Docker system
clean_docker_system() {
    log "INFO" "Starting Docker system cleanup..."
    
    local cleanup_report=""
    
    # Remove unused containers, networks, images, and volumes
    if output=$(docker system prune -af --volumes 2>&1); then
        cleanup_report="Docker System Prune:\n$output\n\n"
        log "SUCCESS" "Docker system prune completed"
    else
        log "ERROR" "Docker system prune failed: $output"
        return 1
    fi
    
    # Additional image cleanup
    if output=$(docker image prune -af 2>&1); then
        cleanup_report+="Docker Image Prune:\n$output\n\n"
        log "SUCCESS" "Docker image prune completed"
    else
        log "WARN" "Docker image prune failed: $output"
    fi
    
    # Clean build cache
    if output=$(docker builder prune -af 2>&1); then
        cleanup_report+="Docker Builder Prune:\n$output"
        log "SUCCESS" "Docker builder prune completed"
    else
        log "WARN" "Docker builder prune failed: $output"
    fi
    
    # Log cleanup summary
    if [[ -n "$cleanup_report" ]]; then
        log "INFO" "Docker cleanup summary:"
        echo -e "$cleanup_report" | while IFS= read -r line; do
            [[ -n "$line" ]] && log "INFO" "  $line"
        done
    fi
    
    return 0
}

# Check disk usage
check_disk_usage() {
    log "INFO" "Checking disk usage..."
    
    # Overall disk usage
    log "INFO" "Disk usage by filesystem:"
    df -h | while IFS= read -r line; do
        log "INFO" "  $line"
    done
    
    # Docker space usage
    if command_exists docker; then
        log "INFO" "Docker space usage:"
        docker system df 2>/dev/null | while IFS= read -r line; do
            log "INFO" "  $line"
        done
    fi
    
    # Check for critical disk usage (>90%)
    local critical_mounts=()
    while IFS= read -r line; do
        if [[ $line =~ ([0-9]+)%.*(/.*) ]]; then
            local usage=${BASH_REMATCH[1]}
            local mount=${BASH_REMATCH[2]}
            if [[ $usage -gt 90 ]]; then
                critical_mounts+=("$mount ($usage%)")
            fi
        fi
    done < <(df -h | tail -n +2)
    
    if [[ ${#critical_mounts[@]} -gt 0 ]]; then
        log "WARN" "Critical disk usage detected:"
        for mount in "${critical_mounts[@]}"; do
            log "WARN" "  $mount"
        done
        send_notification "Critical disk usage detected: ${critical_mounts[*]}" "WARN"
    fi
}

# Update and restart services
update_services() {
    log "INFO" "Starting service updates..."
    
    if [[ ! -d "$SERVICES_DIR" ]]; then
        log "WARN" "Services directory not found: $SERVICES_DIR"
        return 0
    fi
    
    local updated_services=()
    local failed_services=()
    local total_services=0
    
    for service_path in "$SERVICES_DIR"/*; do
        if [[ -d "$service_path" ]] && [[ -f "$service_path/docker-compose.yml" ]]; then
            local service_name=$(basename "$service_path")
            total_services=$((total_services + 1))
            
            log "INFO" "Processing service: $service_name"
            cd "$service_path"
            
            # Pull latest images
            if docker-compose pull --quiet; then
                log "SUCCESS" "Images pulled for $service_name"
                
                # Check if any images were updated by comparing image IDs
                local needs_restart=false
                local current_images=$(docker-compose images -q 2>/dev/null | sort)
                
                # Recreate and restart services
                if docker-compose up -d --remove-orphans; then
                    log "SUCCESS" "Service updated and restarted: $service_name"
                    updated_services+=("$service_name")
                    
                    # Wait a moment for services to stabilize
                    sleep 5
                    
                    # Check if services are healthy
                    if ! docker-compose ps | grep -v "Up" | grep -q "$service_name"; then
                        log "SUCCESS" "Service $service_name is running normally"
                    else
                        log "WARN" "Service $service_name may have issues after update"
                    fi
                else
                    log "ERROR" "Failed to restart service: $service_name"
                    failed_services+=("$service_name")
                fi
            else
                log "ERROR" "Failed to pull images for service: $service_name"
                failed_services+=("$service_name")
            fi
        fi
    done
    
    # Summary report
    log "INFO" "Service update summary:"
    log "INFO" "  Total services: $total_services"
    log "INFO" "  Successfully updated: ${#updated_services[@]}"
    log "INFO" "  Failed updates: ${#failed_services[@]}"
    
    if [[ ${#updated_services[@]} -gt 0 ]]; then
        log "SUCCESS" "Updated services: ${updated_services[*]}"
    fi
    
    if [[ ${#failed_services[@]} -gt 0 ]]; then
        log "ERROR" "Failed services: ${failed_services[*]}"
        send_notification "Service update failures: ${failed_services[*]}" "ERROR"
    fi
}

# Perform health check on all services
health_check() {
    log "INFO" "Performing health check..."
    
    if [[ ! -d "$SERVICES_DIR" ]]; then
        log "WARN" "Services directory not found: $SERVICES_DIR"
        return 0
    fi
    
    local healthy_services=()
    local unhealthy_services=()
    local total_services=0
    
    log "INFO" "Service health status:"
    
    for service_path in "$SERVICES_DIR"/*; do
        if [[ -d "$service_path" ]] && [[ -f "$service_path/docker-compose.yml" ]]; then
            local service_name=$(basename "$service_path")
            total_services=$((total_services + 1))
            
            cd "$service_path"
            
            # Get service status
            local service_status=$(docker-compose ps --services --filter status=running 2>/dev/null | wc -l)
            local total_services_defined=$(docker-compose config --services 2>/dev/null | wc -l)
            
            if [[ $service_status -eq $total_services_defined ]] && [[ $service_status -gt 0 ]]; then
                log "SUCCESS" "  ✓ $service_name ($service_status/$total_services_defined containers running)"
                healthy_services+=("$service_name")
            else
                log "ERROR" "  ✗ $service_name ($service_status/$total_services_defined containers running)"
                unhealthy_services+=("$service_name")
                
                # Log detailed status for unhealthy services
                docker-compose ps 2>/dev/null | while IFS= read -r line; do
                    if [[ -n "$line" ]] && [[ "$line" != *"Name"* ]]; then
                        log "ERROR" "    $line"
                    fi
                done
            fi
        fi
    done
    
    # Health summary
    log "INFO" "Health check summary:"
    log "INFO" "  Total services: $total_services"
    log "INFO" "  Healthy services: ${#healthy_services[@]}"
    log "INFO" "  Unhealthy services: ${#unhealthy_services[@]}"
    
    if [[ ${#unhealthy_services[@]} -gt 0 ]]; then
        send_notification "Unhealthy services detected: ${unhealthy_services[*]}" "ERROR"
    fi
}

# Clean up old log files
cleanup_logs() {
    log "INFO" "Cleaning up old log files..."
    
    local cleaned_count=0
    local log_dirs=("$HOME/logs" "$SERVICES_DIR/*/logs")
    
    for log_dir in ${log_dirs[@]}; do
        if [[ -d "$log_dir" ]]; then
            # Remove log files older than 30 days
            while IFS= read -r -d '' log_file; do
                rm -f "$log_file"
                cleaned_count=$((cleaned_count + 1))
                log "INFO" "Removed old log: $(basename "$log_file")"
            done < <(find "$log_dir" -name "*.log" -type f -mtime +30 -print0 2>/dev/null)
        fi
    done
    
    if [[ $cleaned_count -eq 0 ]]; then
        log "INFO" "No old log files to clean up"
    else
        log "SUCCESS" "Cleaned up $cleaned_count old log files"
    fi
}

# Generate maintenance report
generate_report() {
    local end_time=$(date '+%Y-%m-%d %H:%M:%S')
    local report_file="$HOME/logs/maintenance-report-$(date +%Y%m%d).txt"
    
    log "INFO" "=== MAINTENANCE REPORT ==="
    log "INFO" "Completed at: $end_time"
    log "INFO" "Hostname: $HOSTNAME"
    log "INFO" "Report saved to: $report_file"
    log "INFO" "=========================="
    
    # Create detailed report file
    {
        echo "Docker Services Maintenance Report"
        echo "Generated on: $end_time"
        echo "Hostname: $HOSTNAME"
        echo ""
        echo "=== DISK USAGE ==="
        df -h
        echo ""
        echo "=== DOCKER SPACE USAGE ==="
        docker system df 2>/dev/null || echo "Docker not available"
        echo ""
        echo "=== SERVICE STATUS ==="
        for service_path in "$SERVICES_DIR"/*; do
            if [[ -d "$service_path" ]] && [[ -f "$service_path/docker-compose.yml" ]]; then
                echo "Service: $(basename "$service_path")"
                cd "$service_path"
                docker-compose ps 2>/dev/null || echo "  Status unavailable"
                echo ""
            fi
        done
    } > "$report_file"
    
    # Send summary notification
    local notification_message="Maintenance completed on $HOSTNAME at $end_time"
    send_notification "$notification_message" "SUCCESS"
}

# Main execution
main() {
    local start_time=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Setup
    setup_logging
    
    log "INFO" "Starting maintenance at $start_time"
    
    # System information
    get_system_info
    
    # Pre-flight checks
    if ! check_docker; then
        log "ERROR" "Docker system check failed, aborting maintenance"
        send_notification "Maintenance aborted: Docker system unavailable" "ERROR"
        exit 1
    fi
    
    # Maintenance tasks
    clean_docker_system
    check_disk_usage
    update_services
    health_check
    cleanup_logs
    
    # Generate final report
    generate_report
    
    log "SUCCESS" "Maintenance completed successfully"
}

# Cleanup on script interruption
cleanup_on_exit() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log "ERROR" "Maintenance script interrupted or failed with exit code: $exit_code"
        send_notification "Maintenance script failed with exit code: $exit_code" "ERROR"
    fi
}

trap cleanup_on_exit EXIT

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi