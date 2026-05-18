#!/bin/bash
# =============================================================================
# kops + kubectl Installation & K8s Cluster Provisioning Script
# Target OS : CentOS 7 / 8 / Stream
# Usage     : sudo bash kops-setup-centos.sh
# Route53 DNS zone --dns-zone=kubepro.bkrinfo.xyz must already exist as a public hosted zone in Route53 before running this script.
# =============================================================================

# ─── Colour helpers ───────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# =============================================================================
# ── CONFIGURATION  (edit this section before running) ────────────────────────
# =============================================================================

CLUSTER_NAME="kubepro.bkrinfo.xyz"
S3_BUCKET="s3://kubepro1189"
ZONES="us-east-1a,us-east-1b"
NODE_COUNT=2
NODE_SIZE="t3.small"
CONTROL_PLANE_SIZE="t3.small"
DNS_ZONE="kubepro.bkrinfo.xyz"
NODE_VOLUME_SIZE=8
CONTROL_PLANE_VOLUME_SIZE=8

# SSH key name (without extension). Change to match your key, e.g. id_ed25519
SSH_KEY_NAME="id_rsa"

# AWS credentials – fill in for non-interactive mode, or leave blank to be
# prompted by "aws configure".
AWS_ACCESS_KEY_ID=""
AWS_SECRET_ACCESS_KEY=""
AWS_DEFAULT_REGION="us-east-1"
AWS_OUTPUT_FORMAT="json"

# =============================================================================
# ── PRE-FLIGHT CHECKS ─────────────────────────────────────────────────────────
# =============================================================================

# FIX 1: Must run with sudo, not as a direct root login, so SUDO_USER is set.
# If someone logs in as root directly, SUDO_USER is empty; warn and fall back.
[[ $EUID -ne 0 ]] && error "Run as root: sudo bash $0"

REAL_USER="${SUDO_USER:-}"
if [[ -z "$REAL_USER" ]]; then
    warn "SUDO_USER is not set (are you logged in directly as root?)."
    warn "Defaulting to 'ec2-user'. Edit REAL_USER in this script if different."
    REAL_USER="ec2-user"
fi

REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
[[ -z "$REAL_HOME" ]] && error "Cannot determine home directory for user '$REAL_USER'."

SSH_PUBLIC_KEY="${REAL_HOME}/.ssh/${SSH_KEY_NAME}.pub"
SSH_PRIVATE_KEY="${REAL_HOME}/.ssh/${SSH_KEY_NAME}"

info "Real user  : ${REAL_USER}"
info "User home  : ${REAL_HOME}"
info "SSH key    : ${SSH_PRIVATE_KEY}"

# =============================================================================
# STEP 1 – System update
# =============================================================================
info "STEP 1 – Updating system packages..."
yum update -y || error "yum update failed."
success "System updated."

# =============================================================================
# STEP 2 – Install dependencies + AWS CLI v2
#   CentOS has no snap; install from the official AWS binary bundle.
# =============================================================================
info "STEP 2 – Installing AWS CLI v2..."
if command -v aws &>/dev/null; then
    warn "AWS CLI already installed ($(aws --version 2>&1)). Skipping."
else
    # FIX 2: Also install 'which' and 'tar' — commonly missing on minimal CentOS
    yum install -y unzip curl which tar || error "Failed to install dependencies."
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" \
         -o /tmp/awscliv2.zip || error "Failed to download AWS CLI."
    unzip -q /tmp/awscliv2.zip -d /tmp/
    /tmp/aws/install || error "AWS CLI installer failed."
    rm -rf /tmp/awscliv2.zip /tmp/aws
    # FIX 3: aws installs to /usr/local/bin — ensure it's on PATH for this session
    export PATH="/usr/local/bin:$PATH"
    success "AWS CLI installed: $(aws --version 2>&1)"
fi

# =============================================================================
# STEP 3 – Configure AWS credentials
# =============================================================================
info "STEP 3 – Configuring AWS credentials..."

AWS_DIR="${REAL_HOME}/.aws"
mkdir -p "$AWS_DIR"

if [[ -n "$AWS_ACCESS_KEY_ID" && -n "$AWS_SECRET_ACCESS_KEY" ]]; then
    cat > "${AWS_DIR}/credentials" <<EOF
[default]
aws_access_key_id     = ${AWS_ACCESS_KEY_ID}
aws_secret_access_key = ${AWS_SECRET_ACCESS_KEY}
EOF
    cat > "${AWS_DIR}/config" <<EOF
[default]
region = ${AWS_DEFAULT_REGION}
output = ${AWS_OUTPUT_FORMAT}
EOF
    chown -R "${REAL_USER}:${REAL_USER}" "$AWS_DIR"
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY \
           AWS_DEFAULT_REGION AWS_OUTPUT_FORMAT
    success "AWS credentials written to ${AWS_DIR}/"
