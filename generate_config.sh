#!/bin/bash

# Configuration
ENV_FILE=".xray.env"
CONFIG_FILE="config.json"
XRAY_IMAGE="ghcr.io/xtls/xray-core:latest"

# Detect Xray command
if command -v xray &> /dev/null; then
    echo "Using local xray binary."
    XRAY_CMD="xray"
else
    echo "Local xray not found. Using Docker image: $XRAY_IMAGE"
    if ! command -v docker &> /dev/null; then
        echo "Error: Neither xray binary nor docker found. Please install one of them."
        exit 1
    fi
    # Pull image if not present (optional, but good practice)
    # docker pull "$XRAY_IMAGE" > /dev/null
    XRAY_CMD="docker run --rm --entrypoint xray $XRAY_IMAGE"
fi

# Load existing environment variables
if [ -f "$ENV_FILE" ]; then
    echo "Loading existing configuration from $ENV_FILE"
    source "$ENV_FILE"
fi

# Generate missing variables
UPDATED=false

if [ -z "$UUID" ]; then
    echo "Generating new UUID..."
    # Try using uuidgen if available, otherwise fallback to xray
    if command -v uuidgen &> /dev/null; then
        UUID=$(uuidgen)
    else
        UUID=$($XRAY_CMD uuid)
    fi
    UPDATED=true
fi

if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    echo "Generating new X25519 key pair..."
    KEYS=$($XRAY_CMD x25519)
    # Output format involves "PrivateKey:" and "Password:" (which is the Public Key for Reality)
    PRIVATE_KEY=$(echo "$KEYS" | grep "PrivateKey:" | awk '{print $2}')
    PUBLIC_KEY=$(echo "$KEYS" | grep "Password:" | awk '{print $2}')
    
    if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
        echo "Error: Failed to generate/parse specific keys. Output was:"
        echo "$KEYS"
        exit 1
    fi
    UPDATED=true
fi

if [ -z "$SHORT_ID" ]; then
    echo "Generating new Short ID..."
    SHORT_ID=$(openssl rand -hex 4)
    UPDATED=true
fi

# Set defaults for optional variables
PORT=${PORT:-443}
SNI=${SNI:-www.microsoft.com}
SERVER_NAME=${SERVER_NAME:-microsoft.com} 

# Save to environment file if updated
if [ "$UPDATED" = true ]; then
    echo "Saving new configuration to $ENV_FILE..."
    cat > "$ENV_FILE" <<EOF
UUID=$UUID
PRIVATE_KEY=$PRIVATE_KEY
PUBLIC_KEY=$PUBLIC_KEY
SHORT_ID=$SHORT_ID
PORT=$PORT
SNI=$SNI
SERVER_NAME=$SERVER_NAME
EOF
fi

echo "Configuration:"
echo "UUID: $UUID"
echo "Public Key: $PUBLIC_KEY"
echo "Short ID: $SHORT_ID"
echo "Port: $PORT"
echo "SNI: $SNI"
echo "----------------------------------------"

# Generate config.json
echo "Generating $CONFIG_FILE..."
cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$SNI:443",
          "xver": 0,
          "serverNames": [
            "$SNI",
            "$SERVER_NAME"
          ],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": [
            "$SHORT_ID"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "blocked"
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "ip": [
          "geoip:private"
        ],
        "outboundTag": "blocked"
      }
    ]
  }
}
EOF

echo "$CONFIG_FILE generated successfully."

# Construct VLESS Share Link
# Format: vless://UUID@IP:PORT?security=reality&encryption=none&pbk=PUBLIC_KEY&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=SNI&sid=SHORT_ID#REMARKS
# Note: IP is autodetection or manual input. Using "YOUR_IP" as placeholder.
# Determine IP Address
# 1. Check if IP is set in environment (e.g. from .xray.env)
if [ -z "$IP" ]; then
    echo "Detecting IP address..."
    # 2. Try external services
    IP=$(curl -s --max-time 3 ifconfig.me || curl -s --max-time 3 icanhazip.com || curl -s --max-time 3 api.ipify.org)
    
    # 3. Fallback to local IP if external fails or returns empty
    if [ -z "$IP" ]; then
        echo "Warning: Could not detect external IP. Using local IP."
        IP=$(hostname -I | awk '{print $1}')
    fi

    # 4. Final fallback
    if [ -z "$IP" ]; then
        IP="YOUR_IP"
    fi
fi
echo "Detected IP: $IP"

LINK="vless://$UUID@$IP:$PORT?security=reality&encryption=none&pbk=$PUBLIC_KEY&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=$SNI&sid=$SHORT_ID#Reality-Server"

# Auto Deploy Feature
if [ "$AUTO_DEPLOY" = "true" ]; then
    echo "----------------------------------------"
    echo "Auto Deploy Enabled"
    TARGET_DIR="/usr/local/etc/xray"
    TARGET_FILE="$TARGET_DIR/config.json"

    # Check for root/sudo
    if [ "$EUID" -ne 0 ]; then
        echo "Error: Auto deploy requires root privileges. Please run with sudo."
        echo "Try: sudo AUTO_DEPLOY=true ./generate_config.sh"
    else
        echo "Deploying to $TARGET_FILE..."
        
        # Ensure directory exists
        if [ ! -d "$TARGET_DIR" ]; then
            echo "Creating directory $TARGET_DIR..."
            mkdir -p "$TARGET_DIR"
        fi

        # Backup existing config
        if [ -f "$TARGET_FILE" ]; then
            echo "Backing up existing config to $TARGET_FILE.bak..."
            cp "$TARGET_FILE" "$TARGET_FILE.bak"
        fi

        # Move new config
        echo "Installing new config..."
        cp "$CONFIG_FILE" "$TARGET_FILE"

        # Restart Service
        echo "Restarting Xray service..."
        if systemctl restart xray; then
             echo "Xray service restarted successfully."
             systemctl status xray --no-pager
        else
             echo "Error: Failed to restart Xray service. Check logs."
        fi
    fi
     echo "----------------------------------------"
fi

echo ""
echo "VLESS Share Link (Import this to your client):"
echo "$LINK"
echo ""

# Generate QR Code if qrencode is available
if command -v qrencode &> /dev/null; then
    echo "QR Code:"
    echo "$LINK" | qrencode -t ANSIUTF8
else
    echo "Tip: Install 'qrencode' to see a QR code here (sudo apt install qrencode)."
fi
echo ""
