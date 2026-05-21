#!/bin/bash
# Grafana Enterprise Installation Script
# Standard paths: /etc/grafana (config), /var/lib/grafana (data)
# Version: 12.2.1
# Ubuntu compatible

set -euo pipefail  # FIX #2: added -u and -o pipefail

# Variables
GRAFANA_VERSION="12.2.1"
DOWNLOAD_URL="https://dl.grafana.com/grafana-enterprise/release/${GRAFANA_VERSION}/grafana-enterprise_${GRAFANA_VERSION}_18655849634_linux_amd64.deb"
DEB_FILE="grafana-enterprise_${GRAFANA_VERSION}_18655849634_linux_amd64.deb"
# SHA256 sourced from official Grafana download page for 12.2.1 Ubuntu/Debian (64-bit)
EXPECTED_SHA256="8d2a55424ff257b9ef6fe3009ce18b12e690d4ecc1dcd43aef509f616185e23a"
SERVICE="grafana-server"

# FIX #4: Only update package lists — do NOT run a full system upgrade on production
sudo apt-get update -y

# Install dependencies
sudo apt-get install -y adduser libfontconfig1 musl

# Download package
wget -q "${DOWNLOAD_URL}"

# FIX #1: Verify SHA256 checksum before installing
echo "${EXPECTED_SHA256}  ${DEB_FILE}" | sha256sum -c - || {
  echo "ERROR: SHA256 checksum mismatch! Aborting installation."
  rm -f "${DEB_FILE}"
  exit 1
}

# Install package
sudo dpkg -i "${DEB_FILE}"

# FIX #6: Clean up downloaded .deb to free disk space
rm -f "${DEB_FILE}"

# Reload, enable, and start service
sudo systemctl daemon-reload
sudo systemctl enable "${SERVICE}"
sudo systemctl start "${SERVICE}"

# FIX #5: Confirm service is actually running before declaring success
if ! sudo systemctl is-active --quiet "${SERVICE}"; then
  echo "ERROR: Grafana service failed to start. Check logs with: journalctl -u ${SERVICE} -n 50"
  exit 1
fi

echo "Grafana Enterprise ${GRAFANA_VERSION} installed successfully!"
echo " - Config  : /etc/grafana/grafana.ini"
echo " - Data    : /var/lib/grafana/"
echo " - Logs    : journalctl -u ${SERVICE} -f"
echo " - Service : systemctl status ${SERVICE}"
echo ""
echo "⚠️  Access Grafana UI at http://$(hostname -I | awk '{print $1}'):3000"
echo "⚠️  Default credentials are admin/admin — CHANGE THIS IMMEDIATELY after first login!"