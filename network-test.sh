#!/bin/bash
# network-test.sh - Quick network and OVN test

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

run_test() {
    local name="$1"
    local cmd="$2"
    local invert="$3"
    
    echo -n "  Testing $name... "
    if eval "$cmd" >/dev/null 2>&1; then
        if [[ "$invert" == "invert" ]]; then
            echo -e "${RED}FAIL${NC}"
            return 1
        else
            echo -e "${GREEN}PASS${NC}"
            return 0
        fi
    else
        if [[ "$invert" == "invert" ]]; then
            echo -e "${GREEN}PASS${NC}"
            return 0
        else
            echo -e "${RED}FAIL${NC}"
            return 1
        fi
    fi
}

test_vlan_interfaces() {
    echo ""
    echo "1. VLAN Interfaces:"
    
    # Test mgmt VLAN
    run_test "mgmt VLAN (4003)" "ip link show mgmt"
    
    # Test internal VLAN
    run_test "internal VLAN (4001)" "ip link show internal"
    
    # Test storage VLAN
    run_test "storage VLAN (4002)" "ip link show storage"
    
    # Test external VLAN for controller
    if [[ "$NODE_TYPE" == "controller" ]]; then
        run_test "external VLAN (4000)" "ip link show external"
    fi
}

test_ovs_bridges() {
    echo ""
    echo "2. OVS Bridges:"
    
    run_test "br-int bridge" "ovs-vsctl br-exists br-int"
    run_test "br-ex bridge" "ovs-vsctl br-exists br-ex"
}

test_ovn_services() {
    echo ""
    echo "3. OVN Services:"
    
    if [[ "$NODE_TYPE" == "controller" ]]; then
        run_test "ovn-northd service" "systemctl is-active ovn-northd"
        run_test "OVN NB database" "ovn-nbctl show >/dev/null"
    else
        run_test "ovn-controller service" "systemctl is-active ovn-controller"
        run_test "OVN remote connection" "ovs-vsctl get open . external-ids:ovn-remote | grep -q tcp"
    fi
}

test_connectivity() {
    echo ""
    echo "4. Connectivity:"
    
    # Get management IP
    MGMT_IP=$(ip -4 addr show mgmt 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "")
    
    if [[ -n "$MGMT_IP" ]]; then
        run_test "local ping ($MGMT_IP)" "ping -c 1 -W 1 $MGMT_IP >/dev/null"
    fi
    
    # Controller connectivity for compute
    if [[ "$NODE_TYPE" == "compute" ]]; then
        CONTROLLER_IP=$(ovs-vsctl get open . external-ids:ovn-remote 2>/dev/null | grep -oP '\d+(\.\d+){3}' || echo "")
        if [[ -n "$CONTROLLER_IP" ]]; then
            run_test "controller ping ($CONTROLLER_IP)" "ping -c 1 -W 1 $CONTROLLER_IP >/dev/null"
            run_test "OVN port (6642)" "timeout 1 nc -zv $CONTROLLER_IP 6642 >/dev/null"
        fi
    fi
    
    # Internet
    run_test "internet (8.8.8.8)" "ping -c 1 -W 2 8.8.8.8 >/dev/null"
}

test_vlan_isolation() {
    echo ""
    echo "5. VLAN Isolation:"
    
    # Get IPs for each VLAN
    MGMT_IP=$(ip -4 addr show mgmt 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "")
    INTERNAL_IP=$(ip -4 addr show internal 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "")
    STORAGE_IP=$(ip -4 addr show storage 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "")
    
    if [[ -n "$MGMT_IP" && -n "$INTERNAL_IP" ]]; then
        run_test "mgmt → internal isolation" "ping -c 1 -W 1 -I $MGMT_IP $INTERNAL_IP >/dev/null" "invert"
    fi
    
    if [[ -n "$MGMT_IP" && -n "$STORAGE_IP" ]]; then
        run_test "mgmt → storage isolation" "ping -c 1 -W 1 -I $MGMT_IP $STORAGE_IP >/dev/null" "invert"
    fi
    
    if [[ -n "$INTERNAL_IP" && -n "$STORAGE_IP" ]]; then
        run_test "internal → storage isolation" "ping -c 1 -W 1 -I $INTERNAL_IP $STORAGE_IP >/dev/null" "invert"
    fi
}

test_ovn_tunnel() {
    if [[ "$NODE_TYPE" == "compute" ]]; then
        echo ""
        echo "6. OVN Tunnel:"
        
        run_test "tunnel interface" "ovs-vsctl list-ports br-int | grep -q geneve"
        run_test "tunnel configuration" "ovs-vsctl get open . external-ids:ovn-encap-type | grep -q geneve"
    fi
}

show_summary() {
    echo ""
    echo "="*60
    echo "TEST SUMMARY"
    echo "="*60
    
    echo ""
    echo "To view detailed information:"
    echo "  ip addr show              # Show all interfaces"
    echo "  ovs-vsctl show            # Show OVS configuration"
    
    if [[ "$NODE_TYPE" == "controller" ]]; then
        echo "  ovn-nbctl show           # Show OVN networks"
        echo "  ovn-sbctl show           # Show OVN chassis"
    else
        echo "  ovs-vsctl get open . external-ids  # Show OVN config"
    fi
    
    echo ""
    echo "Common issues:"
    echo "  1. VLANs not created:     Check /etc/netplan/"
    echo "  2. OVS bridges missing:   Restart openvswitch-switch"
    echo "  3. OVN services down:     Check systemctl status"
    echo "  4. No connectivity:       Check routes and firewall"
}

detect_node_type() {
    if systemctl is-active ovn-northd >/dev/null 2>&1; then
        NODE_TYPE="controller"
    else
        NODE_TYPE="compute"
    fi
}

main() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║         CLOUD PROVIDER NETWORK TEST                     ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
    
    # Detect node type
    detect_node_type
    echo "Detected node type: $NODE_TYPE"
    
    # Run tests
    test_vlan_interfaces
    test_ovs_bridges
    test_ovn_services
    test_connectivity
    test_vlan_isolation
    test_ovn_tunnel
    
    show_summary
}

# Run main
trap 'echo -e "\nTest interrupted."; exit 1' INT
main "$@"