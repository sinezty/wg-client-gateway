#!/bin/bash

# =============================================================================
# WireGuard Client Gateway Setup Script
# Support: Debian 11/12/13, Ubuntu 20.04/22.04/24.04+, Raspbian, DietPi
# Purpose: Turn a local device into a WireGuard VPN gateway for the entire LAN.
# =============================================================================

# --- ERROR HANDLING ---
rollback() {
    local step=$1
    warn "Rollback starting... Step: $step"
    
    case "$step" in
        "wireguard")
            systemctl stop wg-quick@wg0 2>/dev/null || true
            systemctl disable wg-quick@wg0 2>/dev/null || true
            ;;
        "network")
            if [[ -f "$DHCPCD_BACKUP" ]]; then
                mv "$DHCPCD_BACKUP" /etc/dhcpcd.conf 2>/dev/null || true
                warn "dhcpcd.conf restored from backup."
            fi
            if [[ -f "$NETPLAN_BACKUP" ]]; then
                mv "$NETPLAN_BACKUP" "$NETPLAN_FILE" 2>/dev/null || true
                warn "Netplan config restored from backup."
            fi
            ;;
        *)
            warn "Undefined rollback step: $step"
            ;;
    esac
}

handle_error() {
    local exit_code=$?
    error_noexit "Error occurred: Line $1, Exit code: $exit_code"
    exit $exit_code
}

trap 'handle_error $LINENO' ERR

# --- COLORS AND LOGGING ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
LOG_FILE="/var/log/wg_client_setup.log"

