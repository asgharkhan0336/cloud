#!/bin/bash
# /opt/cloud-provider/phases/02-network.sh

source "$(dirname "$0")/../lib/common.sh"

run_network_config() {
    log_header "Network Configuration"
    
    # Backup existing netplan config
    if ls /etc/netplan/*.yaml 1>/dev/null 2>&1; then
        local backup_dir="/etc/netplan/backup-$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$backup_dir"
        cp /etc/netplan/*.yaml "$backup_dir/"
        log_info "Backed up existing netplan config to $backup_dir"
    fi
    
    # Create netplan configuration based on node type
    case "$NODE_TYPE" in
        "controller")
            create_controller_network
            ;;
        "compute")
            create_compute_network
            ;;
        "storage")
            create_storage_network
            ;;
        "combined")
            create_combined_network
            ;;
    esac
    
    # Apply network configuration
    log_info "Applying network configuration..."
    netplan generate
    netplan apply
    
    # Wait for network to settle
    sleep 5
    
    # Verify configuration
    verify_network
}

create_controller_network() {
    log_info "Creating controller network configuration..."
    
    cat > /etc/netplan/00-cloud-provider.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $PHYSICAL_INTERFACE:
      dhcp4: no
      dhcp6: no
      
  vlans:
    mgmt:
      id: 4003
      link: $PHYSICAL_INTERFACE
      addresses: [$MGMT_IP/24]
      routes:
        - to: 0.0.0.0/0
          via: 10.0.0.1
      nameservers:
        addresses: [8.8.8.8, 1.1.1.1]
      
    external:
      id: 4000
      link: $PHYSICAL_INTERFACE
      addresses: []
      mtu: 1500
      
    internal:
      id: 4001
      link: $PHYSICAL_INTERFACE
      addresses: [$INTERNAL_IP/24]
      mtu: 9000
      
    storage:
      id: 4002
      link: $PHYSICAL_INTERFACE
      addresses: [$STORAGE_IP/24]
      mtu: 9000
EOF
}

create_compute_network() {
    log_info "Creating compute network configuration..."
    
    cat > /etc/netplan/00-cloud-provider.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $PHYSICAL_INTERFACE:
      dhcp4: no
      dhcp6: no
      
  vlans:
    mgmt:
      id: 4003
      link: $PHYSICAL_INTERFACE
      addresses: [$MGMT_IP/24]
      routes:
        - to: 0.0.0.0/0
          via: 10.0.0.1
      nameservers:
        addresses: [8.8.8.8, 1.1.1.1]
      
    internal:
      id: 4001
      link: $PHYSICAL_INTERFACE
      addresses: [$INTERNAL_IP/24]
      mtu: 9000
      
    storage:
      id: 4002
      link: $PHYSICAL_INTERFACE
      addresses: [$STORAGE_IP/24]
      mtu: 9000
EOF
}

create_storage_network() {
    log_info "Creating storage network configuration..."
    
    cat > /etc/netplan/00-cloud-provider.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $PHYSICAL_INTERFACE:
      dhcp4: no
      dhcp6: no
      
  vlans:
    mgmt:
      id: 4003
      link: $PHYSICAL_INTERFACE
      addresses: [$MGMT_IP/24]
      routes:
        - to: 0.0.0.0/0
          via: 10.0.0.1
      nameservers:
        addresses: [8.8.8.8, 1.1.1.1]
      
    storage:
      id: 4002
      link: $PHYSICAL_INTERFACE
      addresses: [$STORAGE_IP/24]
      mtu: 9000
EOF
}

create_combined_network() {
    log_info "Creating combined node network configuration..."
    
    cat > /etc/netplan/00-cloud-provider.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $PHYSICAL_INTERFACE:
      dhcp4: no
      dhcp6: no
      
  vlans:
    mgmt:
      id: 4003
      link: $PHYSICAL_INTERFACE
      addresses: [$MGMT_IP/24]
      routes:
        - to: 0.0.0.0/0
          via: 10.0.0.1
      nameservers:
        addresses: [8.8.8.8, 1.1.1.1]
      
    external:
      id: 4000
      link: $PHYSICAL_INTERFACE
      addresses: []
      mtu: 1500
      
    internal:
      id: 4001
      link: $PHYSICAL_INTERFACE
      addresses: [$INTERNAL_IP/24]
      mtu: 9000
      
    storage:
      id: 4002
      link: $PHYSICAL_INTERFACE
      addresses: [$STORAGE_IP/24]
      mtu: 9000
EOF
}

verify_network() {
    log_info "Verifying network configuration..."
    
    # Check VLAN interfaces
    local interfaces=""
    case "$NODE_TYPE" in
        "controller"|"combined") interfaces="mgmt external internal storage" ;;
        "compute") interfaces="mgmt internal storage" ;;
        "storage") interfaces="mgmt storage" ;;
    esac
    
    for intf in $interfaces; do
        if ip link show "$intf" >/dev/null 2>&1; then
            log_success "Interface $intf is up"
        else
            log_error "Interface $intf is not up"
        fi
    done
    
    # Check IP assignments
    if ip addr show mgmt | grep -q "$MGMT_IP"; then
        log_success "Management IP configured correctly"
    else
        log_error "Management IP not configured correctly"
    fi
    
    # Test connectivity
    if ping -c 2 8.8.8.8 >/dev/null 2>&1; then
        log_success "Internet connectivity OK"
    else
        log_warning "No internet connectivity"
    fi
    
    log_success "Network configuration completed"
}

# Main
load_config
run_network_config