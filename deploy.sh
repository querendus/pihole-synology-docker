#!/usr/bin/env bash
# deploy.sh — Deploy Pi-hole to Synology NAS
#
# Runs from your workstation over SSH. Handles:
#   1. Preflight checks (SSH, Container Manager)
#   2. Create data directories on NAS
#   3. Prompt for .env values (password, timezone)
#   4. Copy all files to NAS
#   5. Pull image + start container
#   6. Activate macvlan shim (host ↔ container)
#   7. Persist shim across reboots (rc.d)
#
# Prerequisites:
#   - SSH key auth to Synology
#   - Container Manager installed from DSM Package Center
#   - Edit CONFIGURATION section below
#
# Usage: ./deploy.sh

set -euo pipefail

# ═════════════════════════════════════════════════════════════════════
# CONFIGURATION — Edit these to match your setup
# ═════════════════════════════════════════════════════════════════════
NAS_USER="martin"         # Your SSH username on the Synology
NAS_IP="172.16.3.42"             # Your Synology's IP address
NAS_HOST="${NAS_USER}@${NAS_IP}"
NAS_DIR="/volume1/docker/pihole" # Deployment directory on NAS
PIHOLE_IP="172.16.2.21"         # Pi-hole's IP (must match docker-compose.yml)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ═════════════════════════════════════════════════════════════════════

ok()   { printf "  \033[32m✓\033[0m %s\n" "$*"; }
fail() { printf "  \033[31m✗\033[0m %s\n" "$*" >&2; exit 1; }
info() { printf "  → %s\n" "$*"; }
step() { printf "\n\033[1m[%s]\033[0m %s\n" "$1" "$2"; }

echo ""
echo "╔══════════════════════════════════════╗"
echo "║   Pi-hole → Synology NAS             ║"
echo "╚══════════════════════════════════════╝"

# ─────────────────────────────────────────────
step "1/7" "Preflight checks"
# ─────────────────────────────────────────────
info "Testing SSH to ${NAS_HOST}..."
ssh -o ConnectTimeout=5 -o BatchMode=yes "${NAS_HOST}" "true" 2>/dev/null \
    || fail "Cannot SSH to ${NAS_HOST}. Check key auth and connectivity."
ok "SSH connection"

info "Checking Container Manager..."
CM_STATUS=$(ssh "${NAS_HOST}" "/usr/syno/bin/synopkg status ContainerManager 2>/dev/null" || echo "")
if echo "$CM_STATUS" | grep -qi "started\|running"; then
    ok "Container Manager is running"
else
    fail "Container Manager is not installed or not running.
    Install from DSM Package Center → Container Manager, then re-run."
fi

info "Checking Docker CLI..."
ssh "${NAS_HOST}" "sudo docker-compose version >/dev/null 2>&1" \
    || fail "docker-compose not available. Is Container Manager fully started?"
ok "docker-compose available"

# ─────────────────────────────────────────────
step "2/7" "Creating data directories"
# ─────────────────────────────────────────────
ssh "${NAS_HOST}" "sudo mkdir -p ${NAS_DIR}/{etc-pihole,etc-dnsmasq.d}"
ok "${NAS_DIR}/{etc-pihole,etc-dnsmasq.d}"

# ─────────────────────────────────────────────
step "3/7" "Configuring .env"
# ─────────────────────────────────────────────
if ssh "${NAS_HOST}" "test -f ${NAS_DIR}/.env" 2>/dev/null; then
    ok ".env already exists on NAS — skipping (delete it to reconfigure)"
else
    read -rsp "  Enter Pi-hole web password (empty = no password): " PW
    echo ""
    read -rp "  Timezone [America/New_York]: " TZ_IN
    TZ_VAL="${TZ_IN:-America/New_York}"

    TMPENV=$(mktemp)
    cat > "$TMPENV" <<EOF
PIHOLE_PASSWORD=${PW}
TZ=${TZ_VAL}
EOF
    scp -q "$TMPENV" "${NAS_HOST}:${NAS_DIR}/.env"
    rm -f "$TMPENV"
    ok ".env created on NAS"
fi

# ─────────────────────────────────────────────
step "4/7" "Copying compose files"
# ─────────────────────────────────────────────
scp -q "${SCRIPT_DIR}/docker-compose.yml" "${NAS_HOST}:${NAS_DIR}/"
scp -q "${SCRIPT_DIR}/.env.example"       "${NAS_HOST}:${NAS_DIR}/"
scp -q "${SCRIPT_DIR}/macvlan-shim.sh"    "${NAS_HOST}:${NAS_DIR}/"
scp -q "${SCRIPT_DIR}/backup.sh"          "${NAS_HOST}:${NAS_DIR}/"
ssh "${NAS_HOST}" "chmod +x ${NAS_DIR}/macvlan-shim.sh ${NAS_DIR}/backup.sh"
ok "Files deployed to ${NAS_DIR}/"

# ─────────────────────────────────────────────
step "5/7" "Pulling image and starting Pi-hole"
# ─────────────────────────────────────────────
info "Pulling pihole/pihole:latest (this may take a minute)..."
ssh "${NAS_HOST}" "cd ${NAS_DIR} && sudo docker-compose pull --quiet"
ok "Image pulled"

ssh "${NAS_HOST}" "cd ${NAS_DIR} && sudo docker-compose up -d"
ok "Container started"

# ─────────────────────────────────────────────
step "6/7" "Activating macvlan shim"
# ─────────────────────────────────────────────
ssh "${NAS_HOST}" "sudo bash ${NAS_DIR}/macvlan-shim.sh start"
ok "Shim active — NAS can reach ${PIHOLE_IP}"

# ─────────────────────────────────────────────
step "7/7" "Persisting shim across reboots"
# ─────────────────────────────────────────────
# Copy to rc.d so it runs at boot (DSM calls rc.d scripts with "start" on boot)
ssh "${NAS_HOST}" "sudo cp ${NAS_DIR}/macvlan-shim.sh /usr/local/etc/rc.d/macvlan-shim.sh \
    && sudo chmod 755 /usr/local/etc/rc.d/macvlan-shim.sh"
ok "Installed to /usr/local/etc/rc.d/macvlan-shim.sh"

# ─────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
echo "  Deployment complete!"
echo ""
echo "  Web UI:   http://${PIHOLE_IP}/admin"
echo "  Test DNS: dig @${PIHOLE_IP} google.com"
echo ""
echo "  Next step: ./verify.sh"
echo "════════════════════════════════════════"