log() { echo -e "${BLUE}[$(date +%T)]${NC} $1" | tee -a "$LOG_FILE"; }
success() { echo -e "${GREEN}[OK]${NC} $1" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"; trap - ERR; exit 1; }
error_noexit() { echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"; }

# --- 1. PREREQUISITE CHECKS ---
echo -e "${CYAN}===================================================="
echo -e "   WIREGUARD CLIENT GATEWAY INSTALLER"
echo -e "====================================================${NC}"

if [[ $EUID -ne 0 ]]; then
   error "This script must be run with root privileges!"
fi

# PATH correction (for minimal systems)
export PATH=$PATH:/sbin:/usr/sbin:/usr/local/sbin:/usr/local/bin:/usr/bin:/bin

# --- SYSTEM STATE CHECK ---
log "Checking system state..."

# Check existing WireGuard configuration
EXISTING_WG_CONFIG=""
if [[ -d /etc/wireguard ]]; then
    EXISTING_WG_CONFIG="$(find /etc/wireguard -maxdepth 1 -name '*.conf' -print -quit 2>/dev/null)"
fi
if [[ -n "$EXISTING_WG_CONFIG" ]]; then
    warn "Existing WireGuard configuration found: $EXISTING_WG_CONFIG"
    echo -e "  ${YELLOW}Re-running this script will overwrite the current config.${NC}"
    read -p "Continue with fresh setup? (y/n) [y]: " WG_OVERWRITE
    WG_OVERWRITE=${WG_OVERWRITE:-y}
    if [[ "$WG_OVERWRITE" != "y" && "$WG_OVERWRITE" != "Y" ]]; then
        error "User cancelled."
    fi
    log "Re-run mode: cleaning previous installation..."
fi

# Stop and clean existing WireGuard service
if systemctl is-active --quiet wg-quick@wg0; then
    warn "Stopping running WireGuard service..."
    systemctl stop wg-quick@wg0 >> "$LOG_FILE" 2>&1 || true
fi
if systemctl is-enabled --quiet wg-quick@wg0 2>/dev/null; then
    systemctl disable wg-quick@wg0 >> "$LOG_FILE" 2>&1 || true
fi

# Clean existing gateway iptables rules (safe for re-runs)
iptables -D FORWARD -i wg0 -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -o wg0 -j ACCEPT 2>/dev/null || true
iptables -t nat -D POSTROUTING -o wg0 -j MASQUERADE 2>/dev/null || true

# --- 2. NETWORK DETECTION ---
log "Detecting network configuration..."

NET_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
if [[ -z "$NET_INTERFACE" ]]; then
    NET_INTERFACE=$(ip link show | grep -v "lo:" | grep "state UP" | grep -o "^[0-9]*: [^:]*" | head -n1 | cut -d: -f2 | tr -d ' ')
    if [[ -z "$NET_INTERFACE" ]]; then
        error "Network interface not found. Please configure manually."
    fi
fi
log "Network interface: $NET_INTERFACE"

# Get current IP info
CURRENT_IP=$(ip -4 addr show "$NET_INTERFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
CURRENT_CIDR=$(ip -4 addr show "$NET_INTERFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -n1)
CURRENT_SUBNET=$(echo "$CURRENT_CIDR" | grep -oP '/\d+')
CURRENT_GATEWAY=$(ip route | grep default | awk '{print $3}' | head -n1)

if [[ -z "$CURRENT_IP" ]]; then
    error "Could not detect current IP address on $NET_INTERFACE."
fi

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}Current Network Configuration${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  Interface : ${GREEN}$NET_INTERFACE${NC}"
echo -e "  IP Address: ${GREEN}$CURRENT_IP${CURRENT_SUBNET}${NC}"
echo -e "  Gateway   : ${GREEN}$CURRENT_GATEWAY${NC}"
echo ""

# --- 3. STATIC IP CONFIGURATION ---
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}Static IP Configuration${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  Gateway devices require a static IP address."
echo -e "  1) Keep current IP (${GREEN}$CURRENT_IP${NC}) and make it static"
echo -e "  2) Enter a new static IP"
read -p "Selection [1]: " IP_CHOICE
IP_CHOICE=${IP_CHOICE:-1}

if [[ "$IP_CHOICE" == "2" ]]; then
    read -p "New static IP address (e.g. 192.168.1.100): " STATIC_IP
    read -p "Subnet mask CIDR (e.g. /24) [$CURRENT_SUBNET]: " STATIC_SUBNET
    STATIC_SUBNET=${STATIC_SUBNET:-$CURRENT_SUBNET}
    read -p "Gateway [$CURRENT_GATEWAY]: " STATIC_GW
    STATIC_GW=${STATIC_GW:-$CURRENT_GATEWAY}
    
    if [[ -z "$STATIC_IP" ]]; then
        error "IP address cannot be empty."
    fi
else
    STATIC_IP="$CURRENT_IP"
    STATIC_SUBNET="$CURRENT_SUBNET"
    STATIC_GW="$CURRENT_GATEWAY"
fi

log "Static IP: $STATIC_IP$STATIC_SUBNET, Gateway: $STATIC_GW"

# DNS for the gateway device itself
read -p "DNS for this device [1.1.1.1]: " DEVICE_DNS
DEVICE_DNS=${DEVICE_DNS:-1.1.1.1}

# Detect init system and apply static IP
DHCPCD_BACKUP=""
NETPLAN_BACKUP=""

if [[ -f /etc/dhcpcd.conf ]]; then
    # Raspbian / DietPi style
    log "Configuring static IP via dhcpcd.conf..."
    DHCPCD_BACKUP="/etc/dhcpcd.conf.backup.$(date +%s)"
    cp /etc/dhcpcd.conf "$DHCPCD_BACKUP"
    log "dhcpcd.conf backup: $DHCPCD_BACKUP"
    
    # Remove existing static config for this interface (supports re-run)
    sed -i '/^# WG-GATEWAY-START/,/^# WG-GATEWAY-END/d' /etc/dhcpcd.conf 2>/dev/null || true
    sed -i "/^interface $NET_INTERFACE/,/^interface\|^$/d" /etc/dhcpcd.conf 2>/dev/null || true
    
    cat >> /etc/dhcpcd.conf <<EOF

# WG-GATEWAY-START
interface $NET_INTERFACE
static ip_address=$STATIC_IP$STATIC_SUBNET
static routers=$STATIC_GW
static domain_name_servers=$DEVICE_DNS
# WG-GATEWAY-END
EOF
    success "Static IP configured in dhcpcd.conf"

elif command -v netplan &>/dev/null; then
    # Ubuntu / Netplan style
    log "Configuring static IP via netplan..."
    NETPLAN_FILE=$(find /etc/netplan -name '*.yaml' -print -quit 2>/dev/null)
    
    if [[ -z "$NETPLAN_FILE" ]]; then
        NETPLAN_FILE="/etc/netplan/01-wg-gateway.yaml"
    else
        NETPLAN_BACKUP="${NETPLAN_FILE}.backup.$(date +%s)"
        cp "$NETPLAN_FILE" "$NETPLAN_BACKUP"
        log "Netplan backup: $NETPLAN_BACKUP"
    fi
    
    cat > "$NETPLAN_FILE" <<EOF
network:
  version: 2
  ethernets:
    $NET_INTERFACE:
      dhcp4: no
      addresses:
        - $STATIC_IP$STATIC_SUBNET
      routes:
        - to: default
          via: $STATIC_GW
      nameservers:
        addresses:
          - $DEVICE_DNS
EOF
    netplan apply >> "$LOG_FILE" 2>&1 || warn "Netplan apply failed, will take effect after reboot."
    success "Static IP configured via netplan"

elif [[ -f /etc/network/interfaces ]]; then
    # Classic Debian interfaces
    log "Configuring static IP via /etc/network/interfaces..."
    cp /etc/network/interfaces "/etc/network/interfaces.backup.$(date +%s)"
    
    # Convert CIDR to netmask
    case "$STATIC_SUBNET" in
        /24) NETMASK="255.255.255.0" ;;
        /16) NETMASK="255.255.0.0" ;;
        /8)  NETMASK="255.0.0.0" ;;
        *)   NETMASK="255.255.255.0" ;;
    esac
    
    cat > /etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

