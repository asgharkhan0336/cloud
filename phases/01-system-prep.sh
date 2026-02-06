#!/bin/bash
# /opt/cloud-provider/phases/01-system-prep.sh

source "$(dirname "$0")/../lib/common.sh"

run_system_prep() {
    log_header "System Preparation"
    
    # Update package lists
    log_info "Updating package lists..."
    apt-get update
    
    # Upgrade system
    log_info "Upgrading system packages..."
    apt-get upgrade -y
    
    # Install common tools
    log_info "Installing common tools..."
    apt-get install -y \
        curl \
        wget \
        jq \
        git \
        vim \
        htop \
        tmux \
        ufw \
        fail2ban \
        chrony \
        prometheus-node-exporter \
        python3-pip \
        python3-venv
    
    # Configure firewall defaults
    log_info "Configuring firewall..."
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow from 10.0.0.0/24 to any port 22
    ufw --force enable
    
    # Configure SSH
    log_info "Hardening SSH..."
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config
    systemctl restart sshd
    
    # Configure NTP
    log_info "Configuring NTP..."
    cat > /etc/chrony/chrony.conf <<EOF
pool 0.ubuntu.pool.ntp.org iburst
pool 1.ubuntu.pool.ntp.org iburst
pool 2.ubuntu.pool.ntp.org iburst
pool 3.ubuntu.pool.ntp.org iburst
keyfile /etc/chrony/chrony.keys
driftfile /var/lib/chrony/chrony.drift
logdir /var/log/chrony
maxupdateskew 100.0
rtcsync
makestep 1 3
EOF
    systemctl restart chrony
    
    # Kernel optimizations
    log_info "Applying kernel optimizations..."
    cat >> /etc/sysctl.conf <<EOF
# Network optimization
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.core.netdev_max_backlog = 300000
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.ip_forward = 1

# VM optimization
vm.swappiness = 10
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.overcommit_memory = 1
EOF
    
    sysctl -p
    
    # Configure hugepages for better VM performance
    log_info "Configuring hugepages..."
    echo "vm.nr_hugepages = 1024" >> /etc/sysctl.conf
    sysctl -p
    
    log_success "System preparation completed"
}

# Main
load_config
run_system_prep