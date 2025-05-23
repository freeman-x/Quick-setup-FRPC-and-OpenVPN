#!/bin/bash

# Script version
SCRIPT_VERSION="1.2.1"

echo "Multi-Platform OpenVPN and FRPC Installation Script - Version $SCRIPT_VERSION"

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root"
  exit 1
fi

# Detect system architecture
ARCH=$(uname -m)
echo "Detected system architecture: $ARCH"

# Determine package manager
if command -v apt-get > /dev/null; then
  PKG_MANAGER="apt-get"
  PKG_INSTALL="install -y"
  PKG_UPDATE="update -qq"
elif command -v yum > /dev/null; then
  PKG_MANAGER="yum"
  PKG_INSTALL="install -y"
  PKG_UPDATE="makecache fast"
elif command -v dnf > /dev/null; then
  PKG_MANAGER="dnf"
  PKG_INSTALL="install -y"
  PKG_UPDATE="makecache fast"
else
  echo "Unsupported package manager. Please install manually."
  exit 1
fi

# Get the current user's home directory
USER_HOME=$(eval echo ~${SUDO_USER})
if [ -z "$USER_HOME" ]; then
  echo "Error: Cannot determine the user's home directory."
  exit 1
fi

# Device hostname
HOSTNAME=$(hostname)

# Function to generate a random passphrase (16 characters)
generate_passphrase() {
  head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16 ; echo ''
}

# Collect FRPS server information from user
read -p "Enter the FRPS server IP: " FRPS_SERVER_IP
while [[ -z "$FRPS_SERVER_IP" ]]; do
  echo "FRPS server IP cannot be empty."
  read -p "Enter the FRPS server IP: " FRPS_SERVER_IP
done

read -p "Enter the FRPS token: " FRPS_TOKEN
while [[ -z "$FRPS_TOKEN" ]]; do
  echo "FRPS token cannot be empty."
  read -p "Enter the FRPS token: " FRPS_TOKEN
done

read -p "Enter the FRPC remote port (default is 6000): " FRPC_REMOTE_PORT
FRPC_REMOTE_PORT=${FRPC_REMOTE_PORT:-6000}

# Ask for protocol type
read -p "Enter the protocol type (tcp/udp, default is tcp): " FRPC_PROTOCOL
FRPC_PROTOCOL=${FRPC_PROTOCOL:-tcp}
if [[ "$FRPC_PROTOCOL" != "tcp" && "$FRPC_PROTOCOL" != "udp" ]]; then
  echo "Invalid protocol type. Defaulting to tcp."
  FRPC_PROTOCOL="tcp"
fi

# Generate random VPN password
VPN_PASSWORD=$(generate_passphrase)

# Configuration file name
CLIENT_CONF_NAME="${HOSTNAME}_${VPN_PASSWORD}.ovpn"
CLIENT_OVPN_FILE="$USER_HOME/$CLIENT_CONF_NAME"