auto $NET_INTERFACE
iface $NET_INTERFACE inet static
    address $STATIC_IP
    netmask $NETMASK
    gateway $STATIC_GW
    dns-nameservers $DEVICE_DNS
EOF
    success "Static IP configured in /etc/network/interfaces"
else
    warn "Could not detect network configuration method."
    warn "Please configure static IP manually after installation."
fi

# --- 4. CLIENT CONFIG ---
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}WireGuard Client Configuration${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  You need the ${GREEN}client.conf${NC} file from your WireGuard server."
echo -e "  (generated by wg-secure-gateway / install.sh)"
echo ""

# Auto-detect common locations
AUTO_CONF=""
for check_path in ~/client.conf /tmp/client.conf /root/client.conf; do
    if [[ -f "$check_path" ]]; then
        AUTO_CONF="$check_path"
        break
    fi
done

if [[ -n "$AUTO_CONF" ]]; then
    echo -e "  ${GREEN}✓ Found:${NC} $AUTO_CONF"
    echo ""
    echo -e "  1) ${GREEN}Use${NC} $AUTO_CONF"
    echo -e "  2) ${GREEN}Open editor${NC} — paste config into nano"
    echo -e "  3) ${GREEN}Other file${NC} — specify a different path"
    read -p "Selection [1]: " CONF_METHOD
    CONF_METHOD=${CONF_METHOD:-1}
else
    echo -e "  1) ${GREEN}Open editor${NC} — paste config into nano"
    echo -e "  2) ${GREEN}File path${NC} — I already copied it to this device"
    read -p "Selection [1]: " CONF_METHOD
    CONF_METHOD=${CONF_METHOD:-1}
    # Remap: no auto-detect, so 1=editor, 2=path
    if [[ "$CONF_METHOD" == "1" ]]; then
        CONF_METHOD="editor"
    else
        CONF_METHOD="3"
    fi
fi

case "$CONF_METHOD" in
    1)
        # Use auto-detected file
        CLIENT_CONF_PATH="$AUTO_CONF"
        success "Using: $CLIENT_CONF_PATH"
        ;;
    2|editor)
        # Editor mode — open nano with temp file
        CLIENT_CONF_PATH="/tmp/client_pasted.conf"
        > "$CLIENT_CONF_PATH"
        
        echo ""
        echo -e "${YELLOW}nano will open now. Paste your client.conf content,${NC}"
        echo -e "${YELLOW}then save with: Ctrl+O → Enter → Ctrl+X${NC}"
        read -p "Press Enter to open editor..."
        
        nano "$CLIENT_CONF_PATH"
        
        if [[ ! -s "$CLIENT_CONF_PATH" ]]; then
            error "File is empty. Please try again."
        fi
        
        success "Config received ($(wc -l < "$CLIENT_CONF_PATH") lines)"
        ;;
    3)
        # File path mode
        echo ""
        read -p "client.conf path: " CLIENT_CONF_PATH
        
        # Expand ~ if used
        CLIENT_CONF_PATH="${CLIENT_CONF_PATH/#\~/$HOME}"
        
        if [[ ! -f "$CLIENT_CONF_PATH" ]]; then
            error "File not found: $CLIENT_CONF_PATH"
        fi
        ;;
    *)
        error "Invalid selection."
        ;;
