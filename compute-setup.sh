#!/bin/bash
# install-compute.sh - Complete compute node installation

set -e

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "$1"; }
info() { log "${BLUE}[INFO]${NC} $1"; }
success() { log "${GREEN}[SUCCESS]${NC} $1"; }
error() { log "${RED}[ERROR]${NC} $1"; }
warning() { log "${YELLOW}[WARNING]${NC} $1"; }

# Configuration
CONTROLLER_IP="10.0.0.10"  # Change this if different
COMPUTE_IP=""  # Will be detected

print_banner() {
    clear
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║         COMPUTE NODE INSTALLATION                        ║"
    echo "║                KVM + Libvirt + OVN                       ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
}

check_prerequisites() {
    info "Checking prerequisites..."
    
    # Check root
    [[ $EUID -eq 0 ]] || { error "Must be run as root"; exit 1; }
    
    # Check Ubuntu 22.04
    if [[ ! -f /etc/os-release ]]; then
        error "Cannot determine OS"
        exit 1
    fi
    
    source /etc/os-release
    if [[ "$ID" != "ubuntu" ]] || [[ "$VERSION_ID" != "22.04" ]]; then
        warning "This script is tested on Ubuntu 22.04 LTS"
        read -p "Continue anyway? [y/N]: " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || exit 1
    fi
    
    # Check KVM support
    if ! grep -q -E 'vmx|svm' /proc/cpuinfo; then
        warning "CPU virtualization not detected (KVM may not work)"
        read -p "Continue anyway? [y/N]: " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || exit 1
    fi
    
    # Get compute IP
    COMPUTE_IP=$(hostname -I | awk '{print $1}')
    info "Compute node IP: $COMPUTE_IP"
    
    # Check controller connectivity
    info "Testing controller connectivity..."
    if ! ping -c 2 -W 1 "$CONTROLLER_IP" >/dev/null 2>&1; then
        error "Cannot reach controller at $CONTROLLER_IP"
        echo "Please verify:"
        echo "  1. Controller is running"
        echo "  2. Network is configured"
        echo "  3. Firewall allows ICMP"
        read -p "Continue anyway? [y/N]: " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || exit 1
    else
        success "Controller connectivity: OK"
    fi
    
    # Check VLAN interfaces
    info "Checking VLAN interfaces..."
    for vlan in mgmt internal storage; do
        if ip link show "$vlan" >/dev/null 2>&1; then
            success "VLAN $vlan: OK"
        else
            error "VLAN $vlan: NOT FOUND"
            echo "Run network setup first!"
            exit 1
        fi
    done
}

install_kvm_libvirt() {
    info "Installing KVM and Libvirt..."
    
    # Update packages
    apt-get update
    
    # Install KVM packages
    apt-get install -y \
        qemu-kvm \
        qemu-utils \
        libvirt-daemon-system \
        libvirt-clients \
        virtinst \
        virt-manager \
        bridge-utils \
        cpu-checker \
        cloud-image-utils \
        genisoimage
    
    # Check KVM
    if kvm-ok; then
        success "KVM is available"
    else
        warning "KVM check failed (may still work)"
    fi
    
    # Add user to libvirt group
    CURRENT_USER=${SUDO_USER:-$USER}
    usermod -a -G libvirt,kvm "$CURRENT_USER"
    success "Added $CURRENT_USER to libvirt and kvm groups"
    
    # Enable nested virtualization (if supported)
    if grep -q -E 'vmx|svm' /proc/cpuinfo; then
        echo "options kvm-intel nested=1" > /etc/modprobe.d/kvm-intel.conf
        modprobe -r kvm_intel
        modprobe kvm_intel
        success "Enabled nested virtualization"
    fi
    
    # Start and enable services
    systemctl enable --now libvirtd
    systemctl enable --now virtlogd
    
    success "KVM and Libvirt installed"
}

