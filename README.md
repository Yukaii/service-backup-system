# Docker Compose Services Maintenance Guide

This guide provides a comprehensive backup and maintenance strategy for Docker Compose services running on a remote machine.

## 📁 Directory Structure

```
~/Services/
├── service-a/
│   ├── docker-compose.yml
│   ├── .env
│   └── backup.sh (optional)
├── service-b/
│   ├── docker-compose.yml
│   ├── .env
│   └── backup.sh (optional)
└── ...
```

## 🔧 Initial Setup

### 1. Install Required Tools

```bash
# Install rclone
curl https://rclone.org/install.sh | sudo bash

# Install Docker and Docker Compose (if not already installed)
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
```

### 2. Configure Rclone for S3

```bash
rclone config

# Follow the prompts:
# 1. New remote
# 2. Name: backup-s3
# 3. Storage: Amazon S3
# 4. Provider: AWS
# 5. Enter AWS credentials or use IAM role
# 6. Region: your-region
# 7. Leave other options as default
```

### 3. Create Backup Scripts

Create the main backup script at `~/scripts/backup-all-services.sh`:

```bash
#!/bin/bash

# Configuration
SERVICES_DIR="$HOME/Services"
BACKUP_BASE_DIR="$HOME/backups"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="$BACKUP_BASE_DIR/$DATE"
HOSTNAME=$(hostname)
S3_BUCKET="your-backup-bucket-name"
LOG_FILE="$HOME/logs/backup.log"

# Create directories
mkdir -p "$BACKUP_DIR"
mkdir -p "$(dirname "$LOG_FILE")"

echo "[$(date)] Starting backup process" >> "$LOG_FILE"

# Backup all service configurations
echo "[$(date)] Backing up service configurations..." >> "$LOG_FILE"
tar -czf "$BACKUP_DIR/services-config.tar.gz" \
    -C "$HOME" \
    --exclude='Services/*/data' \
    --exclude='Services/*/logs' \
    --exclude='Services/*/.git' \
    Services/

# Process each service
for service_path in "$SERVICES_DIR"/*; do
    if [ -d "$service_path" ]; then
        service_name=$(basename "$service_path")
        echo "[$(date)] Processing $service_name..." >> "$LOG_FILE"
        
        cd "$service_path"
        
        # Run service-specific backup if exists
        if [ -f "backup.sh" ]; then
            echo "[$(date)] Running custom backup for $service_name" >> "$LOG_FILE"
            bash backup.sh "$BACKUP_DIR/${service_name}"
        else
            # Default backup: export volumes
            if [ -f "docker-compose.yml" ]; then
                # Get all volumes for this service
                volumes=$(docker-compose config --volumes 2>/dev/null)
                if [ ! -z "$volumes" ]; then
                    mkdir -p "$BACKUP_DIR/${service_name}"
                    for volume in $volumes; do
                        docker run --rm \
                            -v "${service_name}_${volume}:/data:ro" \
                            -v "$BACKUP_DIR/${service_name}:/backup" \
                            alpine \
                            tar -czf "/backup/${volume}.tar.gz" -C /data .
                    done
                fi
            fi
        fi
    fi
done

# Upload to S3 using rclone
echo "[$(date)] Uploading to S3..." >> "$LOG_FILE"
rclone copy "$BACKUP_DIR" "backup-s3:${S3_BUCKET}/${HOSTNAME}/${DATE}/" \
    --transfers 4 \
    --checkers 8 \
    --log-file="$LOG_FILE" \
    --log-level INFO

# Clean up local backups older than 3 days
echo "[$(date)] Cleaning up old local backups..." >> "$LOG_FILE"
find "$BACKUP_BASE_DIR" -maxdepth 1 -type d -mtime +3 -exec rm -rf {} +

# Clean up S3 backups older than 30 days (optional, use lifecycle policy instead)
# rclone delete "backup-s3:${S3_BUCKET}/${HOSTNAME}/" \
#     --min-age 30d \
#     --rmdirs

echo "[$(date)] Backup completed" >> "$LOG_FILE"
```

### 4. Example Service-Specific Backup Script

For services with PostgreSQL, create `~/Services/service-a/backup.sh`:

