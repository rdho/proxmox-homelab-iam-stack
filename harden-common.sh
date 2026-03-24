#!/bin/bash
set -euo pipefail

# =============================================================================
# Purpose:     Common security hardening for all sampledomain.com VMs
#              - SSH hardening (password auth for Guacamole passthrough)
#              - auditd, sysctl hardening, PAM password policy
#              - User activity logging (bash audit)
#              - fail2ban, unattended upgrades, journald retention
#
# Usage:       sudo bash harden-common.sh <GUAC_IP> <ROLE>
#              ROLE: web (Moodle) | java (Keycloak) | rdp (Guacamole)
#              Example (Moodle):    sudo bash harden-common.sh 192.168.2.197 web
#              Example (Keycloak):  sudo bash harden-common.sh 192.168.2.197 java
#              Example (Guacamole): sudo bash harden-common.sh 192.168.2.197 rdp
#
# NOTE on SSH auth:
#   PasswordAuthentication is LEFT ENABLED to support Guacamole
#   ${GUAC_USERNAME}/${GUAC_PASSWORD} passthrough for SSH connections.
#   SSH is restricted to source IP via iptables instead.
#
# Last Updated: 2026-03
# =============================================================================

GUAC_IP="${1:-192.168.2.197}"   # Only Guacamole is allowed to SSH in
ROLE="${2:-web}"                # Role: web (Moodle) | java (Keycloak) | rdp (Guacamole)
ADMIN_USER="${SUDO_USER:-devoops}"
TIMEZONE="UTC"

[[ $EUID -ne 0 ]] && { echo "[ERROR] Must run as root"; exit 1; }

echo "[INFO] ============================================================"
echo "[INFO] Hardening VM: $(hostname)"
echo "[INFO] SSH allowed from : $GUAC_IP (Guacamole only)"
echo "[INFO] Role            : $ROLE"
echo "[INFO] Admin user      : $ADMIN_USER"
echo "[INFO] Timezone        : $TIMEZONE"
echo "[INFO] ============================================================"

# === SYSTEM UPDATE ===
echo ""
echo "[STEP 1] Updating system packages..."
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y \
  curl wget git vim tmux htop iotop iftop \
  net-tools dnsutils lsof \
  unattended-upgrades apt-listchanges \
  chrony auditd audispd-plugins \
  fail2ban iptables-persistent netfilter-persistent ipset \
  logrotate rsyslog \
  ca-certificates gnupg lsb-release \
  libpam-pwquality
# Note: ufw intentionally omitted — we manage firewall via iptables+ipset
# directly to support ipset-based Tor blocking. UFW conflicts with iptables.

# === TIMEZONE / NTP ===
echo ""
echo "[STEP 2] Setting timezone and NTP..."
timedatectl set-timezone "$TIMEZONE"
systemctl enable --now chrony
echo "[OK]   Timezone: $TIMEZONE"

# === DISABLE ROOT SSH (keep local root for emergency console access) ===
echo ""
echo "[STEP 3] Disabling root SSH login..."
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config

# === SSH HARDENING ===
# PasswordAuthentication enabled — Guacamole passes explicit credentials
# set in each connection's Authentication tab (not OIDC token passthrough).
# Access restricted to Guacamole IP only via iptables (STEP 6).
echo ""
echo "[STEP 4] Hardening SSH config..."

rm -f /etc/ssh/sshd_config.d/99-hardened.conf

cat > /etc/ssh/sshd_config.d/99-hardened.conf << EOF
Protocol 2
PermitRootLogin no

# Password auth enabled — Guacamole uses explicit username/password
# per connection. Source restricted to Guacamole IP via iptables.
PasswordAuthentication yes
PubkeyAuthentication yes
PermitEmptyPasswords no
KbdInteractiveAuthentication yes
UsePAM yes

X11Forwarding no
AllowTcpForwarding no
GatewayPorts no
PermitTunnel no
MaxAuthTries 3
MaxSessions 5
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
LogLevel VERBOSE
Banner /etc/ssh/banner

# Strong crypto only
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
KexAlgorithms curve25519-sha256,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512

# Restrict to admin user only
AllowUsers ${ADMIN_USER}
EOF

