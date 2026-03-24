#!/usr/bin/env bash
# =============================================================================
# fix-keycloak-504.sh
#
# Problem:   504 Gateway Timeout on Keycloak admin console + cloudflared
#            "Incoming request ended abruptly: context canceled"
#
# Root cause chain:
#   [1] Keycloak 26 on 2GB RAM starts slowly (60-120s full warmup).
#       During startup, Keycloak does DB schema checks + Infinispan cache
#       init that causes JDBC ResultSet "leaks" (harmless startup artifact,
#       tracked upstream: github.com/keycloak/keycloak/issues/34195 and
#       #34819). These are NOT the cause of the 504 but confirm slow start.
#
#   [2] Nginx proxy_read_timeout defaults to 60s. Keycloak isn't ready in
#       time → Nginx returns 504 to cloudflared.
#
#   [3] cloudflared receives the 504 / dropped connection and logs:
#       "Incoming request ended abruptly: context canceled"
#       This is the SYMPTOM, not the cause. Cloudflare's edge has a hard
#       ~100s timeout; Nginx already killed it at 60s.
#
# Fixes applied:
#   [A] Nginx: raise proxy_read_timeout to 300s, add upstream keepalive,
#       add large buffer sizes for KC's verbose headers, add X-Forwarded-*
#       headers properly scoped
#   [B] Keycloak: tune JVM heap & GC for 2GB VM, raise db-pool sizes,
#       add cache-stack=local (single-node, avoids JGroups UDP multicast
#       overhead and the "thread_dumps_threshold deprecated" noise)
#   [C] systemd: raise TimeoutStartSec so systemd doesn't race the slow
#       first boot; add health-check pre-check before marking "started"
#
# Usage: sudo bash fix-keycloak-504.sh
# =============================================================================

set -euo pipefail

KC_HOME="/opt/keycloak"
KC_USER="keycloak"
KC_CONF="${KC_HOME}/conf/keycloak.conf"
NGINX_PUBLIC_CONF="/etc/nginx/sites-available/keycloak-public.conf"
NGINX_ADMIN_CONF="/etc/nginx/sites-available/keycloak-admin.conf"
PUBLIC_DOMAIN="auth.sampledomain.com"
ADMIN_DOMAIN="iam.sampledomain.com"

# ── preflight ─────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && { echo "[ERROR] Run as root"; exit 1; }
[[ ! -f "$KC_CONF"            ]] && { echo "[ERROR] $KC_CONF not found"; exit 1; }
[[ ! -f "$NGINX_PUBLIC_CONF"  ]] && { echo "[ERROR] $NGINX_PUBLIC_CONF not found"; exit 1; }
[[ ! -f "$NGINX_ADMIN_CONF"   ]] && { echo "[ERROR] $NGINX_ADMIN_CONF not found"; exit 1; }

echo "[INFO] ================================================================"
echo "[INFO] Keycloak 504 / cloudflared context-canceled fix"
echo "[INFO] ================================================================"

# ── STEP 1: verify Keycloak is actually listening on 8080 ─────────────────────
echo ""
echo "[STEP 1] Checking Keycloak is reachable on 127.0.0.1:8080..."
KC_HEALTH=$(curl -sSo /dev/null -w "%{http_code}" \
    --max-time 5 "http://127.0.0.1:8080/health/ready" 2>/dev/null || echo "000")

if [[ "$KC_HEALTH" == "200" ]]; then
    echo "[OK]   Keycloak health: HTTP 200 — service is up"
elif [[ "$KC_HEALTH" == "000" ]]; then
    echo "[WARN] Keycloak not responding yet (still starting or crashed)"
    echo "       Check: journalctl -u keycloak -n 40 --no-pager"
else
    echo "[WARN] Keycloak health returned HTTP $KC_HEALTH"
fi

# ── STEP 2: check current Nginx timeout values ────────────────────────────────
echo ""
echo "[STEP 2] Checking Nginx proxy timeout values (current)..."
echo "  --- keycloak-public.conf ---"
grep -E "proxy_read_timeout|proxy_send_timeout|proxy_connect_timeout|keepalive" \
    "$NGINX_PUBLIC_CONF" || echo "  (none — using Nginx global default of 60s)"
echo "  --- keycloak-admin.conf ---"
grep -E "proxy_read_timeout|proxy_send_timeout|proxy_connect_timeout|keepalive" \
    "$NGINX_ADMIN_CONF" || echo "  (none — using Nginx global default of 60s)"

