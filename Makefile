# Docker Services Backup System Makefile
# Installs and configures the backup system across different Linux distributions

.DEFAULT_GOAL := help
.PHONY: help install uninstall check setup-dirs setup-cron setup-rclone test clean status

# Configuration
PREFIX ?= /usr/local
INSTALL_DIR = $(PREFIX)/bin
SCRIPTS_DIR = ./scripts
TEMPLATES_DIR = ./templates
SERVICE_USER ?= $(USER)
SERVICE_HOME ?= $(HOME)

# Detect OS and distribution
OS := $(shell uname -s)
DISTRO := $(shell if [ -f /etc/os-release ]; then . /etc/os-release && echo $$ID; else echo "unknown"; fi)
PACKAGE_MANAGER := $(shell \
	if command -v apt-get >/dev/null 2>&1; then echo "apt"; \
	elif command -v yum >/dev/null 2>&1; then echo "yum"; \
	elif command -v dnf >/dev/null 2>&1; then echo "dnf"; \
	elif command -v zypper >/dev/null 2>&1; then echo "zypper"; \
	elif command -v pacman >/dev/null 2>&1; then echo "pacman"; \
	elif command -v apk >/dev/null 2>&1; then echo "apk"; \
	else echo "unknown"; fi)

# Colors for output
RED := \033[0;31m
GREEN := \033[0;32m
YELLOW := \033[1;33m
BLUE := \033[0;34m
NC := \033[0m # No Color

# Helper functions
define log_info
	@echo -e "$(BLUE)[INFO]$(NC) $(1)"
endef

define log_success
	@echo -e "$(GREEN)[SUCCESS]$(NC) $(1)"
endef

define log_warn
	@echo -e "$(YELLOW)[WARN]$(NC) $(1)"
endef

define log_error
	@echo -e "$(RED)[ERROR]$(NC) $(1)"
endef

help: ## Show this help message
	@echo "Docker Services Backup System"
	@echo "============================="
	@echo ""
	@echo "Detected system:"
	@echo "  OS: $(OS)"
	@echo "  Distribution: $(DISTRO)"
	@echo "  Package Manager: $(PACKAGE_MANAGER)"
	@echo "  User: $(SERVICE_USER)"
	@echo "  Home: $(SERVICE_HOME)"
	@echo ""
	@echo "Available targets:"
	@awk 'BEGIN {FS = ":.*##"}; /^[a-zA-Z_-]+:.*##/ { printf "  %-20s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@echo ""
	@echo "Environment variables:"
	@echo "  PREFIX            Installation prefix (default: /usr/local)"
	@echo "  SERVICE_USER      User to run services (default: current user)"
	@echo "  SERVICE_HOME      Home directory (default: current user home)"
	@echo "  S3_BUCKET         S3 bucket name for backups"
	@echo "  S3_REMOTE         rclone remote name (default: backup-s3)"

check: ## Check system requirements and dependencies
	$(call log_info,"Checking system requirements...")
	@echo "System Information:"
	@echo "  OS: $(OS)"
	@echo "  Distribution: $(DISTRO)"
	@echo "  Package Manager: $(PACKAGE_MANAGER)"
	@echo "  Architecture: $(shell uname -m)"
	@echo "  Kernel: $(shell uname -r)"
	@echo ""
	@echo "Checking dependencies:"
	
	@if command -v bash >/dev/null 2>&1; then \
		echo "  ✓ bash: $(shell bash --version | head -n1)"; \
	else \
		echo "  ✗ bash: Not found"; \
		exit 1; \
	fi
	
	@if command -v docker >/dev/null 2>&1; then \
		echo "  ✓ docker: $(shell docker --version)"; \
	else \
		echo "  ✗ docker: Not installed"; \
		echo "    Install with: make install-docker"; \
	fi
	
	@if command -v docker-compose >/dev/null 2>&1; then \
		echo "  ✓ docker-compose: $(shell docker-compose --version)"; \
	else \
		echo "  ✗ docker-compose: Not installed"; \
		echo "    Install with: make install-docker"; \
	fi
	
	@if command -v rclone >/dev/null 2>&1; then \
		echo "  ✓ rclone: $(shell rclone version --check=false | head -n1)"; \
	else \
		echo "  ✗ rclone: Not installed"; \
		echo "    Install with: make install-rclone"; \
	fi
	
	@if command -v curl >/dev/null 2>&1; then \
		echo "  ✓ curl: $(shell curl --version | head -n1)"; \
	else \
		echo "  ✗ curl: Not found"; \
	fi
	
	@if command -v tar >/dev/null 2>&1; then \
		echo "  ✓ tar: $(shell tar --version | head -n1 2>/dev/null || echo 'Available')"; \
	else \
		echo "  ✗ tar: Not found"; \
	fi
	
	@if command -v gzip >/dev/null 2>&1; then \
		echo "  ✓ gzip: Available"; \
	else \
		echo "  ✗ gzip: Not found"; \
	fi
	
	@if command -v jq >/dev/null 2>&1; then \
		echo "  ✓ jq: $(shell jq --version)"; \
	else \
		echo "  ⚠ jq: Not installed (optional, needed for JSON reports)"; \
	fi
	
	@if command -v bc >/dev/null 2>&1; then \
		echo "  ✓ bc: Available"; \
	else \
		echo "  ⚠ bc: Not installed (optional, used for size calculations)"; \
	fi
	
	$(call log_success,"System check completed")

install-deps: ## Install system dependencies
	$(call log_info,"Installing system dependencies for $(DISTRO)...")
	
ifeq ($(PACKAGE_MANAGER),apt)
	sudo apt-get update
	sudo apt-get install -y curl tar gzip jq bc coreutils findutils
else ifeq ($(PACKAGE_MANAGER),yum)
	sudo yum install -y curl tar gzip jq bc coreutils findutils
else ifeq ($(PACKAGE_MANAGER),dnf)
	sudo dnf install -y curl tar gzip jq bc coreutils findutils
else ifeq ($(PACKAGE_MANAGER),zypper)
	sudo zypper install -y curl tar gzip jq bc coreutils findutils
else ifeq ($(PACKAGE_MANAGER),pacman)
	sudo pacman -S --noconfirm curl tar gzip jq bc coreutils findutils
else ifeq ($(PACKAGE_MANAGER),apk)
	sudo apk add --no-cache curl tar gzip jq bc coreutils findutils
else
	$(call log_warn,"Unknown package manager: $(PACKAGE_MANAGER)")
	$(call log_warn,"Please install dependencies manually: curl tar gzip jq bc")
endif
	
	$(call log_success,"Dependencies installed")

install-docker: ## Install Docker and Docker Compose
	$(call log_info,"Installing Docker and Docker Compose...")
	
	@if ! command -v docker >/dev/null 2>&1; then \
		echo "Installing Docker..."; \
		curl -fsSL https://get.docker.com | sh; \
		sudo usermod -aG docker $(SERVICE_USER); \
		echo "Please log out and back in to use Docker without sudo"; \
	else \
		echo "Docker is already installed"; \
	fi
	
	@if ! command -v docker-compose >/dev/null 2>&1; then \
		echo "Installing Docker Compose..."; \
		sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(shell uname -s)-$(shell uname -m)" -o /usr/local/bin/docker-compose; \
		sudo chmod +x /usr/local/bin/docker-compose; \
	else \
		echo "Docker Compose is already installed"; \
	fi
	
	$(call log_success,"Docker installation completed")

install-rclone: ## Install rclone
	$(call log_info,"Installing rclone...")
	
	@if ! command -v rclone >/dev/null 2>&1; then \
		curl https://rclone.org/install.sh | sudo bash; \
	else \
		echo "rclone is already installed: $$(rclone version --check=false | head -n1)"; \
	fi
	
	$(call log_success,"rclone installation completed")

setup-dirs: ## Create necessary directories
	$(call log_info,"Setting up directories...")
	
	@mkdir -p $(SERVICE_HOME)/Services
	@mkdir -p $(SERVICE_HOME)/backups
	@mkdir -p $(SERVICE_HOME)/logs
	@mkdir -p $(SERVICE_HOME)/scripts
	@mkdir -p $(SERVICE_HOME)/restore_temp
	
	@chmod 755 $(SERVICE_HOME)/Services
	@chmod 755 $(SERVICE_HOME)/backups
	@chmod 755 $(SERVICE_HOME)/logs
	@chmod 755 $(SERVICE_HOME)/scripts
	@chmod 700 $(SERVICE_HOME)/restore_temp
	
	$(call log_success,"Directory structure created")

install-scripts: setup-dirs ## Install backup scripts to system
	$(call log_info,"Installing backup scripts...")
	
	# Install scripts to user directory
	@cp $(SCRIPTS_DIR)/*.sh $(SERVICE_HOME)/scripts/
	@chmod +x $(SERVICE_HOME)/scripts/*.sh
	
	# Create symlinks to system bin directory (if writable)
	@if [ -w $(INSTALL_DIR) ] || sudo test -w $(INSTALL_DIR) 2>/dev/null; then \
		echo "Creating system-wide symlinks..."; \
		sudo ln -sf $(SERVICE_HOME)/scripts/backup-all-services.sh $(INSTALL_DIR)/backup-services; \
		sudo ln -sf $(SERVICE_HOME)/scripts/restore-service.sh $(INSTALL_DIR)/restore-service; \
		sudo ln -sf $(SERVICE_HOME)/scripts/maintenance.sh $(INSTALL_DIR)/maintenance-services; \
		sudo ln -sf $(SERVICE_HOME)/scripts/health-check.sh $(INSTALL_DIR)/health-check-services; \
	else \
		echo "Cannot create system-wide symlinks (no write access to $(INSTALL_DIR))"; \
		echo "Scripts are available in $(SERVICE_HOME)/scripts/"; \
	fi
	
	# Install templates
	@mkdir -p $(SERVICE_HOME)/templates
	@cp $(TEMPLATES_DIR)/*.sh $(SERVICE_HOME)/templates/
	@chmod +x $(SERVICE_HOME)/templates/*.sh
	
	$(call log_success,"Scripts installed successfully")

setup-cron: ## Setup automated cron jobs
	$(call log_info,"Setting up cron jobs...")
	
	@# Create temporary cron file
	@crontab -l 2>/dev/null > /tmp/current_cron || true
	
	@# Remove any existing backup-related cron jobs
	@grep -v "backup-all-services\|maintenance\|health-check-services" /tmp/current_cron > /tmp/new_cron || true
	
	@# Add new cron jobs
	@echo "# Docker Services Backup System - Automated Jobs" >> /tmp/new_cron
	@echo "# Daily backup at 2:00 AM" >> /tmp/new_cron
	@echo "0 2 * * * $(SERVICE_HOME)/scripts/backup-all-services.sh >> $(SERVICE_HOME)/logs/backup-cron.log 2>&1" >> /tmp/new_cron
	@echo "# Weekly maintenance on Sunday at 3:00 AM" >> /tmp/new_cron
	@echo "0 3 * * 0 $(SERVICE_HOME)/scripts/maintenance.sh >> $(SERVICE_HOME)/logs/maintenance-cron.log 2>&1" >> /tmp/new_cron
	@echo "# Health check every hour" >> /tmp/new_cron
	@echo "0 * * * * $(SERVICE_HOME)/scripts/health-check.sh -q >> $(SERVICE_HOME)/logs/health-cron.log 2>&1" >> /tmp/new_cron
	@echo "" >> /tmp/new_cron
	
	@# Install new crontab
	@crontab /tmp/new_cron
	@rm /tmp/current_cron /tmp/new_cron 2>/dev/null || true
	
	$(call log_success,"Cron jobs configured")
	@echo "Scheduled jobs:"
	@echo "  - Daily backup: 2:00 AM"
	@echo "  - Weekly maintenance: Sunday 3:00 AM" 
	@echo "  - Hourly health check"

setup-rclone: ## Interactive rclone configuration
	$(call log_info,"Setting up rclone configuration...")
	
	@if ! command -v rclone >/dev/null 2>&1; then \
		echo "rclone is not installed. Run 'make install-rclone' first."; \
		exit 1; \
	fi
	
	@echo ""
	@echo "Please configure rclone with your S3 credentials:"
	@echo "1. Choose 'New remote'"
	@echo "2. Name it 'backup-s3' (or set S3_REMOTE environment variable)"
	@echo "3. Choose 'Amazon S3 Compliant Storage Providers'"
	@echo "4. Choose 'Amazon Web Services (AWS) S3'"
	@echo "5. Enter your AWS Access Key ID and Secret Access Key"
	@echo "6. Choose your region"
	@echo "7. Leave other options as default"
	@echo ""
	@rclone config
	
	@# Secure rclone config file
	@chmod 600 $(HOME)/.config/rclone/rclone.conf 2>/dev/null || true
	
	$(call log_success,"rclone configuration completed")

test-backup: ## Test backup functionality
	$(call log_info,"Testing backup system...")
	
	@if [ -z "$(S3_BUCKET)" ]; then \
		echo "Error: S3_BUCKET environment variable must be set"; \
		echo "Example: make test-backup S3_BUCKET=my-backup-bucket"; \
		exit 1; \
	fi
	
	@echo "Testing rclone configuration..."
	@S3_BUCKET=$(S3_BUCKET) rclone lsd backup-s3:$(S3_BUCKET)/ || exit 1
	
	@echo "Running backup script in test mode..."
	@S3_BUCKET=$(S3_BUCKET) $(SERVICE_HOME)/scripts/backup-all-services.sh || exit 1
	
	$(call log_success,"Backup test completed successfully")

test-health: ## Test health check functionality
	$(call log_info,"Testing health check system...")
	
	@$(SERVICE_HOME)/scripts/health-check.sh -v
	
	$(call log_success,"Health check test completed")

status: ## Show system status
	$(call log_info,"Docker Services Backup System Status")
	@echo ""
	
	@echo "Installation Status:"
	@if [ -f $(SERVICE_HOME)/scripts/backup-all-services.sh ]; then \
		echo "  ✓ Scripts installed"; \
	else \
		echo "  ✗ Scripts not installed"; \
	fi
	
	@if crontab -l 2>/dev/null | grep -q backup-all-services; then \
		echo "  ✓ Cron jobs configured"; \
	else \
		echo "  ✗ Cron jobs not configured"; \
	fi
	
	@if [ -f $(HOME)/.config/rclone/rclone.conf ] && rclone listremotes | grep -q backup-s3; then \
		echo "  ✓ rclone configured"; \
	else \
		echo "  ✗ rclone not configured"; \
	fi
	
	@echo ""
	@echo "Directory Status:"
	@for dir in Services backups logs scripts; do \
		if [ -d $(SERVICE_HOME)/$$dir ]; then \
			echo "  ✓ $(SERVICE_HOME)/$$dir"; \
		else \
			echo "  ✗ $(SERVICE_HOME)/$$dir"; \
		fi \
	done
	
	@echo ""
	@echo "Recent Activity:"
	@if [ -f $(SERVICE_HOME)/logs/backup.log ]; then \
		echo "  Last backup: $$(tail -n1 $(SERVICE_HOME)/logs/backup.log 2>/dev/null | cut -d']' -f1 | cut -d'[' -f2 || echo 'No backup log found')"; \
	fi
	
	@if [ -f $(SERVICE_HOME)/logs/health.log ]; then \
		echo "  Last health check: $$(tail -n1 $(SERVICE_HOME)/logs/health.log 2>/dev/null | cut -d']' -f1 | cut -d'[' -f2 || echo 'No health log found')"; \
	fi
	
	@echo ""
	@echo "Services Directory:"
	@if [ -d $(SERVICE_HOME)/Services ] && [ "$$(ls -A $(SERVICE_HOME)/Services 2>/dev/null)" ]; then \
		ls -la $(SERVICE_HOME)/Services | grep '^d' | awk '{print "  - " $$9}' | grep -v '^\.\|^\.\.'; \
	else \
		echo "  No services configured"; \
	fi

install: install-deps install-scripts setup-dirs ## Full installation
	$(call log_info,"Running full installation...")
	
	@echo ""
	@echo "Installation Summary:"
	@echo "====================="
	@echo "✓ System dependencies installed"
	@echo "✓ Scripts installed to $(SERVICE_HOME)/scripts/"
	@echo "✓ Directory structure created"
	@echo ""
	@echo "Next steps:"
	@echo "1. Install Docker: make install-docker"
	@echo "2. Install rclone: make install-rclone"
	@echo "3. Configure rclone: make setup-rclone"
	@echo "4. Set up cron jobs: make setup-cron"
	@echo "5. Test the system: make test-backup S3_BUCKET=your-bucket-name"
	@echo ""
	
	$(call log_success,"Installation completed")

uninstall: ## Remove the backup system
	$(call log_info,"Uninstalling backup system...")
	
	# Remove cron jobs
	@crontab -l 2>/dev/null | grep -v "backup-all-services\|maintenance\|health-check-services" | crontab - 2>/dev/null || true
	
	# Remove system symlinks
	@sudo rm -f $(INSTALL_DIR)/backup-services 2>/dev/null || true
	@sudo rm -f $(INSTALL_DIR)/restore-service 2>/dev/null || true
	@sudo rm -f $(INSTALL_DIR)/maintenance-services 2>/dev/null || true
	@sudo rm -f $(INSTALL_DIR)/health-check-services 2>/dev/null || true
	
	# Remove scripts (ask for confirmation)
	@echo "Remove scripts and logs from $(SERVICE_HOME)? [y/N]"
	@read -r confirm; \
	if [ "$$confirm" = "y" ] || [ "$$confirm" = "Y" ]; then \
		rm -rf $(SERVICE_HOME)/scripts; \
		rm -rf $(SERVICE_HOME)/templates; \
		rm -rf $(SERVICE_HOME)/logs; \
		echo "Scripts and logs removed"; \
	else \
		echo "Scripts and logs preserved"; \
	fi
	
	$(call log_success,"Uninstallation completed")

clean: ## Clean temporary files and old logs
	$(call log_info,"Cleaning temporary files...")
	
	@rm -rf $(SERVICE_HOME)/restore_temp/* 2>/dev/null || true
	@find $(SERVICE_HOME)/logs -name "*.log.old" -delete 2>/dev/null || true
	@find $(SERVICE_HOME)/backups -maxdepth 1 -type d -mtime +7 -exec rm -rf {} + 2>/dev/null || true
	
	$(call log_success,"Cleanup completed")

quick-install: ## Quick installation for development/testing
	$(call log_info,"Quick installation for development...")
	
	@make install-deps
	@make setup-dirs
	@make install-scripts
	
	$(call log_success,"Quick installation completed")
	@echo ""
	@echo "For production use, also run:"
	@echo "  make install-docker"
	@echo "  make install-rclone" 
	@echo "  make setup-rclone"
	@echo "  make setup-cron"