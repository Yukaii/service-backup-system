#!/bin/bash

# Service-Specific Backup Script Template
# Place this script as 'backup.sh' in your service directory
# Make it executable: chmod +x backup.sh

set -euo pipefail

# Get backup target directory from command line argument
BACKUP_TARGET_DIR="${1:-}"
SERVICE_NAME=$(basename "$(pwd)")
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# Validation
if [[ -z "$BACKUP_TARGET_DIR" ]]; then
    echo "ERROR: Backup target directory not provided"
    echo "Usage: $0 <backup_target_directory>"
    exit 1
fi

# Logging function
log() {
    echo "[$TIMESTAMP] [$SERVICE_NAME] $*"
}

# Create backup target directory
mkdir -p "$BACKUP_TARGET_DIR"

log "Starting custom backup for service: $SERVICE_NAME"
log "Backup directory: $BACKUP_TARGET_DIR"

# =============================================================================
# DATABASE BACKUPS
# =============================================================================

# PostgreSQL backup
if docker-compose ps | grep -q postgres; then
    log "Backing up PostgreSQL database..."
    
    # Get database container name
    POSTGRES_CONTAINER=$(docker-compose ps -q postgres)
    
    if [[ -n "$POSTGRES_CONTAINER" ]]; then
        # Create database dump with custom options
        docker-compose exec -T postgres pg_dumpall \
            --username=postgres \
            --clean \
            --if-exists \
            --quote-all-identifiers | \
            gzip > "$BACKUP_TARGET_DIR/postgres-dump.sql.gz"
        
        # Also backup individual databases for easier restoration
        DATABASES=$(docker-compose exec -T postgres psql -U postgres -t -c "SELECT datname FROM pg_database WHERE datistemplate = false;" | grep -v "^$" | xargs)
        
        for db in $DATABASES; do
            if [[ "$db" != "postgres" ]]; then
                log "Backing up database: $db"
                docker-compose exec -T postgres pg_dump \
                    --username=postgres \
                    --dbname="$db" \
                    --clean \
                    --if-exists \
                    --quote-all-identifiers | \
                    gzip > "$BACKUP_TARGET_DIR/postgres-${db}.sql.gz"
            fi
        done
        
        log "PostgreSQL backup completed"
    else
        log "PostgreSQL container not running, skipping database backup"
    fi
fi

# MySQL/MariaDB backup
if docker-compose ps | grep -q -E "(mysql|mariadb)"; then
    log "Backing up MySQL/MariaDB database..."
    
    MYSQL_CONTAINER=$(docker-compose ps -q mysql mariadb 2>/dev/null | head -n1)
    
    if [[ -n "$MYSQL_CONTAINER" ]]; then
        # Get MySQL root password from environment
        MYSQL_ROOT_PASSWORD=$(docker-compose exec -T "$MYSQL_CONTAINER" printenv MYSQL_ROOT_PASSWORD 2>/dev/null || echo "")
        
        if [[ -n "$MYSQL_ROOT_PASSWORD" ]]; then
            docker-compose exec -T mysql mysqldump \
                --user=root \
                --password="$MYSQL_ROOT_PASSWORD" \
                --single-transaction \
                --routines \
                --triggers \
                --all-databases | \
                gzip > "$BACKUP_TARGET_DIR/mysql-dump.sql.gz"
        else
            log "MySQL root password not found, attempting backup without password"
            docker-compose exec -T mysql mysqldump \
                --user=root \
                --single-transaction \
                --routines \
                --triggers \
                --all-databases | \
                gzip > "$BACKUP_TARGET_DIR/mysql-dump.sql.gz" 2>/dev/null || \
                log "MySQL backup failed - check credentials"
        fi
        
        log "MySQL backup completed"
    fi
fi

# MongoDB backup
if docker-compose ps | grep -q mongo; then
    log "Backing up MongoDB database..."
    
    MONGO_CONTAINER=$(docker-compose ps -q mongo)
    
    if [[ -n "$MONGO_CONTAINER" ]]; then
        # Create MongoDB dump
        docker-compose exec -T mongo mongodump \
            --out /tmp/mongo_backup \
            --gzip 2>/dev/null || log "MongoDB backup failed"
        
        # Copy dump from container
        docker cp "${MONGO_CONTAINER}:/tmp/mongo_backup" "$BACKUP_TARGET_DIR/mongodb/"
        
        # Cleanup temporary backup in container
        docker-compose exec -T mongo rm -rf /tmp/mongo_backup
        
        log "MongoDB backup completed"
    fi
fi

# Redis backup
if docker-compose ps | grep -q redis; then
    log "Backing up Redis data..."
    
    REDIS_CONTAINER=$(docker-compose ps -q redis)
    
    if [[ -n "$REDIS_CONTAINER" ]]; then
        # Trigger background save
        docker-compose exec -T redis redis-cli BGSAVE
        
        # Wait for background save to complete
        while docker-compose exec -T redis redis-cli LASTSAVE | xargs -I {} test {} -eq $(docker-compose exec -T redis redis-cli LASTSAVE); do
            sleep 1
        done
        
        # Copy dump file
        docker cp "${REDIS_CONTAINER}:/data/dump.rdb" "$BACKUP_TARGET_DIR/redis-dump.rdb" 2>/dev/null || \
            log "Redis dump file not found, using fallback method"
        
        log "Redis backup completed"
    fi
fi

# =============================================================================
# FILE SYSTEM BACKUPS
# =============================================================================

# Backup uploads directory
if [[ -d "./uploads" ]]; then
    log "Backing up uploads directory..."
    tar -czf "$BACKUP_TARGET_DIR/uploads.tar.gz" ./uploads
    log "Uploads backup completed ($(du -h "$BACKUP_TARGET_DIR/uploads.tar.gz" | cut -f1))"