esac

# Validate config format
if ! grep -q "\[Interface\]" "$CLIENT_CONF_PATH" || ! grep -q "\[Peer\]" "$CLIENT_CONF_PATH"; then
    error "Invalid WireGuard config: Missing [Interface] or [Peer] section."
fi

if ! grep -q "PrivateKey" "$CLIENT_CONF_PATH"; then
    error "Invalid WireGuard config: Missing PrivateKey."
fi

success "Client config validated ✓"

# Check AllowedIPs for gateway mode
if ! grep -qE 'AllowedIPs\s*=.*0\.0\.0\.0/0' "$CLIENT_CONF_PATH"; then
    warn "AllowedIPs does not contain 0.0.0.0/0"
    warn "Gateway mode requires all traffic to be routed through the VPN tunnel."
    read -p "Fix AllowedIPs to 0.0.0.0/0 automatically? (y/n) [y]: " FIX_ALLOWED
    FIX_ALLOWED=${FIX_ALLOWED:-y}
    if [[ "$FIX_ALLOWED" != "y" && "$FIX_ALLOWED" != "Y" ]]; then
        warn "Continuing without fixing AllowedIPs. Gateway may not route all traffic!"
    else
        FIX_ALLOWED_IPS=true
        log "AllowedIPs will be set to 0.0.0.0/0"
    fi
else
    log "AllowedIPs contains 0.0.0.0/0 — full tunnel confirmed."
fi

# --- 5. PACKAGE INSTALLATION ---
log "Preparing system packages..."

RETRY_COUNT=0
MAX_RETRIES=3
while [[ $RETRY_COUNT -lt $MAX_RETRIES ]]; do
    log "Fetching package lists... (attempt: $(($RETRY_COUNT + 1))/$MAX_RETRIES)"
    if apt-get update -y >> "$LOG_FILE" 2>&1; then
        log "Package lists updated successfully."
        break
    else
        RETRY_COUNT=$((RETRY_COUNT + 1))
        if [[ $RETRY_COUNT -lt $MAX_RETRIES ]]; then
            warn "Failed to fetch package lists, retrying..."
            sleep 5
        else
            error "Could not update package lists. Please check your internet connection."
        fi
    fi
done

PACKAGES="wireguard wireguard-tools openresolv iptables iproute2 procps iptables-persistent"

log "Installing required packages..."
MISSING_PACKAGES=""
for pkg in $PACKAGES; do
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
        MISSING_PACKAGES="$MISSING_PACKAGES $pkg"
    fi
done

if [[ -n "$MISSING_PACKAGES" ]]; then
    log "Missing packages:$MISSING_PACKAGES"
    # Pre-answer iptables-persistent prompts
    echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections 2>/dev/null || true
    echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections 2>/dev/null || true
    
    if ! apt-get install -y $MISSING_PACKAGES --no-install-recommends >> "$LOG_FILE" 2>&1; then
        warn "Some packages failed, retrying with --fix-missing..."
        apt-get install -f -y --no-install-recommends >> "$LOG_FILE" 2>&1 || true
        apt-get install -y $MISSING_PACKAGES --no-install-recommends >> "$LOG_FILE" 2>&1 || \
            warn "Some packages could not be installed but continuing..."
    fi
