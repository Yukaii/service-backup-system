#!/bin/bash

# Configuration Validation Script
# Validates system configuration for the backup system

set -euo pipefail

# Configuration
SERVICES_DIR="${SERVICES_DIR:-$HOME/Services}"
S3_BUCKET="${S3_BUCKET:-}"
S3_REMOTE="${S3_REMOTE:-backup-s3}"
LOG_FILE="${LOG_FILE:-$HOME/logs/validation.log}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Validation counters
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
WARNING_CHECKS=0

# Arrays for tracking results
declare -a PASSED_LIST=()
declare -a FAILED_LIST=()
declare -a WARNING_LIST=()

# Logging function
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
    
    case "$level" in
        "ERROR")
            echo -e "${RED}✗ $message${NC}" >&2
            ;;
        "WARN")
            echo -e "${YELLOW}⚠ $message${NC}" >&2
            ;;
        "SUCCESS")
            echo -e "${GREEN}✓ $message${NC}"
            ;;
        "INFO")
            echo -e "${BLUE}ℹ $message${NC}"
            ;;
    esac
}

# Check function with result tracking
check() {
    local description="$1"
    local command="$2"
    local level="${3:-ERROR}"  # ERROR, WARN, or SUCCESS
    
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    
    if eval "$command" >/dev/null 2>&1; then
        log "SUCCESS" "$description"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
        PASSED_LIST+=("$description")
        return 0
    else
        if [[ "$level" == "WARN" ]]; then
            log "WARN" "$description"
            WARNING_CHECKS=$((WARNING_CHECKS + 1))
            WARNING_LIST+=("$description")
        else
            log "ERROR" "$description"
            FAILED_CHECKS=$((FAILED_CHECKS + 1))
            FAILED_LIST+=("$description")
        fi
        return 1
    fi
}

# System requirements validation
validate_system_requirements() {
    log "INFO" "=== SYSTEM REQUIREMENTS ==="
    
    check "Operating System is Linux" "test '$(uname -s)' = 'Linux'"
    check "Bash version 4.0 or higher" "test $(bash --version | head -n1 | grep -o '[0-9]\+' | head -n1) -ge 4"
    check "User has home directory" "test -d '$HOME'"
    check "User can write to home directory" "test -w '$HOME'"
    
    # Check available disk space
    check "At least 1GB free space in home directory" "test $(df '$HOME' | tail -n1 | awk '{print $4}') -gt 1048576"
    
    # Check system utilities
    check "curl is installed" "command -v curl"
    check "tar is installed" "command -v tar"
    check "gzip is installed" "command -v gzip"
    check "find is installed" "command -v find"
    check "awk is installed" "command -v awk"
    check "sed is installed" "command -v sed"
    
    # Optional utilities
    check "jq is installed (optional)" "command -v jq" "WARN"
    check "bc is installed (optional)" "command -v bc" "WARN"
    check "mail is available (optional)" "command -v mail || command -v sendmail" "WARN"
}

# Docker validation
validate_docker() {
    log "INFO" "=== DOCKER VALIDATION ==="
    
    check "Docker is installed" "command -v docker"
    
    if command -v docker >/dev/null 2>&1; then
        check "Docker daemon is running" "docker info"
        check "User can access Docker" "docker ps"
        check "Docker Compose is installed" "command -v docker-compose"
        
        if command -v docker-compose >/dev/null 2>&1; then
            check "Docker Compose version is recent" "docker-compose version --short | grep -E '^[2-9]\.|^1\.(2[7-9]|[3-9][0-9])'"
        fi
        
        # Check Docker storage driver
        local storage_driver
        storage_driver=$(docker info --format '{{.Driver}}' 2>/dev/null || echo "unknown")
        check "Docker storage driver is supported" "test '$storage_driver' != 'unknown'"
        
        # Check Docker root directory space
        local docker_root
        docker_root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo "/var/lib/docker")
        check "Docker root directory has sufficient space" "test $(df '$docker_root' | tail -n1 | awk '{print $4}') -gt 2097152"
    fi
}

