#!/usr/bin/env bash
set -Eeuo pipefail 2>/dev/null || set -e

# ==============================
# VPN INSTALLER v3 (SELF-HEALING)
# WireGuard production-ready single client
# ==============================

export DEBIAN_FRONTEND=noninteractive

WG_IF="wg0"
WG_DIR="/etc/wireguard"
CLIENT_DIR="/root/vpn-client"

SERVER_PORT=51820
WG_NET="10.10.0"

LOG_FILE="/var/log/vpn-installer.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "[INFO] Starting VPN installer v3..."

# ==============================
# 1. ROOT CHECK
# ==============================
if [ "$EUID" -ne 0 ]; then
  echo "[ERROR] Run as root"
  exit 1
fi

# ==============================
# 2. CRLF FIX (self-heal)
# ==============================
sed -i 's/\r$//' "$0" 2>/dev/null || true

# ==============================
# 3. INTERNET CHECK (self-heal)
# ==============================
if ! ping -c 1 1.1.1.1 >/dev/null 2>&1; then
  echo "[ERROR] No internet connection"
  exit 1
fi

# ==============================
# 4. OS CHECK
# ==============================
if [ ! -f /etc/os-release ]; then
  echo "[ERROR] Unsupported OS"
  exit 1
fi

. /etc/os-release
echo "[INFO] OS detected: $ID"

# ==============================
# 5. INSTALL DEPENDENCIES (retry-safe)
# ==============================
apt update -y || apt update -y || true

apt install -y \
  wireguard \
  qrencode \
  iptables \
  curl \
  iproute2 \
  >/dev/null 2>&1 || {
    echo "[ERROR] Package install failed"
    exit 1
}

# ==============================
# 6. WAN INTERFACE DETECT (safe)
# ==============================
WAN_IF=$(ip route | awk '/default/ {print $5; exit}')

if [ -z "$WAN_IF" ]; then
  echo "[ERROR] Cannot detect WAN interface"
  exit 1
fi

# ==============================
# 7. SERVER IP DETECT (fallback chain)
# ==============================
SERVER_IP=$(curl -4 -s --max-time 5 ifconfig.me || true)

if [ -z "$SERVER_IP" ]; then
  SERVER_IP=$(hostname -I | awk '{print $1}')
fi

echo "[INFO] Server IP: $SERVER_IP"

# ==============================
# 8. ENABLE IP FORWARDING (idempotent)
# ==============================
grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || \
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

sysctl -p >/dev/null 2>&1 || true

# ==============================
# 9. CLEAN PREVIOUS STATE (safe re-run)
# ==============================
systemctl stop wg-quick@$WG_IF 2>/dev/null || true
systemctl disable wg-quick@$WG_IF 2>/dev/null || true
ip link delete "$WG_IF" 2>/dev/null || true

mkdir -p "$WG_DIR" "$CLIENT_DIR"

# ==============================
# 10. GENERATE KEYS (persistent)
# ==============================
if [ ! -f "$WG_DIR/server_private.key" ]; then
  wg genkey | tee "$WG_DIR/server_private.key" | wg pubkey > "$WG_DIR/server_public.key"
fi

if [ ! -f "$WG_DIR/client_private.key" ]; then
  wg genkey | tee "$WG_DIR/client_private.key" | wg pubkey > "$WG_DIR/client_public.key"
fi

SERVER_PRIV=$(cat "$WG_DIR/server_private.key")
SERVER_PUB=$(cat "$WG_DIR/server_public.key")

CLIENT_PRIV=$(cat "$WG_DIR/client_private.key")
CLIENT_PUB=$(cat "$WG_DIR/client_public.key")

# ==============================
# 11. WRITE CONFIG (safe overwrite)
# ==============================
cat > "$WG_DIR/$WG_IF.conf" <<EOF
[Interface]
Address = $WG_NET.1/24
ListenPort = $SERVER_PORT
PrivateKey = $SERVER_PRIV

PostUp = iptables -A FORWARD -i $WG_IF -j ACCEPT; iptables -t nat -A POSTROUTING -o $WAN_IF -j MASQUERADE
PostDown = iptables -D FORWARD -i $WG_IF -j ACCEPT; iptables -t nat -D POSTROUTING -o $WAN_IF -j MASQUERADE

[Peer]
PublicKey = $CLIENT_PUB
AllowedIPs = $WG_NET.2/32
EOF

# ==============================
# 12. CLIENT CONFIG
# ==============================
CLIENT_CONF="$CLIENT_DIR/client.conf"

cat > "$CLIENT_CONF" <<EOF
[Interface]
PrivateKey = $CLIENT_PRIV
Address = $WG_NET.2/32
DNS = 1.1.1.1

[Peer]
PublicKey = $SERVER_PUB
Endpoint = $SERVER_IP:$SERVER_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

# ==============================
# 13. START SERVICE (self-heal)
# ==============================
systemctl enable wg-quick@$WG_IF >/dev/null 2>&1 || true
systemctl restart wg-quick@$WG_IF || {
  echo "[ERROR] WireGuard failed to start"
  exit 1
}

# ==============================
# 14. OUTPUT
# ==============================
echo ""
echo "=============================="
echo "VPN v3 READY"
echo "SERVER: $SERVER_IP"
echo "CLIENT FILE: $CLIENT_CONF"
echo "LOG: $LOG_FILE"
echo "=============================="
echo ""

qrencode -t ansiutf8 < "$CLIENT_CONF"

echo ""
echo "[DONE]"
