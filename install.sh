#!/bin/bash

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (using sudo)"
  exit 1
fi

set -e

echo "Updating package list..."
apt-get update

echo "Installing wireguard, jq, qrencode, iptables-persistent, curl..."
DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard jq qrencode iptables-persistent curl

echo "Installing Xray..."
if [ -d /run/systemd/system ] || [ -f /sbin/init ]; then
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
else
    echo "WARNING: systemd not detected. Xray installation may fail or require manual service setup."
    echo "This is expected in Docker environments. On a real Ubuntu server, Xray will install and start automatically."
    # We still try to run it in case there's another way, but we've warned the user.
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install || true
fi

echo "Opening port 443 via iptables..."
iptables -I INPUT -p tcp --dport 443 -j ACCEPT
iptables -I INPUT -p udp --dport 443 -j ACCEPT

echo "Saving iptables rules..."
if command -v netfilter-persistent > /dev/null; then
    netfilter-persistent save
else
    # Fallback if netfilter-persistent is not available for some reason
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
fi

echo "Installation complete!"
