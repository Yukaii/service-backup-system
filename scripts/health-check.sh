#!/bin/bash

# Docker Services Health Check Script
# Monitors Docker services health and sends alerts

set -euo pipefail

# Configuration
SERVICES_DIR="${SERVICES_DIR:-$HOME/Services}"
LOG_FILE="${LOG_FILE:-$HOME/logs/health.log}"
ALERT_EMAIL="${ALERT_EMAIL:-}"
DISCORD_WEBHOOK="${DISCORD_WEBHOOK:-}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
PUSHOVER_TOKEN="${PUSHOVER_TOKEN:-}"
PUSHOVER_USER="${PUSHOVER_USER:-}"
HOSTNAME=$(hostname)
MAX_LOG_SIZE="50M"

# Health check configuration
CHECK_TIMEOUT=30
RETRY_COUNT=3
RETRY_DELAY=10

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global counters
TOTAL_SERVICES=0
HEALTHY_SERVICES=0
UNHEALTHY_SERVICES=0
UNKNOWN_SERVICES=0

# Arrays for tracking
declare -a HEALTHY_LIST=()
declare -a UNHEALTHY_LIST=()
declare -a UNKNOWN_LIST=()

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

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Setup logging with rotation
setup_logging() {
    mkdir -p "$(dirname "$LOG_FILE")"
    
    # Rotate log if it's too large
    if [[ -f "$LOG_FILE" ]]; then
        local log_size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
        local max_size_bytes=$(echo "$MAX_LOG_SIZE" | sed 's/M/*1024*1024/; s/K/*1024/' | bc 2>/dev/null || echo 52428800)
        
        if [[ $log_size -gt $max_size_bytes ]]; then
            mv "$LOG_FILE" "${LOG_FILE}.old"
            log "INFO" "Health log rotated due to size limit"
        fi
    fi
}

# Send email alert
send_email_alert() {
    local subject="$1"
    local message="$2"
    local priority="${3:-normal}"
    
    if [[ -z "$ALERT_EMAIL" ]]; then
        return 0
    fi
    
    if command_exists mail; then
        echo "$message" | mail -s "$subject" "$ALERT_EMAIL" 2>/dev/null || {
            log "WARN" "Failed to send email alert"
        }
    elif command_exists sendmail; then
        {
            echo "To: $ALERT_EMAIL"
            echo "Subject: $subject"
            echo "From: docker-health@$HOSTNAME"
            echo ""
            echo "$message"
        } | sendmail "$ALERT_EMAIL" 2>/dev/null || {
            log "WARN" "Failed to send email alert via sendmail"
        }
    else
        log "WARN" "No email client available for alerts"
    fi
}

# Send Discord notification
send_discord_notification() {
    local title="$1"
    local message="$2"
    local level="${3:-INFO}"
    
    if [[ -z "$DISCORD_WEBHOOK" ]]; then
        return 0
    fi
    
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
                \"title\": \"$title\",
                \"description\": \"$message\",
                \"color\": $color,
                \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\",
                \"footer\": {
                    \"text\": \"$HOSTNAME\"
                }
            }]
         }" \
         "$DISCORD_WEBHOOK" >/dev/null 2>&1 || {
        log "WARN" "Failed to send Discord notification"
    }
}

# Send Slack notification
send_slack_notification() {
    local title="$1"
    local message="$2"
    local level="${3:-INFO}"
    
    if [[ -z "$SLACK_WEBHOOK" ]]; then
        return 0
    fi
    
    local emoji=":information_source:"
    case "$level" in
        "ERROR") emoji=":x:" ;;
        "WARN") emoji=":warning:" ;;
        "SUCCESS") emoji=":white_check_mark:" ;;
    esac
    
    curl -sS -X POST -H 'Content-type: application/json' \
         --data "{
            \"text\": \"$emoji *$title*\",
            \"blocks\": [
                {
                    \"type\": \"section\",
                    \"text\": {
                        \"type\": \"mrkdwn\",
                        \"text\": \"*$title*\n$message\"
                    }
                },
                {
                    \"type\": \"context\",
                    \"elements\": [
                        {
                            \"type\": \"mrkdwn\",
                            \"text\": \"Host: $HOSTNAME | $(date '+%Y-%m-%d %H:%M:%S')\"
                        }
                    ]
                }
            ]
         }" \
         "$SLACK_WEBHOOK" >/dev/null 2>&1 || {
        log "WARN" "Failed to send Slack notification"
    }
}