configure_libvirt() {
    info "Configuring Libvirt..."
    
    # Backup default libvirt config
    cp /etc/libvirt/libvirtd.conf /etc/libvirt/libvirtd.conf.backup
    
    # Configure libvirt to listen on management network
    cat >> /etc/libvirt/libvirtd.conf <<EOF
# Cloud provider custom configuration
listen_tls = 0
listen_tcp = 1
listen_addr = "$COMPUTE_IP"
auth_tcp = "none"
tcp_port = "16509"
EOF
    
    # Enable TCP socket
    sed -i 's/^#libvirtd_opts=.*/libvirtd_opts="-l"/' /etc/default/libvirtd
    
    # Configure qemu.conf for better performance
    cp /etc/libvirt/qemu.conf /etc/libvirt/qemu.conf.backup
    
    cat >> /etc/libvirt/qemu.conf <<EOF
# Performance optimizations
user = "root"
group = "root"
dynamic_ownership = 0
cgroup_device_acl = [
    "/dev/null", "/dev/full", "/dev/zero",
    "/dev/random", "/dev/urandom",
    "/dev/ptmx", "/dev/kvm", "/dev/kqemu",
    "/dev/rtc", "/dev/hpet", "/dev/net/tun"
]
EOF
    
    # Restart libvirt
    systemctl restart libvirtd
    
    # Create default storage pool
    mkdir -p /var/lib/libvirt/images
    virsh pool-define-as default dir - - - - "/var/lib/libvirt/images"
    virsh pool-start default
    virsh pool-autostart default
    
    success "Libvirt configured"
}

setup_lvm_storage() {
    info "Setting up LVM storage for VMs..."
    
    # Show available disks
    echo ""
    echo "=== AVAILABLE DISKS ==="
    lsblk -d -o NAME,SIZE,TYPE,MODEL,TRAN | grep -v "nvme0n1\|nvme1n1\|loop"
    echo ""
    
    read -p "Enter disk for VM storage (e.g., /dev/sdb): " VM_DISK
    
    if [[ ! -b "$VM_DISK" ]]; then
        error "Disk $VM_DISK not found!"
        exit 1
    fi
    
    # Install LVM tools
    apt-get install -y lvm2 thin-provisioning-tools
    
    # Create Physical Volume
    info "Creating physical volume on $VM_DISK..."
    pvcreate -f -y "$VM_DISK"
    
    # Create Volume Group
    info "Creating volume group 'vmstorage'..."
    vgcreate -f -y vmstorage "$VM_DISK"
    
    # Calculate sizes
    vg_size=$(vgdisplay vmstorage --units b | grep "VG Size" | awk '{print $3}' | sed 's/\..*//')
    pool_size=$((vg_size * 90 / 100))  # 90% for thin pool
    meta_size=$((vg_size * 5 / 100))   # 5% for metadata
    
    # Create thin pool
    info "Creating thin pool..."
    lvcreate -L ${pool_size}b -T vmstorage/thinpool --poolmetadatasize ${meta_size}b
    
    # Create ISO storage
    info "Creating ISO storage..."
    lvcreate -L 50G -n iso-store vmstorage
    mkfs.ext4 /dev/vmstorage/iso-store
    mkdir -p /var/lib/libvirt/isos
    echo "/dev/vmstorage/iso-store /var/lib/libvirt/isos ext4 defaults 0 0" >> /etc/fstab
    mount /var/lib/libvirt/isos
    
    # Create Libvirt storage pool for LVM
    info "Creating Libvirt storage pool..."
    
    virsh pool-define-as vm-lvm logical --source-name vmstorage --target /dev/vmstorage
    virsh pool-build vm-lvm
    virsh pool-start vm-lvm
    virsh pool-autostart vm-lvm
    
    # Create storage volume for cloud images
    virsh vol-create-as vm-lvm base-ubuntu-22.04.qcow2 10G --format qcow2
    
    success "LVM storage configured"
    echo ""
    echo "Storage layout:"
    pvs
    echo ""
    vgs
    echo ""
    lvs
}

download_cloud_images() {
    info "Downloading cloud images..."
    
    mkdir -p /var/lib/libvirt/isos
    
    # Ubuntu 22.04
    if [[ ! -f /var/lib/libvirt/isos/jammy-server-cloudimg-amd64.img ]]; then
        wget -q https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img \
            -O /var/lib/libvirt/isos/jammy-server-cloudimg-amd64.img
        success "Downloaded Ubuntu 22.04 cloud image"
    else
        info "Ubuntu 22.04 image already exists"
    fi
    
    # Ubuntu 20.04
    if [[ ! -f /var/lib/libvirt/isos/focal-server-cloudimg-amd64.img ]]; then
        wget -q https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img \
            -O /var/lib/libvirt/isos/focal-server-cloudimg-amd64.img
        success "Downloaded Ubuntu 20.04 cloud image"
    else
        info "Ubuntu 20.04 image already exists"
    fi
    
    # Debian 11
    if [[ ! -f /var/lib/libvirt/isos/debian-11-genericcloud-amd64.qcow2 ]]; then
        wget -q https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-genericcloud-amd64.qcow2 \
            -O /var/lib/libvirt/isos/debian-11-genericcloud-amd64.qcow2
        success "Downloaded Debian 11 cloud image"
    else
        info "Debian 11 image already exists"
    fi
    
    success "Cloud images downloaded"
}