```bash
#!/bin/bash
# backup.sh - Service-specific backup script

BACKUP_TARGET_DIR=$1
SERVICE_NAME=$(basename $(pwd))

mkdir -p "$BACKUP_TARGET_DIR"

# Backup PostgreSQL database
if docker-compose ps | grep -q postgres; then
    echo "Backing up PostgreSQL database..."
    docker-compose exec -T postgres pg_dumpall -U postgres | \
        gzip > "$BACKUP_TARGET_DIR/postgres-dump.sql.gz"
fi

# Backup specific directories if needed
if [ -d "./uploads" ]; then
    tar -czf "$BACKUP_TARGET_DIR/uploads.tar.gz" ./uploads
fi

# Export docker-compose environment
docker-compose config > "$BACKUP_TARGET_DIR/docker-compose-resolved.yml"
```

### 5. Create Maintenance Script

Create `~/scripts/maintenance.sh`:

```bash
#!/bin/bash

LOG_FILE="$HOME/logs/maintenance.log"
SERVICES_DIR="$HOME/Services"

echo "[$(date)] Starting maintenance" >> "$LOG_FILE"

# Clean Docker system
echo "[$(date)] Cleaning Docker system..." >> "$LOG_FILE"
docker system prune -af --volumes >> "$LOG_FILE" 2>&1
docker image prune -af >> "$LOG_FILE" 2>&1

# Check disk usage
echo "[$(date)] Disk usage:" >> "$LOG_FILE"
df -h >> "$LOG_FILE"

# Update all services
for service_path in "$SERVICES_DIR"/*; do
    if [ -d "$service_path" ] && [ -f "$service_path/docker-compose.yml" ]; then
        service_name=$(basename "$service_path")
        echo "[$(date)] Updating $service_name..." >> "$LOG_FILE"
        cd "$service_path"
        docker-compose pull >> "$LOG_FILE" 2>&1
        docker-compose up -d >> "$LOG_FILE" 2>&1
    fi
done

# Health check
echo "[$(date)] Service health status:" >> "$LOG_FILE"
for service_path in "$SERVICES_DIR"/*; do
    if [ -d "$service_path" ] && [ -f "$service_path/docker-compose.yml" ]; then
        cd "$service_path"
        docker-compose ps >> "$LOG_FILE" 2>&1
    fi
done

echo "[$(date)] Maintenance completed" >> "$LOG_FILE"
```

## ⏰ Automated Scheduling

Add to crontab (`crontab -e`):

```bash
# Daily backup at 2:00 AM
0 2 * * * /home/user/scripts/backup-all-services.sh

# Weekly maintenance on Sunday at 3:00 AM
0 3 * * 0 /home/user/scripts/maintenance.sh

# Health check every hour
0 * * * * docker ps --format "table {{.Names}}\t{{.Status}}" > /home/user/logs/health.log
```

## ☁️ S3 Lifecycle Policy

To optimize storage costs, configure the following lifecycle policy in your S3 bucket:

1. Go to S3 Console → Select your bucket → Management → Lifecycle rules
2. Create a new rule with the following configuration:

```json
{
  "Rules": [
    {
      "Id": "BackupArchivalPolicy",
      "Status": "Enabled",
      "Prefix": "",
      "Transitions": [
        {
          "Days": 7,
          "StorageClass": "STANDARD_IA"
        },
        {
          "Days": 30,
          "StorageClass": "GLACIER_INSTANT_RETRIEVAL"
        },
        {
          "Days": 90,
          "StorageClass": "GLACIER_FLEXIBLE_RETRIEVAL"
        },
        {
          "Days": 180,
          "StorageClass": "DEEP_ARCHIVE"
        }
      ],
      "Expiration": {
        "Days": 365
      }
    }
  ]
}
```

This policy will:
- Move backups to Infrequent Access after 7 days
- Move to Glacier Instant Retrieval after 30 days
- Move to Glacier Flexible Retrieval after 90 days
- Move to Deep Archive after 180 days
- Delete backups after 365 days

## 🔄 Restore Process

### Restore Entire Service