# Send Pushover notification
send_pushover_notification() {
    local title="$1"
    local message="$2"
    local priority="${3:-0}"
    
    if [[ -z "$PUSHOVER_TOKEN" ]] || [[ -z "$PUSHOVER_USER" ]]; then
        return 0
    fi
    
    # Convert priority levels
    case "$priority" in
        "ERROR") priority=1 ;;
        "WARN") priority=0 ;;
        *) priority=0 ;;
    esac
    
    curl -sS \
         -F "token=$PUSHOVER_TOKEN" \
         -F "user=$PUSHOVER_USER" \
         -F "title=$title" \
         -F "message=$message" \
         -F "priority=$priority" \
         https://api.pushover.net/1/messages.json >/dev/null 2>&1 || {
        log "WARN" "Failed to send Pushover notification"
    }
}

# Send notification to all configured services
send_notification() {
    local title="$1"
    local message="$2"
    local level="${3:-INFO}"
    
    send_email_alert "$title" "$message" "$level"
    send_discord_notification "$title" "$message" "$level"
    send_slack_notification "$title" "$message" "$level"
    send_pushover_notification "$title" "$message" "$level"
}

# Check Docker system health
check_docker_system() {
    log "INFO" "Checking Docker system health..."
    
    if ! command_exists docker; then
        log "ERROR" "Docker is not installed"
        return 1
    fi
    
    if ! docker info >/dev/null 2>&1; then
        log "ERROR" "Cannot connect to Docker daemon"
        send_notification "Docker System Alert" "Cannot connect to Docker daemon on $HOSTNAME" "ERROR"
        return 1
    fi
    
    # Check Docker disk usage
    local docker_space
    docker_space=$(docker system df --format "table {{.Type}}\t{{.Total}}\t{{.Active}}\t{{.Size}}\t{{.Reclaimable}}" 2>/dev/null || echo "")
    
    if [[ -n "$docker_space" ]]; then
        log "INFO" "Docker space usage:"
        echo "$docker_space" | while IFS= read -r line; do
            [[ -n "$line" ]] && log "INFO" "  $line"
        done
    fi
    
    log "SUCCESS" "Docker system is healthy"
    return 0
}

# Test HTTP endpoint
test_http_endpoint() {
    local url="$1"
    local expected_code="${2:-200}"
    local timeout="${3:-10}"
    
    local response_code
    response_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$timeout" "$url" 2>/dev/null || echo "000")
    
    if [[ "$response_code" == "$expected_code" ]]; then
        return 0
    else
        return 1
    fi
}