else
    log "All required packages already installed."
fi

# Verify critical packages
for pkg in wireguard wireguard-tools; do
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
        error "$pkg is required but could not be installed."
    fi
done

# --- 6. WIREGUARD CONFIGURATION ---
log "Setting up WireGuard client gateway..."

WG_DIR="/etc/wireguard"
mkdir -p "$WG_DIR" && chmod 700 "$WG_DIR"

# Extract client WireGuard IP for reference
CLIENT_WG_IP=$(grep -oP 'Address\s*=\s*\K[^\s]+' "$CLIENT_CONF_PATH" | head -n1)
log "WireGuard client IP: $CLIENT_WG_IP"

# Build wg0.conf: PostUp/PostDown must be in [Interface] section (before [Peer])
# wg-quick only processes these directives when they are in [Interface]
log "Building gateway config (PostUp/PostDown in [Interface] section)..."

# Gateway NAT rules
GW_POSTUP="PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o %i -j MASQUERADE"
GW_POSTDOWN="PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o %i -j MASQUERADE"

# Remove any existing PostUp/PostDown from client config (to avoid conflicts)
if grep -qE '^\s*(PostUp|PostDown)\s*=' "$CLIENT_CONF_PATH"; then
    warn "Existing PostUp/PostDown found in client.conf — replacing with gateway rules."
fi

# Process client.conf: insert our PostUp/PostDown before [Peer], strip originals
{
    IN_INTERFACE=false
    PEER_FOUND=false
    while IFS= read -r line; do
        # Skip existing PostUp/PostDown lines
        if [[ "$line" =~ ^[[:space:]]*(PostUp|PostDown)[[:space:]]*= ]]; then
            continue
        fi
        
        # When we hit [Peer], inject our gateway rules first
        if [[ "$line" =~ ^\[Peer\] ]] && [[ "$PEER_FOUND" == "false" ]]; then
            # Insert gateway NAT rules before [Peer]
            echo "# Gateway NAT rules (added by install.sh)"
            echo "$GW_POSTUP"
            echo "$GW_POSTDOWN"
            echo ""
            PEER_FOUND=true
        fi
        
        # Fix AllowedIPs if requested
        if [[ "${FIX_ALLOWED_IPS:-}" == "true" ]] && [[ "$line" =~ ^[[:space:]]*AllowedIPs[[:space:]]*= ]]; then
            echo "AllowedIPs = 0.0.0.0/0"
            continue
        fi
        
        echo "$line"
    done < "$CLIENT_CONF_PATH"
    
    # If no [Peer] was found (unusual), append rules at the end
    if [[ "$PEER_FOUND" == "false" ]]; then
        echo ""
        echo "# Gateway NAT rules (added by install.sh)"
        echo "$GW_POSTUP"
        echo "$GW_POSTDOWN"
    fi
} > "$WG_DIR/wg0.conf"

chmod 600 "$WG_DIR/wg0.conf"
success "WireGuard config written to $WG_DIR/wg0.conf"

# --- 7. IP FORWARDING ---
log "Enabling IP forwarding..."

cat > /etc/sysctl.d/99-wg-gateway.conf <<EOF
net.ipv4.ip_forward = 1
EOF
sysctl -p /etc/sysctl.d/99-wg-gateway.conf >> "$LOG_FILE" 2>&1 || true
success "IP forwarding enabled"

# --- 8. IPTABLES PERSISTENT RULES ---
log "Saving iptables rules..."

# Save current rules so they persist after reboot
if command -v netfilter-persistent &>/dev/null; then
    netfilter-persistent save >> "$LOG_FILE" 2>&1 || true
    log "iptables rules saved via netfilter-persistent"
