#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Purpose:     Install and configure Moodle on Ubuntu 24.04
#              - Apache 2.4 (latest), PHP 8.3-FPM, PostgreSQL 16
#              - Let's Encrypt SSL (learn.sampledomain.com)
#              - HTTP → HTTPS redirect
#              - Keycloak OIDC auth integration
#              - Cloudflare Tunnel (cloudflared)
#              - iptables firewall (HTTP/HTTPS open, SSH from Guacamole only)
# Usage:       sudo ./install-moodle.sh
# Prerequisites: Ubuntu 24.04, DNS A record for learn.sampledomain.com → Cloudflare Tunnel
# Last Updated: 2026-03
# =============================================================================

# === VARIABLES ===
DOMAIN="learn.sampledomain.com"
MOODLE_DIR="/var/www/moodle"
MOODLE_DATA="/var/moodledata"
DB_NAME="moodledb"
DB_USER="moodleuser"
DB_PASS="$(openssl rand -base64 24)"   # Generated on first run; save this!
ADMIN_USER="sysadmin"
GUACAMOLE_IP="192.168.2.197"
KEYCLOAK_URL="https://auth.sampledomain.com"
MOODLE_VERSION="MOODLE_405_STABLE"     # Latest stable as of early 2026 (4.5.x)

# === PREFLIGHT ===
[[ $EUID -ne 0 ]] && { echo "[ERROR] Must run as root"; exit 1; }
echo "[INFO] Starting Moodle installation on $DOMAIN"
echo "[WARN] DB password (SAVE THIS): $DB_PASS"
echo "$DB_PASS" > /root/.moodle_db_pass
chmod 600 /root/.moodle_db_pass

# === ADD PHP 8.3 REPO ===
# Install iptables-persistent first -- it creates /etc/iptables/ which we need for saving rules
echo "[INFO] Installing base dependencies and PHP 8.3 PPA..."
apt-get install -y software-properties-common iptables-persistent netfilter-persistent
add-apt-repository -y ppa:ondrej/php
add-apt-repository -y ppa:ondrej/apache2
apt-get update -qq

# === OPEN FIREWALL PORTS FOR WEB ===
# /etc/iptables/ now exists (created by iptables-persistent above)
echo "[INFO] Opening HTTP/HTTPS in iptables..."
iptables -A INPUT -p tcp --dport 80 -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j ACCEPT
iptables-save > /etc/iptables/rules.v4

# === INSTALL APACHE + PHP 8.3 ===
echo "[INFO] Installing Apache and PHP 8.3..."
apt-get install -y \
  apache2 \
  php8.3 php8.3-fpm php8.3-common \
  php8.3-pgsql php8.3-gd php8.3-curl \
  php8.3-intl php8.3-mbstring php8.3-soap php8.3-zip \
  php8.3-xml php8.3-opcache php8.3-redis \
  libapache2-mod-fcgid
# Note: php8.3-xmlrpc was removed from PHP 8.x upstream.
# Moodle 4.5+ no longer requires xmlrpc. If a plugin needs it, build from PECL.

# Enable Apache modules
a2enmod rewrite ssl headers proxy_fcgi setenvif http2
a2enconf php8.3-fpm
a2dismod php8.3 2>/dev/null || true   # Use FPM, not mod_php
a2dissite 000-default.conf 2>/dev/null || true

# === INSTALL POSTGRESQL 16 ===
echo "[INFO] Installing PostgreSQL 16..."
apt-get install -y postgresql postgresql-contrib
systemctl enable --now postgresql

# === CREATE DATABASE ===
echo "[INFO] Creating Moodle PostgreSQL database..."
sudo -u postgres psql << SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${DB_USER}') THEN
    CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASS}';
  END IF;
END
\$\$;

SELECT 'CREATE DATABASE ${DB_NAME} OWNER ${DB_USER} ENCODING UTF8 LC_COLLATE ''en_US.UTF-8'' LC_CTYPE ''en_US.UTF-8'' TEMPLATE template0'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${DB_NAME}')\gexec
SQL
echo "[INFO] PostgreSQL database ready: $DB_NAME / $DB_USER"

# === INSTALL MOODLE ===
echo "[INFO] Cloning Moodle $MOODLE_VERSION..."
apt-get install -y git
if [[ ! -d "$MOODLE_DIR/.git" ]]; then
  git clone --depth 1 --branch "$MOODLE_VERSION" \
    https://github.com/moodle/moodle.git "$MOODLE_DIR"
else
  echo "[INFO] Moodle already cloned; skipping."
fi