configure_ovn_integration() {
    info "Configuring OVN integration with Libvirt..."
    
    # Create OVN network definition for Libvirt
    cat > /tmp/ovn-network.xml <<EOF
<network>
  <name>ovn</name>
  <forward mode='bridge'/>
  <bridge name='br-int'/>
  <virtualport type='openvswitch'/>
</network>
EOF
    
    # Define and start OVN network
    virsh net-define /tmp/ovn-network.xml
    virsh net-start ovn
    virsh net-autostart ovn
    
    # Disable default network
    virsh net-destroy default 2>/dev/null || true
    virsh net-autostart default --disable 2>/dev/null || true
    
    success "OVN integration configured"
}

create_vm_templates() {
    info "Creating VM templates..."
    
    # Create cloud-init configuration directory
    mkdir -p /etc/cloud-init/templates
    
    # Create Ubuntu 22.04 template
    cat > /etc/cloud-init/templates/ubuntu-22.04.xml <<EOF
<domain type='kvm'>
  <name>ubuntu-22-04-template</name>
  <memory unit='GiB'>2</memory>
  <vcpu>2</vcpu>
  <os>
    <type arch='x86_64'>hvm</type>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
    <apic/>
    <vmport state='off'/>
  </features>
  <cpu mode='host-passthrough' check='none'/>
  <clock offset='utc'>
    <timer name='rtc' tickpolicy='catchup'/>
    <timer name='pit' tickpolicy='delay'/>
    <timer name='hpet' present='no'/>
  </clock>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='/var/lib/libvirt/isos/jammy-server-cloudimg-amd64.img'/>
      <target dev='vda' bus='virtio'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x04' function='0x0'/>
    </disk>
    <interface type='network'>
      <source network='ovn'/>
      <model type='virtio'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x03' function='0x0'/>
    </interface>
    <serial type='pty'>
      <target type='isa-serial' port='0'>
        <model name='isa-serial'/>
      </target>
    </serial>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>
    <graphics type='vnc' port='-1' autoport='yes' listen='0.0.0.0'>
      <listen type='address' address='0.0.0.0'/>
    </graphics>
    <video>
      <model type='qxl' ram='65536' vram='65536' vgamem='16384' heads='1' primary='yes'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x02' function='0x0'/>
    </video>
    <memballoon model='virtio'>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x05' function='0x0'/>
    </memballoon>
  </devices>
</domain>
EOF
    
    # Create VM management scripts
    cat > /usr/local/bin/create-vm.sh <<'EOF'
#!/bin/bash
# Create a new VM with cloud-init

if [[ $# -lt 3 ]]; then
    echo "Usage: $0 <vm-name> <tenant-id> <ip-address>"
    echo "Example: $0 web-server 1 172.16.1.10"
    exit 1
fi

VM_NAME="$1"
TENANT_ID="$2"
IP_ADDRESS="$3"
MAC_ADDRESS=$(printf '00:00:00:%02X:%02X:%02X' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))
TENANT_NET="tenant-$TENANT_ID-net"

echo "Creating VM: $VM_NAME"
echo "Network: $TENANT_NET"
echo "IP: $IP_ADDRESS"
echo "MAC: $MAC_ADDRESS"

# Create cloud-init directory
CLOUD_INIT_DIR="/var/lib/libvirt/cloud-init/$VM_NAME"
mkdir -p "$CLOUD_INIT_DIR"

# Generate network configuration
cat > "$CLOUD_INIT_DIR/network-config" <<NETCFG
version: 2
ethernets:
  eth0:
    match:
      macaddress: "$MAC_ADDRESS"
    addresses:
      - $IP_ADDRESS/24
    gateway4: 172.16.$TENANT_ID.1
    nameservers:
      addresses: [8.8.8.8, 1.1.1.1]
NETCFG

# Generate user-data
cat > "$CLOUD_INIT_DIR/user-data" <<USERDATA
#cloud-config
hostname: $VM_NAME
manage_etc_hosts: true
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: users, admin
    home: /home/ubuntu
    shell: /bin/bash
    lock_passwd: false
    ssh-authorized-keys:
      - ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQD... user@cloud
ssh_pwauth: false
disable_root: false
chpasswd:
  list: |
    ubuntu:ubuntu
  expire: false
packages:
  - qemu-guest-agent
  - curl
  - wget
  - net-tools
runcmd:
  - systemctl enable qemu-guest-agent
  - systemctl start qemu-guest-agent
  - echo "Welcome to $VM_NAME" > /etc/motd
USERDATA

# Generate meta-data
cat > "$CLOUD_INIT_DIR/meta-data" <<METADATA
instance-id: $VM_NAME
local-hostname: $VM_NAME
METADATA

# Create cloud-init ISO
cloud-localds -v \
    --network-config "$CLOUD_INIT_DIR/network-config" \
    "$CLOUD_INIT_DIR/cloud-init.iso" \
    "$CLOUD_INIT_DIR/user-data" \
    "$CLOUD_INIT_DIR/meta-data"

# Create VM disk (thin provisioned)
virsh vol-create-as vm-lvm "$VM_NAME.qcow2" 20G --format qcow2

# Create VM from template
virt-install \
    --name "$VM_NAME" \
    --memory 2048 \
    --vcpus 2 \
    --disk vol=vm-lvm/$VM_NAME.qcow2,bus=virtio \
    --disk "$CLOUD_INIT_DIR/cloud-init.iso,device=cdrom" \
    --network network=ovn,model=virtio,mac="$MAC_ADDRESS" \
    --graphics none \
    --console pty,target_type=serial \
    --os-type linux \
    --os-variant ubuntu22.04 \
    --import \
    --noautoconsole

echo "VM $VM_NAME created successfully!"
echo "Connect: virsh console $VM_NAME"
echo "IP: $IP_ADDRESS"
EOF
    
    chmod +x /usr/local/bin/create-vm.sh
    
    # Create VM management script
    cat > /usr/local/bin/manage-vm.sh <<'EOF'
#!/bin/bash
# Manage VMs

ACTION="$1"
VM_NAME="$2"

case "$ACTION" in
    start)
        virsh start "$VM_NAME"
        ;;
    stop)
        virsh shutdown "$VM_NAME"
        ;;
    reboot)
        virsh reboot "$VM_NAME"
        ;;
    destroy)
        virsh destroy "$VM_NAME"
        virsh undefine "$VM_NAME"
        ;;
    console)
        virsh console "$VM_NAME"
        ;;
    list)
        virsh list --all
        ;;
    status)
        virsh dominfo "$VM_NAME"
        ;;
    snapshot-create)
        virsh snapshot-create-as "$VM_NAME" "$3"
        ;;
    snapshot-list)
        virsh snapshot-list "$VM_NAME"
        ;;
    snapshot-restore)
        virsh snapshot-revert "$VM_NAME" "$3"
        ;;
    *)
        echo "Usage: $0 {start|stop|reboot|destroy|console|list|status|snapshot-create|snapshot-list|snapshot-restore} [vm-name] [snapshot-name]"
        exit 1
        ;;