# SSH login banner
cat > /etc/ssh/banner << 'BANNER'
*******************************************************************************
AUTHORIZED ACCESS ONLY — sampledomain.com infrastructure
This system is monitored. All activity is logged.
Unauthorized access will be prosecuted to the fullest extent of the law.
*******************************************************************************
BANNER

# Validate config before restart
sshd -t && systemctl restart ssh
echo "[OK]   SSH hardened (password auth, Guacamole IP only via iptables)"

# === PAM: clean default stack ===
# Standard Ubuntu PAM for sshd — no custom auth modules
echo ""
echo "[STEP 5] Verifying clean PAM sshd stack..."
cat > /etc/pam.d/sshd << 'PAMEOF'
@include common-auth
@include common-account
@include common-password
@include common-session
session optional pam_motd.so motd=/run/motd.dynamic
session optional pam_motd.so noupdate
session optional pam_mail.so standard noenv
session required pam_limits.so
session required pam_env.so
session required pam_mkhomedir.so skel=/etc/skel umask=0022
PAMEOF
echo "[OK]   PAM sshd: standard Ubuntu stack"

# === FIREWALL (iptables) ===
echo ""
echo "[STEP 6] Configuring iptables firewall..."

# Flush existing rules
iptables -F
iptables -X
iptables -Z

# Default policies
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# Allow loopback — MUST be first to prevent service breakage
iptables -A INPUT -i lo -j ACCEPT

# Allow established/related
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# SSH: allow ONLY from Guacamole IP
# Moodle and Keycloak cannot SSH to each other — only Guacamole can SSH in
iptables -A INPUT -p tcp --dport 22 -s "$GUAC_IP" \
  -m conntrack --ctstate NEW -j ACCEPT
iptables -A INPUT -p tcp --dport 22 \
  -j LOG --log-prefix "SSH_DENIED: " --log-level 4

# ICMP ping from LAN only (for monitoring/troubleshooting)
iptables -A INPUT -p icmp --icmp-type echo-request -s 192.168.2.0/24 -j ACCEPT

# Role-based port rules
case "$ROLE" in
  web)
    # Moodle: Cloudflare tunnel connects to Nginx on port 80 via loopback
    # HTTPS 443 open for LAN direct access
    iptables -A INPUT -p tcp --dport 80  -s 127.0.0.1/8 -j ACCEPT
    iptables -A INPUT -p tcp --dport 443 -s 192.168.2.0/24 \
      -m conntrack --ctstate NEW -j ACCEPT
    echo "[OK]   Ports: 80 (loopback/cloudflared), 443 (LAN HTTPS)"
    ;;
  java)
    # Keycloak: Nginx on 80/443, Keycloak backend on 7080 (loopback only)
    # Admin console via Nginx HTTPS on LAN
    iptables -A INPUT -p tcp --dport 80  -s 127.0.0.1/8 -j ACCEPT
    iptables -A INPUT -p tcp --dport 443 -s 192.168.2.0/24 \
      -m conntrack --ctstate NEW -j ACCEPT
    iptables -A INPUT -p tcp --dport 7080 -s 127.0.0.1/8 -j ACCEPT
    echo "[OK]   Ports: 80/7080 (loopback), 443 (LAN HTTPS admin)"
    ;;
  rdp)
    # Guacamole: Nginx on 80/443, Tomcat on 8080 (loopback only)
    # Cloudflared connects to 80, LAN users hit 443
    iptables -A INPUT -p tcp --dport 80   -s 127.0.0.1/8 -j ACCEPT
    iptables -A INPUT -p tcp --dport 443  -s 192.168.2.0/24 \
      -m conntrack --ctstate NEW -j ACCEPT
    iptables -A INPUT -p tcp --dport 8080 -s 127.0.0.1/8 -j ACCEPT
    echo "[OK]   Ports: 80/8080 (loopback), 443 (LAN HTTPS)"
    ;;
  *)
    echo "[WARN] Unknown role '$ROLE' — no service ports opened. Valid: web|java|rdp"
    ;;
esac