# Clear all existing OpenVPN, EasyRSA, and FRPC configurations
echo "Clearing all existing OpenVPN, EasyRSA, and FRPC configurations..."
systemctl stop openvpn@server
systemctl disable openvpn@server
systemctl stop frpc
systemctl disable frpc
rm -rf $USER_HOME/openvpn-ca /etc/openvpn/* $USER_HOME/frp /etc/systemd/system/frpc.service $CLIENT_OVPN_FILE
echo "Cleared all configurations."

# Update system and install required packages
echo "Updating system packages..."
$PKG_MANAGER $PKG_UPDATE > /dev/null
$PKG_MANAGER $PKG_INSTALL easy-rsa openvpn iptables-persistent wget tar > /dev/null
echo "System update complete."

# Install EasyRSA
echo "Setting up EasyRSA..."
mkdir -p $USER_HOME/openvpn-ca
cp -r /usr/share/easy-rsa/* $USER_HOME/openvpn-ca

# Initialize EasyRSA PKI
cd $USER_HOME/openvpn-ca
./easyrsa init-pki

# Generate CA certificate
PASS=$(generate_passphrase)
COMMON_NAME="${HOSTNAME}_$(openssl rand -hex 4)"

echo "Generating CA certificate..."
echo -e "$PASS\n$PASS" | $USER_HOME/openvpn-ca/easyrsa --batch build-ca nopass > /dev/null

# Generate server certificate and key
echo "Generating server certificate and key..."
echo -e "$PASS\n$PASS" | $USER_HOME/openvpn-ca/easyrsa gen-req $COMMON_NAME nopass > /dev/null
echo -e "$PASS\n$PASS" | $USER_HOME/openvpn-ca/easyrsa --batch sign-req server $COMMON_NAME > /dev/null

# Generate Diffie-Hellman parameters
echo "Generating Diffie-Hellman parameters..."
$USER_HOME/openvpn-ca/easyrsa gen-dh > /dev/null

# Generate client certificate and key
CLIENT_COMMON_NAME="${HOSTNAME}_$(openssl rand -hex 4)"
echo "Generating client certificate and key..."
echo -e "$PASS\n$PASS" | $USER_HOME/openvpn-ca/easyrsa gen-req $CLIENT_COMMON_NAME nopass > /dev/null
echo -e "$PASS\n$PASS" | $USER_HOME/openvpn-ca/easyrsa --batch sign-req client $CLIENT_COMMON_NAME > /dev/null

# Check if certificates are generated successfully
if [ ! -f "$USER_HOME/openvpn-ca/pki/issued/$CLIENT_COMMON_NAME.crt" ]; then
  echo "Error: $CLIENT_COMMON_NAME.crt not found."
  exit 1
fi
if [ ! -f "$USER_HOME/openvpn-ca/pki/private/$CLIENT_COMMON_NAME.key" ]; then
  echo "Error: $CLIENT_COMMON_NAME.key not found."
  exit 1
fi

# Copy certificates and keys to OpenVPN directory
echo "Copying certificates and keys to OpenVPN directory..."
cp $USER_HOME/openvpn-ca/pki/ca.crt /etc/openvpn/
cp $USER_HOME/openvpn-ca/pki/issued/$COMMON_NAME.crt /etc/openvpn/server.crt
cp $USER_HOME/openvpn-ca/pki/private/$COMMON_NAME.key /etc/openvpn/server.key
cp $USER_HOME/openvpn-ca/pki/dh.pem /etc/openvpn/
cp $USER_HOME/openvpn-ca/pki/issued/$CLIENT_COMMON_NAME.crt /etc/openvpn/client1.crt
cp $USER_HOME/openvpn-ca/pki/private/$CLIENT_COMMON_NAME.key /etc/openvpn/client1.key
echo "Certificates and keys copied."

# Create OpenVPN server configuration file
echo "Creating OpenVPN server configuration file..."
cat > /etc/openvpn/server.conf <<EOF
# Port that OpenVPN server will listen on
port 1194
# Use $FRPC_PROTOCOL protocol
proto $FRPC_PROTOCOL
# Use TUN device (virtual tunnel interface)
dev tun

# Certificate Settings
ca ca.crt
cert server.crt
key server.key
dh dh.pem

# IP address range and subnet mask to assign to VPN clients
server 10.8.0.0 255.255.255.0
# Maintain client IP address persistence
ifconfig-pool-persist ipp.txt

# Redirect all client traffic through VPN
push "redirect-gateway def1 bypass-dhcp"

# Push DNS server to clients
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 8.8.4.4"

# Enable client-to-client communication
client-to-client

push "route 10.8.0.0 255.255.255.0"

# Keep connection: ping every 10 seconds, disconnect after 120 seconds of no response
keepalive 10 120

cipher AES-256-CBC
user nobody
group nogroup
persist-key
persist-tun

# Log configuration
status /var/log/openvpn-status.log
log-append /var/log/openvpn.log
verb 3

# Add auth-user-pass-verify script
script-security 3
auth-user-pass-verify /etc/openvpn/checkpsw.sh via-env
EOF

# Create checkpsw.sh script for password verification
echo "Creating password verification script..."
cat > /etc/openvpn/checkpsw.sh <<EOF
#!/bin/bash

VPNUSER="openvpn"
VPNPASS="$VPN_PASSWORD"

if [[ "\$username" == "\$VPNUSER" && "\$password" == "\$VPNPASS" ]]; then
  exit 0
else
  exit 1
fi
EOF

# Set permissions for checkpsw.sh
chmod +x /etc/openvpn/checkpsw.sh

# Start and enable OpenVPN service
echo "Starting and enabling OpenVPN service..."
systemctl start openvpn@server
systemctl enable openvpn@server
systemctl status openvpn@server --no-pager

# Generate OpenVPN client configuration file
echo "Generating OpenVPN client configuration file..."
cat > $CLIENT_OVPN_FILE <<EOF
client
dev tun
proto $FRPC_PROTOCOL
remote $FRPS_SERVER_IP $FRPC_REMOTE_PORT
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
auth-user-pass
cipher AES-256-CBC
verb 3

<ca>
$(cat /etc/openvpn/ca.crt)
</ca>

<cert>
$(cat /etc/openvpn/client1.crt)
</cert>

<key>
$(cat /etc/openvpn/client1.key)
</key>
EOF

# Define download URL and file path for FRPC based on architecture
case "$ARCH" in
  x86_64)
    FRPC_ARCH="linux_amd64"
    ;;
  armv7l)
    FRPC_ARCH="linux_arm"
    ;;
  aarch64)
    FRPC_ARCH="linux_arm64"
    ;;
  *)
    echo "Unsupported architecture: $ARCH"
    exit 1
    ;;
esac

FRPC_VERSION="0.51.3"
FRPC_DOWNLOAD_URL="https://github.com/fatedier/frp/releases/download/v$FRPC_VERSION/frp_${FRPC_VERSION}_${FRPC_ARCH}.tar.gz"
FRPC_TAR_FILE="$USER_HOME/frp_${FRPC_VERSION}_${FRPC_ARCH}.tar.gz"
FRPC_DIR="$USER_HOME/frp_${FRPC_VERSION}_${FRPC_ARCH}"

# Download and install FRPC
echo "Downloading and installing FRPC..."
wget $FRPC_DOWNLOAD_URL -O $FRPC_TAR_FILE

# Check if download was successful
if [ $? -ne 0 ]; then
  echo "Error: Failed to download FRPC from $FRPC_DOWNLOAD_URL"
  exit 1
fi

# Extract the file
tar -zxvf $FRPC_TAR_FILE -C $USER_HOME
if [ $? -ne 0 ]; then
  echo "Error: Failed to extract FRPC tar file."
  exit 1
fi

# Move FRPC and set permissions
if [ -f "$FRPC_DIR/frpc" ]; then
  mv $FRPC_DIR/frpc /usr/local/bin/
  chmod +x /usr/local/bin/frpc
else
  echo "Error: FRPC binary not found after extraction."
  exit 1
fi

# Create FRPC configuration file
echo "Creating FRPC configuration file..."
cat > /etc/frpc.ini <<EOF
[common]
server_addr = $FRPS_SERVER_IP
server_port = 7000
token = $FRPS_TOKEN

[OpenVPN-$HOSTNAME]
type = $FRPC_PROTOCOL
local_ip = 127.0.0.1
local_port = 1194
remote_port = $FRPC_REMOTE_PORT
EOF

# Create FRPC systemd service file
echo "Creating FRPC systemd service file..."
cat > /etc/systemd/system/frpc.service <<EOF
[Unit]
Description=FRPC Client Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/frpc -c /etc/frpc.ini
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

# Start and enable FRPC service
echo "Starting and enabling FRPC service..."
systemctl daemon-reload
systemctl start frpc
systemctl enable frpc
systemctl status frpc --no-pager

# Open OpenVPN port in firewall
echo "Opening OpenVPN port in firewall..."
if command -v ufw > /dev/null; then
  ufw allow 1194/$FRPC_PROTOCOL
  ufw reload
elif command -v firewall-cmd > /dev/null; then
  firewall-cmd --permanent --add-port=1194/$FRPC_PROTOCOL
  firewall-cmd --reload
else
  echo "No compatible firewall management tool found. Please open port 1194 manually."
fi

# Function to start a simple HTTP server
start_http_server() {
  local port=$1
  echo "Starting a simple HTTP server on port $port..."
  python3 -m http.server $port --directory $USER_HOME > /dev/null 2>&1 &
  HTTP_SERVER_PID=$!
}

# Function to stop the HTTP server
stop_http_server() {
  if [ -n "$HTTP_SERVER_PID" ]; then
    echo "Stopping the HTTP server..."
    kill $HTTP_SERVER_PID
  fi
}

# Check if port 8000 is free
if lsof -Pi :8000 -sTCP:LISTEN -t >/dev/null ; then
  echo "Port 8000 is already in use. Please free the port and re-run the script."
  exit 1
fi

# Start HTTP server on port 8000
start_http_server 8000

# Generate download link for OpenVPN client configuration file
CLIENT_DOWNLOAD_URL="http://$(hostname -I | awk '{print $1}'):8000/$CLIENT_CONF_NAME"

# Print generated password information
echo -e "\n\033[1;32mOpenVPN client connection information:\033[0m"
echo -e "Username: \033[1;34mopenvpn\033[0m"
echo -e "Password: \033[1;34m$VPN_PASSWORD\033[0m"

# Print client configuration file path and download link
echo "OpenVPN client configuration file path: $CLIENT_OVPN_FILE"
echo -e "Download link: \033[1;34m$CLIENT_DOWNLOAD_URL\033[0m"

# Prompt user to press any key to exit and stop HTTP server
read -p "Press any key to exit and stop HTTP server..." -n 1 -s
stop_http_server