else
    warn "No credentials set in script – running interactive 'aws configure'."
    sudo -u "$REAL_USER" aws configure || error "aws configure failed."
    AWS_DEFAULT_REGION=$(sudo -u "$REAL_USER" \
        aws configure get region 2>/dev/null || echo "us-east-1")
    success "AWS credentials configured interactively."
fi

# Sanity-check: verify AWS auth actually works before going any further
sudo -u "$REAL_USER" aws sts get-caller-identity > /dev/null \
    || error "AWS credentials invalid. Check your Access Key / Secret Key."
success "AWS credentials verified."

# =============================================================================
# STEP 4 – Generate SSH key pair (if not already present)
# =============================================================================
info "STEP 4 – Checking SSH key pair..."
mkdir -p "${REAL_HOME}/.ssh"
chown "${REAL_USER}:${REAL_USER}" "${REAL_HOME}/.ssh"
chmod 700 "${REAL_HOME}/.ssh"

if [[ -f "$SSH_PUBLIC_KEY" ]]; then
    warn "SSH key already exists at ${SSH_PUBLIC_KEY}. Skipping generation."
else
    sudo -u "$REAL_USER" ssh-keygen -t rsa -b 4096 -f "$SSH_PRIVATE_KEY" -N "" \
        || error "ssh-keygen failed."
    success "SSH key pair created: ${SSH_PRIVATE_KEY}"
fi

# FIX 4: Ensure private key permissions are strict (ssh/kops will reject it otherwise)
chmod 600 "$SSH_PRIVATE_KEY"
chmod 644 "$SSH_PUBLIC_KEY"
success "SSH key permissions verified (600/644)."

# =============================================================================
# STEP 5 – Install kops
# =============================================================================
info "STEP 5 – Installing kops..."
if command -v kops &>/dev/null; then
    warn "kops already installed ($(kops version 2>&1 | head -1)). Skipping."
else
    KOPS_LATEST=$(curl -s https://api.github.com/repos/kubernetes/kops/releases/latest \
                  | grep '"tag_name"' | cut -d '"' -f 4)
    [[ -z "$KOPS_LATEST" ]] && error "Could not fetch latest kops version from GitHub API."
    info "Downloading kops ${KOPS_LATEST}..."
    curl -fsSL \
        "https://github.com/kubernetes/kops/releases/download/${KOPS_LATEST}/kops-linux-amd64" \
        -o /tmp/kops || error "kops download failed."
    chmod +x /tmp/kops
    mv /tmp/kops /usr/local/bin/kops
    success "kops installed: $(kops version 2>&1 | head -1)"
fi

# =============================================================================
# STEP 6 – Install kubectl
#   CentOS has no snap; use the official Kubernetes yum repository.
# =============================================================================
info "STEP 6 – Installing kubectl..."
if command -v kubectl &>/dev/null; then
    warn "kubectl already installed. Skipping."
else
    cat > /etc/yum.repos.d/kubernetes.repo <<'EOF'
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.29/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.29/rpm/repodata/repomd.xml.key
EOF
    yum install -y kubectl || error "kubectl install failed."
    success "kubectl installed."
fi
kubectl version --client 2>/dev/null | head -1 || true

# =============================================================================
# STEP 7 – Export KOPS_STATE_STORE (required before ANY kops command)
# =============================================================================
export KOPS_STATE_STORE="${S3_BUCKET}"
info "KOPS_STATE_STORE = ${KOPS_STATE_STORE}"

# Persist for future shell sessions of the real user
PROFILE_FILE="${REAL_HOME}/.bashrc"
if ! grep -q "KOPS_STATE_STORE" "$PROFILE_FILE" 2>/dev/null; then
    echo "export KOPS_STATE_STORE=${S3_BUCKET}" >> "$PROFILE_FILE"
    info "KOPS_STATE_STORE added to ${PROFILE_FILE}"
fi

# =============================================================================
# STEP 8 – Ensure S3 bucket exists for kops state store
# =============================================================================
BUCKET_NAME="${S3_BUCKET#s3://}"
info "STEP 8 – Checking S3 state-store bucket (${BUCKET_NAME})..."

if sudo -u "$REAL_USER" aws s3 ls "s3://${BUCKET_NAME}" > /dev/null 2>&1; then
    warn "Bucket s3://${BUCKET_NAME} already exists. Skipping creation."