esac
EOF
    
    chmod +x /usr/local/bin/manage-vm.sh
    
    success "VM templates and scripts created"
}

configure_firewall() {
    info "Configuring firewall..."
    
    # Install UFW if not installed
    apt-get install -y ufw
    
    # Default policies
    ufw default deny incoming
    ufw default allow outgoing
    
    # Allow SSH on management interface
    ufw allow from 10.0.0.0/24 to any port 22
    
    # Allow Libvirt API
    ufw allow from 10.0.0.0/24 to any port 16509
    
    # Allow VNC (5900-5910)
    ufw allow from 10.0.0.0/24 to any port 5900:5910
    
    # Allow OVN tunnel network
    ufw allow from 10.0.1.0/24
    
    # Allow storage network
    ufw allow from 10.0.2.0/24
    
    # Enable firewall
    ufw --force enable
    
    success "Firewall configured"
}

configure_monitoring() {
    info "Configuring monitoring..."
    
    # Install monitoring tools
    apt-get install -y \
        prometheus-node-exporter \
        virt-top \
        sysstat
    
    # Configure node exporter for Libvirt metrics
    cat >> /etc/default/prometheus-node-exporter <<EOF
ARGS="--collector.textfile.directory=/var/lib/node_exporter/textfile_collector"
EOF
    
    # Create Libvirt metrics script
    cat > /usr/local/bin/libvirt-metrics.sh <<'EOF'
#!/bin/bash
# Export Libvirt metrics for Prometheus

OUTPUT_FILE="/var/lib/node_exporter/textfile_collector/libvirt.prom"
TEMP_FILE="/tmp/libvirt_metrics.$$"

# Get VM count
RUNNING_VMS=$(virsh list --state-running | grep -v "Id" | wc -l)
TOTAL_VMS=$(virsh list --all | grep -v "Id" | wc -l)

# Get CPU/memory usage
TOTAL_CPU=0
TOTAL_MEM=0
for vm in $(virsh list --name --all); do
    if virsh dominfo "$vm" | grep -q "State:.*running"; then
        CPU=$(virsh dominfo "$vm" | grep "CPU(s)" | awk '{print $2}')
        MEM=$(virsh dominfo "$vm" | grep "Max memory" | awk '{print $3}')
        TOTAL_CPU=$((TOTAL_CPU + CPU))
        TOTAL_MEM=$((TOTAL_MEM + MEM))
    fi
done

# Write metrics
cat > "$TEMP_FILE" <<METRICS
# HELP libvirt_vms_total Total number of VMs
# TYPE libvirt_vms_total gauge
libvirt_vms_total $TOTAL_VMS

# HELP libvirt_vms_running Number of running VMs
# TYPE libvirt_vms_running gauge
libvirt_vms_running $RUNNING_VMS

# HELP libvirt_cpu_total Total CPU cores allocated to VMs
# TYPE libvirt_cpu_total gauge
libvirt_cpu_total $TOTAL_CPU

# HELP libvirt_memory_total Total memory allocated to VMs (KiB)
# TYPE libvirt_memory_total gauge
libvirt_memory_total $TOTAL_MEM
METRICS

mv "$TEMP_FILE" "$OUTPUT_FILE"
EOF
    
    chmod +x /usr/local/bin/libvirt-metrics.sh
    
    # Add to cron
    echo "* * * * * root /usr/local/bin/libvirt-metrics.sh" > /etc/cron.d/libvirt-metrics
    
    # Restart node exporter
    systemctl restart prometheus-node-exporter
    
    success "Monitoring configured"
}