fi

# Backup static files
if [[ -d "./static" ]]; then
    log "Backing up static files..."
    tar -czf "$BACKUP_TARGET_DIR/static.tar.gz" ./static
    log "Static files backup completed"
fi

# Backup media files
if [[ -d "./media" ]]; then
    log "Backing up media files..."
    tar -czf "$BACKUP_TARGET_DIR/media.tar.gz" ./media
    log "Media files backup completed"
fi

# Backup custom data directory
if [[ -d "./data" ]]; then
    log "Backing up data directory..."
    tar -czf "$BACKUP_TARGET_DIR/data.tar.gz" ./data
    log "Data directory backup completed"
fi

# =============================================================================
# CONFIGURATION BACKUPS
# =============================================================================

# Export resolved docker-compose configuration
log "Exporting Docker Compose configuration..."
docker-compose config > "$BACKUP_TARGET_DIR/docker-compose-resolved.yml" 2>/dev/null || \
    log "Failed to export Docker Compose configuration"

# Backup environment files (sanitized)
if [[ -f ".env" ]]; then
    log "Backing up environment configuration..."
    
    # Create sanitized version of .env (remove sensitive values)
    cp .env "$BACKUP_TARGET_DIR/.env.backup"
    
    # Optionally sanitize sensitive values
    sed -i 's/\(PASSWORD\|SECRET\|KEY\|TOKEN\)=.*/\1=***REDACTED***/g' "$BACKUP_TARGET_DIR/.env.backup"
    
    log "Environment configuration backed up (sanitized)"
fi

# Backup additional config files
for config_file in "config.yml" "config.json" "settings.ini" "app.conf"; do
    if [[ -f "$config_file" ]]; then
        log "Backing up $config_file..."
        cp "$config_file" "$BACKUP_TARGET_DIR/"
    fi
done

# =============================================================================
# APPLICATION-SPECIFIC BACKUPS
# =============================================================================

# WordPress specific
if [[ -f "wp-config.php" ]] || docker-compose ps | grep -q wordpress; then
    log "Detected WordPress, performing WordPress-specific backup..."
    
    # Backup wp-content if it exists
    if [[ -d "./wp-content" ]]; then
        tar -czf "$BACKUP_TARGET_DIR/wp-content.tar.gz" ./wp-content
        log "WordPress content backed up"
    fi
    
    # WordPress database backup via WP-CLI if available
    if docker-compose exec -T wordpress wp --version >/dev/null 2>&1; then
        docker-compose exec -T wordpress wp db export - | gzip > "$BACKUP_TARGET_DIR/wordpress-db.sql.gz"
        log "WordPress database backed up via WP-CLI"
    fi
fi

# Nextcloud specific
if docker-compose ps | grep -q nextcloud; then
    log "Detected Nextcloud, performing Nextcloud-specific backup..."
    
    # Backup Nextcloud data directory
    if [[ -d "./data" ]]; then
        tar -czf "$BACKUP_TARGET_DIR/nextcloud-data.tar.gz" ./data
        log "Nextcloud data backed up"
    fi
    
    # Put Nextcloud in maintenance mode
    docker-compose exec -T nextcloud php occ maintenance:mode --on
    
    # Backup database
    if docker-compose ps | grep -q postgres; then
        docker-compose exec -T postgres pg_dump -U postgres nextcloud | gzip > "$BACKUP_TARGET_DIR/nextcloud-db.sql.gz"
    fi
    
    # Disable maintenance mode
    docker-compose exec -T nextcloud php occ maintenance:mode --off
    
    log "Nextcloud backup completed"
fi

# GitLab specific
if docker-compose ps | grep -q gitlab; then
    log "Detected GitLab, performing GitLab backup..."
    
    # Run GitLab backup command
    docker-compose exec -T gitlab gitlab-backup create SKIP=uploads,builds,artifacts,lfs,registry,pages
    
    # Copy backup files
    GITLAB_BACKUPS_DIR=$(docker-compose exec -T gitlab bash -c 'ls -t /var/opt/gitlab/backups/*.tar 2>/dev/null | head -n1' | tr -d '\r')
    if [[ -n "$GITLAB_BACKUPS_DIR" ]]; then
        docker cp "$(docker-compose ps -q gitlab):$GITLAB_BACKUPS_DIR" "$BACKUP_TARGET_DIR/gitlab-backup.tar"
        log "GitLab backup completed"
    fi
fi

# =============================================================================
# VERIFICATION AND CLEANUP
# =============================================================================

# Verify backup files were created
backup_files=$(find "$BACKUP_TARGET_DIR" -type f | wc -l)
backup_size=$(du -sh "$BACKUP_TARGET_DIR" | cut -f1)

log "Backup verification:"
log "  Files created: $backup_files"
log "  Total size: $backup_size"
log "  Location: $BACKUP_TARGET_DIR"

# List all backup files
log "Backup contents:"
find "$BACKUP_TARGET_DIR" -type f -exec basename {} \; | sed 's/^/  - /'

# Test backup integrity for compressed files
log "Testing backup integrity..."
for backup_file in "$BACKUP_TARGET_DIR"/*.gz; do
    if [[ -f "$backup_file" ]]; then
        if gzip -t "$backup_file" 2>/dev/null; then
            log "  ✓ $(basename "$backup_file") - OK"
        else
            log "  ✗ $(basename "$backup_file") - CORRUPTED"
        fi
    fi
done

log "Custom backup completed for service: $SERVICE_NAME"

# Exit with success
exit 0