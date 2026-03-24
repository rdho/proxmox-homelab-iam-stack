#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Purpose:     Fix Keycloak 26.x startup failure:
#              "hostname must be set to a URL when hostname-admin is set"
#
# Root cause:  Keycloak 26 (hostname v2) requires 'hostname' to be a full URL
#              (https://...) when 'hostname-admin' is also set. The original
#              config had: hostname=auth.devoops.lol  ← bare hostname, invalid
#              Fix:        hostname=https://auth.devoops.lol  ← full URL
#
#              Additionally, 'hostname-admin' must also be a full URL.
#              The original had: hostname-admin=https://iam.devoops.lol ← OK
#              but it still fails because 'hostname' was bare.
#
#              After fixing keycloak.conf, 'kc.sh build' must be re-run to
#              recompile the Quarkus optimized image with the new config baked in.
#
# Usage:       sudo bash fix-keycloak-hostname.sh
# Last Updated: 2026-03
# Reference:   https://www.keycloak.org/server/hostname
# =============================================================================

# === VARIABLES ===
KC_HOME="/opt/keycloak"
KC_USER="keycloak"
KC_CONF="${KC_HOME}/conf/keycloak.conf"
PUBLIC_DOMAIN="auth.devoops.lol"
ADMIN_DOMAIN="iam.devoops.lol"

# === PREFLIGHT ===
[[ $EUID -ne 0 ]] && { echo "[ERROR] Must run as root"; exit 1; }
[[ ! -f "$KC_CONF" ]] && { echo "[ERROR] keycloak.conf not found at $KC_CONF"; exit 1; }

echo "[INFO] ============================================================"
echo "[INFO] Fixing Keycloak 26 hostname configuration"
echo "[INFO] KC_HOME : $KC_HOME"
echo "[INFO] Config  : $KC_CONF"
echo "[INFO] ============================================================"

# === SHOW CURRENT BROKEN CONFIG ===
echo "[INFO] Current hostname-related config:"
grep -E "^hostname|^proxy" "$KC_CONF" || echo "(none found)"
echo ""

# === STOP KEYCLOAK ===
echo "[INFO] Stopping Keycloak service..."
systemctl stop keycloak || true
sleep 3

# === BACKUP ORIGINAL CONFIG ===
cp "$KC_CONF" "${KC_CONF}.bak.$(date +%Y%m%d%H%M%S)"
echo "[INFO] Config backed up."

# === REWRITE keycloak.conf WITH CORRECT VALUES ===
# Key fixes vs the original:
#   hostname=auth.devoops.lol          → hostname=https://auth.devoops.lol
#   hostname-admin=https://iam...      → unchanged (already full URL, but re-stated for clarity)
#
# Keycloak 26 hostname v2 rules:
#   - hostname        MUST be a full URL (https://...) when hostname-admin is set
#   - hostname-admin  MUST be a full URL (https://...)
#   - http-enabled=true required because Nginx terminates TLS (edge proxy)
#   - proxy-headers=xforwarded because Nginx sets X-Forwarded-* headers
#   - proxy-trusted-addresses restricts which IPs Keycloak trusts for those headers
#     (127.0.0.1 = Nginx on same host; Cloudflare Tunnel also comes from localhost)

echo "[INFO] Writing corrected keycloak.conf..."
cat > "$KC_CONF" << EOF
# =============================================================================
# Keycloak 26.x Configuration
# VM: 192.168.2.157 | Ubuntu 24.04 | 2 vCPU / 2GB RAM
# =============================================================================

# === Database ===
db=postgres
db-url=jdbc:postgresql://localhost:5432/keycloak
db-username=keycloak
# Load password from environment or file — do not hardcode here
# Set via systemd service: Environment="KC_DB_PASSWORD=..."
# (see /etc/systemd/system/keycloak.service)

# === HTTP ===
# Keycloak listens on HTTP (8080); Nginx handles TLS termination externally.
# In Keycloak 26, http-enabled=true is required for edge/TLS-terminating proxies.
http-enabled=true
http-port=8080
https-required=external   # Enforce HTTPS for external requests, not for localhost