create_status_scripts() {
    info "Creating status scripts..."
    
    # Compute node status
    cat > /usr/local/bin/compute-status.sh <<'EOF'
#!/bin/bash
echo "=== COMPUTE NODE STATUS ==="
echo ""
echo "Hostname: $(hostname)"
echo "IP Address: $(hostname -I)"
echo "Uptime: $(uptime -p)"
echo ""
echo "=== KVM STATUS ==="
if kvm-ok 2>/dev/null; then
    echo "KVM: Available"
else
    echo "KVM: Not available"
fi
echo ""
echo "=== LIBVIRT STATUS ==="
systemctl status libvirtd --no-pager | grep -A1 "Active:"
echo ""
echo "=== VIRTUAL MACHINES ==="
virsh list --all
echo ""
echo "=== STORAGE ==="
echo "LVM:"
vgs
echo ""
lvs
echo ""
echo "=== NETWORK ==="
echo "VLAN Interfaces:"
for vlan in mgmt internal storage; do
    if ip link show "$vlan" >/dev/null 2>&1; then
        ip=$(ip -4 addr show "$vlan" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "no IP")
        echo "  $vlan: UP ($ip)"
    else
        echo "  $vlan: DOWN"
    fi
done
echo ""
echo "=== OVN ==="
systemctl status ovn-controller --no-pager | grep -A1 "Active:"
echo "Connected to: $(ovs-vsctl get open . external-ids:ovn-remote 2>/dev/null || echo "unknown")"
EOF
    
    chmod +x /usr/local/bin/compute-status.sh
    
    # Resource usage
    cat > /usr/local/bin/compute-resources.sh <<'EOF'
#!/bin/bash
echo "=== RESOURCE USAGE ==="
echo ""
echo "CPU:"
echo "  Load average: $(uptime | awk -F'load average:' '{print $2}')"
echo "  Cores: $(nproc)"
echo ""
echo "MEMORY:"
free -h
echo ""
echo "DISK:"
df -h / /var/lib/libvirt/images /var/lib/libvirt/isos
echo ""
echo "VM RESOURCES:"
echo "  Total VMs: $(virsh list --all | grep -v "Id" | wc -l)"
echo "  Running VMs: $(virsh list --state-running | grep -v "Id" | wc -l)"
echo ""
echo "NETWORK:"
for vlan in mgmt internal storage; do
    if [ -d "/sys/class/net/$vlan/statistics" ]; then
        rx=$(cat /sys/class/net/$vlan/statistics/rx_bytes)
        tx=$(cat /sys/class/net/$vlan/statistics/tx_bytes)
        echo "  $vlan: RX $(numfmt --to=iec $rx) / TX $(numfmt --to=iec $tx)"
    fi
done
EOF
    
    chmod +x /usr/local/bin/compute-resources.sh
    
    success "Status scripts created"
}

