#!/bin/bash
# network-ovn-setup.sh - Complete network and OVN setup

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "$1"; }
info() { log "${BLUE}[INFO]${NC} $1"; }
success() { log "${GREEN}[SUCCESS]${NC} $1"; }
error() { log "${RED}[ERROR]${NC} $1"; }
warning() { log "${YELLOW}[WARNING]${NC} $1"; }

validate_ip() {
    [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && return 0 || return 1
}

get_octet() {
    echo "$1" | cut -d. -f4
}

detect_interface() {
    local iface
    iface=$(ip route | grep default | awk '{print $5}' | head -1)
    [[ -z "$iface" ]] && iface=$(ip link | grep -E '^[0-9]+:' | grep -v lo | awk -F: '{print $2}' | tr -d ' ' | head -1)
    echo "${iface:-eth0}"
}

print_banner() {
    clear
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║         NETWORK & OVN SETUP FOR CLOUD PROVIDER           ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
}

get_config() {
    print_banner
    
    # Node type
    echo "Select node type:"
    echo "  1. Controller (OVN Central)"
    echo "  2. Compute (OVN Host)"
    echo ""
    
    while true; do
        read -p "Enter choice [1/2]: " choice
        case $choice in
            1) NODE_TYPE="controller"; break ;;
            2) NODE_TYPE="compute"; break ;;
            *) echo "Invalid choice. Please enter 1 or 2." ;;
        esac
    done
    
    # Network info
    echo ""
    echo "Network Configuration:"
    echo "  VLAN 4003 (mgmt):    10.0.0.0/24"
    echo "  VLAN 4001 (internal): 10.0.1.0/24 ← OVN tunnels"
    echo "  VLAN 4002 (storage):  10.0.2.0/24 ← Storage"
    echo ""
    
    # Management IP
    while true; do
        read -p "Enter management IP [e.g., 10.0.0.10]: " MGMT_IP
        if validate_ip "$MGMT_IP"; then
            break
        else
            echo "Invalid IP format. Please try again."
        fi
    done
    
    # Controller IP for compute
    if [[ "$NODE_TYPE" == "compute" ]]; then
        while true; do
            read -p "Enter controller IP [e.g., 10.0.0.10]: " CONTROLLER_IP
            if validate_ip "$CONTROLLER_IP"; then
                break
            else
                echo "Invalid IP format. Please try again."
            fi
        done
    else
        CONTROLLER_IP="$MGMT_IP"
    fi
    
    # Network interface
    INTERFACE=$(detect_interface)
    read -p "Enter physical interface [$INTERFACE]: " input
    INTERFACE="${input:-$INTERFACE}"
    
    # Summary
    OCTET=$(get_octet "$MGMT_IP")
    
    echo ""
    echo "========================================================="
    echo "        CONFIGURATION SUMMARY"
    echo "========================================================="
    echo "Node Type:        $NODE_TYPE"
    echo "Management IP:    $MGMT_IP"
    echo "Interface:        $INTERFACE"
    [[ "$NODE_TYPE" == "compute" ]] && echo "Controller IP:    $CONTROLLER_IP"
    echo ""
    echo "VLAN Configuration:"
    echo "  mgmt (4003):    $MGMT_IP/24"
    echo "  internal (4001): 10.0.1.$OCTET/24"
    echo "  storage (4002):  10.0.2.$OCTET/24"
    [[ "$NODE_TYPE" == "controller" ]] && echo "  external (4000): Your public IPs"
    echo "========================================================="
    
    read -p "Proceed with setup? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || exit 0
}

install_packages() {
    info "Installing packages..."
    
    apt-get update
    
    if [[ "$NODE_TYPE" == "controller" ]]; then
        apt-get install -y openvswitch-switch openvswitch-common ovn-central ovn-host
    else
        apt-get install -y openvswitch-switch openvswitch-common ovn-host
    fi
    
    success "Packages installed"
}