# Rclone validation
validate_rclone() {
    log "INFO" "=== RCLONE VALIDATION ==="
    
    check "rclone is installed" "command -v rclone"
    
    if command -v rclone >/dev/null 2>&1; then
        check "rclone version is recent" "rclone version --check=false | head -n1 | grep -E 'v1\.(5[4-9]|[6-9][0-9])'"
        
        # Check if config exists
        local rclone_config="$HOME/.config/rclone/rclone.conf"
        check "rclone configuration exists" "test -f '$rclone_config'"
        
        if [[ -f "$rclone_config" ]]; then
            check "rclone configuration is readable" "test -r '$rclone_config'"
            check "rclone configuration has secure permissions" "test $(stat -c '%a' '$rclone_config') = '600'"
            
            # Check if remote is configured
            check "S3 remote '$S3_REMOTE' is configured" "rclone listremotes | grep -q '^${S3_REMOTE}:$'"
            
            if rclone listremotes | grep -q "^${S3_REMOTE}:$"; then
                if [[ -n "$S3_BUCKET" ]]; then
                    check "S3 bucket '$S3_BUCKET' is accessible" "rclone lsd '${S3_REMOTE}:${S3_BUCKET}/'"
                else
                    log "WARN" "S3_BUCKET not set, skipping bucket accessibility check"
                fi
            fi
        fi
    fi
}