mkdir -p /etc/iptables
iptables-save | tee /etc/iptables/rules.v4 > /dev/null
netfilter-persistent save
echo "[OK]   iptables: SSH from Guacamole ($GUAC_IP) only, service ports per role"

# === FAIL2BAN ===
echo ""
echo "[STEP 7] Configuring fail2ban..."
cat > /etc/fail2ban/jail.local << 'JAILEOF'
[DEFAULT]
bantime   = 24h
findtime  = 10m
maxretry  = 3
backend   = systemd
# iptables-allports more reliable than iptables-multiport on Ubuntu 24.04
# when using iptables directly (not nftables)
banaction = iptables-allports

[sshd]
enabled  = true
port     = ssh
logpath  = %(sshd_log)s
maxretry = 3
bantime  = 72h
JAILEOF
systemctl enable --now fail2ban
echo "[OK]   fail2ban enabled (SSH ban: 3 attempts → 72h)"

# === AUDITD ===
echo ""
echo "[STEP 8] Configuring auditd..."
cat > /etc/audit/rules.d/99-hardening.rules << 'AUDITEOF'
## Delete existing rules
-D

## Buffer size
-b 8192

## Failure mode: 1=silent, 2=panic
-f 1

## === PRIVILEGED COMMANDS ===
-a always,exit -F path=/usr/bin/sudo    -F perm=x -F auid>=1000 -F auid!=unset -k privileged
-a always,exit -F path=/usr/bin/su      -F perm=x -F auid>=1000 -F auid!=unset -k privileged
-a always,exit -F path=/usr/bin/passwd  -F perm=x -F auid>=1000 -F auid!=unset -k privileged
-a always,exit -F path=/usr/sbin/useradd  -F perm=x -F auid>=1000 -F auid!=unset -k privileged
-a always,exit -F path=/usr/sbin/userdel  -F perm=x -F auid>=1000 -F auid!=unset -k privileged
-a always,exit -F path=/usr/sbin/usermod  -F perm=x -F auid>=1000 -F auid!=unset -k privileged

## === FILE INTEGRITY ===
-w /etc/passwd    -p wa -k identity
-w /etc/shadow    -p wa -k identity
-w /etc/group     -p wa -k identity
-w /etc/sudoers   -p wa -k scope
-w /etc/sudoers.d -p wa -k scope
-w /etc/ssh/sshd_config    -p wa -k sshd
-w /etc/ssh/sshd_config.d  -p wa -k sshd
-w /etc/pam.d              -p wa -k pam
-w /etc/crontab   -p wa -k cron
-w /var/spool/cron -p wa -k cron
-w /etc/cron.d    -p wa -k cron

## === AUTHENTICATION EVENTS ===
-w /var/log/auth.log  -p wa -k authentication
-w /var/log/faillog   -p wa -k authentication
-w /var/log/lastlog   -p wa -k authentication

## === NETWORK CONFIG CHANGES ===
-a always,exit -F arch=b64 -S sethostname -S setdomainname -k network_modifications
-w /etc/hosts    -p wa -k network_modifications
-w /etc/network  -p wa -k network_modifications

## === KERNEL MODULES ===
-a always,exit -F path=/usr/sbin/insmod   -F perm=x -F auid>=1000 -F auid!=unset -k modules
-a always,exit -F path=/usr/sbin/rmmod    -F perm=x -F auid>=1000 -F auid!=unset -k modules
-a always,exit -F path=/usr/sbin/modprobe -F perm=x -F auid>=1000 -F auid!=unset -k modules
-a always,exit -F arch=b64 -S init_module -S delete_module -k modules

## === IMMUTABLE (require reboot to change rules) ===
-e 2
AUDITEOF

systemctl enable --now auditd
sleep 2
/sbin/augenrules --load 2>/dev/null || augenrules --load 2>/dev/null || true
systemctl restart auditd
echo "[OK]   auditd configured and enabled"

# === BASH COMMAND HISTORY LOGGING ===
echo ""
echo "[STEP 9] Enabling bash command logging to syslog..."

# Idempotent — only add if not already present
if ! grep -q "BASH_CMD" /etc/bash.bashrc; then
  cat >> /etc/bash.bashrc << 'BASHRC'