# Check service health
check_service_health() {
    local service_path="$1"
    local service_name=$(basename "$service_path")
    
    log "INFO" "Checking health of service: $service_name"
    
    cd "$service_path"
    
    # Check if docker-compose.yml exists
    if [[ ! -f "docker-compose.yml" ]]; then
        log "WARN" "No docker-compose.yml found for $service_name"
        UNKNOWN_SERVICES=$((UNKNOWN_SERVICES + 1))
        UNKNOWN_LIST+=("$service_name (no docker-compose.yml)")
        return 2
    fi
    
    local health_status="healthy"
    local health_details=""
    local containers_info=""
    
    # Get container status
    local running_containers=0
    local total_containers=0
    local container_statuses=""
    
    while IFS= read -r line; do
        if [[ -n "$line" && ! "$line" =~ ^(Name|----) ]]; then
            total_containers=$((total_containers + 1))
            containers_info+="$line\n"
            
            if echo "$line" | grep -q " Up "; then
                running_containers=$((running_containers + 1))
            else
                health_status="unhealthy"
                container_statuses+="$(echo "$line" | awk '{print $1": "$5" "$6" "$7" "$8}')\n"
            fi
        fi
    done < <(docker-compose ps 2>/dev/null)
    
    # Service health assessment
    if [[ $total_containers -eq 0 ]]; then
        health_status="unknown"
        health_details="No containers defined or service not started"
    elif [[ $running_containers -eq $total_containers ]]; then
        health_status="healthy"
        health_details="$running_containers/$total_containers containers running"
    elif [[ $running_containers -gt 0 ]]; then
        health_status="degraded"
        health_details="$running_containers/$total_containers containers running"
    else
        health_status="unhealthy"
        health_details="$running_containers/$total_containers containers running"
    fi
    
    # Perform additional health checks if configured
    local health_check_file="$service_path/health-check.sh"
    if [[ -f "$health_check_file" && -x "$health_check_file" ]]; then
        log "INFO" "Running custom health check for $service_name"
        
        if timeout "$CHECK_TIMEOUT" bash "$health_check_file"; then
            log "SUCCESS" "Custom health check passed for $service_name"
        else
            health_status="unhealthy"
            health_details+=" (custom health check failed)"
            log "ERROR" "Custom health check failed for $service_name"
        fi
    fi
    
    # Check common HTTP endpoints
    local http_endpoints=()
    
    # Look for common web service ports
    local exposed_ports
    exposed_ports=$(docker-compose port web 80 2>/dev/null || docker-compose port web 8080 2>/dev/null || docker-compose port app 3000 2>/dev/null || echo "")
    
    if [[ -n "$exposed_ports" ]]; then
        local port_ip=$(echo "$exposed_ports" | cut -d: -f1)
        local port_num=$(echo "$exposed_ports" | cut -d: -f2)
        
        if [[ "$port_ip" == "0.0.0.0" ]]; then
            port_ip="localhost"
        fi
        
        local test_url="http://$port_ip:$port_num"
        
        if test_http_endpoint "$test_url" "200" 5; then
            log "SUCCESS" "HTTP endpoint is responsive for $service_name: $test_url"
        elif test_http_endpoint "$test_url" "000" 5; then
            log "WARN" "HTTP endpoint is not responding for $service_name: $test_url"
            if [[ "$health_status" == "healthy" ]]; then
                health_status="degraded"
                health_details+=" (HTTP endpoint not responding)"
            fi
        fi
    fi
    
    # Log health status
    case "$health_status" in
        "healthy")
            log "SUCCESS" "Service $service_name is healthy ($health_details)"
            HEALTHY_SERVICES=$((HEALTHY_SERVICES + 1))
            HEALTHY_LIST+=("$service_name")
            return 0
            ;;
        "degraded")
            log "WARN" "Service $service_name is degraded ($health_details)"
            UNHEALTHY_SERVICES=$((UNHEALTHY_SERVICES + 1))
            UNHEALTHY_LIST+=("$service_name (degraded: $health_details)")
            if [[ -n "$container_statuses" ]]; then
                log "WARN" "Container issues: $container_statuses"
            fi
            return 1
            ;;
        "unhealthy")
            log "ERROR" "Service $service_name is unhealthy ($health_details)"
            UNHEALTHY_SERVICES=$((UNHEALTHY_SERVICES + 1))
            UNHEALTHY_LIST+=("$service_name (unhealthy: $health_details)")
            if [[ -n "$container_statuses" ]]; then
                log "ERROR" "Container issues: $container_statuses"
            fi
            return 1
            ;;
        *)
            log "WARN" "Service $service_name status unknown ($health_details)"
            UNKNOWN_SERVICES=$((UNKNOWN_SERVICES + 1))
            UNKNOWN_LIST+=("$service_name (unknown: $health_details)")
            return 2
            ;;
    esac
}

