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

# Load existing env
# Capture CLI-provided variables before sourcing .env (so we can assert precedence and persist them)
CLI_NORD_KEY="$NORD_WG_PRIVATE_KEY"
CLI_NORD_COUNTRIES="$NORD_COUNTRIES"
CLI_AUTO_DEPLOY="$AUTO_DEPLOY"

if [ -f "$ENV_FILE" ]; then
    echo "Loading existing configuration from $ENV_FILE"
    source "$ENV_FILE"
fi

# Function to update or append variable in .env
update_env() {
    local key=$1
    local val=$2
    if grep -q "^${key}=" "$ENV_FILE"; then
        grep -v "^${key}=" "$ENV_FILE" > "$ENV_FILE.tmp" && mv -f "$ENV_FILE.tmp" "$ENV_FILE"
    fi
    echo "${key}=${val}" >> "$ENV_FILE"
}

# If CLI provided variables, overwrite and persist them
if [ -n "$CLI_NORD_KEY" ]; then
    NORD_WG_PRIVATE_KEY="$CLI_NORD_KEY"
    update_env "NORD_WG_PRIVATE_KEY" "$NORD_WG_PRIVATE_KEY"
fi

if [ -n "$CLI_NORD_COUNTRIES" ]; then
    NORD_COUNTRIES="$CLI_NORD_COUNTRIES"
    update_env "NORD_COUNTRIES" "$NORD_COUNTRIES"
fi

if [ -n "$CLI_AUTO_DEPLOY" ]; then
    AUTO_DEPLOY="$CLI_AUTO_DEPLOY"
    update_env "AUTO_DEPLOY" "$AUTO_DEPLOY"
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
# NordVPN Integration Logic
OUTBOUNDS_JSON=""
ROUTING_RULES_JSON=""

if [ -n "$NORD_WG_PRIVATE_KEY" ] && [ -n "$NORD_COUNTRIES" ]; then
    echo "NordVPN Integration Enabled."
    echo "Fetching country list..."
    COUNTRIES_JSON=$(curl -s "https://api.nordvpn.com/v1/countries")

    IFS=',' read -ra COUNTRY_CODES <<< "$NORD_COUNTRIES"
    
    # Initialize JSON arrays if they are empty
    OUTBOUNDS_JSON=""
    ROUTING_RULES_JSON=""
    VALID_NORD_COUNTRIES=()

    for CODE in "${COUNTRY_CODES[@]}"; do
        # Trim whitespace
        CODE=$(echo "$CODE" | xargs)
        echo "Processing country: $CODE"
        
        # Find Country ID (case-insensitive search)
        COUNTRY_ID=$(echo "$COUNTRIES_JSON" | jq -r --arg CODE "$CODE" '.[] | select(.code == $CODE) | .id')
        
        if [ -z "$COUNTRY_ID" ] || [ "$COUNTRY_ID" == "null" ]; then
            echo "Warning: Country code $CODE not found. Skipping."
            continue
        fi
        
        echo "  Country ID: $COUNTRY_ID. Fetching best WireGuard server..."
        
        # Fetch best server: technology 35 (WireGuard), filter by country, limit 1 to sort by load locally
        # API response is {"servers": [...]}, so we need to access .servers first
        SERVER_JSON=$(curl -s "https://api.nordvpn.com/v2/servers?limit=1&filters\[servers_technologies\]\[id\]=35&filters\[country_id\]=$COUNTRY_ID" | jq '.servers | sort_by(.load) | .[0]')
        
        if [ -z "$SERVER_JSON" ] || [ "$SERVER_JSON" == "null" ]; then
             echo "  No servers found for $CODE. Skipping."
             continue
        fi

        HOSTNAME=$(echo "$SERVER_JSON" | jq -r '.hostname')
        STATION=$(echo "$SERVER_JSON" | jq -r '.station')
        # Extract Public Key from technologies metadata
        PUB_KEY=$(echo "$SERVER_JSON" | jq -r '.technologies[] | select(.id == 35) | .metadata[] | select(.name == "public_key") | .value')
        
        if [ -z "$PUB_KEY" ] || [ "$PUB_KEY" == "null" ]; then
             echo "  Could not extract public key for $HOSTNAME. Skipping."
             continue
        fi

        echo "  Selected: $HOSTNAME ($STATION) - Load: $(echo "$SERVER_JSON" | jq -r '.load')%"

        # Add to valid list
        VALID_NORD_COUNTRIES+=("$CODE")

        # Generate unique tag and client ID for this country
        TAG="nord-$CODE"
        CLIENT_ID=$(uuidgen) # Generate a specific UUID for this routing path? Or reuse main UUID with email? 
        # Let's use a specific email mapping in the main inbound for simplicity
        
        # Append to Outbounds
        # Append to Outbounds
        # Note: endpoint is station IP : 51820 (default WG port)
        
        OUTBOUND_JSON=$(cat <<EOF
    {
      "tag": "$TAG",
      "protocol": "wireguard",
      "settings": {
        "secretKey": "$NORD_WG_PRIVATE_KEY",
        "address": ["10.5.0.2/32"],
        "peers": [
          {
            "publicKey": "$PUB_KEY",
            "endpoint": "$STATION:51820"
          }
        ]
      }
    },
EOF
)
        OUTBOUNDS_JSON="${OUTBOUNDS_JSON}${OUTBOUND_JSON}"

        # Append to Routing Rules
        # Append to Routing Rules
        # Map a specific user email to this tag.
        # User email format: nord-CODE (e.g., "nord-US", "nord-DE")
        RULE_JSON=$(cat <<EOF
      {
        "type": "field",
        "user": [
          "nord-$CODE"
        ],
        "outboundTag": "$TAG"
      },
EOF
)
        ROUTING_RULES_JSON="${ROUTING_RULES_JSON}${RULE_JSON}"
        
        echo "  Added outbound $TAG and routing rule for user 'nord-$CODE'"
        
        echo "  Added outbound $TAG and routing rule for user 'nord-$CODE'"
        
    done