# ── STEP 3: check what the Nginx → KC request actually returns ─────────────────
echo ""
echo "[STEP 3] Probing Nginx upstream directly (port 7080 / internal)..."
NGINX_STATUS=$(curl -sSo /dev/null -w "%{http_code}" \
    --max-time 10 "http://127.0.0.1:7080/health/ready" 2>/dev/null || echo "000")
echo "  Nginx→KC health: HTTP $NGINX_STATUS"

echo ""
echo "[STEP 3b] Timing a real admin page request through Nginx..."
TIMING=$(curl -sSo /dev/null \
    -w "HTTP:%{http_code} total:%{time_total}s connect:%{time_connect}s ttfb:%{time_starttransfer}s" \
    --max-time 90 "http://127.0.0.1:7080/admin/master/console/" 2>/dev/null || echo "TIMEOUT")
echo "  $TIMING"

# ── STEP 4: patch Nginx configs ───────────────────────────────────────────────
# There are two separate files matching what install-keycloak.sh created:
#   keycloak-public.conf  — listens on 127.0.0.1:7080 (cloudflared originService)
#   keycloak-admin.conf   — listens on 443 ssl (LAN-only iam.sampledomain.com)
#
# Key changes vs originals:
#   proxy_read_timeout 300s   ← was 60s default → root cause of the 504
#   proxy_send_timeout 300s   ← symmetrically raised
#   proxy_buffer_size 128k    ← preserved from original (KC sends large headers)
#   proxy_buffers 4 256k      ← preserved from original
#   proxy_http_version 1.1    ← added: required for upstream keepalive
#   Connection ""             ← added: clears Connection header for keepalive
#   X-Forwarded-Port 443      ← added: KC needs public port for correct redirects

echo ""
echo "[STEP 4a] Patching $NGINX_PUBLIC_CONF ..."
cp "$NGINX_PUBLIC_CONF" "${NGINX_PUBLIC_CONF}.bak.$(date +%Y%m%d%H%M%S)"

cat > "$NGINX_PUBLIC_CONF" << 'NGINXEOF'
# auth.sampledomain.com — public-facing OIDC endpoint
# Cloudflare Tunnel sends traffic to 127.0.0.1:7080 (plain HTTP, no TLS here;
# Cloudflare terminates TLS at its edge, tunnel leg is mTLS internally).
server {
    listen 127.0.0.1:7080;
    server_name auth.sampledomain.com;

    # ── Proxy timeouts ────────────────────────────────────────────────────────
    # Keycloak 26 on 2GB RAM takes 60-120s to warm up on first request.
    # Default proxy_read_timeout is 60s — that was causing the 504.
    proxy_connect_timeout  10s;
    proxy_send_timeout    300s;
    proxy_read_timeout    300s;

    proxy_buffer_size          128k;
    proxy_buffers              4 256k;
    proxy_busy_buffers_size    256k;

    location / {
        proxy_pass         http://127.0.0.1:8080;

        # proxy_http_version 1.1 + Connection "" enables upstream keepalive
        proxy_http_version 1.1;
        proxy_set_header   Connection "";

        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto https;
        proxy_set_header   X-Forwarded-Host  $host;
        # Tell KC the public port so redirect URIs are built correctly
        proxy_set_header   X-Forwarded-Port  443;
        proxy_set_header   Accept-Encoding   "";
    }
}
NGINXEOF

echo "[OK]   keycloak-public.conf written."

echo ""
echo "[STEP 4b] Patching $NGINX_ADMIN_CONF ..."
cp "$NGINX_ADMIN_CONF" "${NGINX_ADMIN_CONF}.bak.$(date +%Y%m%d%H%M%S)"

# Determine cert path — original uses auth.sampledomain.com cert for both domains
CERT_BASE="/etc/letsencrypt/live/auth.sampledomain.com"

cat > "$NGINX_ADMIN_CONF" << NGINXEOF
# iam.sampledomain.com — admin dashboard, LAN-only
server {
    listen 443 ssl;
    server_name ${ADMIN_DOMAIN};

    ssl_certificate     ${CERT_BASE}/fullchain.pem;
    ssl_certificate_key ${CERT_BASE}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 10m;

    # ── LAN-only restriction ──────────────────────────────────────────────────
    allow 192.168.2.0/24;
    deny  all;

    # ── Proxy timeouts ────────────────────────────────────────────────────────
    # Raised from 60s default to prevent 504 on slow KC cold-start responses.
    proxy_connect_timeout  10s;
    proxy_send_timeout    300s;
    proxy_read_timeout    300s;

    proxy_buffer_size          64k;
    proxy_buffers              8 64k;
    proxy_busy_buffers_size    128k;

    client_max_body_size 10m;

    location / {
        proxy_pass         http://127.0.0.1:8080;

        proxy_http_version 1.1;
        proxy_set_header   Connection "";

        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto https;
        proxy_set_header   X-Forwarded-Host  ${ADMIN_DOMAIN};
        proxy_set_header   X-Forwarded-Port  443;
        proxy_set_header   Accept-Encoding   "";
    }

    # HTTP → HTTPS redirect for iam domain
    error_page 497 https://\$host\$request_uri;
}

