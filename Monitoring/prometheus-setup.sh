#!/bin/bash
# Prometheus Installation Script
# Standard paths: /etc/prometheus (config), /var/lib/prometheus (data)
# Version: 3.5.0

set -euo pipefail  # FIX #3: added -u (catch unset vars) and -o pipefail

# Set hostname
echo "prometheus" > /etc/hostname
hostname prometheus

# Variables
PROM_VERSION="3.5.0"
DOWNLOAD_URL="https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/prometheus-${PROM_VERSION}.linux-amd64.tar.gz"
TAR_FILE="prometheus-${PROM_VERSION}.linux-amd64.tar.gz"
EXTRACT_DIR="prometheus-${PROM_VERSION}.linux-amd64"
WORK_DIR="/tmp/prom"
CONFIG_DIR="/etc/prometheus"
DATA_DIR="/var/lib/prometheus"
BIN_DIR="/usr/local/bin"
SERVICE_FILE="/etc/systemd/system/prometheus.service"

# Create working directory
mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"

# Download, verify checksum, and extract
# FIX #2: Download and verify SHA256 checksum before extracting
wget -q "${DOWNLOAD_URL}"
wget -q "${DOWNLOAD_URL}.sha256sum"
sha256sum -c "${TAR_FILE}.sha256sum" || { echo "ERROR: Checksum verification failed!"; exit 1; }
tar xzvf "${TAR_FILE}"

# FIX #5: Create group and user only if they don't already exist
groupadd --system prometheus 2>/dev/null || true
useradd -s /sbin/nologin --system -g prometheus prometheus 2>/dev/null || true

# FIX #6: Create data directory safely (idempotent)
mkdir -p "${DATA_DIR}"
chown -R prometheus:prometheus "${DATA_DIR}"
chmod -R 750 "${DATA_DIR}"  # FIX #1: 750 instead of 775 (no world/group write)

# Create config subdirectories
mkdir -p "${CONFIG_DIR}/rules"
mkdir -p "${CONFIG_DIR}/rules.d"   # FIX #4: was "rules.s" — typo fixed
mkdir -p "${CONFIG_DIR}/files_sd"

# Enter extracted directory
cd "${EXTRACT_DIR}"

# Move binaries
mv prometheus promtool "${BIN_DIR}"

# Check version
prometheus --version

# Move config and console assets
mv prometheus.yml "${CONFIG_DIR}"

# FIX #7: Copy consoles and console_libraries (referenced in ExecStart)
cp -r consoles "${CONFIG_DIR}/consoles"
cp -r console_libraries "${CONFIG_DIR}/console_libraries"

# Create systemd service file
cat > "${SERVICE_FILE}" << EOF
[Unit]
Description=Prometheus
Documentation=https://prometheus.io/docs/introduction/overview/
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=prometheus
Group=prometheus
ExecReload=/bin/kill -HUP \$MAINPID
ExecStart=/usr/local/bin/prometheus \\
  --config.file=/etc/prometheus/prometheus.yml \\
  --storage.tsdb.path=/var/lib/prometheus \\
  --web.console.templates=/etc/prometheus/consoles \\
  --web.console.libraries=/etc/prometheus/console_libraries \\
  --web.listen-address=0.0.0.0:9090 \\
  --web.enable-remote-write-receiver
SyslogIdentifier=prometheus
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

# Set permissions on config dir
chown -R prometheus:prometheus "${CONFIG_DIR}"
chmod -R 750 "${CONFIG_DIR}"   # FIX #1: 750 instead of 775

# Reload and start service
systemctl daemon-reload
systemctl enable prometheus
systemctl start prometheus
systemctl status prometheus --no-pager

# Display service file for verification
cat "${SERVICE_FILE}"

# Cleanup temp files
rm -rf "${WORK_DIR}"