fi

# Generate config.json (Modified to include dynamic parts)
echo "Generating $CONFIG_FILE..."

# Build Inbound Clients JSON
# Default client
CLIENTS_JSON=$(cat <<EOF
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision",
            "email": "default"
          }
EOF
)

# Add clients for VALID Nord countries
if [ ${#VALID_NORD_COUNTRIES[@]} -gt 0 ]; then
    for CODE in "${VALID_NORD_COUNTRIES[@]}"; do
        # Generate a dedicated UUID for each country alias to ensure unique routing matching.
        
        # Load or Generate UUID for this country
        VAR_NAME="UUID_NORD_${CODE}"
        # Read from .xray.env if exists (loaded earlier)
        EXISTING_ID=${!VAR_NAME}
        
        if [ -z "$EXISTING_ID" ]; then
            if command -v uuidgen &> /dev/null; then
               NEW_ID=$(uuidgen)
            else
               NEW_ID=$($XRAY_CMD uuid)
            fi
            echo "$VAR_NAME=$NEW_ID" >> "$ENV_FILE"
            EXISTING_ID=$NEW_ID
        fi
        
        # Export variable for later use (Fix for empty UUID in printing loop)
        export "$VAR_NAME"="$EXISTING_ID"
        
        CLIENT_JSON=$(cat <<EOF
,
          {
            "id": "$EXISTING_ID",
            "flow": "xtls-rprx-vision",
            "email": "nord-$CODE"
          }
EOF
)
        CLIENTS_JSON="${CLIENTS_JSON}${CLIENT_JSON}"
        
        # Store for printing links later
        declare "LINK_${CODE}=vless://$EXISTING_ID@$IP:$PORT?security=reality&encryption=none&pbk=$PUBLIC_KEY&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=$SNI&sid=$SHORT_ID#Nord-${CODE}"
    done
fi

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
$CLIENTS_JSON
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
    },
${OUTBOUNDS_JSON}
    {
       "protocol": "freedom",
       "tag": "fallback-freedom" 
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
${ROUTING_RULES_JSON}
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

# Construct VLESS Share Links
# Main Link
LINK="vless://$UUID@$IP:$PORT?security=reality&encryption=none&pbk=$PUBLIC_KEY&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=$SNI&sid=$SHORT_ID#Reality-Direct"


# Determine IP Address (Moved up)
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
echo "========================================"
echo "VLESS Share Links"
echo "========================================"
echo ""

# Function to print link and QR
print_link() {
    local LABEL=$1
    local LINK=$2
    echo "$LABEL:"
    echo "$LINK"
    if command -v qrencode &> /dev/null; then
        echo "QR Code:"
        echo "$LINK" | qrencode -t ANSIUTF8
    fi
    echo "----------------------------------------"
}

# 1. Main Direct Link
# Recalculate main link with detected IP
LINK="vless://$UUID@$IP:$PORT?security=reality&encryption=none&pbk=$PUBLIC_KEY&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=$SNI&sid=$SHORT_ID#Reality-Direct"
print_link "Reality Direct (No VPN)" "$LINK"

# 2. NordVPN Links
if [ ${#VALID_NORD_COUNTRIES[@]} -gt 0 ]; then
    for CODE in "${VALID_NORD_COUNTRIES[@]}"; do
        # Reconstruct variable name for link
        VAR_NAME="LINK_${CODE}"
        LINK_VAL=${!VAR_NAME}
        if [ -n "$LINK_VAL" ]; then
             # Populate IP address
             LINK_VAL="${LINK_VAL//$IP_ADDRESS/$IP}"
             VAR_UUID="UUID_NORD_${CODE}"
             UUID_VAL=${!VAR_UUID}
             LINK_VAL="vless://$UUID_VAL@$IP:$PORT?security=reality&encryption=none&pbk=$PUBLIC_KEY&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=$SNI&sid=$SHORT_ID#Nord-${CODE}"
             
             print_link "NordVPN - $CODE" "$LINK_VAL"
        fi
    done
fi

if ! command -v qrencode &> /dev/null; then
    echo "Tip: Install 'qrencode' to see QR codes (sudo apt install qrencode)."
fi
echo ""