# === Hostname (v2) ===
# CRITICAL: When hostname-admin is set, hostname MUST be a full URL (https://...)
# A bare hostname like "auth.devoops.lol" is rejected in production mode.
# Reference: https://www.keycloak.org/server/hostname
hostname=https://${PUBLIC_DOMAIN}
hostname-admin=https://${ADMIN_DOMAIN}

# === Proxy ===
# proxy-headers=xforwarded: Keycloak reads X-Forwarded-For/Proto/Host from Nginx.
# proxy-trusted-addresses: Only trust these addresses to set proxy headers.
# 127.0.0.1 = Nginx (same host). Without this, Keycloak ignores or mistrusts headers.
proxy-headers=xforwarded
proxy-trusted-addresses=127.0.0.1

# === Health & Metrics (exposed on management port 9000, not proxied) ===
health-enabled=true
metrics-enabled=true

# === Features ===
features=token-exchange,admin-fine-grained-authz

# === Logging ===
log-level=INFO
EOF

echo "[INFO] keycloak.conf written."
echo ""
echo "[INFO] New hostname-related config:"
grep -E "^hostname|^proxy|^http" "$KC_CONF"
echo ""

# === INJECT DB PASSWORD INTO SYSTEMD SERVICE ===
# Read the saved password from /root/.keycloak_creds
echo "[INFO] Updating systemd service with DB password..."
if [[ -f /root/.keycloak_creds ]]; then
  DB_PASS=$(grep "^DB_PASS=" /root/.keycloak_creds | cut -d= -f2-)
  KC_ADMIN_USER=$(grep "^KC_ADMIN_USER=" /root/.keycloak_creds | cut -d= -f2-)
  KC_ADMIN_PASS=$(grep "^KC_ADMIN_PASS=" /root/.keycloak_creds | cut -d= -f2-)
else
  echo "[ERROR] /root/.keycloak_creds not found."
  echo "        Cannot inject DB password into service unit."
  echo "        Manually add to /etc/systemd/system/keycloak.service:"
  echo "        Environment=\"KC_DB_PASSWORD=<your-db-pass>\""
  exit 1
fi

# Rewrite the systemd service with all env vars correctly set
cat > /etc/systemd/system/keycloak.service << EOF
[Unit]
Description=Keycloak Identity Provider v26
After=network.target postgresql.service
Requires=postgresql.service

[Service]
Type=idle
User=${KC_USER}
Group=${KC_USER}
WorkingDirectory=${KC_HOME}

# JVM heap tuned for 2GB VM
Environment="JAVA_OPTS=-Xms512m -Xmx768m -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -XX:+UseStringDeduplication -Djava.net.preferIPv4Stack=true"

# Database password (read from saved creds)
Environment="KC_DB_PASSWORD=${DB_PASS}"

# Bootstrap admin — only used on first start to create the initial admin user.
# Keycloak 26: these are ignored after the first admin is created in the DB.
Environment="KC_BOOTSTRAP_ADMIN_USERNAME=${KC_ADMIN_USER}"
Environment="KC_BOOTSTRAP_ADMIN_PASSWORD=${KC_ADMIN_PASS}"

ExecStart=${KC_HOME}/bin/kc.sh start --optimized

# Restart behavior
Restart=on-failure
RestartSec=15s
TimeoutStartSec=120s

# Security hardening
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
ReadWritePaths=${KC_HOME} /tmp

LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

echo "[INFO] systemd service unit updated."

# === REBUILD KEYCLOAK ===
# 'kc.sh build' re-runs the Quarkus augmentation phase which bakes in the config.
# This is REQUIRED after any changes to keycloak.conf — without it, 'start --optimized'
# uses the previously compiled config and the fix has no effect.
echo ""
echo "[INFO] Running 'kc.sh build' to recompile with new config..."
echo "[INFO] This takes approximately 1-3 minutes on a 2 vCPU VM..."
echo ""

