#!/bin/bash
# /opt/cloud-provider/phases/07-verification.sh

source "$(dirname "$0")/../lib/common.sh"

run_verification() {
    log_header "Installation Verification"
    
    verify_system
    verify_network
    verify_services
    verify_functionality
    generate_report
}

verify_system() {
    log_info "Verifying system configuration..."
    
    # Check kernel version
    local kernel=$(uname -r)
    log_info "Kernel version: $kernel"
    
    # Check CPU virtualization
    if grep -q -E 'vmx|svm' /proc/cpuinfo; then
        log_success "CPU virtualization: ENABLED"
    else
        log_warning "CPU virtualization: NOT DETECTED"
    fi
    
    # Check memory
    local total_mem=$(free -g | awk '/^Mem:/{print $2}')
    log_info "Total memory: ${total_mem}GB"
    
    # Check disk space
    echo "Disk space:"
    df -h / /var/lib/libvirt/images /backup 2>/dev/null | awk '{print "  " $0}'
    
    # Check system load
    local load=$(uptime | awk -F'load average:' '{print $2}')
    log_info "System load: $load"
}

verify_network() {
    log_info "Verifying network configuration..."
    
    # Check VLAN interfaces
    log_info "Network interfaces:"
    ip -o addr show | grep -v "lo" | while read line; do
        log_info "  $line"
    done
    
    # Verify VLANs are up
    local missing_vlans=""
    
    case "$NODE_TYPE" in
        "controller"|"combined")
            check_interface "mgmt" "$MGMT_IP"
            check_interface "internal" "$INTERNAL_IP"
            check_interface "storage" "$STORAGE_IP"
            check_interface "external" ""
            ;;
        "compute")
            check_interface "mgmt" "$MGMT_IP"
            check_interface "internal" "$INTERNAL_IP"
            check_interface "storage" "$STORAGE_IP"
            ;;
        "storage")
            check_interface "mgmt" "$MGMT_IP"
            check_interface "storage" "$STORAGE_IP"
            ;;
    esac
    
    # Test connectivity
    log_info "Testing connectivity..."
    
    # Test internet connectivity
    if ping -c 2 -W 1 8.8.8.8 >/dev/null 2>&1; then
        log_success "Internet connectivity: OK"
    else
        log_warning "Internet connectivity: FAILED"
    fi
    
    # Test controller connectivity (for compute/storage nodes)
    if [[ "$NODE_TYPE" == "compute" || "$NODE_TYPE" == "storage" ]]; then
        if ping -c 2 -W 1 "$CONTROLLER_IP" >/dev/null 2>&1; then
            log_success "Controller connectivity: OK"
        else
            log_error "Controller connectivity: FAILED"
        fi
    fi
}

check_interface() {
    local iface="$1"
    local expected_ip="$2"
    
    if ip link show "$iface" >/dev/null 2>&1; then
        if [[ -n "$expected_ip" ]]; then
            if ip addr show "$iface" | grep -q "$expected_ip"; then
                log_success "Interface $iface: UP (IP: $expected_ip)"
            else
                log_error "Interface $iface: WRONG IP"
            fi
        else
            log_success "Interface $iface: UP"
        fi
    else
        log_error "Interface $iface: MISSING"
    fi
}

verify_services() {
    log_info "Verifying services..."
    
    # Common services
    check_service "ssh" "SSH"
    check_service "chrony" "NTP"
    check_service "prometheus-node-exporter" "Node Exporter"
    check_service "ufw" "Firewall"
    
    # Node-specific services
    case "$NODE_TYPE" in
        "controller"|"combined")
            check_service "openvswitch-switch" "Open vSwitch"
            check_service "ovn-northd" "OVN Northbound"
            check_service "ovn-metrics" "OVN Metrics"
            check_service "metadata.service" "Metadata Service"
            check_service "cloud-api.service" "Management API"
            check_service "prometheus" "Prometheus"
            check_service "grafana-server" "Grafana"
            
            # Check OVN databases
            if ovn-nbctl show >/dev/null 2>&1; then
                log_success "OVN Northbound: ACCESSIBLE"
            else
                log_error "OVN Northbound: INACCESSIBLE"
            fi
            
            if ovn-sbctl show >/dev/null 2>&1; then
                log_success "OVN Southbound: ACCESSIBLE"
            else
                log_error "OVN Southbound: INACCESSIBLE"
            fi
            ;;
        
        "compute"|"combined")
            check_service "openvswitch-switch" "Open vSwitch"
            check_service "ovn-controller" "OVN Controller"
            check_service "libvirtd" "Libvirt"
            check_service "virtlogd" "Virt Log"
            
            # Check OVS bridges
            if ovs-vsctl br-exists br-int; then
                log_success "OVS bridge br-int: EXISTS"
            else
                log_error "OVS bridge br-int: MISSING"
            fi
            
            # Check OVN connectivity
            if ovs-vsctl get open . external-ids:ovn-remote | grep -q "$CONTROLLER_IP"; then
                log_success "OVN remote: CONFIGURED"
            else
                log_error "OVN remote: MISCONFIGURED"
            fi
            ;;
        
        "storage")
            # Ceph services will be added when storage phase is implemented
            log_info "Storage services verification pending"
            ;;
    esac
}

check_service() {
    local service="$1"
    local name="$2"
    
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        log_success "$name: RUNNING"
    else
        log_error "$name: STOPPED"
    fi
}