# Generate health report
generate_health_report() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local overall_status="HEALTHY"
    
    if [[ $UNHEALTHY_SERVICES -gt 0 ]]; then
        overall_status="UNHEALTHY"
    elif [[ $UNKNOWN_SERVICES -gt 0 ]]; then
        overall_status="UNKNOWN"
    fi
    
    log "INFO" "=== HEALTH CHECK REPORT ==="
    log "INFO" "Timestamp: $timestamp"
    log "INFO" "Hostname: $HOSTNAME"
    log "INFO" "Overall Status: $overall_status"
    log "INFO" "Total Services: $TOTAL_SERVICES"
    log "INFO" "Healthy: $HEALTHY_SERVICES"
    log "INFO" "Unhealthy: $UNHEALTHY_SERVICES"
    log "INFO" "Unknown: $UNKNOWN_SERVICES"
    
    # Detailed status
    if [[ ${#HEALTHY_LIST[@]} -gt 0 ]]; then
        log "SUCCESS" "Healthy services:"
        for service in "${HEALTHY_LIST[@]}"; do
            log "SUCCESS" "  ✓ $service"
        done
    fi
    
    if [[ ${#UNHEALTHY_LIST[@]} -gt 0 ]]; then
        log "ERROR" "Unhealthy services:"
        for service in "${UNHEALTHY_LIST[@]}"; do
            log "ERROR" "  ✗ $service"
        done
    fi
    
    if [[ ${#UNKNOWN_LIST[@]} -gt 0 ]]; then
        log "WARN" "Unknown status services:"
        for service in "${UNKNOWN_LIST[@]}"; do
            log "WARN" "  ? $service"
        done
    fi
    
    log "INFO" "=========================="
    
    # Send notifications for unhealthy services
    if [[ $UNHEALTHY_SERVICES -gt 0 ]]; then
        local alert_message="Health Check Alert - $HOSTNAME\n\n"
        alert_message+="$UNHEALTHY_SERVICES out of $TOTAL_SERVICES services are unhealthy:\n\n"
        
        for service in "${UNHEALTHY_LIST[@]}"; do
            alert_message+="• $service\n"
        done
        
        alert_message+="\nTimestamp: $timestamp"
        
        send_notification "Docker Services Health Alert" "$(echo -e "$alert_message")" "ERROR"
    fi
    
    # Create JSON report for monitoring systems
    local json_report_file="$HOME/logs/health-report.json"
    cat > "$json_report_file" << EOF
{
  "timestamp": "$timestamp",
  "hostname": "$HOSTNAME",
  "overall_status": "$overall_status",
  "total_services": $TOTAL_SERVICES,
  "healthy_services": $HEALTHY_SERVICES,
  "unhealthy_services": $UNHEALTHY_SERVICES,
  "unknown_services": $UNKNOWN_SERVICES,
  "healthy_list": $(printf '%s\n' "${HEALTHY_LIST[@]}" | jq -R . | jq -s .),
  "unhealthy_list": $(printf '%s\n' "${UNHEALTHY_LIST[@]}" | jq -R . | jq -s .),
  "unknown_list": $(printf '%s\n' "${UNKNOWN_LIST[@]}" | jq -R . | jq -s .)
}
EOF
    
    return $([ "$overall_status" = "HEALTHY" ] && echo 0 || echo 1)
}

# Show usage
show_usage() {
    cat << EOF
Docker Services Health Check Script

Usage: $0 [OPTIONS]

Options:
    -s, --service SERVICE    Check specific service only
    -j, --json              Output results in JSON format
    -q, --quiet             Suppress console output (log file only)
    -v, --verbose           Enable verbose logging
    -h, --help              Show this help message

Environment Variables:
    SERVICES_DIR            Services directory (default: \$HOME/Services)
    LOG_FILE               Log file location (default: \$HOME/logs/health.log)
    ALERT_EMAIL            Email address for alerts
    DISCORD_WEBHOOK        Discord webhook URL for notifications
    SLACK_WEBHOOK          Slack webhook URL for notifications
    PUSHOVER_TOKEN         Pushover application token
    PUSHOVER_USER          Pushover user key

Examples:
    $0                      # Check all services
    $0 -s nginx            # Check specific service
    $0 -j                  # Output JSON report
    $0 -q                  # Quiet mode

EOF
}

# Parse command line arguments
parse_arguments() {
    local specific_service=""
    local json_output=false
    local quiet_mode=false
    local verbose_mode=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -s|--service)
                specific_service="$2"
                shift 2
                ;;
            -j|--json)
                json_output=true
                shift
                ;;
            -q|--quiet)
                quiet_mode=true
                shift
                ;;
            -v|--verbose)
                verbose_mode=true
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
    
    # Set global variables
    SPECIFIC_SERVICE="$specific_service"
    JSON_OUTPUT="$json_output"
    QUIET_MODE="$quiet_mode"
    VERBOSE_MODE="$verbose_mode"
}

# Main execution
main() {
    local start_time=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Parse arguments
    parse_arguments "$@"
    
    # Setup
    setup_logging
    
    log "INFO" "Starting health check at $start_time"
    
    # Check Docker system
    if ! check_docker_system; then
        log "ERROR" "Docker system check failed"
        exit 1
    fi
    
    # Check services directory
    if [[ ! -d "$SERVICES_DIR" ]]; then
        log "ERROR" "Services directory not found: $SERVICES_DIR"
        exit 1
    fi
    
    # Perform health checks
    if [[ -n "${SPECIFIC_SERVICE:-}" ]]; then
        # Check specific service
        local service_path="$SERVICES_DIR/$SPECIFIC_SERVICE"
        if [[ -d "$service_path" ]]; then
            TOTAL_SERVICES=1
            check_service_health "$service_path"
        else
            log "ERROR" "Service not found: $SPECIFIC_SERVICE"
            exit 1
        fi
    else
        # Check all services
        for service_path in "$SERVICES_DIR"/*; do
            if [[ -d "$service_path" ]]; then
                TOTAL_SERVICES=$((TOTAL_SERVICES + 1))
                check_service_health "$service_path"
            fi
        done
    fi
    
    # Generate report
    if ! generate_health_report; then
        log "WARN" "Some services are not healthy"
    fi
    
    log "INFO" "Health check completed"
    
    # Exit with appropriate code
    if [[ $UNHEALTHY_SERVICES -gt 0 ]]; then
        exit 1
    else
        exit 0
    fi
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi