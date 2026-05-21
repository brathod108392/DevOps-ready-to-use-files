#!/bin/bash
# Loki Installation Script
# Standard paths: /etc/loki (config), /var/lib/loki (data)
# Version: 3.6.11
# Docs: https://grafana.com/docs/loki/latest/

set -euo pipefail

# ── Root check ────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This script must be run as root. Use: sudo $0"
  exit 1
fi

# ── Variables ─────────────────────────────────────────────────────────────────
LOKI_VERSION="3.6.11"
DOWNLOAD_URL="https://github.com/grafana/loki/releases/download/v${LOKI_VERSION}/loki-linux-amd64.zip"
ZIP_FILE="loki-linux-amd64.zip"
BINARY_NAME="loki-linux-amd64"
# SHA256 from official GitHub release page for v3.6.11 loki-linux-amd64.zip
# Verify at: https://github.com/grafana/loki/releases/tag/v3.6.11
EXPECTED_SHA256="sha256:e87959e3d7f32ae3e6a74704d71f5721d51c7558ff42614a7a0c85b5da2a9c9d"
WORK_DIR="/tmp/loki-install"
BIN_DIR="/usr/local/bin"
CONFIG_DIR="/etc/loki"
DATA_DIR="/var/lib/loki"
SERVICE_FILE="/etc/systemd/system/loki.service"
SERVICE="loki"

# ── Color output helpers ───────────────────────────────────────────────────────
info()    { echo "[INFO]  $*"; }
success() { echo "[OK]    $*"; }
error()   { echo "[ERROR] $*" >&2; }

# ── Working directory ─────────────────────────────────────────────────────────
info "Creating working directory ${WORK_DIR}"
mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"

# ── Download binary ───────────────────────────────────────────────────────────
info "Downloading Loki v${LOKI_VERSION}..."
wget -q --show-progress "${DOWNLOAD_URL}" -O "${ZIP_FILE}"

# ── Checksum verification ─────────────────────────────────────────────────────
# NOTE: Replace VERIFY_AT_GITHUB_RELEASE_PAGE above with the actual SHA256 from:
# https://github.com/grafana/loki/releases/tag/v${LOKI_VERSION}
# Look for loki-linux-amd64.zip in the assets list.
if [[ "${EXPECTED_SHA256}" == "VERIFY_AT_GITHUB_RELEASE_PAGE" ]]; then
  info "⚠️  Skipping checksum — replace EXPECTED_SHA256 in the script with the"
  info "    value from https://github.com/grafana/loki/releases/tag/v${LOKI_VERSION}"
else
  info "Verifying SHA256 checksum..."
  echo "${EXPECTED_SHA256}  ${ZIP_FILE}" | sha256sum -c - || {
    error "SHA256 checksum mismatch! The download may be corrupted or tampered with."
    rm -f "${ZIP_FILE}"
    exit 1
  }
  success "Checksum verified."
fi

# ── Extract binary ────────────────────────────────────────────────────────────
info "Extracting binary..."
apt-get install -y unzip -qq
unzip -q "${ZIP_FILE}"
chmod +x "${BINARY_NAME}"
mv "${BINARY_NAME}" "${BIN_DIR}/loki"
success "Binary installed to ${BIN_DIR}/loki"

# ── Verify binary works ───────────────────────────────────────────────────────
loki --version
success "Loki binary is functional."

# ── Create system user and group ──────────────────────────────────────────────
info "Creating loki system user and group..."
getent group loki  &>/dev/null || groupadd --system loki
getent passwd loki &>/dev/null || useradd \
  --system \
  --no-create-home \
  --shell /sbin/nologin \
  --gid loki \
  loki
success "User/group loki ready."

# ── Create directories ────────────────────────────────────────────────────────
info "Creating data and config directories..."
mkdir -p "${CONFIG_DIR}"
mkdir -p "${DATA_DIR}/chunks"
mkdir -p "${DATA_DIR}/wal"
mkdir -p "${DATA_DIR}/rules"
mkdir -p "${DATA_DIR}/boltdb-cache"

chown -R loki:loki "${DATA_DIR}" "${CONFIG_DIR}"
chmod -R 750 "${DATA_DIR}" "${CONFIG_DIR}"
success "Directories created and permissions set."

# ── Write Loki config ─────────────────────────────────────────────────────────
info "Writing Loki configuration to ${CONFIG_DIR}/loki.yml..."
cat > "${CONFIG_DIR}/loki.yml" << 'EOF'
# Loki Configuration
# Docs: https://grafana.com/docs/loki/latest/configuration/

auth_enabled: false

server:
  http_listen_port: 3100
  grpc_listen_port: 9096
  log_level: warn
  log_format: logfmt

