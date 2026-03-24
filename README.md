# 🏠 proxmox-homelab-iam-stack

> Self-hosted IAM + LMS + Remote Access on Proxmox VE — secured behind Cloudflare Tunnel, hardened with iptables, and wired together with Keycloak OIDC.

---

## What is this?

A fully self-hosted homelab platform running three Ubuntu 24.04 VMs on Proxmox VE 9.1. The whole thing lives behind Cloudflare Tunnel so there are **zero open inbound ports** on the network — everything punches out, not in.

| VM | Role | Public URL |
|---|---|---|
| **Keycloak 26.1** | Identity & Access Management (SSO) | `auth.sampledomain.com` |
| **Moodle 4.5** | Learning Management System | `learn.sampledomain.com` |
| **Guacamole 1.6** | Remote Access / Jump Host | `tty.sampledomain.com` |

All three VMs share the same security baseline and are SSH-accessible **only** through Guacamole — no direct SSH from anywhere else.

---

## Architecture

```
                        ┌─────────────────────────────────────────────┐
                        │              INTERNET                        │
                        └──────────────┬──────────────────────────────┘
                                       │
                        ┌──────────────▼──────────────────────────────┐
                        │           CLOUDFLARE EDGE                    │
                        │  WAF · DDoS · Tor/Anon Proxy Block · TLS    │
                        └───┬──────────────┬──────────────┬───────────┘
                            │ CF Tunnel    │ CF Tunnel    │ CF Tunnel
                ────────────▼──────  ──────▼──────  ──────▼──────────
               │  auth.sampledomain.com │ │learn.devoops│ │ tty.devoops  │
               │                  │ │    .lol     │ │    .lol      │
               │  ┌─────────────┐ │ │ ┌─────────┐ │ │ ┌──────────┐ │
               │  │  Keycloak   │ │ │ │  Moodle │ │ │ │Guacamole │ │
               │  │  26.1.0     │ │ │ │  4.5    │ │ │ │  1.6.0   │ │
               │  │  JDK 21     │ │ │ │ Apache  │ │ │ │ Tomcat 9 │ │
               │  │  PostgreSQL │ │ │ │ PHP-FPM │ │ │ │  guacd   │ │
               │  │  Nginx      │ │ │ │ Postgres│ │ │ │ MariaDB  │ │
               │  │  :7080      │ │ │ │  :80    │ │ │ │  :8080   │ │
               │  └─────────────┘ │ │ └─────────┘ │ │ └──────────┘ │
               │  192.168.2.157   │ │192.168.2.243│ │192.168.2.197 │
               └──────────────────┘ └─────────────┘ └──────────────┘
                                                              │
                          ┌──────────────────────────────────┘
                          │  SSH from 192.168.2.197 only
                          │
              ┌───────────▼──────────────────────────┐
              │          PROXMOX VE 9.1               │
              │    192.168.2.0/24 LAN subnet          │
              │    2 vCPU / 2GB RAM per VM            │
              │    Ubuntu 24.04.4 LTS                 │
              └──────────────────────────────────────┘
```

**Traffic rules in plain English:**
- Web requests → Cloudflare WAF → cloudflared tunnel → Nginx → app. No ports open on the firewall.
- SSH to Moodle or Keycloak → **must go through Guacamole**. Period.
- Tor and anonymous proxies blocked at Cloudflare WAF (Anonymous Proxies rule).
- All VMs drop everything by default, loopback and ESTABLISHED first.

---

## Repo Structure

```
proxmox-homelab-iam-stack/
│
├── keycloak/
│   ├── install-keycloak.sh        # JDK 21 + PostgreSQL + Keycloak 26.1 + Nginx
│   ├── keycloak-continue.sh       # SSL cert + cloudflared + realm + OIDC clients
│   ├── fix-keycloak-hostname.sh   # Fix Keycloak 26 hostname v2 startup bug
│   └── fix-keycloak-504.sh        # Fix cloudflared 504 / context-canceled errors
│
├── moodle/
│   ├── install-moodle.sh          # Apache + PHP 8.3-FPM + PostgreSQL + Moodle 4.5
│   └── moodle-continue.sh         # SSL cert + cloudflared + Keycloak OAuth2 plugin
│
├── guacamole/
│   ├── install-guacamole.sh       # guacd (from source) + Tomcat 9 (manual) + MariaDB + WAR
│   └── guacamole-continue.sh      # SSL cert + cloudflared + Keycloak OIDC config
│
└── shared/
    ├── harden-common.sh           # SSH lockdown + iptables + auditd + fail2ban + sysctl
    ├── tor-block.sh               # ipset-based Tor exit blocking (defence-in-depth)
    └── tune-performance.sh        # THP disable + BBR + ulimits + swap
```