sudo -u "$KC_USER" "${KC_HOME}/bin/kc.sh" build 2>&1 | tee /tmp/kc-build.log

# Check build succeeded
if grep -q "ERROR\|BUILD FAILURE" /tmp/kc-build.log; then
  echo "[ERROR] kc.sh build reported errors. Check /tmp/kc-build.log"
  tail -20 /tmp/kc-build.log
  exit 1
fi
echo "[INFO] Build completed successfully."

# === RELOAD AND START ===
systemctl daemon-reload
echo "[INFO] Starting Keycloak service..."
systemctl enable keycloak
systemctl start keycloak

# === WAIT AND CHECK ===
echo "[INFO] Waiting up to 90s for Keycloak to become ready..."
MAX_WAIT=90
WAITED=0
INTERVAL=5
while [[ $WAITED -lt $MAX_WAIT ]]; do
  sleep $INTERVAL
  WAITED=$((WAITED + INTERVAL))

  # Check if service is still running (didn't crash immediately)
  if ! systemctl is-active --quiet keycloak; then
    echo "[ERROR] Keycloak service stopped after ${WAITED}s."
    echo "[ERROR] Last 30 log lines:"
    journalctl -u keycloak -n 30 --no-pager
    exit 1
  fi

  # Poll the health endpoint
  HTTP_STATUS=$(curl -sSo /dev/null -w "%{http_code}" \
    --max-time 3 "http://127.0.0.1:8080/health/ready" 2>/dev/null || echo "000")

  if [[ "$HTTP_STATUS" == "200" ]]; then
    echo "[INFO] Keycloak is healthy after ${WAITED}s (HTTP 200 on /health/ready)"
    break
  fi

  echo "[INFO] ${WAITED}s — Keycloak still starting... (health: HTTP $HTTP_STATUS)"
done

if [[ "$HTTP_STATUS" != "200" ]]; then
  echo "[WARN] Keycloak health endpoint did not return 200 within ${MAX_WAIT}s."
  echo "[WARN] It may still be starting. Check: journalctl -u keycloak -f"
fi

# === VALIDATE OIDC DISCOVERY ===
echo ""
echo "[INFO] Testing OIDC discovery endpoint via Nginx proxy (port 7080)..."
DISCOVERY_URL="http://127.0.0.1:7080/realms/master/.well-known/openid-configuration"
DISCOVERY_STATUS=$(curl -sSo /dev/null -w "%{http_code}" \
  --max-time 5 "$DISCOVERY_URL" 2>/dev/null || echo "000")

if [[ "$DISCOVERY_STATUS" == "200" ]]; then
  echo "[INFO] OIDC discovery endpoint: OK (HTTP 200)"
else
  echo "[WARN] OIDC discovery returned HTTP $DISCOVERY_STATUS"
  echo "[WARN] Nginx may need a reload, or Keycloak may still be warming up."
  echo "       Try: curl -s http://127.0.0.1:7080/realms/master/.well-known/openid-configuration | python3 -m json.tool"
fi

# === FINAL SUMMARY ===
echo ""
echo "[INFO] ============================================================"
echo "[INFO] Fix complete. Service status:"
systemctl status keycloak --no-pager -l | head -20
echo ""
echo "[INFO] Key endpoints:"
echo "  Health (direct)   : http://127.0.0.1:8080/health/ready"
echo "  Health (via Nginx): http://127.0.0.1:7080/health/ready"
echo "  Admin console     : https://${ADMIN_DOMAIN}  (LAN only)"
echo "  OIDC discovery    : https://${PUBLIC_DOMAIN}/realms/<realm>/.well-known/openid-configuration"
echo ""
echo "[INFO] If still failing, check full logs:"
echo "  journalctl -u keycloak -f --no-pager"
echo "  journalctl -u keycloak -n 50 --no-pager | grep -E 'ERROR|WARN|hostname'"
echo "[INFO] ============================================================"