# Directory structure validation
validate_directories() {
    log "INFO" "=== DIRECTORY STRUCTURE ==="
    
    local required_dirs=(
        "$HOME/Services"
        "$HOME/backups"
        "$HOME/logs"
        "$HOME/scripts"
    )
    
    for dir in "${required_dirs[@]}"; do
        check "Directory '$dir' exists" "test -d '$dir'"
        if [[ -d "$dir" ]]; then
            check "Directory '$dir' is writable" "test -w '$dir'"
        fi
    done
    
    # Check Services directory content
    if [[ -d "$SERVICES_DIR" ]]; then
        if [[ -n "$(ls -A "$SERVICES_DIR" 2>/dev/null)" ]]; then
            log "INFO" "Found services in $SERVICES_DIR:"
            for service_dir in "$SERVICES_DIR"/*; do
                if [[ -d "$service_dir" ]]; then
                    local service_name=$(basename "$service_dir")
                    log "INFO" "  - $service_name"
                    
                    # Check docker-compose.yml
                    check "Service '$service_name' has docker-compose.yml" "test -f '$service_dir/docker-compose.yml'"
                    
                    # Check for custom backup script
                    if [[ -f "$service_dir/backup.sh" ]]; then
                        check "Service '$service_name' backup script is executable" "test -x '$service_dir/backup.sh'"
                    fi
                fi
            done
        else
            log "WARN" "No services found in $SERVICES_DIR"
        fi
    fi
}

# Scripts validation
validate_scripts() {
    log "INFO" "=== SCRIPTS VALIDATION ==="
    
    local required_scripts=(
        "$HOME/scripts/backup-all-services.sh"
        "$HOME/scripts/restore-service.sh"
        "$HOME/scripts/maintenance.sh"
        "$HOME/scripts/health-check.sh"
    )
    
    for script in "${required_scripts[@]}"; do
        local script_name=$(basename "$script")
        check "Script '$script_name' exists" "test -f '$script'"
        
        if [[ -f "$script" ]]; then
            check "Script '$script_name' is executable" "test -x '$script'"
            check "Script '$script_name' has valid bash shebang" "head -n1 '$script' | grep -q '#!/bin/bash'"
            
            # Basic syntax check
            check "Script '$script_name' has valid syntax" "bash -n '$script'"
        fi
    done
}

# Cron jobs validation
validate_cron() {
    log "INFO" "=== CRON JOBS VALIDATION ==="
    
    local cron_content
    cron_content=$(crontab -l 2>/dev/null || echo "")
    
    if [[ -n "$cron_content" ]]; then
        check "Backup cron job is configured" "echo '$cron_content' | grep -q 'backup-all-services.sh'"
        check "Maintenance cron job is configured" "echo '$cron_content' | grep -q 'maintenance.sh'" "WARN"
        check "Health check cron job is configured" "echo '$cron_content' | grep -q 'health-check.sh'" "WARN"
    else
        log "WARN" "No cron jobs configured"
        WARNING_CHECKS=$((WARNING_CHECKS + 3))
        WARNING_LIST+=("No backup cron job configured")
        WARNING_LIST+=("No maintenance cron job configured")
        WARNING_LIST+=("No health check cron job configured")
    fi
}

# Environment validation
validate_environment() {
    log "INFO" "=== ENVIRONMENT VALIDATION ==="
    
    # Check required environment variables
    local env_vars=(
        "HOME:Current user home directory"
        "USER:Current username"
        "PATH:System PATH"
    )
    
    for var_info in "${env_vars[@]}"; do
        local var_name="${var_info%%:*}"
        local var_desc="${var_info##*:}"
        check "Environment variable '$var_name' is set ($var_desc)" "test -n \"\$$var_name\""
    done
    
    # Check optional environment variables
    local optional_vars=(
        "S3_BUCKET:S3 bucket name for backups"
        "S3_REMOTE:rclone remote name"
        "SERVICES_DIR:Services directory path"
    )
    
    for var_info in "${optional_vars[@]}"; do
        local var_name="${var_info%%:*}"
        local var_desc="${var_info##*:}"
        if [[ -n "${!var_name:-}" ]]; then
            log "SUCCESS" "Optional environment variable '$var_name' is set: ${!var_name}"
        else
            log "INFO" "Optional environment variable '$var_name' not set ($var_desc)"
        fi
    done
}

# Network connectivity validation
validate_network() {
    log "INFO" "=== NETWORK CONNECTIVITY ==="
    
    check "Internet connectivity" "curl -s --max-time 10 https://www.google.com >/dev/null"
    check "Docker Hub connectivity" "curl -s --max-time 10 https://hub.docker.com >/dev/null" "WARN"
    
    if command -v rclone >/dev/null 2>&1 && rclone listremotes | grep -q "^${S3_REMOTE}:$"; then
        check "S3 connectivity" "rclone lsd '${S3_REMOTE}:' --max-depth 1 --timeout 30s" "WARN"
    fi
}

# Performance validation
validate_performance() {
    log "INFO" "=== PERFORMANCE VALIDATION ==="
    
    # Check system load
    local load_avg
    load_avg=$(uptime | grep -o 'load average:.*' | cut -d: -f2 | cut -d, -f1 | xargs)
    check "System load is reasonable (< 5.0)" "test $(echo '$load_avg < 5.0' | bc 2>/dev/null || echo '1')"
    
    # Check available memory
    if command -v free >/dev/null 2>&1; then
        local available_mem
        available_mem=$(free -m | awk 'NR==2{printf "%.0f", $7}')
        check "At least 512MB memory available" "test ${available_mem:-0} -gt 512" "WARN"
    fi
    
    # Check I/O wait
    if command -v iostat >/dev/null 2>&1; then
        local iowait
        iowait=$(iostat -c 1 2 | tail -n1 | awk '{print $4}' | cut -d. -f1)
        check "I/O wait time is reasonable (< 50%)" "test ${iowait:-0} -lt 50" "WARN"
    fi
}

# Security validation
validate_security() {
    log "INFO" "=== SECURITY VALIDATION ==="
    
    # Check file permissions
    local sensitive_files=(
        "$HOME/.config/rclone/rclone.conf"
        "$HOME/.aws/credentials"
        "$HOME/.aws/config"
    )
    
    for file in "${sensitive_files[@]}"; do
        if [[ -f "$file" ]]; then
            local perms=$(stat -c '%a' "$file" 2>/dev/null || echo "000")
            check "File '$file' has secure permissions" "test '$perms' = '600'"
        fi
    done
    
    # Check if running as root
    check "Not running as root user" "test $(id -u) -ne 0" "WARN"
    
    # Check umask
    check "Umask is secure" "test $(umask) = '0022' -o $(umask) = '0077'" "WARN"
}

# Generate validation report
generate_report() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local overall_status="PASSED"
    
    if [[ $FAILED_CHECKS -gt 0 ]]; then
        overall_status="FAILED"
    elif [[ $WARNING_CHECKS -gt 0 ]]; then
        overall_status="WARNINGS"
    fi
    
    log "INFO" "=== VALIDATION REPORT ==="
    log "INFO" "Timestamp: $timestamp"
    log "INFO" "Overall Status: $overall_status"
    log "INFO" "Total Checks: $TOTAL_CHECKS"
    log "INFO" "Passed: $PASSED_CHECKS"
    log "INFO" "Failed: $FAILED_CHECKS"
    log "INFO" "Warnings: $WARNING_CHECKS"
    
    if [[ ${#FAILED_LIST[@]} -gt 0 ]]; then
        log "ERROR" "Failed checks:"
        for check in "${FAILED_LIST[@]}"; do
            log "ERROR" "  ✗ $check"
        done
    fi
    
    if [[ ${#WARNING_LIST[@]} -gt 0 ]]; then
        log "WARN" "Warning checks:"
        for check in "${WARNING_LIST[@]}"; do
            log "WARN" "  ⚠ $check"
        done
    fi
    
    log "INFO" "=========================="
    
    # Create JSON report
    local json_report_file="$HOME/logs/validation-report.json"
    cat > "$json_report_file" << EOF
{
  "timestamp": "$timestamp",
  "overall_status": "$overall_status",
  "total_checks": $TOTAL_CHECKS,
  "passed_checks": $PASSED_CHECKS,
  "failed_checks": $FAILED_CHECKS,
  "warning_checks": $WARNING_CHECKS,
  "failed_list": $(printf '%s\n' "${FAILED_LIST[@]}" | jq -R . | jq -s . 2>/dev/null || echo '[]'),
  "warning_list": $(printf '%s\n' "${WARNING_LIST[@]}" | jq -R . | jq -s . 2>/dev/null || echo '[]'),
  "passed_list": $(printf '%s\n' "${PASSED_LIST[@]}" | jq -R . | jq -s . 2>/dev/null || echo '[]')
}
EOF
    
    log "INFO" "JSON report saved to: $json_report_file"
    
    # Return appropriate exit code
    if [[ "$overall_status" == "FAILED" ]]; then
        return 1
    else
        return 0
    fi
}

# Show usage
show_usage() {
    cat << EOF
Configuration Validation Script

Usage: $0 [OPTIONS]

Options:
    --quick             Quick validation (skip optional checks)
    --full              Full validation including performance checks
    --json              Output results in JSON format only
    --fix               Attempt to fix common issues (interactive)
    -h, --help          Show this help message

Environment Variables:
    SERVICES_DIR        Services directory (default: \$HOME/Services)
    S3_BUCKET          S3 bucket name for backups
    S3_REMOTE          rclone remote name (default: backup-s3)
    LOG_FILE           Log file location (default: \$HOME/logs/validation.log)

Examples:
    $0                  # Full validation
    $0 --quick          # Quick validation
    $0 --json           # JSON output only

EOF
}

# Main execution
main() {
    local quick_mode=false
    local full_mode=true
    local json_only=false
    local fix_mode=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --quick)
                quick_mode=true
                full_mode=false
                shift
                ;;
            --full)
                full_mode=true
                shift
                ;;
            --json)
                json_only=true
                shift
                ;;
            --fix)
                fix_mode=true
                shift
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
    
    # Setup logging
    mkdir -p "$(dirname "$LOG_FILE")"
    
    if [[ "$json_only" != true ]]; then
        log "INFO" "Starting configuration validation..."
        log "INFO" "Mode: $([ "$quick_mode" = true ] && echo "Quick" || echo "Full")"
    fi
    
    # Run validation checks
    validate_system_requirements
    validate_docker
    validate_rclone
    validate_directories
    validate_scripts
    validate_environment
    
    if [[ "$quick_mode" != true ]]; then
        validate_cron
        validate_network
        
        if [[ "$full_mode" == true ]]; then
            validate_performance
            validate_security
        fi
    fi
    
    # Generate report
    if ! generate_report; then
        exit 1
    fi
    
    if [[ "$json_only" != true ]]; then
        log "SUCCESS" "Configuration validation completed"
    fi
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi