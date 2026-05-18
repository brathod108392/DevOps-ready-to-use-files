===============================================================
  KUBEADM + CALICO CNI — PRODUCTION-READY SETUP GUIDE
  1 Master + 2 Worker Nodes | CentOS | Local VM
===============================================================

HOST MACHINE SPECS
------------------
CPU     : Intel Core i5-6400T @ 2.20GHz
RAM     : 24.0 GB
Storage : 932 GB SSD
OS      : Windows 10/11, 64-bit

RECOMMENDED VM ALLOCATION
--------------------------
Node        | vCPUs | RAM  | Disk
------------|-------|------|------
k8s-master  |  2    | 4 GB | 40 GB
k8s-worker1 |  2    | 4 GB | 40 GB
k8s-worker2 |  2    | 4 GB | 40 GB

VM IP PLAN (adjust to your network)
-------------------------------------
k8s-master   -> 192.168.56.10
k8s-worker1  -> 192.168.56.11
k8s-worker2  -> 192.168.56.12


===============================================================
  PHASE 0 — VM SETUP (ALL 3 NODES)
===============================================================

# Set hostnames
# On master:
hostnamectl set-hostname k8s-master

# On worker1:
hostnamectl set-hostname k8s-worker1

# On worker2:
hostnamectl set-hostname k8s-worker2

# Add /etc/hosts entries on ALL 3 nodes:
cat >> /etc/hosts <<EOF
192.168.56.10   k8s-master
192.168.56.11   k8s-worker1
192.168.56.12   k8s-worker2
EOF


===============================================================
  PHASE 1 — PREREQUISITES (ALL 3 NODES)
===============================================================

# 1.1 Disable Swap
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# 1.2 Keep SELinux in Enforcing mode [SECURITY IMPROVEMENT]
# Do NOT disable or set to permissive in production.
# Install the container SELinux policy instead:
dnf install -y container-selinux

# Verify SELinux is still enforcing:
getenforce
# Should print: Enforcing

# NOTE: If you hit SELinux denials later, use audit2allow to create
# targeted policies rather than blanket-disabling SELinux.
# To inspect denials: ausearch -m avc -ts recent | audit2why

# 1.3 Configure Firewall (do NOT disable firewalld) [SECURITY IMPROVEMENT]

# --- MASTER NODE — run only on k8s-master ---
sudo firewall-cmd --permanent --add-port=6443/tcp       # API server
sudo firewall-cmd --permanent --add-port=2379-2380/tcp  # etcd client + peer
sudo firewall-cmd --permanent --add-port=10250/tcp      # kubelet API
sudo firewall-cmd --permanent --add-port=10257/tcp      # controller-manager
sudo firewall-cmd --permanent --add-port=10259/tcp      # scheduler
sudo firewall-cmd --permanent --add-port=179/tcp        # Calico BGP
sudo firewall-cmd --permanent --add-port=4789/udp       # Calico VXLAN overlay
sudo firewall-cmd --permanent --add-port=51820/udp      # Calico WireGuard (optional)
sudo firewall-cmd --permanent --add-masquerade          # Required for pod routing
sudo firewall-cmd --reload

# --- WORKER NODES — run on k8s-worker1 AND k8s-worker2 ---
sudo firewall-cmd --permanent --add-port=10250/tcp      # kubelet API
sudo firewall-cmd --permanent --add-port=10256/tcp      # kube-proxy health check
sudo firewall-cmd --permanent --add-port=30000-32767/tcp # NodePort services
sudo firewall-cmd --permanent --add-port=179/tcp        # Calico BGP
sudo firewall-cmd --permanent --add-port=4789/udp       # Calico VXLAN overlay
sudo firewall-cmd --permanent --add-port=51820/udp      # Calico WireGuard (optional)
sudo firewall-cmd --permanent --add-masquerade          # Required for pod routing
sudo firewall-cmd --reload

# Verify rules applied:
sudo firewall-cmd --list-all

# 1.4 Load Kernel Modules
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

# 1.5 Set Kernel Parameters
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system

# Verify (both should return = 1):
sysctl net.bridge.bridge-nf-call-iptables net.ipv4.ip_forward

# 1.6 Harden SSH [SECURITY IMPROVEMENT — ALL 3 nodes]
# Disable root login and password authentication:
sed -i 's/#PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart sshd

IMPORTANT: Ensure your SSH public key is added to ~/.ssh/authorized_keys
           BEFORE applying PasswordAuthentication no, or you will lock yourself out.

# 1.7 Keep System Updated [SECURITY IMPROVEMENT — ALL 3 nodes]
dnf update -y
dnf install -y dnf-automatic
sed -i 's/apply_updates = no/apply_updates = yes/' /etc/dnf/automatic.conf
systemctl enable --now dnf-automatic.timer


===============================================================
  PHASE 2 — INSTALL CONTAINERD RUNTIME (ALL 3 NODES)
===============================================================

# Add Docker repo (containerd source)
dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
dnf install -y containerd.io

# Generate default config
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml

# CRITICAL: Enable SystemdCgroup (required for kubeadm)
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# Enable and start containerd
systemctl enable --now containerd
systemctl status containerd


===============================================================
  PHASE 3 — INSTALL KUBEADM, KUBELET, KUBECTL (ALL 3 NODES)
===============================================================

# 3.1 Add Kubernetes repo
cat <<EOF | tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.29/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.29/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

NOTE: Replace v1.29 with latest stable version if needed (e.g. v1.30, v1.31)

# 3.2 Install packages
dnf install -y kubelet kubeadm kubectl --disableexcludes=kubernetes
systemctl enable --now kubelet

NOTE: kubelet will be in a crash-loop here — this is EXPECTED until kubeadm init runs.

# 3.3 Lock versions to prevent accidental upgrades [SECURITY IMPROVEMENT]
dnf install -y 'dnf-command(versionlock)'
dnf versionlock kubelet kubeadm kubectl


===============================================================
  PHASE 4 — INITIALIZE CONTROL PLANE (MASTER ONLY)
===============================================================

kubeadm init \
  --pod-network-cidr=192.168.0.0/16 \
  --apiserver-advertise-address=192.168.56.10 \
  --node-name=k8s-master \
  --cri-socket=unix:///var/run/containerd/containerd.sock

IMPORTANT: --pod-network-cidr=192.168.0.0/16 is Calico's default. Do NOT change it.

# 4.1 Configure kubectl for master
mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

# Restrict kubeconfig permissions [SECURITY IMPROVEMENT]
chmod 600 $HOME/.kube/config

# 4.2 SAVE THE JOIN COMMAND shown at the end of kubeadm init output!
# It looks like:
#   kubeadm join 192.168.56.10:6443 --token <token> \
#     --discovery-token-ca-cert-hash sha256:<hash>

# Use a short-lived token for joining (expires in 1h) [SECURITY IMPROVEMENT]
kubeadm token create --ttl 1h --print-join-command

# Or regenerate the default 24h token anytime:
kubeadm token create --print-join-command


===============================================================
  PHASE 5 — INSTALL CALICO CNI (MASTER ONLY)
===============================================================

# Install Calico operator
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/tigera-operator.yaml

# Install Calico custom resources
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/custom-resources.yaml

NOTE: Check https://github.com/projectcalico/calico/releases for the latest version.
      Replace v3.27.0 above with latest if needed.

# Wait for Calico pods to be Running before joining workers:
watch kubectl get pods -n calico-system


===============================================================
  PHASE 6 — JOIN WORKER NODES (WORKER1 AND WORKER2)
===============================================================

# Run the join command saved from Phase 4 on BOTH workers:
kubeadm join 192.168.56.10:6443 --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>


===============================================================
  PHASE 7 — VERIFY CLUSTER HEALTH (MASTER)
===============================================================

# All nodes should show STATUS = Ready
kubectl get nodes -o wide

# All pods should be Running
kubectl get pods -A

# Calico specifically
kubectl get pods -n calico-system

Expected output:
  NAME           STATUS   ROLES           AGE   VERSION
  k8s-master     Ready    control-plane   10m   v1.29.x
  k8s-worker1    Ready    <none>          5m    v1.29.x
  k8s-worker2    Ready    <none>          5m    v1.29.x


===============================================================
  PHASE 8 — PRODUCTION HARDENING & SECURITY
===============================================================

# 8.1 Label worker nodes properly
kubectl label node k8s-worker1 node-role.kubernetes.io/worker=worker
kubectl label node k8s-worker2 node-role.kubernetes.io/worker=worker

# 8.2 Verify etcd health
kubectl get pods -n kube-system | grep etcd

# 8.3 Check component statuses
kubectl get componentstatuses

# 8.4 Enable audit logging
# Edit: /etc/kubernetes/manifests/kube-apiserver.yaml
# Add these flags under spec.containers.command:
#   --audit-log-path=/var/log/kubernetes/audit.log
#   --audit-log-maxage=30
#   --audit-log-maxbackup=10
#   --audit-log-maxsize=100

# 8.5 Apply default deny-all NetworkPolicy [SECURITY IMPROVEMENT]
# Ensures pods cannot communicate unless explicitly allowed (zero-trust).
# Apply this to every namespace you create:

cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: default
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
EOF

NOTE: After applying this, add explicit allow policies per application.

# 8.6 Disable anonymous API access [SECURITY IMPROVEMENT]
# Edit /etc/kubernetes/manifests/kube-apiserver.yaml
# Ensure this flag exists:
#   --anonymous-auth=false

# 8.7 Enable Pod Security Admission [SECURITY IMPROVEMENT]
# Kubernetes 1.25+ — enforces pod-level security standards per namespace:
kubectl label namespace default pod-security.kubernetes.io/enforce=baseline
kubectl label namespace default pod-security.kubernetes.io/warn=restricted
kubectl label namespace default pod-security.kubernetes.io/audit=restricted

# Security levels:
#   privileged = unrestricted (avoid in production)
#   baseline   = blocks privilege escalation (minimum recommended)
#   restricted = fully hardened (best practice)

# 8.8 Enable etcd encryption at rest [SECURITY IMPROVEMENT]
# Protects Kubernetes Secrets stored in etcd from disk-level reads.
# Create the encryption config on master:

cat <<EOF > /etc/kubernetes/encryption-config.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: $(head -c 32 /dev/urandom | base64)
      - identity: {}
EOF

# Then add to /etc/kubernetes/manifests/kube-apiserver.yaml:
#   --encryption-provider-config=/etc/kubernetes/encryption-config.yaml

# 8.9 Verify etcd is bound to localhost or master IP only
grep "listen-client-urls" /etc/kubernetes/manifests/etcd.yaml
# Should show: https://127.0.0.1:2379 and/or https://192.168.56.10:2379
# It must NOT show 0.0.0.0

# 8.10 Audit RBAC — never use cluster-admin for applications [SECURITY IMPROVEMENT]
kubectl get clusterrolebindings -o wide | grep cluster-admin

# 8.11 Monitor certificate expiry [SECURITY IMPROVEMENT]
# Certificates expire in 1 year by default — renew before they do:
kubeadm certs check-expiration
# To renew:
kubeadm certs renew all


===============================================================
  PHASE 9 — ONGOING SECURITY MONITORING [SECURITY IMPROVEMENT]
===============================================================

# 9.1 Install kube-bench (CIS Kubernetes Benchmark scanner)
# Audits your cluster against industry CIS security standards:
curl -L https://github.com/aquasecurity/kube-bench/releases/latest/download/kube-bench_linux_amd64.tar.gz \
  | tar -xz
./kube-bench run --targets master          # Run on master
./kube-bench run --targets node            # Run on each worker

# 9.2 Monitor audit logs for delete events
tail -f /var/log/kubernetes/audit.log | grep '"verb":"delete"'

# 9.3 Check for privileged pods (should return nothing in a hardened cluster)
kubectl get pods -A -o jsonpath=\
'{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[*].securityContext.privileged}{"\n"}{end}' \
  | grep true

# 9.4 Watch for unauthorized API access attempts
journalctl -u kube-apiserver | grep "Forbidden\|Unauthorized" | tail -20


===============================================================
  TROUBLESHOOTING REFERENCE
===============================================================

Problem                          | Fix
---------------------------------|----------------------------------------------
Nodes show NotReady              | Calico not ready yet — wait 2-3 mins
kubelet won't start              | journalctl -u kubelet -f (swap or cgroup issue)
kubeadm init fails on preflight  | kubeadm init --ignore-preflight-errors=all
Workers can't join               | Check firewall, port 6443, token expiry (24h)
Pods stuck in ContainerCreating  | Calico not done — kubectl describe pod <name>
Cross-node pod traffic fails     | Check: sudo firewall-cmd --list-all (masquerade)
SELinux blocking containerd      | ausearch -m avc -ts recent | audit2why
Permission denied on kubeconfig  | chmod 600 ~/.kube/config


===============================================================
  FIREWALL PORT REFERENCE (SUMMARY)
===============================================================

MASTER NODE
-----------
6443/tcp         API server (all nodes + kubectl)
2379-2380/tcp    etcd client + peer
10250/tcp        kubelet API
10257/tcp        controller-manager
10259/tcp        scheduler
179/tcp          Calico BGP
4789/udp         Calico VXLAN overlay
51820/udp        Calico WireGuard (optional)
masquerade       Pod routing across nodes

WORKER NODES
------------
10250/tcp        kubelet API
10256/tcp        kube-proxy health check
30000-32767/tcp  NodePort services
179/tcp          Calico BGP
4789/udp         Calico VXLAN overlay
51820/udp        Calico WireGuard (optional)
masquerade       Pod routing across nodes


===============================================================
  QUICK REFERENCE COMMANDS
===============================================================

# Check node status
kubectl get nodes -o wide

# Check all pods
kubectl get pods -A

# Check cluster info
kubectl cluster-info

# Regenerate join token
kubeadm token create --print-join-command

# Reset a node (start over)
kubeadm reset && rm -rf /etc/kubernetes ~/.kube /var/lib/etcd

# View kubelet logs
journalctl -u kubelet -f

# View containerd status
systemctl status containerd

# Check certificate expiry
kubeadm certs check-expiration

# Check NetworkPolicies
kubectl get networkpolicy -A

# Check RBAC bindings
kubectl get clusterrolebindings -o wide

# Run CIS benchmark (after installing kube-bench)
./kube-bench run --targets master


===============================================================
  SECURITY IMPROVEMENTS SUMMARY
===============================================================

Improvement                     | Why It Matters
--------------------------------|----------------------------------------------
SELinux kept Enforcing          | Mandatory access control — critical on CentOS
Firewall rules (not disabled)   | Least-privilege network access per port
SSH root login disabled         | Prevent direct root-level compromise
SSH password auth disabled      | Force key-based authentication only
dnf automatic security updates  | Patch OS vulnerabilities automatically
Version lock kubeadm/kubelet    | Prevent accidental breaking upgrades
chmod 600 on kubeconfig         | Prevent other OS users reading cluster creds
Short-lived join tokens (1h)    | Reduces window for stolen token abuse
Default deny NetworkPolicy      | Zero-trust pod-to-pod communication
anonymous-auth=false            | Block unauthenticated API server access
Pod Security Admission          | Enforce hardened pod standards per namespace
etcd encryption at rest         | Protects secrets from disk-level reads
etcd bound to localhost only    | Prevent external etcd access
RBAC audit (no cluster-admin)   | Prevent over-privileged service accounts
kube-bench CIS scanning         | Continuous compliance and audit readiness
Certificate expiry monitoring   | Prevent cluster lockout on cert expiry


===============================================================
  END OF GUIDE
===============================================================
