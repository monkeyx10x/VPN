#!/bin/bash
set -e
set -u
set -o pipefail 2>/dev/null || true

# =====================================================
# VPN INSTALL (CURL MODE SAFE)
# 1 VPS = 1 CLIENT (WireGuard)
# =====================================================

export DEBIAN_FRONTEND=noninteractive

WG_INTERFACE="wg0"
WG_DIR="/etc/wireguard"
CLIENT_DIR="/root/wireguard-client"

SERVER_PORT=51820
WG_NET="10.10.0"
SERVER_WG_IP="10.10.0.1/24"
CLIENT_IP="10.10.0.2/32"
CLIENT_NAME="client1"
CLIENT_DNS="1.1.1.1"

mkdir -p "$WG_DIR" "$CLIENT_DIR"

# =====================================================
# SAFETY: не ставим повторно
# =====================================================
if [ -f "$WG_DIR/$WG_INTERFACE.conf" ]; then
  echo "[INFO] WireGuard already installed. Exiting safely."
  exit 0
fi

# =====================================================
# INSTALL PACKAGES
# =====================================================
apt update -y
apt install -y wireguard qrencode iptables curl

# =====================================================
# GET PUBLIC IP (NO HARDCODE)
# =====================================================
SERVER_IP=$(curl -s ifconfig.me)

# =====================================================
# DETECT WAN INTERFACE
# =====================================================
WAN_IF=$(ip route | grep default | awk '{print $5}' | head -n1)

# =====================================================
# ENABLE IP FORWARDING (SAFE)
# =====================================================
grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || \
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

sysctl -p

# =====================================================
# GENERATE SERVER KEYS (ONLY ONCE)
# =====================================================
if [ ! -f "$WG_DIR/server_private.key" ]; then
  wg genkey | tee "$WG_DIR/server_private.key" | wg pubkey > "$WG_DIR/server_public.key"
fi

SERVER_PRIV=$(cat "$WG_DIR/server_private.key")
SERVER_PUB=$(cat "$WG_DIR/server_public.key")

# =====================================================
# GENERATE CLIENT KEYS (STATIC 1 VPS = 1 CLIENT)
# =====================================================
if [ ! -f "$WG_DIR/client_private.key" ]; then
  wg genkey | tee "$WG_DIR/client_private.key" | wg pubkey > "$WG_DIR/client_public.key"
fi

CLIENT_PRIV=$(cat "$WG_DIR/client_private.key")
CLIENT_PUB=$(cat "$WG_DIR/client_public.key")

# =====================================================
# CREATE WIREGUARD SERVER CONFIG
# =====================================================
cat > "$WG_DIR/$WG_INTERFACE.conf" <<EOF
[Interface]
Address = $SERVER_WG_IP
ListenPort = $SERVER_PORT
PrivateKey = $SERVER_PRIV

PostUp = iptables -A FORWARD -i $WG_INTERFACE -j ACCEPT; iptables -t nat -A POSTROUTING -o $WAN_IF -j MASQUERADE
PostDown = iptables -D FORWARD -i $WG_INTERFACE -j ACCEPT; iptables -t nat -D POSTROUTING -o $WAN_IF -j MASQUERADE

[Peer]
PublicKey = $CLIENT_PUB
AllowedIPs = $CLIENT_IP
EOF

# =====================================================
# ENABLE SERVICE
# =====================================================
systemctl enable wg-quick@$WG_INTERFACE
systemctl restart wg-quick@$WG_INTERFACE

# =====================================================
# CLIENT CONFIG
# =====================================================
CLIENT_CONF="$CLIENT_DIR/$CLIENT_NAME.conf"

cat > "$CLIENT_CONF" <<EOF
[Interface]
PrivateKey = $CLIENT_PRIV
Address = $CLIENT_IP
DNS = $CLIENT_DNS

[Peer]
PublicKey = $SERVER_PUB
Endpoint = $SERVER_IP:$SERVER_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

# =====================================================
# OUTPUT
# =====================================================
echo ""
echo "=============================="
echo "VPN READY"
echo "SERVER IP: $SERVER_IP"
echo "CLIENT IP: $CLIENT_IP"
echo "=============================="
echo ""

qrencode -t ansiutf8 < "$CLIENT_CONF"

echo ""
echo "CONFIG FILE:"
echo "$CLIENT_CONF"
echo ""
echo "[DONE]"
