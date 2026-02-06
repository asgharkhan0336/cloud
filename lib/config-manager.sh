#!/bin/bash
# /opt/cloud-provider/lib/config-manager.sh

source "$(dirname "$0")/common.sh"

collect_configuration() {
    log_header "Cloud Provider Node Configuration"
    
    # Node type selection
    echo ""
    echo "Select node type:"
    echo "1) Controller (OVN Central, API, Monitoring)"
    echo "2) Compute (KVM, OVN Host, VM Hosting)"
    echo "3) Storage (Ceph, Object/Block Storage)"
    echo "4) Combined (Controller + Compute)"
    echo ""
    
    while true; do
        read -p "Enter choice [1-4]: " node_choice
        case $node_choice in
            1) NODE_TYPE="controller"; break ;;
            2) NODE_TYPE="compute"; break ;;
            3) NODE_TYPE="storage"; break ;;
            4) NODE_TYPE="combined"; break ;;
            *) echo "Invalid choice. Please enter 1-4." ;;
        esac
    done
    
    # Network configuration
    echo ""
    echo "Network Configuration:"
    echo "VLAN 4003 (mgmt): 10.0.0.0/24"
    echo "VLAN 4001 (internal): 10.0.1.0/24"
    echo "VLAN 4002 (storage): 10.0.2.0/24"
    echo ""
    
    MGMT_IP=$(get_input "Enter management IP address (VLAN 4003)" "" "validate_ip")
    
    # Calculate derived IPs
    IFS='.' read -r i1 i2 i3 i4 <<< "$MGMT_IP"
    INTERNAL_IP="10.0.1.$i4"
    STORAGE_IP="10.0.2.$i4"
    
    # Controller IP for compute/storage nodes
    if [[ "$NODE_TYPE" == "compute" || "$NODE_TYPE" == "storage" ]]; then
        CONTROLLER_IP=$(get_input "Enter controller node IP address" "10.0.0.10" "validate_ip")
    else
        CONTROLLER_IP="$MGMT_IP"
    fi
    
    # Physical interface
    DETECTED_INTERFACE=$(detect_interface)
    PHYSICAL_INTERFACE=$(get_input "Enter physical network interface" "$DETECTED_INTERFACE")
    
    # Public IP block (for controller/combined)
    if [[ "$NODE_TYPE" == "controller" || "$NODE_TYPE" == "combined" ]]; then
        echo ""
        echo "Public IP Configuration:"
        PUBLIC_IP_BLOCK=$(get_input "Enter public IP block (CIDR)" "203.0.113.0/24" "validate_cidr")
        PUBLIC_GATEWAY=$(get_input "Enter public gateway IP" "203.0.113.254" "validate_ip")
    fi
    
    # Storage configuration
    if [[ "$NODE_TYPE" == "storage" || "$NODE_TYPE" == "combined" ]]; then
        echo ""
        echo "Storage Configuration:"
        CEPH_NETWORK=$(get_input "Enter Ceph cluster network" "10.0.2.0/24" "validate_cidr")
        CEPH_PUBLIC_NETWORK=$(get_input "Enter Ceph public network" "10.0.2.0/24" "validate_cidr")
        
        echo ""
        echo "Available disks:"
        lsblk -d -o NAME,SIZE,TYPE,MODEL | grep -v "sda\|vda\|loop\|rom"
        
        CEPH_DISKS=$(get_input "Enter disk names for Ceph (comma-separated, e.g., sdb,sdc)" "")
    fi
    
    # Show summary
    show_config_summary
}

show_config_summary() {
    log_header "Configuration Summary"
    
    echo "┌──────────────────────────────────────┐"
    echo "│        Configuration Summary         │"
    echo "├──────────────────────────────────────┤"
    echo "│ Node Type:        $(printf "%-20s" "$NODE_TYPE") │"
    echo "│ Management IP:    $(printf "%-20s" "$MGMT_IP") │"
    echo "│ Internal IP:      $(printf "%-20s" "$INTERNAL_IP") │"
    echo "│ Storage IP:       $(printf "%-20s" "$STORAGE_IP") │"
    echo "│ Physical Intf:    $(printf "%-20s" "$PHYSICAL_INTERFACE") │"
    
    if [[ "$NODE_TYPE" == "compute" || "$NODE_TYPE" == "storage" ]]; then
        echo "│ Controller IP:    $(printf "%-20s" "$CONTROLLER_IP") │"
    fi
    
    if [[ "$NODE_TYPE" == "controller" || "$NODE_TYPE" == "combined" ]]; then
        echo "│ Public IP Block:  $(printf "%-20s" "$PUBLIC_IP_BLOCK") │"
        echo "│ Public Gateway:   $(printf "%-20s" "$PUBLIC_GATEWAY") │"
    fi
    
    if [[ "$NODE_TYPE" == "storage" || "$NODE_TYPE" == "combined" ]]; then
        echo "│ Ceph Network:     $(printf "%-20s" "$CEPH_NETWORK") │"
        echo "│ Ceph Disks:       $(printf "%-20s" "$CEPH_DISKS") │"
    fi
    echo "└──────────────────────────────────────┘"
    
    echo ""
    read -p "Proceed with installation? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Installation cancelled"
        exit 0
    fi
    
    save_config
}