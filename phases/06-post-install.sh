#!/bin/bash
# /opt/cloud-provider/phases/06-post-install.sh

source "$(dirname "$0")/../lib/common.sh"

run_post_install() {
    log_header "Post-Install Configuration"
    
    configure_firewall
    create_utilities
    setup_backups
    configure_monitoring
    create_documentation
    finalize_installation
}

configure_firewall() {
    log_info "Configuring firewall rules..."
    
    # Common rules for all nodes
    ufw allow from 10.0.0.0/24  # Management network
    ufw allow from 10.0.1.0/24  # Internal network (OVN tunnels)
    ufw allow from 10.0.2.0/24  # Storage network
    
    # Node-specific rules
    case "$NODE_TYPE" in
        "controller"|"combined")
            ufw allow 80/tcp     # Metadata service
            ufw allow 443/tcp    # HTTPS (future)
            ufw allow 8000/tcp   # Management API
            ufw allow 9090/tcp   # Prometheus
            ufw allow 3000/tcp   # Grafana
            ufw allow 6641/tcp   # OVN Northbound
            ufw allow 6642/tcp   # OVN Southbound
            ufw allow 2379/tcp   # etcd (if used)
            ufw allow 2380/tcp   # etcd peer
            ;;
        
        "compute"|"combined")
            ufw allow 5900:5910/tcp  # VNC/Spice console
            ufw allow 16509/tcp       # Libvirt
            ufw allow 16514/tcp       # Libvirt TLS
            ufw allow 49152:49215/tcp # QEMU migrations
            ;;
        
        "storage")
            ufw allow 6789/tcp   # Ceph Monitor
            ufw allow 6800:7300/tcp # Ceph OSD/MDS/MGR
            ufw allow 3300/tcp   # Ceph RadosGW
            ufw allow 7480/tcp   # Ceph Dashboard
            ;;
    esac
    
    # Enable fail2ban for SSH protection
    log_info "Configuring fail2ban..."
    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
EOF
    
    systemctl restart fail2ban
    ufw reload
    
    log_success "Firewall configured"
}

create_utilities() {
    log_info "Creating utility scripts..."
    
    # Create a unified status script
    cat > /usr/local/bin/cloud-status.sh <<'EOF'
#!/bin/bash
# Unified status script for cloud provider nodes

source /etc/cloud-provider/node.conf 2>/dev/null || echo "No configuration found"

echo "╔══════════════════════════════════════════════════════════╗"
echo "║                CLOUD PROVIDER STATUS                     ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║ Hostname:        $(hostname)"
echo "║ Node Type:       ${NODE_TYPE:-Unknown}"
echo "║ Management IP:   ${MGMT_IP:-Not configured}"
echo "║ Uptime:          $(uptime -p | sed 's/up //')"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# System information
echo "=== SYSTEM ==="
echo "CPU:  $(lscpu | grep 'Model name' | cut -d: -f2 | xargs)"
echo "RAM:  $(free -h | awk '/^Mem:/{print $2}') total, $(free -h | awk '/^Mem:/{print $3}') used"
echo "Disk: $(df -h / | awk 'NR==2{print $2}') total, $(df -h / | awk 'NR==2{print $5}') used"
echo ""

# Services based on node type
case "${NODE_TYPE}" in
    "controller"|"combined")
        echo "=== CONTROLLER SERVICES ==="
        check_service "ovn-northd" "OVN Northbound"
        check_service "ovn-metrics" "OVN Metrics"
        check_service "metadata.service" "Metadata Service"
        check_service "cloud-api.service" "Management API"
        check_service "prometheus" "Prometheus"
        check_service "grafana-server" "Grafana"
        echo ""
        
        echo "=== OVN STATUS ==="
        if command -v ovn-nbctl >/dev/null 2>&1; then
            echo "Logical Switches: $(ovn-nbctl list logical_switch 2>/dev/null | wc -l)"
            echo "Logical Routers:  $(ovn-nbctl list logical_router 2>/dev/null | wc -l)"
            echo "Chassis:          $(ovn-sbctl list chassis 2>/dev/null | wc -l)"
        fi
        ;;
    
    "compute"|"combined")
        echo "=== COMPUTE SERVICES ==="
        check_service "ovn-controller" "OVN Controller"
        check_service "libvirtd" "Libvirt Daemon"
        check_service "virtlogd" "Virt Log Daemon"
        echo ""
        
        echo "=== VIRTUALIZATION ==="
        if command -v virsh >/dev/null 2>&1; then
            echo "Running VMs: $(virsh list --state-running | grep -v "Id" | wc -l)"
            echo "All VMs:     $(virsh list --all | grep -v "Id" | wc -l)"
        fi
        
        echo "=== OVS STATUS ==="
        if command -v ovs-vsctl >/dev/null 2>&1; then
            echo "Bridges:      $(ovs-vsctl list-br | wc -l)"
            echo "Ports:        $(ovs-vsctl list-ports br-int 2>/dev/null | wc -l)"
        fi
        ;;
    
    "storage")
        echo "=== STORAGE SERVICES ==="
        check_service "ceph-mon" "Ceph Monitor"
        check_service "ceph-mgr" "Ceph Manager"
        echo ""
        
        if command -v ceph >/dev/null 2>&1; then
            echo "=== CEPH STATUS ==="
            ceph status 2>/dev/null || echo "Ceph not configured"
        fi
        ;;