verify_installation() {
    info "Verifying installation..."
    
    echo ""
    echo "=== VERIFICATION TESTS ==="
    echo ""
    
    # Test 1: Libvirt service
    if systemctl is-active --quiet libvirtd; then
        success "✓ Libvirt service: RUNNING"
    else
        error "✗ Libvirt service: STOPPED"
    fi
    
    # Test 2: KVM module
    if lsmod | grep -q kvm; then
        success "✓ KVM module: LOADED"
    else
        error "✗ KVM module: NOT LOADED"
    fi
    
    # Test 3: OVN controller
    if systemctl is-active --quiet ovn-controller; then
        success "✓ OVN controller: RUNNING"
    else
        error "✗ OVN controller: STOPPED"
    fi
    
    # Test 4: Storage pools
    if virsh pool-list --all | grep -q vm-lvm; then
        success "✓ LVM storage pool: CONFIGURED"
    else
        error "✗ LVM storage pool: MISSING"
    fi
    
    # Test 5: OVN network
    if virsh net-list --all | grep -q ovn; then
        success "✓ OVN network: CONFIGURED"
    else
        error "✗ OVN network: MISSING"
    fi
    
    # Test 6: Cloud images
    if [[ -f /var/lib/libvirt/isos/jammy-server-cloudimg-amd64.img ]]; then
        success "✓ Cloud images: DOWNLOADED"
    else
        warning "⚠ Cloud images: NOT FOUND"
    fi
    
    echo ""
    echo "=== QUICK VM TEST ==="
    read -p "Create a test VM? [y/N]: " create_test
    
    if [[ "$create_test" =~ ^[Yy]$ ]]; then
        echo "Creating test VM..."
        /usr/local/bin/create-vm.sh test-vm 1 172.16.1.99
        
        echo ""
        echo "Test VM created!"
        echo "Check status: virsh list --all"
        echo "Connect to console: virsh console test-vm"
        echo "Delete when done: virsh destroy test-vm && virsh undefine test-vm"
    fi
}

main() {
    print_banner
    
    info "Starting compute node installation..."
    echo ""
    
    # Run all steps
    check_prerequisites
    install_kvm_libvirt
    configure_libvirt
    setup_lvm_storage
    download_cloud_images
    configure_ovn_integration
    create_vm_templates
    configure_firewall
    configure_monitoring
    create_status_scripts
    verify_installation
    
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    success "      COMPUTE NODE INSTALLATION COMPLETE!"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
    echo "Summary:"
    echo "  Node IP: $COMPUTE_IP"
    echo "  Controller: $CONTROLLER_IP"
    echo ""
    echo "Available commands:"
    echo "  compute-status.sh     - Show node status"
    echo "  compute-resources.sh  - Show resource usage"
    echo "  create-vm.sh          - Create new VM"
    echo "  manage-vm.sh          - Manage VMs"
    echo ""
    echo "Next steps:"
    echo "  1. Test VM creation: create-vm.sh web1 1 172.16.1.10"
    echo "  2. Check status: compute-status.sh"
    echo "  3. Monitor resources: compute-resources.sh"
    echo "  4. Configure backups and monitoring"
    echo ""
    echo "Note: Log out and back in for libvirt group permissions to take effect."
}

# Run main
trap 'echo -e "\nInstallation interrupted."; exit 1' INT
main "$@"