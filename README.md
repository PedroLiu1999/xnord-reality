# Xray Reality Config Generator

A simple, robust shell script to generate Xray Reality configurations with persistent credentials.

## Features

- **Automated Configuration**: Generates a complete `config.json` for Xray Reality.
- **Persistent Credentials**: UUID, Private/Public Keys, and ShortIDs are saved to `.xray.env` and reused across runs.
- **Docker Fallback**: If `xray` is not installed locally, the script automatically uses the official Xray Docker image (`ghcr.io/xtls/xray-core:latest`) to generate keys.
- **QR Code Support**: Displays a QR code for the VLESS share link if `qrencode` is installed.

## Prerequisites

- **Bash** (Standard on Linux/macOS)
- **Curl**
- **One of the following for Key Generation**:
    - `xray` binary in your PATH.
    - `docker` (script will pull and run the Xray image).
- **Optional**:
    - `qrencode` (for displaying QR codes in the terminal).

## Assumptions & System Requirements

This script makes the following assumptions about your environment:

1.  **Operating System**: Linux or macOS with a Bash shell environment.
2.  **Permissions**:
    - You have write access to the current directory to create `config.json` and `.xray.env`.
    - If using Docker fallback, your user has permission to run `docker` commands (e.g., is in the `docker` group) without `sudo`, or you run the script as root.
3.  **Network**:
    - You have an active internet connection for IP detection (`curl` to external services).
    - If using Docker fallback, you have network access to pull the `ghcr.io/xtls/xray-core:latest` image.
4.  **Configuration**:
    - The generated `config.json` assumes you will run the Xray server on the same machine.
    - **Port 443**: The default configuration listens on port 443. Ensure this port is available on your server or change it using the `PORT` variable.
    - **Firewall**: You must manually configure your firewall (UFW, iptables, AWS Security Groups, etc.) to allow inbound traffic on the configured port.
    - **Routing**: Traffic that doesn't match a specific blocking rule (e.g., private IPs) defaults to the first outbound, which is configured as `freedom` (direct access).

## Installation & Usage

**Quick Start (Run without downloading):**
```bash
bash <(curl -sL https://raw.githubusercontent.com/PedroLiu1999/xnord-reality/master/generate_config.sh)
```

**Manual Installation:**

1.  **Clone the repository** (or download the script):
    ```bash
    git clone https://github.com/PedroLiu1999/xnord-reality
    cd xnord-reality
    ```

2.  **Make the script executable**:
    ```bash
    chmod +x generate_config.sh
    ```

3.  **Run the generator**:
    ```bash
    ./generate_config.sh
    ```

4.  **Connect**:
    - Import the VLESS share link printed at the end of the output into your client (v2rayN, Nekoray, shadowrocket, etc.).
    - Or scan the QR code if available.

5.  **Activate Configuration** (Standard Installation):

    Move the generated file to your Xray configuration directory and restart the service.

    ```bash
    # Backup existing config
    sudo cp /usr/local/etc/xray/config.json /usr/local/etc/xray/config.json.bak
    
    # Move new config
    sudo mv config.json /usr/local/etc/xray/config.json
    
    # Restart Xray service
    sudo systemctl restart xray
    
    # Check status
    sudo systemctl status xray
    ```

## Configuration

You can customize the server settings by setting environment variables before running the script or by editing the `.xray.env` file.

**Supported Variables:**

| Variable | Default | Description |
| :--- | :--- | :--- |
| `PORT` | `443` | The listening port for the Xray server. |
| `SNI` | `www.microsoft.com` | The Server Name Indication (SNI) to mask traffic as. |
| `SERVER_NAME` | `microsoft.com` | Expected server name in Client Hello. |
| `IP` | *Auto-detected* | Manually override the public IP address in the share link. |
| `AUTO_DEPLOY` | `false` | Set to `true` to automatically move the config and restart Xray (requires sudo). |

**Example:**
```bash
PORT=8443 SNI=www.google.com ./generate_config.sh
```

### Auto-Deploy

You can skip the manual move/restart steps by running with `AUTO_DEPLOY=true` and `sudo`:

```bash
sudo AUTO_DEPLOY=true ./generate_config.sh
```

## Troubleshooting

- **"Local xray not found"**: The script will try to use Docker. Ensure Docker is installed and running if you don't have Xray locally.
- **"Permission denied"**: Make sure to `chmod +x generate_config.sh`.
- **Missing QR Code**: Install `qrencode` using your package manager:
    ```bash
    sudo apt install qrencode
    ```