# === User activity logging (all commands to syslog) ===
export HISTTIMEFORMAT="%Y-%m-%d %H:%M:%S "
export HISTSIZE=50000
export HISTFILESIZE=50000
shopt -s histappend
PROMPT_COMMAND='history 1 | logger -t "BASH_CMD[$(whoami)@$(hostname)]" -p local6.info'
BASHRC
fi

cat > /etc/rsyslog.d/50-commands.conf << 'RSYSEOF'
local6.*    /var/log/commands.log
RSYSEOF
systemctl restart rsyslog

cat > /etc/logrotate.d/commands << 'ROTATEEOF'
/var/log/commands.log {
    daily
    missingok
    rotate 90
    compress
    delaycompress
    notifempty
    create 0640 syslog adm
}
ROTATEEOF
echo "[OK]   Bash commands logged to /var/log/commands.log"

# === KERNEL HARDENING (sysctl) ===
echo ""
echo "[STEP 10] Applying kernel hardening sysctl..."
cat > /etc/sysctl.d/99-hardening.conf << 'SYSCTLEOF'
# === Network hardening ===
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1

# === Memory hardening ===
kernel.randomize_va_space = 2
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.suid_dumpable = 0
kernel.core_uses_pid = 1
SYSCTLEOF
sysctl -p /etc/sysctl.d/99-hardening.conf
echo "[OK]   Kernel hardening applied"

# === PAM PASSWORD POLICY ===
echo ""
echo "[STEP 11] Configuring PAM password policy..."
cat > /etc/security/pwquality.conf << 'PWEOF'
minlen = 14
dcredit = -1
ucredit = -1
lcredit = -1
ocredit = -1
maxrepeat = 3
gecoscheck = 1
PWEOF
echo "[OK]   Password policy: min 14 chars, mixed case + digits + symbols"

# === UNATTENDED SECURITY UPGRADES ===
echo ""
echo "[STEP 12] Enabling unattended security upgrades..."
cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'UPGRADEEOF'
Unattended-Upgrade::Allowed-Origins {
  "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
UPGRADEEOF
systemctl enable --now unattended-upgrades
echo "[OK]   Unattended security upgrades enabled"

# === JOURNALD LOG RETENTION ===
echo ""
echo "[STEP 13] Configuring journald retention..."
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-retention.conf << 'JOURNALEOF'
[Journal]
SystemMaxUse=500M
SystemKeepFree=1G
MaxRetentionSec=1month
Compress=yes
JOURNALEOF
systemctl restart systemd-journald
echo "[OK]   Journal retention: 500MB max, 1 month"

# === SUMMARY ===
echo ""
echo "[INFO] ============================================================"
echo "[INFO] Hardening complete on: $(hostname)"
echo ""
echo "[INFO] SSH:"
echo "         PasswordAuthentication: YES (Guacamole explicit credentials)"
echo "         PermitRootLogin:        NO"
echo "         Source restriction:     $GUAC_IP only (via iptables)"
echo "         AllowUsers:             $ADMIN_USER"
echo ""
echo "[INFO] Firewall ports opened (role: $ROLE):"
case "$ROLE" in
  web)  echo "         80  → loopback only (cloudflared)"
        echo "         443 → LAN 192.168.2.0/24 (HTTPS)" ;;
  java) echo "         80  → loopback only (cloudflared)"
        echo "         7080→ loopback only (Keycloak backend)"
        echo "         443 → LAN 192.168.2.0/24 (Nginx admin)" ;;
  rdp)  echo "         80  → loopback only (cloudflared)"
        echo "         8080→ loopback only (Tomcat)"
        echo "         443 → LAN 192.168.2.0/24 (HTTPS)" ;;
esac
echo ""
echo "[INFO] Timezone: UTC"
echo "[INFO] Services: chrony, auditd, fail2ban, rsyslog, unattended-upgrades"
echo "[INFO] Logging:  commands → /var/log/commands.log | auth → /var/log/auth.log"
echo ""
echo "[NEXT]  Run: sudo bash tor-block.sh"
echo "[NEXT]  Run: sudo bash tune-performance.sh"
echo "[INFO] ============================================================"