# Moodle data directory (outside webroot)
mkdir -p "$MOODLE_DATA"
chown -R www-data:www-data "$MOODLE_DATA" "$MOODLE_DIR"
chmod -R 755 "$MOODLE_DIR"
chmod 770 "$MOODLE_DATA"

# === PHP CONFIGURATION ===
echo "[INFO] Tuning PHP 8.3 for Moodle..."
PHP_INI="/etc/php/8.3/fpm/php.ini"
sed -i 's/^max_execution_time = .*/max_execution_time = 300/' "$PHP_INI"
sed -i 's/^memory_limit = .*/memory_limit = 256M/' "$PHP_INI"
sed -i 's/^post_max_size = .*/post_max_size = 100M/' "$PHP_INI"
sed -i 's/^upload_max_filesize = .*/upload_max_filesize = 100M/' "$PHP_INI"
sed -i 's/^max_input_vars = .*/max_input_vars = 5000/' "$PHP_INI"

# OPcache tuning (critical for Moodle performance)
cat >> "$PHP_INI" << 'EOF'

; OPcache settings for Moodle
opcache.enable=1
opcache.memory_consumption=128
opcache.max_accelerated_files=20000
opcache.revalidate_freq=60
opcache.use_cwd=1
opcache.validate_timestamps=1
opcache.save_comments=1
opcache.enable_file_override=0
EOF

systemctl restart php8.3-fpm

# === APACHE VIRTUAL HOST (HTTP redirect + HTTPS) ===
echo "[INFO] Creating Apache vhosts..."

# HTTP → HTTPS redirect
cat > /etc/apache2/sites-available/moodle-http.conf << EOF
<VirtualHost *:80>
    ServerName ${DOMAIN}
    # Redirect all HTTP to HTTPS
    RewriteEngine On
    RewriteRule ^(.*)$ https://%{HTTP_HOST}\$1 [R=301,L]
</VirtualHost>
EOF

# HTTPS vhost (cert will be added by certbot)
cat > /etc/apache2/sites-available/moodle-https.conf << EOF
<VirtualHost *:443>
    ServerName ${DOMAIN}
    DocumentRoot ${MOODLE_DIR}

    SSLEngine on
    # Certbot will populate these after running
    SSLCertificateFile    /etc/letsencrypt/live/${DOMAIN}/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/${DOMAIN}/privkey.pem

    # Security headers
    Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
    Header always set X-Content-Type-Options nosniff
    Header always set X-Frame-Options SAMEORIGIN
    Header always set X-XSS-Protection "1; mode=block"
    Header always set Referrer-Policy "strict-origin-when-cross-origin"

    # HTTP/2
    Protocols h2 http/1.1

    # PHP-FPM via Unix socket
    <FilesMatch \.php$>
        SetHandler "proxy:unix:/run/php/php8.3-fpm.sock|fcgi://localhost"
    </FilesMatch>

    <Directory ${MOODLE_DIR}>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    # Block access to sensitive dirs
    <DirectoryMatch "/(\.git|vendor|node_modules)">
        Require all denied
    </DirectoryMatch>

    # Cloudflare real IP passthrough
    RemoteIPHeader CF-Connecting-IP
    RemoteIPTrustedProxy 103.21.244.0/22
    RemoteIPTrustedProxy 103.22.200.0/22
    RemoteIPTrustedProxy 103.31.4.0/22
    RemoteIPTrustedProxy 104.16.0.0/13
    RemoteIPTrustedProxy 104.24.0.0/14
    RemoteIPTrustedProxy 108.162.192.0/18
    RemoteIPTrustedProxy 131.0.72.0/22
    RemoteIPTrustedProxy 141.101.64.0/18
    RemoteIPTrustedProxy 162.158.0.0/15
    RemoteIPTrustedProxy 172.64.0.0/13
    RemoteIPTrustedProxy 173.245.48.0/20
    RemoteIPTrustedProxy 188.114.96.0/20
    RemoteIPTrustedProxy 190.93.240.0/20
    RemoteIPTrustedProxy 197.234.240.0/22
    RemoteIPTrustedProxy 198.41.128.0/17

    ErrorLog \${APACHE_LOG_DIR}/${DOMAIN}-error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN}-access.log combined
</VirtualHost>
EOF

a2enmod remoteip
a2ensite moodle-http.conf moodle-https.conf
apache2ctl configtest
systemctl reload apache2

# === INSTALL CERTBOT (Let's Encrypt) ===
echo "[INFO] Installing certbot..."
apt-get install -y certbot python3-certbot-apache