verify_functionality() {
    log_info "Verifying functionality..."
    
    case "$NODE_TYPE" in
        "controller"|"combined")
            verify_controller_functionality
            ;;
        "compute"|"combined")
            verify_compute_functionality
            ;;
        "storage")
            verify_storage_functionality
            ;;
    esac
}

verify_controller_functionality() {
    log_info "Testing controller functionality..."
    
    # Test metadata service
    if curl -s http://localhost/health >/dev/null 2>&1; then
        log_success "Metadata service: RESPONDING"
    else
        log_error "Metadata service: NOT RESPONDING"
    fi
    
    # Test management API
    if curl -s http://localhost:8000/health >/dev/null 2>&1; then
        log_success "Management API: RESPONDING"
    else
        log_error "Management API: NOT RESPONDING"
    fi
    
    # Test Prometheus
    if curl -s http://localhost:9090/-/healthy >/dev/null 2>&1; then
        log_success "Prometheus: RESPONDING"
    else
        log_error "Prometheus: NOT RESPONDING"
    fi
    
    # Test Grafana
    if curl -s http://localhost:3000/api/health >/dev/null 2>&1; then
        log_success "Grafana: RESPONDING"
    else
        log_warning "Grafana: NOT RESPONDING (may need time to start)"
    fi
    
    # Test OVN NB API
    if timeout 5 ovsdb-client list-dbs tcp:127.0.0.1:6641 >/dev/null 2>&1; then
        log_success "OVN NB API: RESPONDING"
    else
        log_error "OVN NB API: NOT RESPONDING"
    fi
}

verify_compute_functionality() {
    log_info "Testing compute functionality..."
    
    # Test libvirt connection
    if virsh list >/dev/null 2>&1; then
        log_success "Libvirt: CONNECTED"
    else
        log_error "Libvirt: CONNECTION FAILED"
    fi
    
    # Test OVN controller connectivity
    if ovs-vsctl get open . external-ids:ovn-remote >/dev/null 2>&1; then
        log_success "OVN controller: CONFIGURED"
    else
        log_error "OVN controller: NOT CONFIGURED"
    fi
    
    # Test KVM availability
    if [[ -c /dev/kvm ]]; then
        log_success "KVM: AVAILABLE"
    else
        log_error "KVM: NOT AVAILABLE"
    fi
    
    # Test cloud image exists
    if [[ -f /var/lib/libvirt/images/ubuntu-22.04-server-cloudimg-amd64.img ]]; then
        log_success "Cloud image: PRESENT"
    else
        log_warning "Cloud image: MISSING"
    fi
}

verify_storage_functionality() {
    log_info "Testing storage functionality..."
    
    # This will be implemented when storage phase is added
    log_info "Storage functionality verification pending"
}

generate_report() {
    log_info "Generating verification report..."
    
    local report_file="/opt/cloud-provider/verification-report-$(date +%Y%m%d-%H%M%S).txt"
    
    {
        echo "CLOUD PROVIDER VERIFICATION REPORT"
        echo "==================================="
        echo "Date: $(date)"
        echo "Hostname: $(hostname)"
        echo "Node Type: $NODE_TYPE"
        echo "Management IP: $MGMT_IP"
        echo ""
        echo "SYSTEM:"
        echo "  Kernel: $(uname -r)"
        echo "  Memory: $(free -h | awk '/^Mem:/{print $2}')"
        echo "  Disk: $(df -h / | awk 'NR==2{print $4}') free"
        echo ""
        echo "NETWORK:"
        ip -o addr show | grep -v "lo" | awk '{print "  " $2 ": " $4}'
        echo ""
        echo "SERVICES:"
        systemctl list-units --type=service --state=running | grep -E '(ovn|libvirt|ceph|prometheus|grafana|metadata)' | awk '{print "  " $1}'
        echo ""
        echo "CONNECTIVITY:"
        echo "  Internet: $(ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1 && echo "OK" || echo "FAILED")"
        if [[ "$NODE_TYPE" == "compute" || "$NODE_TYPE" == "storage" ]]; then
            echo "  Controller: $(ping -c 1 -W 1 "$CONTROLLER_IP" >/dev/null 2>&1 && echo "OK" || echo "FAILED")"
        fi
        echo ""
        echo "ISSUES FOUND:"
        journalctl --since "1 hour ago" -p err --no-pager | tail -5 | sed 's/^/  /'
    } > "$report_file"
    
    # Count issues
    local error_count=$(journalctl --since "1 hour ago" -p err --no-pager | wc -l)
    local warning_count=$(journalctl --since "1 hour ago" -p warning --no-pager | wc -l)
    
    echo "" >> "$report_file"
    echo "SUMMARY:" >> "$report_file"
    echo "  Errors (last hour): $error_count" >> "$report_file"
    echo "  Warnings (last hour): $warning_count" >> "$report_file"
    
    if [[ $error_count -eq 0 ]]; then
        echo "  Overall Status: PASS" >> "$report_file"
        log_success "Verification PASSED"
        log_info "Report saved to: $report_file"
    else
        echo "  Overall Status: FAIL" >> "$report_file"
        log_warning "Verification found issues"
        log_info "Report saved to: $report_file"
        log_info "Review the report for details"
    fi
    
    # Show summary
    log_header "Verification Summary"
    log_info "Report: $report_file"
    log_info "Errors: $error_count"
    log_info "Warnings: $warning_count"
    
    if [[ $error_count -eq 0 ]]; then
        log_success "✅ Node is ready for production use!"
    else
        log_warning "⚠️  Node has issues that need attention"
    fi
}

# Main
load_config
run_verification