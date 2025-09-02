# Docker Services Backup System - Installation Guide

This guide provides step-by-step instructions for installing and configuring the Docker Services Backup System across different Linux distributions.

## 📋 Table of Contents

- [Prerequisites](#prerequisites)
- [Quick Installation](#quick-installation)
- [Manual Installation](#manual-installation)
- [Configuration](#configuration)
- [Verification](#verification)
- [Troubleshooting](#troubleshooting)
- [Uninstallation](#uninstallation)

## 🔧 Prerequisites

### System Requirements

- **Operating System**: Linux (Ubuntu, CentOS, Debian, Fedora, SUSE, Arch, Alpine)
- **Architecture**: x86_64 (amd64) or ARM64
- **Memory**: Minimum 1GB RAM, 2GB recommended
- **Storage**: At least 5GB free space for backups and logs
- **User**: Non-root user with sudo privileges

### Software Dependencies

The following will be automatically installed during setup:

- **Docker** (latest stable version)
- **Docker Compose** (v1.27.0+ or v2.x)
- **rclone** (latest version)
- **System utilities**: curl, tar, gzip, jq, bc

## 🚀 Quick Installation

For most users, the automated installation is recommended:

### 1. Clone the Repository

```bash
git clone https://github.com/your-username/ykmade-service-backup.git
cd ykmade-service-backup
```

### 2. Run Quick Installation

```bash
make install
```

This will:
- Install system dependencies
- Create directory structure
- Install backup scripts
- Set appropriate permissions

### 3. Install Docker (if not already installed)

```bash
make install-docker
```

### 4. Install and Configure rclone

```bash
make install-rclone
make setup-rclone
```

Follow the interactive prompts to configure your S3 credentials.

### 5. Set up Automated Jobs

```bash
make setup-cron
```

### 6. Test the Installation

```bash
make test-backup S3_BUCKET=your-backup-bucket-name
```

## 🔨 Manual Installation

### Step 1: System Dependencies

#### Ubuntu/Debian

```bash
sudo apt-get update
sudo apt-get install -y curl tar gzip jq bc coreutils findutils
```

#### CentOS/RHEL/Rocky Linux

```bash
sudo yum install -y curl tar gzip jq bc coreutils findutils
# OR for newer versions
sudo dnf install -y curl tar gzip jq bc coreutils findutils
```

#### SUSE/openSUSE

```bash
sudo zypper install -y curl tar gzip jq bc coreutils findutils
```

#### Arch Linux

```bash
sudo pacman -S --noconfirm curl tar gzip jq bc coreutils findutils
```

#### Alpine Linux

```bash
sudo apk add --no-cache curl tar gzip jq bc coreutils findutils
```

### Step 2: Install Docker

#### Using Docker's Official Installation Script

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
```

**Note**: Log out and back in after adding user to docker group.

#### Install Docker Compose

```bash
sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
```

### Step 3: Install rclone

```bash
curl https://rclone.org/install.sh | sudo bash
```

### Step 4: Create Directory Structure

```bash
mkdir -p $HOME/{Services,backups,logs,scripts,restore_temp}
chmod 755 $HOME/{Services,backups,logs,scripts}
chmod 700 $HOME/restore_temp
```

### Step 5: Install Scripts

```bash
# Copy scripts to user directory
cp scripts/*.sh $HOME/scripts/
chmod +x $HOME/scripts/*.sh

# Copy templates
mkdir -p $HOME/templates
cp templates/*.sh $HOME/templates/
chmod +x $HOME/templates/*.sh

# Create system-wide symlinks (optional)
sudo ln -sf $HOME/scripts/backup-all-services.sh /usr/local/bin/backup-services
sudo ln -sf $HOME/scripts/restore-service.sh /usr/local/bin/restore-service
sudo ln -sf $HOME/scripts/maintenance.sh /usr/local/bin/maintenance-services
sudo ln -sf $HOME/scripts/health-check.sh /usr/local/bin/health-check-services
```

## ⚙️ Configuration

### 1. Configure rclone for S3 Access

Run the interactive configuration:

```bash
rclone config
```

Configure your remote with these settings:
1. **Name**: `backup-s3` (or set `S3_REMOTE` environment variable)
2. **Type**: `s3` (Amazon S3 Compliant Storage Providers)
3. **Provider**: `AWS` (Amazon Web Services S3)
4. **Credentials**: Enter your AWS Access Key ID and Secret Access Key
5. **Region**: Your AWS region (e.g., `us-west-2`)
6. **Endpoint**: Leave blank for AWS S3
7. **Other options**: Use defaults

Secure the rclone configuration:

```bash
chmod 600 ~/.config/rclone/rclone.conf
```

### 2. Set Environment Variables

Create a configuration file:

```bash
cat > ~/.backup-config << EOF
# S3 Configuration
export S3_BUCKET="your-backup-bucket-name"
export S3_REMOTE="backup-s3"

# Directory Configuration
export SERVICES_DIR="$HOME/Services"
export LOG_FILE="$HOME/logs/backup.log"

# Notification Configuration (optional)
export ALERT_EMAIL="admin@example.com"
export DISCORD_WEBHOOK="https://discord.com/api/webhooks/..."
export SLACK_WEBHOOK="https://hooks.slack.com/services/..."
EOF
```

Source the configuration:

```bash
echo "source ~/.backup-config" >> ~/.bashrc
source ~/.backup-config
```

### 3. Configure Automated Jobs

#### Set up Cron Jobs

```bash
crontab -e
```

Add the following entries:

```cron
# Source environment variables
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Daily backup at 2:00 AM
0 2 * * * source $HOME/.backup-config && $HOME/scripts/backup-all-services.sh >> $HOME/logs/backup-cron.log 2>&1

# Weekly maintenance on Sunday at 3:00 AM
0 3 * * 0 source $HOME/.backup-config && $HOME/scripts/maintenance.sh >> $HOME/logs/maintenance-cron.log 2>&1

# Health check every hour
0 * * * * source $HOME/.backup-config && $HOME/scripts/health-check.sh -q >> $HOME/logs/health-cron.log 2>&1
```

#### Alternative: Using systemd timers

Create service files:

```bash
# Backup service
sudo tee /etc/systemd/system/docker-backup.service << EOF
[Unit]
Description=Docker Services Backup
After=network.target docker.service

[Service]
Type=oneshot
User=$USER
EnvironmentFile=%h/.backup-config
ExecStart=%h/scripts/backup-all-services.sh
StandardOutput=append:%h/logs/backup-systemd.log
StandardError=append:%h/logs/backup-systemd.log
EOF

# Backup timer
sudo tee /etc/systemd/system/docker-backup.timer << EOF
[Unit]
Description=Daily Docker Services Backup
Requires=docker-backup.service

[Timer]
OnCalendar=daily
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Enable and start timer
sudo systemctl enable --now docker-backup.timer
```

## ✅ Verification

### 1. Validate Configuration

```bash
$HOME/scripts/validate-config.sh
```

This script will check:
- System requirements
- Docker installation
- rclone configuration
- Directory structure
- Script permissions
- Network connectivity

### 2. Manual Test

Test the backup system manually:

```bash
# Set your S3 bucket name
export S3_BUCKET="your-backup-bucket-name"

# Run backup script
$HOME/scripts/backup-all-services.sh
```

### 3. Check System Status

```bash
make status
```

Or manually check:

```bash
# Check installed scripts
ls -la $HOME/scripts/

# Check directory structure
ls -la $HOME/

# Check cron jobs
crontab -l

# Check logs
ls -la $HOME/logs/
```

### 4. Test Health Check

```bash
$HOME/scripts/health-check.sh -v
```

### 5. Test Restore Functionality

```bash
# List available backups
$HOME/scripts/restore-service.sh --list

# Test restore (interactive)
$HOME/scripts/restore-service.sh
```

## 🔍 Troubleshooting

### Common Issues

#### 1. Permission Denied Errors

```bash
# Fix script permissions
chmod +x $HOME/scripts/*.sh

# Fix directory permissions
chmod 755 $HOME/{Services,backups,logs,scripts}
chmod 700 $HOME/restore_temp

# Fix rclone config permissions
chmod 600 ~/.config/rclone/rclone.conf
```

#### 2. Docker Access Issues

```bash
# Add user to docker group
sudo usermod -aG docker $USER

# Restart Docker service
sudo systemctl restart docker

# Log out and back in to refresh group membership
```

#### 3. S3 Access Issues

```bash
# Test rclone configuration
rclone lsd backup-s3:

# Reconfigure rclone
rclone config

# Check AWS credentials
rclone config show backup-s3
```

#### 4. Cron Job Issues

```bash
# Check cron logs
sudo tail -f /var/log/cron

# Test cron job manually
source ~/.backup-config && $HOME/scripts/backup-all-services.sh

# Check cron environment
crontab -l | head -5
```

### Log Analysis

```bash
# Check backup logs
tail -f $HOME/logs/backup.log

# Check health check logs
tail -f $HOME/logs/health.log

# Check maintenance logs
tail -f $HOME/logs/maintenance.log

# Check validation logs
tail -f $HOME/logs/validation.log
```

### Performance Issues

```bash
# Check system resources
free -h
df -h
docker system df

# Check Docker performance
docker stats

# Monitor I/O
iostat -x 1
```

## 🗑️ Uninstallation

### Using Makefile

```bash
make uninstall
```

### Manual Uninstallation

```bash
# Remove cron jobs
crontab -l | grep -v "backup-all-services\|maintenance\|health-check" | crontab -

# Remove system symlinks
sudo rm -f /usr/local/bin/{backup-services,restore-service,maintenance-services,health-check-services}

# Remove scripts and logs (optional)
rm -rf $HOME/scripts $HOME/templates $HOME/logs

# Remove systemd services (if used)
sudo systemctl disable --now docker-backup.timer
sudo rm -f /etc/systemd/system/docker-backup.{service,timer}
sudo systemctl daemon-reload
```

## 📚 Next Steps

After successful installation:

1. **Configure Your Services**: Place your Docker Compose services in `$HOME/Services/`
2. **Create Custom Backup Scripts**: Use the template in `$HOME/templates/service-backup-template.sh`
3. **Set up Monitoring**: Configure notification webhooks for alerts
4. **Test Disaster Recovery**: Practice restore procedures
5. **Review Security**: Ensure proper file permissions and network access

## 🆘 Support

If you encounter issues:

1. Run the validation script: `$HOME/scripts/validate-config.sh --full`
2. Check the logs in `$HOME/logs/`
3. Review this troubleshooting guide
4. Check the main [README.md](README.md) for detailed usage information

For additional help, please open an issue in the GitHub repository with:
- Output of `make status`
- Relevant log files
- System information (`uname -a`, distribution info)
- Steps to reproduce the issue