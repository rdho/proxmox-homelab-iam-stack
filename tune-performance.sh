#!/bin/bash
set -euo pipefail

# =============================================================================
# Purpose:     Core system performance tuning for 2 vCPU / 2GB RAM Proxmox VMs
# Usage:       sudo bash tune-performance.sh
# Last Updated: 2026-03
# =============================================================================

[[ $EUID -ne 0 ]] && { echo "[ERROR] Must run as root"; exit 1; }

echo "[INFO] ============================================================"
echo "[INFO] Core performance tuning: $(hostname)"
echo "[INFO] Target: 2 vCPU / 2GB RAM Proxmox VM"
echo "[INFO] ============================================================"

# === STEP 1: DISABLE TRANSPARENT HUGE PAGES ===
echo ""
echo "[STEP 1] Disabling Transparent Huge Pages..."
cat > /etc/systemd/system/disable-thp.service << 'EOF'
[Unit]
Description=Disable Transparent Huge Pages
After=sysinit.target local-fs.target
Before=basic.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled; echo never > /sys/kernel/mm/transparent_hugepage/defrag'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now disable-thp.service

# Apply immediately without waiting for reboot
echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
echo never > /sys/kernel/mm/transparent_hugepage/defrag  2>/dev/null || true
echo "[OK]   THP: $(cat /sys/kernel/mm/transparent_hugepage/enabled)"

# === STEP 2: SYSCTL PERFORMANCE TUNING ===
echo ""
echo "[STEP 2] Applying sysctl performance tuning..."
cat > /etc/sysctl.d/99-performance.conf << 'EOF'
# === Memory (tuned for 2GB RAM) ===
vm.swappiness = 10
vm.dirty_ratio = 20
vm.dirty_background_ratio = 5
vm.vfs_cache_pressure = 50

# === Network: BBR congestion control ===
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0

# === TCP buffers ===
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# === Connection handling ===
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 8192
net.core.netdev_max_backlog = 16384

# === TCP TIME_WAIT ===
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15

# === File descriptors ===
fs.file-max = 524288
fs.nr_open = 524288
EOF
sysctl -p /etc/sysctl.d/99-performance.conf
echo "[OK]   sysctl tuning applied"

# === STEP 3: ULIMITS ===
echo ""
echo "[STEP 3] Setting system-wide ulimits..."
cat > /etc/security/limits.d/99-performance.conf << 'EOF'
* soft nofile 65536
* hard nofile 65536
* soft nproc  32768
* hard nproc  32768
root soft nofile 65536
root hard nofile 65536
EOF

mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/99-limits.conf << 'EOF'
[Manager]
DefaultLimitNOFILE=65536
DefaultLimitNPROC=32768
EOF
systemctl daemon-reload
echo "[OK]   ulimits: nofile=65536, nproc=32768 (PAM + systemd)"

# === SWAP ===
echo ""
echo "[STEP 4] Checking swap..."
if ! swapon --show | grep -q .; then
  echo "[INFO] No swap — creating 1GB swapfile..."
  fallocate -l 1G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q "/swapfile" /etc/fstab \
    || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo "[OK]   1GB swapfile created"
else
  echo "[OK]   Swap already configured:"
  swapon --show
fi

echo ""
echo "[INFO] ============================================================"
echo "[INFO] Tuning complete: $(hostname)"
echo "         THP:     disabled"
echo "         sysctl:  BBR, TCP buffers, file descriptors"
echo "         ulimits: nofile=65536, nproc=32768"
echo "[WARN] Reboot recommended to apply all settings cleanly."
echo "[INFO] ============================================================"