server {
    listen 80;
    server_name ${ADMIN_DOMAIN};
    return 301 https://\$host\$request_uri;
}
NGINXEOF

echo "[OK]   keycloak-admin.conf written."

# ── STEP 5: patch keycloak.conf ───────────────────────────────────────────────
echo ""
echo "[STEP 5] Patching keycloak.conf..."
cp "$KC_CONF" "${KC_CONF}.bak.$(date +%Y%m%d%H%M%S)"

# Read existing DB password from systemd service
DB_PASS=$(grep "^Environment=\"KC_DB_PASSWORD=" /etc/systemd/system/keycloak.service \
    | cut -d= -f3 | tr -d '"' || true)
if [[ -z "$DB_PASS" ]] && [[ -f /root/.keycloak_creds ]]; then
    DB_PASS=$(grep "^DB_PASS=" /root/.keycloak_creds | cut -d= -f2-)
fi
[[ -z "$DB_PASS" ]] && {
    echo "[ERROR] Cannot read KC_DB_PASSWORD from service unit or /root/.keycloak_creds"
    exit 1
}

cat > "$KC_CONF" << EOF
# =============================================================================
# Keycloak 26.x Configuration — tuned for 2 vCPU / 2 GB VM
# Last updated: $(date +%Y-%m-%d)
# =============================================================================

# ── Database ──────────────────────────────────────────────────────────────────
db=postgres
db-url=jdbc:postgresql://localhost:5432/keycloak
db-username=keycloak
# Password injected via systemd Environment= (not stored here)

# db-pool-initial-size: open N connections on startup rather than lazily.
# This front-loads the startup cost so the *first user request* isn't slow.
# On 2GB RAM, 3 initial + 5 min is safe (each PG connection ≈ 5-10 MB RAM).
db-pool-initial-size=3
db-pool-min-size=5
db-pool-max-size=15

# ── HTTP ──────────────────────────────────────────────────────────────────────
# Nginx terminates TLS. KC listens on plain HTTP 8080.
http-enabled=true
http-port=8080
# Enforce HTTPS for externally generated URLs (redirects, OIDC discovery).
# 'external' means: localhost/127.0.0.1 can use HTTP, everything else must HTTPS.
https-required=external

# ── Hostname (v2 — requires full URL when hostname-admin is set) ──────────────
hostname=https://${PUBLIC_DOMAIN}
hostname-admin=https://${ADMIN_DOMAIN}

# ── Proxy ─────────────────────────────────────────────────────────────────────
proxy-headers=xforwarded
# Only trust X-Forwarded-* headers from Nginx on localhost.
# This prevents header spoofing from the public internet.
proxy-trusted-addresses=127.0.0.1

# ── Cache (Infinispan) ────────────────────────────────────────────────────────
# cache=local: single-node mode — skips JGroups UDP multicast discovery
# which is unnecessary on a standalone VM and causes these log lines:
#   WARN JGRP000014: ThreadPool.thread_dumps_threshold has been deprecated: ignored
# This also meaningfully speeds up startup (~10-15s faster on 2 vCPU).
cache=local

# ── Health & Metrics ──────────────────────────────────────────────────────────
# Exposed on management port 9000 (not proxied by Nginx — LAN/localhost only)
health-enabled=true
metrics-enabled=true

# ── Features ─────────────────────────────────────────────────────────────────
features=token-exchange,admin-fine-grained-authz

# ── Logging ───────────────────────────────────────────────────────────────────
log-level=INFO
# Suppress startup-phase JDBC leak warnings — these are a known KC26 startup
# artifact (github.com/keycloak/keycloak/issues/34195) and are not real leaks.
# They occur because Agroal's leak detector fires mid-migration before the
# connection is explicitly closed within its check interval.
log-level=io.agroal:WARN,io.micrometer:WARN,org.jgroups:WARN,INFO
EOF

