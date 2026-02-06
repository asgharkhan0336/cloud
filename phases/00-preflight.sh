#!/bin/bash
# /opt/cloud-provider/phases/00-preflight.sh

source "$(dirname "$0")/../lib/common.sh"

run_preflight() {
    log_header "Pre-flight Checks"
    
    # Check root privileges
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
    fi
    log_success "Running as root"
    
    # Check OS
    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot determine OS version"
    fi
    
    source /etc/os-release
    if [[ "$ID" != "ubuntu" ]]; then
        log_error "This script requires Ubuntu. Detected: $ID"
    fi
    
    if [[ "$VERSION_ID" != "22.04" ]]; then
        log_warning "This script is tested for Ubuntu 22.04 LTS. Detected: $VERSION_ID"
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    log_success "OS: Ubuntu $VERSION_ID"
    
    # Check CPU virtualization support
    if grep -q -E 'vmx|svm' /proc/cpuinfo; then
        log_success "CPU virtualization support detected"
    else
        log_warning "CPU virtualization support not detected (KVM may not work)"
    fi
    
    # Check memory
    local total_mem=$(free -g | awk '/^Mem:/{print $2}')
    if [[ "$NODE_TYPE" == "controller" && $total_mem -lt 4 ]]; then
        log_warning "Controller node should have at least 4GB RAM (detected: ${total_mem}GB)"
    elif [[ "$NODE_TYPE" == "compute" && $total_mem -lt 8 ]]; then
        log_warning "Compute node should have at least 8GB RAM (detected: ${total_mem}GB)"
    fi
    
    # Check disk space
    local free_space=$(df -h / | awk 'NR==2 {print $4}')
    log_info "Free disk space on /: $free_space"
    
    # Check network connectivity
    log_info "Testing network connectivity..."
    if ping -c 2 8.8.8.8 >/dev/null 2>&1; then
        log_success "Network connectivity OK"
    else
        log_warning "No internet connectivity detected"
    fi
    
    # Check for existing installation
    if systemctl is-active --quiet ovn-northd 2>/dev/null; then
        log_warning "OVN services detected - might be already installed"
    fi
    
    if systemctl is-active --quiet libvirtd 2>/dev/null; then
        log_warning "Libvirt detected - might be already installed"
    fi
    
    log_success "Pre-flight checks completed"
}

# Main
load_config
run_preflight