configure_network() {
    info "Configuring network..."
    
    # Backup
    mkdir -p /etc/netplan/backup
    cp /etc/netplan/*.yaml /etc/netplan/backup/ 2>/dev/null || true
    
    # Create netplan config
    OCTET=$(get_octet "$MGMT_IP")
    
    if [[ "$NODE_TYPE" == "controller" ]]; then
        cat > /etc/netplan/00-cloud-provider.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $INTERFACE:
      dhcp4: no
      dhcp6: no
      
  vlans:
    mgmt:
      id: 4003
      link: $INTERFACE
      addresses: [$MGMT_IP/24]
      routes:
        - to: 0.0.0.0/0
          via: 10.0.0.1
      nameservers:
        addresses: [8.8.8.8, 1.1.1.1]
      
    external:
      id: 4000
      link: $INTERFACE
      addresses: []
      mtu: 1500
      
    internal:
      id: 4001
      link: $INTERFACE
      addresses: [10.0.1.$OCTET/24]
      mtu: 9000
      
    storage:
      id: 4002
      link: $INTERFACE
      addresses: [10.0.2.$OCTET/24]
      mtu: 9000
EOF
    else
        cat > /etc/netplan/00-cloud-provider.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $INTERFACE:
      dhcp4: no
      dhcp6: no
      
  vlans:
    mgmt:
      id: 4003
      link: $INTERFACE
      addresses: [$MGMT_IP/24]
      routes:
        - to: 0.0.0.0/0
          via: 10.0.0.1
      nameservers:
        addresses: [8.8.8.8, 1.1.1.1]
      
    internal:
      id: 4001
      link: $INTERFACE
      addresses: [10.0.1.$OCTET/24]
      mtu: 9000
      
    storage:
      id: 4002
      link: $INTERFACE
      addresses: [10.0.2.$OCTET/24]
      mtu: 9000
EOF
    fi
    
    # Apply
    netplan generate && netplan apply
    sleep 3
    success "Network configured"
}

configure_ovs() {
    info "Configuring OVS bridges..."
    
    # Clean up
    systemctl stop openvswitch-switch 2>/dev/null || true
    ovs-vsctl del-br br-int 2>/dev/null || true
    ovs-vsctl del-br br-ex 2>/dev/null || true
    
    # Start OVS
    systemctl start openvswitch-switch
    
    # Create bridges
    ovs-vsctl add-br br-int -- set Bridge br-int fail-mode=secure
    ovs-vsctl add-br br-ex -- set Bridge br-ex fail-mode=standalone
    
    # Configure external bridge for controller
    if [[ "$NODE_TYPE" == "controller" ]]; then
        ovs-vsctl add-port br-ex external \
            vlan_mode=trunk \
            trunks=4000 \
            -- set interface external type=internal
        ip link set external up
    fi
    
    # Patch ports
    ovs-vsctl add-port br-int patch-br-ex-to-int \
        -- set interface patch-br-ex-to-int type=patch \
        options:peer=patch-br-int-to-ex
    ovs-vsctl add-port br-ex patch-br-int-to-ex \
        -- set interface patch-br-int-to-ex type=patch \
        options:peer=patch-br-ex-to-int
    
    success "OVS bridges configured"
}

configure_ovn_controller() {
    info "Configuring OVN controller..."
    
    # Configure databases
    ovn-nbctl set-connection ptcp:6641:$MGMT_IP
    ovn-sbctl set-connection ptcp:6642:$MGMT_IP
    
    # Start northd
    systemctl start ovn-northd
    systemctl enable ovn-northd
    
    # Create initial networks
    ovn-nbctl ls-add external-net
    ovn-nbctl lsp-add external-net external-localnet
    ovn-nbctl lsp-set-type external-localnet localnet
    ovn-nbctl lsp-set-addresses external-localnet unknown
    ovn-nbctl lsp-set-options external-localnet network_name=external
    
    ovn-nbctl lr-add public-router
    
    success "OVN controller configured"
}

configure_ovn_host() {
    info "Configuring OVN host..."
    
    OCTET=$(get_octet "$MGMT_IP")
    TUNNEL_IP="10.0.1.$OCTET"
    
    # Configure OVS for OVN
    ovs-vsctl set open . external-ids:ovn-remote=tcp://$CONTROLLER_IP:6642
    ovs-vsctl set open . external-ids:ovn-encap-type=geneve
    ovs-vsctl set open . external-ids:ovn-encap-ip=$TUNNEL_IP
    ovs-vsctl set open . external-ids:system-id=$(hostname)
    ovs-vsctl set open . external-ids:hostname=$(hostname)
    
    # Start OVN controller
    systemctl start ovn-controller
    systemctl enable ovn-controller
    
    success "OVN host configured"
}

verify() {
    info "Verifying setup..."
    
    echo ""
    echo "=== NETWORK INTERFACES ==="
    for iface in mgmt internal storage; do
        [[ "$NODE_TYPE" == "controller" && "$iface" == "mgmt" ]] && iface="mgmt external internal storage"
        if ip link show $iface >/dev/null 2>&1; then
            echo "✓ $iface: UP"
        else
            echo "✗ $iface: MISSING"
        fi
    done
    
    echo ""
    echo "=== OVS BRIDGES ==="
    for br in br-int br-ex; do
        if ovs-vsctl br-exists $br; then
            echo "✓ $br: EXISTS"
        else
            echo "✗ $br: MISSING"
        fi
    done
    
    echo ""
    echo "=== OVN SERVICES ==="
    if [[ "$NODE_TYPE" == "controller" ]]; then
        if systemctl is-active ovn-northd >/dev/null 2>&1; then
            echo "✓ ovn-northd: RUNNING"
        else
            echo "✗ ovn-northd: STOPPED"
        fi
        
        if ovn-nbctl show >/dev/null 2>&1; then
            echo "✓ OVN NB: ACCESSIBLE"
        else
            echo "✗ OVN NB: INACCESSIBLE"
        fi
    else
        if systemctl is-active ovn-controller >/dev/null 2>&1; then
            echo "✓ ovn-controller: RUNNING"
        else
            echo "✗ ovn-controller: STOPPED"
        fi
        
        if ovs-vsctl get open . external-ids:ovn-remote | grep -q "$CONTROLLER_IP"; then
            echo "✓ Connected to controller: YES"
        else
            echo "✗ Connected to controller: NO"
        fi
    fi
    
    echo ""
    echo "=== CONNECTIVITY ==="
    if ping -c 2 -W 1 $MGMT_IP >/dev/null 2>&1; then
        echo "✓ Local: OK"
    else
        echo "✗ Local: FAILED"
    fi
    
    if [[ "$NODE_TYPE" == "compute" ]]; then
        if ping -c 2 -W 1 $CONTROLLER_IP >/dev/null 2>&1; then
            echo "✓ Controller: OK"
        else
            echo "✗ Controller: FAILED"
        fi
    fi
}

create_utilities() {
    info "Creating utility scripts..."
    
    # Status script
    cat > /usr/local/bin/network-status.sh <<'EOF'
#!/bin/bash
echo "=== NETWORK & OVN STATUS ==="
echo ""
echo "Hostname: $(hostname)"
echo "Management IP: $(ip -4 addr show mgmt 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo 'N/A')"
echo ""
echo "Network:"
ip -o addr show | grep -v lo
echo ""
echo "OVS:"
ovs-vsctl show
echo ""
echo "OVN:"
if systemctl is-active ovn-northd >/dev/null 2>&1; then
    ovn-nbctl show | head -10
elif systemctl is-active ovn-controller >/dev/null 2>&1; then
    echo "Connected to: $(ovs-vsctl get open . external-ids:ovn-remote)"
    echo "Tunnel IP: $(ovs-vsctl get open . external-ids:ovn-encap-ip)"
fi
EOF
    
    chmod +x /usr/local/bin/network-status.sh
    
    # Restart script
    cat > /usr/local/bin/network-restart.sh <<'EOF'
#!/bin/bash
echo "Restarting network services..."
systemctl restart openvswitch-switch
systemctl restart ovn-northd 2>/dev/null || systemctl restart ovn-controller 2>/dev/null
systemctl restart networking
echo "Done."
EOF
    
    chmod +x /usr/local/bin/network-restart.sh
    
    success "Utility scripts created"
}

main() {
    # Check root
    [[ $EUID -ne 0 ]] && { error "Must be run as root"; exit 1; }
    
    # Get configuration
    get_config
    
    # Install packages
    install_packages
    
    # Configure network
    configure_network
    
    # Configure OVS
    configure_ovs
    
    # Configure OVN
    if [[ "$NODE_TYPE" == "controller" ]]; then
        configure_ovn_controller
    else
        configure_ovn_host
    fi
    
    # Create utilities
    create_utilities
    
    # Verify
    verify
    
    # Completion message
    echo ""
    echo "========================================================="
    success "SETUP COMPLETED!"
    echo "========================================================="
    echo ""
    echo "Node Type: $NODE_TYPE"
    echo "Management IP: $MGMT_IP"
    echo "Interface: $INTERFACE"
    [[ "$NODE_TYPE" == "compute" ]] && echo "Controller: $CONTROLLER_IP"
    echo ""
    echo "Utilities:"
    echo "  network-status.sh  - Check status"
    echo "  network-restart.sh - Restart services"
    echo ""
}

# Run main with error handling
trap 'echo -e "\nSetup cancelled."; exit 1' INT
main "$@"