---

## Deployment Order

Run in this order. Don't skip steps — the continue scripts depend on services being up.

```
1.  Keycloak VM   → install-keycloak.sh
2.  Keycloak VM   → keycloak-continue.sh
3.  Moodle VM     → install-moodle.sh
4.  Moodle VM     → moodle-continue.sh
5.  Guacamole VM  → install-guacamole.sh
6.  Guacamole VM  → guacamole-continue.sh
7.  All VMs       → harden-common.sh 192.168.2.197 <role>
8.  All VMs       → tor-block.sh
9.  All VMs       → tune-performance.sh
10. All VMs       → reboot
```

Where `<role>` is `java` for Keycloak, `web` for Moodle, `rdp` for Guacamole. This controls which ports get opened in iptables.

---

## Prerequisites

Before running anything you'll need:
- Proxmox VE 9.1 with three Ubuntu 24.04 VMs spun up
- A Cloudflare account with your domain set up and a Cloudflare API token (for DNS-01 cert challenge)
- Three Cloudflare Tunnel tokens (one per VM) — create them in the Cloudflare dashboard under Zero Trust → Networks → Tunnels
- The VMs need outbound internet access to pull packages and reach Cloudflare

Each VM should have:
- 2 vCPU, 2 GB RAM (minimum — Keycloak is the hungry one)
- Ubuntu 24.04.4 LTS fresh install
- A non-root sudo user (scripts assume `devoops`, change as needed)

---

## What went well ✅

**Cloudflare Tunnel is genuinely great for this.** Zero NAT rules, zero port forwarding, no exposed attack surface. The tunnel just makes outbound connections and Cloudflare routes traffic into it. For a homelab this is pretty much ideal — your ISP doesn't need to assign you a static IP and you never have to touch your router config.

**Keycloak as a single IdP works smoothly.** One realm, multiple clients — Moodle OAuth2 and Guacamole OIDC both wired to the same Keycloak moodle realm. Once the initial setup is done, adding new services as OIDC clients is quick. The Keycloak admin console over HTTPS on the LAN-only Nginx vhost is a nice separation too.

**The split install/continue script pattern paid off.** Every service has a base install script that gets the app running on HTTP, then a continue script that does the cert, HTTPS, and cloudflared setup. This means you can validate the service is actually working before punching it through to the internet, and you're not blocked on having the tunnel token ready during the base install.

**auditd + PROMPT_COMMAND bash logging is solid.** Every command on every VM gets timestamped to `/var/log/commands.log` via rsyslog. Combined with auditd watching `/etc/sudoers`, `/etc/shadow`, `/etc/ssh/` etc., you've got a pretty decent audit trail for a homelab. Useful if you're prepping for ISO 27001 work.

---

## What went wrong 💥

**Ubuntu 24.04 dropped Tomcat 9 from apt.** This was the biggest time sink of the whole project. Guacamole 1.6.0 still uses `javax.servlet` (not Jakarta EE), so it straight-up refuses to run on Tomcat 10. The fix is manually installing Tomcat 9.0.115 from the Apache downloads. Not hard once you know, but the error (`ClassNotFoundException: javax.servlet.ServletContextListener`) takes a moment to trace back to the right root cause.

**guacd systemd service design.** guacd starts, prints its version banner, then forks to background. With `Type=simple`, systemd sees the parent exit and declares the service dead. Switching to `Type=forking` fixes it, but then you need `RuntimeDirectory=guacd` and `PIDFile=` to avoid a permission issue where `ExecStartPre` mkdir was running as the guacd user instead of root. The final unit uses `RuntimeDirectory=` which systemd handles as root before dropping privileges — the clean way to do it.

**Keycloak 26 changed hostname validation.** The v2 hostname provider in Keycloak 26 is strict about startup — it'll refuse to start if the hostname config doesn't match reality. Needed a `fix-keycloak-hostname.sh` to add `hostname-strict=false` while things settle. Worth reading the Keycloak 26 migration guide before upgrading if you're coming from 24/25.

**Guacamole OIDC implicit flow.** Keycloak 26 disables implicit flow by default. Guacamole's OIDC extension defaults to requesting implicit flow. You'll get a cryptic `unauthorized_client` error in the browser URL. The fix is two lines in `guacamole.properties`:
```
openid-response-type=code
openid-response-mode=query
```