esac

echo "=== NETWORK ==="
echo "Interfaces:"
ip -o addr show | grep -v "lo" | awk '{print $2 ": " $4}' | sort
echo ""

echo "=== LOGS ==="
echo "Recent errors:"
journalctl --since "1 hour ago" -p err --no-pager | tail -5

check_service() {
    local service=$1
    local name=$2
    
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        echo "✓ $name: RUNNING"
    else
        echo "✗ $name: STOPPED"
    fi
}
EOF
    
    chmod +x /usr/local/bin/cloud-status.sh
    
    # Create backup script
    cat > /usr/local/bin/cloud-backup.sh <<'EOF'
#!/bin/bash
# Backup script for cloud provider configuration

BACKUP_DIR="/backup/cloud-provider"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_PATH="$BACKUP_DIR/$TIMESTAMP"

mkdir -p "$BACKUP_PATH"

echo "Starting backup to $BACKUP_PATH..."

# Backup configuration files
echo "Backing up configurations..."
cp -r /etc/cloud-provider "$BACKUP_PATH/" 2>/dev/null || true
cp -r /etc/netplan "$BACKUP_PATH/" 2>/dev/null || true
cp /etc/hosts "$BACKUP_PATH/" 2>/dev/null || true

# Backup OVN databases
if command -v ovn-nbctl >/dev/null 2>&1; then
    echo "Backing up OVN databases..."
    ovsdb-client dump tcp:127.0.0.1:6641 > "$BACKUP_PATH/ovn-nb.db" 2>/dev/null || true
    ovsdb-client dump tcp:127.0.0.1:6642 > "$BACKUP_PATH/ovn-sb.db" 2>/dev/null || true
fi

# Backup OVS configuration
if command -v ovs-vsctl >/dev/null 2>&1; then
    echo "Backing up OVS configuration..."
    ovs-vsctl save > "$BACKUP_PATH/ovs-config.backup" 2>/dev/null || true
fi

# Backup libvirt VMs (if compute)
if command -v virsh >/dev/null 2>&1; then
    echo "Backing up libvirt VM definitions..."
    mkdir -p "$BACKUP_PATH/libvirt"
    for vm in $(virsh list --name --all); do
        virsh dumpxml "$vm" > "$BACKUP_PATH/libvirt/$vm.xml" 2>/dev/null
    done
fi

# Create tarball
cd "$BACKUP_DIR"
tar -czf "$TIMESTAMP.tar.gz" "$TIMESTAMP"
rm -rf "$TIMESTAMP"

echo "Backup completed: $BACKUP_DIR/$TIMESTAMP.tar.gz"
EOF
    
    chmod +x /usr/local/bin/cloud-backup.sh
    
    # Create restore script
    cat > /usr/local/bin/cloud-restore.sh <<'EOF'
#!/bin/bash
# Restore script for cloud provider configuration

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <backup-file.tar.gz>"
    exit 1
fi

BACKUP_FILE="$1"
RESTORE_DIR="/tmp/cloud-restore-$(date +%s)"

echo "Restoring from $BACKUP_FILE..."

# Extract backup
mkdir -p "$RESTORE_DIR"
tar -xzf "$BACKUP_FILE" -C "$RESTORE_DIR" --strip-components=1

# Restore configurations
echo "Restoring configurations..."
cp -r "$RESTORE_DIR/cloud-provider" /etc/ 2>/dev/null || true
cp -r "$RESTORE_DIR/netplan" /etc/ 2>/dev/null || true
cp "$RESTORE_DIR/hosts" /etc/ 2>/dev/null || true

# Restore OVS/OVN if present
if [[ -f "$RESTORE_DIR/ovs-config.backup" ]]; then
    echo "Restoring OVS configuration..."
    ovs-vsctl restore < "$RESTORE_DIR/ovs-config.backup" 2>/dev/null || true
fi