# Single-binary mode for standalone installs
# Change to 'distributed' for production clusters
target: all

common:
  instance_addr: 127.0.0.1
  path_prefix: /var/lib/loki
  storage:
    filesystem:
      chunks_directory: /var/lib/loki/chunks
      rules_directory:  /var/lib/loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

# Schema — use v13 (current recommended for Loki 3.x)
schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

# Query performance tuning
query_range:
  results_cache:
    cache:
      embedded_cache:
        enabled: true
        max_size_mb: 150

# Ingestion limits (tune to your log volume)
limits_config:
  reject_old_samples:         true
  reject_old_samples_max_age: 168h    # 7 days
  ingestion_rate_mb:          16
  ingestion_burst_size_mb:    32
  max_query_lookback:         720h    # 30 days
  retention_period:           744h    # 31 days

# Compactor — handles retention and index compaction
compactor:
  working_directory:         /var/lib/loki/boltdb-cache
  delete_request_store:      filesystem
  retention_enabled:         true
  retention_delete_delay:    2h
  retention_delete_worker_count: 150

# Ruler (for alerting rules — optional)
ruler:
  storage:
    type: local
    local:
      directory: /var/lib/loki/rules
  rule_path:        /var/lib/loki/rules
  alertmanager_url: http://localhost:9093
  ring:
    kvstore:
      store: inmemory
  enable_api: true

# Analytics — disable to avoid phoning home
analytics:
  reporting_enabled: false
EOF

chown loki:loki "${CONFIG_DIR}/loki.yml"
chmod 640 "${CONFIG_DIR}/loki.yml"
success "Configuration written."

# ── Write systemd service ─────────────────────────────────────────────────────
info "Creating systemd service file at ${SERVICE_FILE}..."
cat > "${SERVICE_FILE}" << EOF
[Unit]
Description=Grafana Loki — Log Aggregation System
Documentation=https://grafana.com/docs/loki/latest/
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=loki
Group=loki
ExecStart=${BIN_DIR}/loki --config.file=${CONFIG_DIR}/loki.yml
ExecReload=/bin/kill -HUP \$MAINPID
SyslogIdentifier=loki
Restart=always
RestartSec=5s

# Security hardening
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
ProtectHome=yes
ReadWritePaths=${DATA_DIR} ${CONFIG_DIR}

[Install]
WantedBy=multi-user.target
EOF

success "Systemd service file written."

# ── Enable and start service ──────────────────────────────────────────────────
info "Enabling and starting Loki service..."
systemctl daemon-reload
systemctl enable "${SERVICE}"
systemctl start  "${SERVICE}"

# ── Health check ──────────────────────────────────────────────────────────────
info "Waiting for Loki to become ready..."
RETRIES=15
READY=false
for i in $(seq 1 ${RETRIES}); do
  if curl -sf http://localhost:3100/ready &>/dev/null; then
    READY=true
    break
  fi
  sleep 2
done

if [[ "${READY}" == "false" ]]; then
  error "Loki did not become ready within $((RETRIES * 2)) seconds."
  error "Check logs with: journalctl -u loki -n 50 --no-pager"
  systemctl status "${SERVICE}" --no-pager
  exit 1
fi

success "Loki is healthy and ready."

# ── Cleanup ───────────────────────────────────────────────────────────────────
info "Cleaning up working directory..."
rm -rf "${WORK_DIR}"
success "Temp files removed."

# ── Final status and summary ──────────────────────────────────────────────────
systemctl status "${SERVICE}" --no-pager

echo ""
echo "════════════════════════════════════════════════════════"
echo "  Loki ${LOKI_VERSION} installed successfully!"
echo "════════════════════════════════════════════════════════"
echo "  API endpoint  : http://$(hostname -I | awk '{print $1}'):3100"
echo "  Ready check   : http://$(hostname -I | awk '{print $1}'):3100/ready"
echo "  Metrics       : http://$(hostname -I | awk '{print $1}'):3100/metrics"
echo "  Config        : ${CONFIG_DIR}/loki.yml"
echo "  Data          : ${DATA_DIR}/"
echo "  Logs          : journalctl -u loki -f"
echo "  Service       : systemctl status loki"
echo ""
echo "  Next steps:"
echo "  1. Add Loki as a data source in Grafana:"
echo "     URL → http://$(hostname -I | awk '{print $1}'):3100"
echo "  2. Install Grafana Alloy in your K8s cluster to ship logs here"
echo "  3. Open firewall: ufw allow from <grafana-ip> to any port 3100"
echo "  4. Open firewall: ufw allow from <k8s-cidr> to any port 3100"
echo "════════════════════════════════════════════════════════"
