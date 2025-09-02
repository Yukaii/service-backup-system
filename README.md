# Docker Services Backup System

A comprehensive, automated backup and maintenance solution for Docker Compose services with S3 storage and cross-platform support.

## 🚀 Quick Start

### 1. Clone and Install
```bash
git clone <repository-url>
cd ykmade-service-backup
make install
```

### 2. Setup Dependencies
```bash
make install-docker    # Install Docker & Docker Compose
make install-rclone    # Install rclone for S3 uploads
make setup-rclone      # Configure S3 credentials interactively
```

### 3. Configure and Test
```bash
export S3_BUCKET="your-backup-bucket-name"
make setup-cron        # Setup automated jobs
make test-backup       # Test the backup system
```

## 📁 Expected Directory Structure

Place your Docker Compose services in `~/Services/`:

```
~/Services/
├── service-a/
│   ├── docker-compose.yml
│   ├── .env
│   └── backup.sh (optional custom backup script)
├── service-b/
│   ├── docker-compose.yml
│   └── .env
└── ...
```

## 🔧 What Gets Installed

The system provides these automated scripts:

- **`backup-all-services.sh`** - Daily automated backups with S3 upload
- **`restore-service.sh`** - Interactive disaster recovery tool
- **`maintenance.sh`** - Weekly Docker cleanup and service updates
- **`health-check.sh`** - Hourly service monitoring with alerts
- **`validate-config.sh`** - System configuration validation

## ⚙️ Configuration

### Environment Variables
```bash
# Required
export S3_BUCKET="your-backup-bucket-name"

# Optional
export S3_REMOTE="backup-s3"                    # rclone remote name
export SERVICES_DIR="$HOME/Services"            # Services directory
export ALERT_EMAIL="admin@example.com"          # Email alerts
export DISCORD_WEBHOOK="https://discord.com..." # Discord notifications
export SLACK_WEBHOOK="https://hooks.slack.com..." # Slack notifications

# Service Ignore Configuration
export BACKUP_CONFIG_FILE="$HOME/.backup-ignore"    # Ignore list file
export BACKUP_IGNORE_SERVICES="service1,service2"   # Comma-separated list
```

### Custom Service Backups
For services requiring special backup procedures, create a `backup.sh` script in the service directory. Use the provided template:

```bash
cp templates/service-backup-template.sh ~/Services/my-service/backup.sh
chmod +x ~/Services/my-service/backup.sh
# Edit as needed
```

### Ignoring Services
Skip specific services from backup using either method:

**Method 1: Ignore File (Recommended)**
```bash
# Create/edit ignore list
cat > ~/.backup-ignore << EOF
# Services to skip
tolgee
weblate
gakuon
EOF
```

**Method 2: Environment Variable**
```bash
export BACKUP_IGNORE_SERVICES="tolgee,weblate,gakuon"
```

## 🔄 Usage

### Manual Operations
```bash
# Run backup manually
~/scripts/backup-all-services.sh

# Check system health
~/scripts/health-check.sh

# Perform maintenance
~/scripts/maintenance.sh

# Validate configuration
~/scripts/validate-config.sh

# List available backups
~/scripts/restore-service.sh --list

# Interactive restore
~/scripts/restore-service.sh
```

### Automated Schedule (via cron)
- **Daily 2:00 AM**: Full backup of all services
- **Weekly Sunday 3:00 AM**: System maintenance and updates
- **Hourly**: Health monitoring with alerts

## 📊 Monitoring & Alerts

The system supports multiple notification channels:
- **Email** (via mail/sendmail)
- **Discord** (webhook)
- **Slack** (webhook) 
- **Pushover** (API)

Configure webhooks in environment variables to receive alerts for:
- Service failures
- Backup failures
- Disk space warnings
- Maintenance reports

## 🛠️ Available Make Targets

```bash
make help              # Show all available commands
make check             # Verify system requirements
make status            # Show installation status
make install           # Full installation
make uninstall         # Remove the system
make clean             # Clean temporary files
make quick-install     # Development/testing install
```

## ☁️ S3 Storage Optimization

Configure S3 lifecycle policies to automatically transition backups:
- Day 7: Standard-IA
- Day 30: Glacier Instant Retrieval  
- Day 90: Glacier Flexible Retrieval
- Day 180: Deep Archive
- Day 365: Delete

## 🔒 Security Features

- Secure rclone configuration (600 permissions)
- Environment variable sanitization in backups
- Pre-restore backup creation
- Integrity verification of backup files
- Support for S3 server-side encryption

## 📋 System Requirements

- **Linux** (Ubuntu, CentOS, Debian, Fedora, SUSE, Arch, Alpine)
- **Docker** + **Docker Compose**
- **rclone** for S3 uploads
- **1GB+ RAM**, **5GB+ disk space**

## 🚨 Troubleshooting

1. **Check system status**: `make status`
2. **Validate configuration**: `~/scripts/validate-config.sh`
3. **View logs**: `tail -f ~/logs/backup.log`
4. **Test connectivity**: `rclone lsd backup-s3:`

## 📚 Documentation

- **[INSTALL.md](INSTALL.md)** - Detailed installation guide
- **Templates** in `templates/` directory
- **Script documentation** via `--help` flags

## 🆘 Support

For issues:
1. Run `~/scripts/validate-config.sh --full`
2. Check logs in `~/logs/`  
3. Review error messages and system status
4. Open GitHub issue with system info and logs

---

**Features**: ✅ Cross-platform ✅ Automated ✅ S3 Integration ✅ Docker Native ✅ Monitoring ✅ Disaster Recovery