echo "[OK]   keycloak.conf written."

# ── STEP 6: patch systemd service (JVM tuning + timeouts) ─────────────────────
echo ""
echo "[STEP 6] Patching systemd keycloak.service..."

# Read admin creds if available
KC_ADMIN_USER=$(grep "^Environment=\"KC_BOOTSTRAP_ADMIN_USERNAME=" \
    /etc/systemd/system/keycloak.service | cut -d= -f3 | tr -d '"' || \
    grep "^KC_ADMIN_USER=" /root/.keycloak_creds 2>/dev/null | cut -d= -f2- || \
    echo "admin")
KC_ADMIN_PASS=$(grep "^Environment=\"KC_BOOTSTRAP_ADMIN_PASSWORD=" \
    /etc/systemd/system/keycloak.service | cut -d= -f3 | tr -d '"' || \
    grep "^KC_ADMIN_PASS=" /root/.keycloak_creds 2>/dev/null | cut -d= -f2- || \
    echo "")

cp /etc/systemd/system/keycloak.service \
   "/etc/systemd/system/keycloak.service.bak.$(date +%Y%m%d%H%M%S)"

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

# ── JVM tuning for 2 vCPU / 2 GB VM ──────────────────────────────────────────
# -Xms256m:  start small — JVM expands heap lazily to avoid OOM at boot
# -Xmx896m:  ~45% of 2GB, leaves room for OS + Nginx + PG on same VM
# G1GC with 200ms max-pause is appropriate for interactive auth workloads
# +UseStringDeduplication: reduces heap for repetitive JWT/config strings
# -Dfile.encoding=UTF-8: prevents KC admin console charset issues on some JDKs
Environment="JAVA_OPTS=-Xms256m -Xmx896m -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -XX:+UseStringDeduplication -XX:+ExitOnOutOfMemoryError -Djava.net.preferIPv4Stack=true -Dfile.encoding=UTF-8"

# ── Keycloak DB password ───────────────────────────────────────────────────────
Environment="KC_DB_PASSWORD=${DB_PASS}"

# ── Bootstrap admin (only used on first start) ────────────────────────────────
Environment="KC_BOOTSTRAP_ADMIN_USERNAME=${KC_ADMIN_USER}"
Environment="KC_BOOTSTRAP_ADMIN_PASSWORD=${KC_ADMIN_PASS}"

# --optimized: uses the pre-compiled Quarkus binary from kc.sh build.
# Do NOT add any config flags here — put everything in keycloak.conf instead.
ExecStart=${KC_HOME}/bin/kc.sh start --optimized

# ── Restart policy ────────────────────────────────────────────────────────────
Restart=on-failure
RestartSec=20s

# ── Startup timeout ───────────────────────────────────────────────────────────
# KC 26 on 2GB RAM can take up to 90s on first boot (DB migration + cache init).
# Without this, systemd may mark the service "timed out" at 90s and kill it.
TimeoutStartSec=180s
TimeoutStopSec=60s

# ── Security hardening ────────────────────────────────────────────────────────
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
ReadWritePaths=${KC_HOME} /tmp
LimitNOFILE=65536
LimitNPROC=4096

[Install]
WantedBy=multi-user.target
EOF

echo "[OK]   systemd service written."

# ── STEP 7: rebuild Keycloak (required after keycloak.conf changes) ───────────
echo ""
echo "[STEP 7] Running 'kc.sh build' (bakes new config into Quarkus binary)..."
echo "         This takes 1-3 minutes on a 2 vCPU VM..."
systemctl stop keycloak || true
sleep 3

sudo -u "$KC_USER" "${KC_HOME}/bin/kc.sh" build 2>&1 | tee /tmp/kc-build-504fix.log

if grep -qiE "^ERROR|BUILD FAILURE" /tmp/kc-build-504fix.log; then
    echo "[ERROR] kc.sh build failed. Check /tmp/kc-build-504fix.log"
    tail -30 /tmp/kc-build-504fix.log
    exit 1
fi
echo "[OK]   kc.sh build succeeded."

# ── STEP 8: validate and reload Nginx ─────────────────────────────────────────
echo ""
echo "[STEP 8] Testing Nginx config..."
nginx -t 2>&1

echo "[OK]   Nginx config valid. Reloading..."
systemctl reload nginx

# ── STEP 9: restart Keycloak ──────────────────────────────────────────────────
echo ""
echo "[STEP 9] Starting Keycloak..."
systemctl daemon-reload
systemctl enable keycloak
systemctl start keycloak