else
    sudo -u "$REAL_USER" aws s3 mb "s3://${BUCKET_NAME}" \
        --region "${AWS_DEFAULT_REGION}" \
        || error "Failed to create S3 bucket."
    sudo -u "$REAL_USER" aws s3api put-bucket-versioning \
        --bucket "${BUCKET_NAME}" \
        --versioning-configuration Status=Enabled \
        || error "Failed to enable S3 bucket versioning."
    success "Bucket s3://${BUCKET_NAME} created with versioning enabled."
fi

# =============================================================================
# STEP 9 – Create kops cluster definition (writes to S3 only, no AWS infra yet)
# =============================================================================
info "STEP 9 – Saving cluster definition to state store..."

# FIX 5: Check if the cluster definition already exists in S3 to avoid a
# "cluster already exists" error if the script is re-run after a partial failure.
if sudo -u "$REAL_USER" kops get cluster \
        --name="${CLUSTER_NAME}" \
        --state="${S3_BUCKET}" > /dev/null 2>&1; then
    warn "Cluster definition already exists in state store. Skipping create."
else
    sudo -u "$REAL_USER" kops create cluster \
        --name="${CLUSTER_NAME}" \
        --state="${S3_BUCKET}" \
        --zones="${ZONES}" \
        --node-count="${NODE_COUNT}" \
        --node-size="${NODE_SIZE}" \
        --control-plane-size="${CONTROL_PLANE_SIZE}" \
        --dns-zone="${DNS_ZONE}" \
        --node-volume-size="${NODE_VOLUME_SIZE}" \
        --control-plane-volume-size="${CONTROL_PLANE_VOLUME_SIZE}" \
        --ssh-public-key="${SSH_PUBLIC_KEY}" \
        || error "kops create cluster failed."
    success "Cluster definition saved to state store."
fi

# =============================================================================
# STEP 10 – Apply cluster (provisions VPC, EC2, ASGs, Route53, etc. on AWS)
# =============================================================================
info "STEP 10 – Provisioning AWS infrastructure (~10–15 min)..."
sudo -u "$REAL_USER" kops update cluster \
    --name="${CLUSTER_NAME}" \
    --state="${S3_BUCKET}" \
    --yes --admin \
    || error "kops update cluster failed."
success "Cluster provisioning initiated. Waiting for nodes to bootstrap..."

# FIX 6: Give AWS ~60 s to spin up EC2 instances before we start polling.
# Polling immediately always returns "not ready" and wastes the first 2 attempts.
info "Waiting 60 s for EC2 instances to start..."
sleep 60

# =============================================================================
# STEP 11 – Validate cluster (retry loop — nodes need time to bootstrap)
# =============================================================================
info "STEP 11 – Validating cluster (poll every 30 s, timeout 20 min)..."
MAX_ATTEMPTS=40
ATTEMPT=0

while true; do
    ATTEMPT=$((ATTEMPT + 1))
    printf "  Attempt %d/%d ... " "$ATTEMPT" "$MAX_ATTEMPTS"

    if sudo -u "$REAL_USER" kops validate cluster \
            --name="${CLUSTER_NAME}" \
            --state="${S3_BUCKET}" > /tmp/kops_validate.out 2>&1; then
        echo -e "${GREEN}READY${NC}"
        break
    fi

    echo -e "${YELLOW}not ready yet${NC}"

    if [[ $ATTEMPT -ge $MAX_ATTEMPTS ]]; then
        echo ""
        warn "Last validation output:"
        cat /tmp/kops_validate.out
        error "Cluster did not become ready within 20 minutes. Check the AWS console."
    fi

    sleep 30
done

# Print final validation summary
sudo -u "$REAL_USER" kops validate cluster \
    --name="${CLUSTER_NAME}" \
    --state="${S3_BUCKET}"

# =============================================================================
# STEP 12 – Post-install summary
# =============================================================================
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  K8s cluster is UP and READY!${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo "  Cluster      : ${CLUSTER_NAME}"
echo "  State store  : ${S3_BUCKET}"
echo "  Zones        : ${ZONES}"
echo "  Nodes        : ${NODE_COUNT} × ${NODE_SIZE}"
echo "  Control plane: ${CONTROL_PLANE_SIZE}"
echo "  SSH key      : ${SSH_PRIVATE_KEY}"
echo ""
echo -e "${CYAN}Verify your cluster:${NC}"
echo "  kubectl get nodes"
echo "  kops validate cluster --name=${CLUSTER_NAME} --state=${S3_BUCKET}"
echo ""
echo -e "${CYAN}SSH into a node (get IP from AWS console or 'kops get ig'):${NC}"
echo "  ssh -i ${SSH_PRIVATE_KEY} ec2-user@<node-ip>"
echo ""
echo -e "${YELLOW}To DELETE the entire cluster when done:${NC}"
echo "  kops delete cluster --name=${CLUSTER_NAME} --state=${S3_BUCKET} --yes"
echo ""