**iptables + service ports.** After running `harden-common.sh` the first time, the Keycloak admin dashboard was unreachable because the script flushed iptables but didn't open port 443 for LAN access. Then separately, Moodle was still SSH-accessible from Keycloak because the original script didn't enforce the source IP restriction hard enough. Both fixed, but it's a reminder that iptables ordering matters — loopback and ESTABLISHED rules have to come before DROP policy.

**Windows line endings (CRLF).** If you're editing these scripts on Windows and transferring them to the VM, you'll hit `invalid option name: pipefail\r`. Run `sed -i 's/\r//' script.sh` before executing. Or just use `dos2unix`.

**Tor blocking at the VM level doesn't work with Cloudflare Tunnel.** Spent some time on ipset-based Tor blocking only to realise: cloudflared is what connects to the app, so the VM always sees a Cloudflare IP as the source, never the actual Tor exit node. The right place to block Tor is in Cloudflare WAF with the "Anonymous Proxies" rule. The ipset script is kept as defence-in-depth for any future services that aren't behind the tunnel.

---

## Scripts Quick Reference

### `harden-common.sh`

```bash
sudo bash harden-common.sh <GUAC_IP> <ROLE>

# Examples:
sudo bash harden-common.sh 192.168.2.197 java    # Keycloak
sudo bash harden-common.sh 192.168.2.197 web     # Moodle
sudo bash harden-common.sh 192.168.2.197 rdp     # Guacamole
```

Applies: SSH hardening, iptables (role-based ports + SSH source restriction), auditd, fail2ban, kernel sysctl hardening, command logging, PAM password policy, unattended-upgrades.

### `tune-performance.sh`

```bash
sudo bash tune-performance.sh
```

Applies: Transparent Huge Pages disabled, BBR congestion control, TCP buffer tuning, file descriptor limits (PAM + systemd), 1GB swapfile if missing.

### `tor-block.sh`

```bash
sudo bash tor-block.sh
```

Fetches the Tor exit list, populates an ipset (`tor_exits`), inserts iptables DROP rules, sets up 6-hourly cron refresh.

---

## Firewall Rules Summary

| Source | Destination | Port | Action |
|---|---|---|---|
| `192.168.2.197` | Keycloak `:22` | SSH | ACCEPT |
| `192.168.2.197` | Moodle `:22` | SSH | ACCEPT |
| Any | Any VM `:22` | SSH | LOG + DROP |
| `127.0.0.1` | Keycloak `:7080` | HTTP | ACCEPT |
| `127.0.0.1` | Tomcat `:8080` | HTTP | ACCEPT |
| `192.168.2.0/24` | Any VM `:443` | HTTPS | ACCEPT |
| `192.168.2.0/24` | Any VM | ICMP | ACCEPT |
| `tor_exits` (ipset) | Any | Any | LOG + DROP |
| Any | Any | Any | DROP (default) |

---

## Known Issues / Gotchas

- **Guacamole SSH connections use explicit username/password** — not OIDC token passthrough. The `${GUAC_USERNAME}` token doesn't populate when using OpenID login flow. Set credentials directly in each connection's Authentication settings in the Guacamole admin panel.

- **Change the default Guacamole admin password** (`guacadmin` / `guacadmin`) immediately after deployment.

- **Keycloak JVM tuning** — with 2GB RAM, Keycloak runs with `-Xms512m -Xmx768m`. If you're running other heavy workloads on the same VM, watch the heap. The JVM override is in `/etc/systemd/system/keycloak.service.d/jvm-tuning.conf`.

- **IPv6 is disabled** system-wide via sysctl. If you need IPv6, remove `net.ipv6.conf.all.disable_ipv6 = 1` from `/etc/sysctl.d/99-hardening.conf` and adjust `curl` calls in scripts to remove the `-4` flag.

- **Let's Encrypt cert renewal** uses Certbot with Cloudflare DNS-01. The cron timer should handle renewal automatically. Run `sudo certbot renew --dry-run` to verify.

---

## Versions

| Component | Version |
|---|---|
| Proxmox VE | 9.1 |
| Ubuntu | 24.04.4 LTS |
| Keycloak | 26.1.0 |
| OpenJDK | 21 |
| Moodle | 4.5 |
| Apache | 2.4 |
| PHP-FPM | 8.3 |
| Guacamole | 1.6.0 |
| Tomcat | 9.0.115 (manual install) |
| guacd | 1.6.0 (built from source) |
| Nginx | 1.24 |
| PostgreSQL | 16 |
| MariaDB | 10.x |

---

## License

MIT — do whatever you want with the scripts. If something blows up your homelab, that's on you. 🤙

---

*Built as a personal lab project. Not production-hardened for enterprise use — but it's a solid starting point if you want a self-hosted IAM stack that's actually secured properly.*