fi

# --- 9. START WIREGUARD SERVICE ---
log "Starting WireGuard service..."

if wg-quick strip wg0 > /dev/null 2>&1; then
    systemctl enable wg-quick@wg0 >> "$LOG_FILE" 2>&1
    
    if systemctl start wg-quick@wg0 2>> "$LOG_FILE"; then
        success "WireGuard service started"
    else
        warn "WireGuard could not be started."
        echo -e "${RED}--- journalctl output ---${NC}"
        journalctl -u wg-quick@wg0 --no-pager -n 15 2>/dev/null || true
        echo -e "${RED}-------------------------${NC}"
    fi
else
    warn "WireGuard config validation failed. Check $WG_DIR/wg0.conf"
fi

# --- 10. CONNECTION VERIFICATION ---
log "Verifying VPN connection..."
sleep 3

WG_STATUS=$(wg show wg0 2>/dev/null || true)
if [[ -n "$WG_STATUS" ]]; then
    success "WireGuard tunnel is UP"
    
    # Check if traffic goes through VPN
    VPN_IP=$(curl -s -4 --connect-timeout 10 ifconfig.me 2>/dev/null || true)
    LOCAL_GW_IP="$STATIC_IP"
    
    if [[ -n "$VPN_IP" ]]; then
        log "Traffic exits from: $VPN_IP"
    fi
else
    warn "WireGuard tunnel could not be verified. Try manually: wg-quick up wg0"
fi

# --- 11. INSTALLATION SUMMARY ---
NOTES_FILE="/root/gateway_notes.txt"

cat > "$NOTES_FILE" <<EOF
==================================================
WIREGUARD CLIENT GATEWAY REPORT ($(date))
==================================================

[GATEWAY INFORMATION]
Device IP : $STATIC_IP$STATIC_SUBNET
Interface : $NET_INTERFACE
Gateway   : $STATIC_GW

[WIREGUARD TUNNEL]
Config    : $WG_DIR/wg0.conf
Client IP : $CLIENT_WG_IP
Status    : $(systemctl is-active wg-quick@wg0 2>/dev/null || echo "unknown")

[HOW TO USE]
To route a device's traffic through this VPN gateway:
  1. Set the device's default gateway to: $STATIC_IP
  2. Set DNS to: $DEVICE_DNS
  3. All traffic will now flow through the VPN tunnel.

Example (Linux client):
  sudo ip route replace default via $STATIC_IP

Example (Windows):
  Network Settings > IPv4 > Gateway: $STATIC_IP

[LOG FILE]
$LOG_FILE

==================================================
EOF

# Disable error trap before final output
trap - ERR

echo ""
echo -e "${GREEN}========================================${NC}"
success "Gateway installation completed!"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}Gateway Summary${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  Gateway IP     : ${GREEN}$STATIC_IP${NC}"
echo -e "  WireGuard IP   : ${GREEN}$CLIENT_WG_IP${NC}"
echo -e "  VPN Exit IP    : ${GREEN}${VPN_IP:-N/A}${NC}"
echo -e "  WG Service     : ${GREEN}$(systemctl is-active wg-quick@wg0 2>/dev/null || echo 'unknown')${NC}"
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}How to use this gateway:${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  Set any device's default gateway to: ${GREEN}$STATIC_IP${NC}"
echo -e "  Set DNS to: ${GREEN}$DEVICE_DNS${NC}"
echo -e "  All traffic will route through the VPN tunnel."
echo ""
warn "Notes saved: $NOTES_FILE"
echo ""

# Reboot prompt
read -p "Reboot now to apply all network changes? (y/n) [y]: " REBOOT_FINAL
REBOOT_FINAL=${REBOOT_FINAL:-y}

if [[ "$REBOOT_FINAL" == "y" || "$REBOOT_FINAL" == "Y" ]]; then
    log "Rebooting system..."
    sleep 2
    reboot
else
    warn "Please reboot manually for static IP changes to take full effect."
    success "WireGuard gateway is active!"
fi