# Restore libvirt VMs
if [[ -d "$RESTORE_DIR/libvirt" ]]; then
    echo "Restoring libvirt VMs..."
    for vm_xml in "$RESTORE_DIR/libvirt"/*.xml; do
        vm_name=$(basename "$vm_xml" .xml)
        virsh define "$vm_xml" 2>/dev/null || true
    done
fi

# Cleanup
rm -rf "$RESTORE_DIR"

echo "Restore completed. Please reboot or restart services."
EOF
    
    chmod +x /usr/local/bin/cloud-restore.sh
    
    # Create maintenance script
    cat > /usr/local/bin/cloud-maintenance.sh <<'EOF'
#!/bin/bash
# Maintenance utilities for cloud provider

case "$1" in
    "cleanup")
        echo "Cleaning up temporary files..."
        apt-get autoremove -y
        apt-get autoclean
        journalctl --vacuum-time=7d
        docker system prune -af 2>/dev/null || true
        echo "Cleanup completed."
        ;;
    
    "update")
        echo "Updating system packages..."
        apt-get update
        apt-get upgrade -y
        echo "Update completed."
        ;;
    
    "restart-services")
        echo "Restarting cloud services..."
        
        # Restart based on node type
        source /etc/cloud-provider/node.conf 2>/dev/null || true
        
        case "${NODE_TYPE}" in
            "controller"|"combined")
                systemctl restart ovn-northd
                systemctl restart metadata.service
                systemctl restart cloud-api.service
                systemctl restart prometheus
                systemctl restart grafana-server
                ;;
            "compute"|"combined")
                systemctl restart ovn-controller
                systemctl restart libvirtd
                ;;
            "storage")
                systemctl restart ceph-mon
                systemctl restart ceph-mgr
                ;;
        esac
        
        echo "Services restarted."
        ;;
    
    "logs")
        tail -f /var/log/cloud-provider-install*.log 2>/dev/null || \
        tail -f /var/log/syslog
        ;;
    
    *)
        echo "Usage: $0 {cleanup|update|restart-services|logs}"
        exit 1
        ;;
esac
EOF
    
    chmod +x /usr/local/bin/cloud-maintenance.sh
    
    log_success "Utility scripts created"
}

setup_backups() {
    log_info "Setting up backup system..."
    
    # Create backup directory
    mkdir -p /backup/cloud-provider
    
    # Create cron job for daily backups
    cat > /etc/cron.daily/cloud-backup <<'EOF'
#!/bin/bash
/usr/local/bin/cloud-backup.sh > /var/log/cloud-backup.log 2>&1
# Keep only last 7 days of backups
find /backup/cloud-provider -name "*.tar.gz" -mtime +7 -delete
EOF
    
    chmod +x /etc/cron.daily/cloud-backup
    
    # Create log rotation for backups
    cat > /etc/logrotate.d/cloud-backup <<EOF
/var/log/cloud-backup.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 644 root root
}
EOF
    
    log_success "Backup system configured"
}

configure_monitoring() {
    log_info "Configuring monitoring..."
    
    # Create custom Prometheus alerts if controller
    if [[ "$NODE_TYPE" == "controller" || "$NODE_TYPE" == "combined" ]]; then
        mkdir -p /etc/prometheus/alerts
        
        cat > /etc/prometheus/alerts/cloud-provider.yml <<'EOF'
groups:
  - name: cloud-provider
    rules:
      - alert: HighCPUUsage
        expr: 100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 80
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High CPU usage on {{ $labels.instance }}"
          description: "CPU usage is above 80% for 5 minutes"
      
      - alert: HighMemoryUsage
        expr: (node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) / node_memory_MemTotal_bytes * 100 > 85
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High memory usage on {{ $labels.instance }}"
          description: "Memory usage is above 85% for 5 minutes"
      
      - alert: ServiceDown
        expr: up == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Service {{ $labels.job }} on {{ $labels.instance }} is down"
          description: "Service has been down for more than 1 minute"
      
      - alert: OVNServiceDown
        expr: ovn_northd_status == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "OVN Northbound service is down"
          description: "OVN Northbound database is not accessible"
EOF
        
        # Update prometheus config to include alerts
        cat >> /etc/prometheus/prometheus.yml <<EOF

rule_files:
  - "/etc/prometheus/alerts/cloud-provider.yml"

alerting:
  alertmanagers:
    - static_configs:
        - targets:
          - localhost:9093
EOF
        
        systemctl restart prometheus
    fi
    
    # Configure log rotation
    cat > /etc/logrotate.d/cloud-provider <<EOF
/var/log/cloud-provider*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 644 root root
    sharedscripts
    postrotate
        systemctl restart rsyslog 2>/dev/null || true
    endscript
}

/var/log/cloud-provider/phases/*.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 644 root root
}
EOF
    
    log_success "Monitoring configured"
}

create_documentation() {
    log_info "Creating documentation..."
    
    mkdir -p /opt/cloud-provider/docs
    
    # Create node documentation
    cat > /opt/cloud-provider/docs/NODE_INFO.md <<EOF
# Cloud Provider Node Information

## Node Details
- **Hostname**: $(hostname)
- **Node Type**: $NODE_TYPE
- **Installation Date**: $(date)
- **Management IP**: $MGMT_IP
- **Internal IP**: $INTERNAL_IP
- **Storage IP**: $STORAGE_IP

## Network Configuration
### VLANs:
- VLAN 4003 (mgmt): $MGMT_IP/24
- VLAN 4001 (internal): $INTERNAL_IP/24
- VLAN 4002 (storage): $STORAGE_IP/24

### Physical Interface:
- Interface: $PHYSICAL_INTERFACE

## Services Installed
EOF
    
    # Add service list based on node type
    case "$NODE_TYPE" in
        "controller")
            cat >> /opt/cloud-provider/docs/NODE_INFO.md <<EOF
- OVN Central (Northbound/Southbound)
- Metadata Service (port 80)
- Management API (port 8000)
- Prometheus (port 9090)
- Grafana (port 3000)
EOF
            ;;
        "compute")
            cat >> /opt/cloud-provider/docs/NODE_INFO.md <<EOF
- OVN Host/Controller
- Libvirt/KVM
- QEMU
EOF
            ;;
        "combined")
            cat >> /opt/cloud-provider/docs/NODE_INFO.md <<EOF
- OVN Central & Host
- Libvirt/KVM
- Metadata Service
- Management API
- Prometheus
- Grafana
EOF
            ;;
        "storage")
            cat >> /opt/cloud-provider/docs/NODE_INFO.md <<EOF
- Ceph Monitor
- Ceph OSD
- Ceph Manager
EOF
            ;;
    esac
    
    cat >> /opt/cloud-provider/docs/NODE_INFO.md <<EOF

## Utility Scripts
- \`cloud-status.sh\` - Check node status
- \`cloud-backup.sh\` - Backup configuration
- \`cloud-restore.sh\` - Restore from backup
- \`cloud-maintenance.sh\` - Maintenance tasks

## Important Files
- Configuration: /etc/cloud-provider/node.conf
- Logs: /var/log/cloud-provider-install*.log
- Phase Logs: /var/log/cloud-provider/phases/
- Backups: /backup/cloud-provider/

## Recovery
To recover this node:
1. Restore from backup: \`cloud-restore.sh <backup-file>\`
2. Re-run installer: \`cloud-install\` (choose "Continue Installation")
3. Or reconfigure: \`cloud-install\` (choose "Reconfigure Node")

## Support
For issues, check logs in /var/log/cloud-provider/
EOF
    
    # Create quick reference
    cat > /opt/cloud-provider/docs/QUICK_REFERENCE.txt <<EOF
QUICK REFERENCE - $(hostname) [$NODE_TYPE]

ACCESS:
  SSH:          ssh user@$MGMT_IP
  Management:   http://$MGMT_IP:8000
  Metrics:      http://$MGMT_IP:9090
  Dashboard:    http://$MGMT_IP:3000 (admin/admin)

COMMANDS:
  Check status:      cloud-status.sh
  Backup:            cloud-backup.sh
  Maintenance:       cloud-maintenance.sh <command>
  View logs:         cloud-maintenance.sh logs

SERVICES:
$(systemctl list-units --type=service --state=running | grep -E '(ovn|libvirt|ceph|prometheus|grafana|metadata)' | awk '{print "  " $1}')

DISK USAGE:
$(df -h | grep -E '(/|/var/lib/libvirt|/backup)')

NETWORK:
$(ip -o addr show | grep -v "lo" | awk '{print "  " $2 ": " $4}')
EOF
    
    log_success "Documentation created"
}

finalize_installation() {
    log_info "Finalizing installation..."
    
    # Set up motd
    cat > /etc/update-motd.d/99-cloud-provider <<EOF
#!/bin/bash
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║                 CLOUD PROVIDER NODE                      ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║ Type:        $NODE_TYPE"
echo "║ IP:          $MGMT_IP"
echo "║ Hostname:    $(hostname)"
echo "║ Installed:   $(date)"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "Quick commands:"
echo "  cloud-status.sh      - Check system status"
echo "  cloud-install        - Reconfigure node"
echo ""
EOF
    
    chmod +x /etc/update-motd.d/99-cloud-provider
    
    # Create completion flag
    touch /etc/cloud-provider/.installed
    
    # Set permissions
    chmod 755 /usr/local/bin/cloud-*.sh
    
    log_success "Installation finalized"
    log_info "Documentation: /opt/cloud-provider/docs/"
    log_info "Utilities: cloud-status.sh, cloud-backup.sh, cloud-maintenance.sh"
}

# Main
load_config
run_post_install