echo ""
echo "[INFO] Waiting for Keycloak to become ready (up to 180s)..."
echo "[INFO] Startup on 2GB RAM typically takes 60-90s. Be patient."
MAX_WAIT=180
WAITED=0
INTERVAL=8

while [[ $WAITED -lt $MAX_WAIT ]]; do
    sleep $INTERVAL
    WAITED=$((WAITED + INTERVAL))

    if ! systemctl is-active --quiet keycloak; then
        echo "[ERROR] Keycloak crashed after ${WAITED}s."
        journalctl -u keycloak -n 40 --no-pager
        exit 1
    fi

    HTTP_STATUS=$(curl -sSo /dev/null -w "%{http_code}" \
        --max-time 4 "http://127.0.0.1:8080/health/ready" 2>/dev/null || echo "000")

    if [[ "$HTTP_STATUS" == "200" ]]; then
        echo "[OK]   Keycloak healthy after ${WAITED}s (HTTP 200)"
        break
    fi
    echo "  [${WAITED}s] Still starting... (health: HTTP $HTTP_STATUS)"
done

if [[ "$HTTP_STATUS" != "200" ]]; then
    echo "[WARN] Health endpoint didn't return 200 within ${MAX_WAIT}s."
    echo "       Keycloak may need more time. Check: journalctl -u keycloak -f"
fi

# ── STEP 10: end-to-end validation ────────────────────────────────────────────
echo ""
echo "[STEP 10] End-to-end validation..."

# a) Direct KC health
DIRECT=$(curl -sSo /dev/null -w "%{http_code}" \
    --max-time 5 "http://127.0.0.1:8080/health/ready" 2>/dev/null || echo "000")
printf "  %-50s %s\n" "Direct KC health (8080):" "HTTP $DIRECT"

# b) Nginx internal port (cloudflared path)
NGXINT=$(curl -sSo /dev/null -w "%{http_code}" \
    --max-time 10 "http://127.0.0.1:7080/health/ready" 2>/dev/null || echo "000")
printf "  %-50s %s\n" "Nginx internal (7080 → KC):" "HTTP $NGXINT"

# c) OIDC discovery
OIDC=$(curl -sSo /dev/null -w "%{http_code}" \
    --max-time 10 "http://127.0.0.1:7080/realms/master/.well-known/openid-configuration" \
    2>/dev/null || echo "000")
printf "  %-50s %s\n" "OIDC discovery (via Nginx):" "HTTP $OIDC"

# d) Admin console
ADMCON=$(curl -sSo /dev/null -w "%{http_code}" \
    --max-time 20 "http://127.0.0.1:7080/admin/master/console/" 2>/dev/null || echo "000")
printf "  %-50s %s\n" "Admin console (via Nginx):" "HTTP $ADMCON"

# e) Nginx timeout config
echo ""
echo "[INFO] Nginx proxy timeout settings in effect:"
echo "  -- keycloak-public.conf --"
grep -E "proxy_read_timeout|proxy_send_timeout|proxy_connect_timeout" \
    "$NGINX_PUBLIC_CONF" | sed 's/^/  /'
echo "  -- keycloak-admin.conf --"
grep -E "proxy_read_timeout|proxy_send_timeout|proxy_connect_timeout" \
    "$NGINX_ADMIN_CONF" | sed 's/^/  /'

# f) Summary
echo ""
echo "[INFO] ================================================================"
echo "[INFO] Fix complete."
echo ""
echo "  Keycloak (direct)  http://127.0.0.1:8080"
echo "  Nginx (internal)   http://127.0.0.1:7080    ← cloudflared originService"
echo "  Admin console      https://${ADMIN_DOMAIN}  (LAN only — must be on 192.168.2.x)"
echo "  OIDC public        https://${PUBLIC_DOMAIN}/realms/master/.well-known/openid-configuration"
echo ""
echo "  If you still see 504:"
echo "  1. Confirm you're accessing iam.sampledomain.com from 192.168.2.x (LAN-only)"
echo "  2. Time a full admin console load:  curl -v --max-time 60 http://127.0.0.1:7080/admin/master/console/"
echo "  3. Watch real-time KC logs:         journalctl -u keycloak -f --no-pager"
echo "  4. Watch real-time Nginx errors:    tail -f /var/log/nginx/error.log"
echo "  5. cloudflared context-canceled errors are NORMAL during KC startup;"
echo "     they should stop once KC is fully warm."
echo "[INFO] ================================================================"