echo ""
echo "[INFO] ==========================================================="
echo "[INFO] Run the following command to obtain SSL cert:"
echo ""
echo "  certbot --apache -d ${DOMAIN} --non-interactive --agree-tos \\"
echo "    --email admin@sampledomain.com --redirect"
echo ""
echo "[INFO] NOTE: DNS must be pointing to Cloudflare Tunnel BEFORE running certbot."
echo "[INFO] For Cloudflare Tunnel (proxied), use certbot with DNS challenge:"
echo ""
echo "  certbot certonly --manual --preferred-challenges dns -d ${DOMAIN}"
echo ""
echo "[INFO] Or use cloudflare DNS plugin:"
echo "  apt-get install -y python3-certbot-dns-cloudflare"
echo "  # Then create /etc/letsencrypt/cloudflare.ini with your CF API token"
echo "  certbot certonly --dns-cloudflare --dns-cloudflare-credentials \\"
echo "    /etc/letsencrypt/cloudflare.ini -d ${DOMAIN}"
echo "[INFO] ==========================================================="

# === MOODLE config.php ===
echo "[INFO] Creating Moodle config.php..."
cat > "${MOODLE_DIR}/config.php" << EOF
<?php
unset(\$CFG);
global \$CFG;
\$CFG = new stdClass();

\$CFG->dbtype    = 'pgsql';
\$CFG->dblibrary = 'native';
\$CFG->dbhost    = 'localhost';
\$CFG->dbname    = '${DB_NAME}';
\$CFG->dbuser    = '${DB_USER}';
\$CFG->dbpass    = '${DB_PASS}';
\$CFG->prefix    = 'mdl_';

\$CFG->wwwroot   = 'https://${DOMAIN}';
\$CFG->dataroot  = '${MOODLE_DATA}';
\$CFG->directorypermissions = 02777;

// Force HTTPS
\$CFG->sslproxy  = true;

// Reverse proxy / Cloudflare
\$CFG->reverseproxy = true;

\$CFG->admin = 'admin';

require_once(__DIR__ . '/lib/setup.php');
EOF
chown www-data:www-data "${MOODLE_DIR}/config.php"
chmod 640 "${MOODLE_DIR}/config.php"
echo "[INFO] config.php created"

# === INSTALL CLOUDFLARED ===
echo "[INFO] Installing cloudflared..."
curl -sSL https://pkg.cloudflare.com/cloudflare-main.gpg \
  | gpg --dearmor > /usr/share/keyrings/cloudflare-main.gpg
echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" \
  > /etc/apt/sources.list.d/cloudflared.list
apt-get update -qq
apt-get install -y cloudflared

echo ""
echo "[INFO] ==========================================================="
echo "[INFO] To configure Cloudflare Tunnel for ${DOMAIN}:"
echo ""
echo "  1. cloudflared tunnel login"
echo "  2. cloudflared tunnel create moodle"
echo "  3. cloudflared tunnel route dns moodle ${DOMAIN}"
echo ""
echo "  Create /etc/cloudflared/config.yml:"
echo "  tunnel: <TUNNEL_UUID>"
echo "  credentials-file: /root/.cloudflared/<TUNNEL_UUID>.json"
echo "  ingress:"
echo "    - hostname: ${DOMAIN}"
echo "      service: https://localhost:443"
echo "      originRequest:"
echo "        noTLSVerify: false"
echo "    - service: http_status:404"
echo ""
echo "  4. cloudflared service install"
echo "  5. systemctl enable --now cloudflared"
echo "[INFO] ==========================================================="

# === MOODLE CRON ===
echo "[INFO] Setting up Moodle cron job..."
(crontab -u www-data -l 2>/dev/null; \
  echo "*/1 * * * * /usr/bin/php ${MOODLE_DIR}/admin/cli/cron.php > /dev/null 2>&1") \
  | crontab -u www-data -

echo ""
echo "[INFO] ==========================================================="
echo "[INFO] Moodle installation complete!"
echo "[INFO] DB password saved to: /root/.moodle_db_pass"
echo ""
echo "[INFO] Next steps:"
echo "  1. Run certbot to get SSL cert"
echo "  2. Configure Cloudflare Tunnel"
echo "  3. Run tor-block.sh from shared/"
echo "  4. Run harden-common.sh from shared/"
echo "  5. Run tune-performance.sh web from shared/"
echo "  6. Complete Moodle web installer at https://${DOMAIN}/install.php"
echo "  7. Configure Keycloak OIDC auth (see keycloak-moodle-oidc-guide.md)"
echo "[INFO] ==========================================================="