```bash
#!/bin/bash
# ~/scripts/restore-service.sh

HOSTNAME=$(hostname)
S3_BUCKET="your-backup-bucket-name"

# List available backups
echo "Available backups:"
rclone ls "backup-s3:${S3_BUCKET}/${HOSTNAME}/" --max-depth 1

read -p "Enter backup date (YYYYMMDD_HHMMSS): " BACKUP_DATE
read -p "Enter service name (or 'all' for everything): " SERVICE_NAME

RESTORE_DIR="$HOME/restore_temp"
mkdir -p "$RESTORE_DIR"

# Download backup
rclone copy "backup-s3:${S3_BUCKET}/${HOSTNAME}/${BACKUP_DATE}/" "$RESTORE_DIR/"

if [ "$SERVICE_NAME" = "all" ]; then
    # Restore all services
    tar -xzf "$RESTORE_DIR/services-config.tar.gz" -C "$HOME"
else
    # Restore specific service
    cd "$HOME/Services/$SERVICE_NAME"
    docker-compose down
    
    # Restore database if dump exists
    if [ -f "$RESTORE_DIR/$SERVICE_NAME/postgres-dump.sql.gz" ]; then
        gunzip < "$RESTORE_DIR/$SERVICE_NAME/postgres-dump.sql.gz" | \
            docker-compose exec -T postgres psql -U postgres
    fi
    
    # Restore volumes
    for volume_backup in "$RESTORE_DIR/$SERVICE_NAME"/*.tar.gz; do
        if [ -f "$volume_backup" ]; then
            volume_name=$(basename "$volume_backup" .tar.gz)
            docker run --rm \
                -v "${SERVICE_NAME}_${volume_name}:/data" \
                -v "$RESTORE_DIR/$SERVICE_NAME:/backup:ro" \
                alpine \
                tar -xzf "/backup/${volume_name}.tar.gz" -C /data
        fi
    done
    
    docker-compose up -d
fi

# Cleanup
rm -rf "$RESTORE_DIR"
```

## 📊 Monitoring

### Simple Health Check Script

```bash
#!/bin/bash
# ~/scripts/health-check.sh

SERVICES_DIR="$HOME/Services"
ALERT_EMAIL="admin@example.com"

for service_path in "$SERVICES_DIR"/*; do
    if [ -d "$service_path" ] && [ -f "$service_path/docker-compose.yml" ]; then
        cd "$service_path"
        service_name=$(basename "$service_path")
        
        # Check if all containers are running
        if ! docker-compose ps | grep -q "Up"; then
            echo "Service $service_name has issues" | \
                mail -s "Docker Service Alert: $service_name" "$ALERT_EMAIL"
        fi
    fi
done
```

## 🔒 Security Best Practices

1. **Rclone Configuration Security**
   ```bash
   chmod 600 ~/.config/rclone/rclone.conf
   ```

2. **Use IAM Roles on EC2**
   - When running on EC2, use IAM roles instead of storing credentials

3. **Encrypt Sensitive Backups**
   ```bash
   # Add encryption to rclone uploads
   rclone copy "$BACKUP_DIR" "backup-s3:${S3_BUCKET}/${HOSTNAME}/${DATE}/" \
       --s3-server-side-encryption "AES256"
   ```

4. **Regular Testing**
   - Test restore process monthly
   - Verify backup integrity
   - Document any service-specific restore procedures

## 📝 Service-Specific Notes

### PostgreSQL Services
- Always use `pg_dumpall` for complete backup
- Consider using `--clean` flag for easier restoration
- Stop writes during backup for consistency (optional)

### Services with File Uploads
- Include upload directories in backup
- Consider using volume mounts for easier backup
- Implement file deduplication if storage is a concern

### Redis Services
- Use `redis-cli BGSAVE` before backup
- Copy dump.rdb file
- Consider AOF persistence for better durability

## 🚨 Troubleshooting

### Common Issues

1. **Backup fails with permission errors**
   ```bash
   sudo chown -R $USER:$USER ~/Services
   chmod +x ~/scripts/*.sh
   ```

2. **Rclone upload fails**
   ```bash
   # Test rclone configuration
   rclone lsd backup-s3:
   
   # Check logs
   tail -f ~/logs/backup.log
   ```

3. **Docker volumes not found**
   ```bash
   # List all volumes
   docker volume ls
   
   # Inspect specific volume
   docker volume inspect <volume_name>
   ```

## 📅 Maintenance Calendar

- **Daily**: Automated backups
- **Weekly**: Docker cleanup, service updates
- **Monthly**: Test restore process, review logs
- **Quarterly**: Review and update backup retention policy
- **Yearly**: Full disaster recovery drill

## 📞 Support

For issues or questions:
1. Check logs in `~/logs/`
2. Verify service health with `docker-compose ps`
3. Test rclone connectivity
4. Review S3 bucket permissions


