#!/bin/bash
# /opt/cloud-provider/phases/04-compute.sh

source "$(dirname "$0")/../lib/common.sh"

run_compute_install() {
    log_header "Compute Installation"
    
    # Only run if node type is compute or combined
    if [[ "$NODE_TYPE" != "compute" && "$NODE_TYPE" != "combined" ]]; then
        log_info "Skipping compute installation (node type: $NODE_TYPE)"
        return 0
    fi
    
    install_virtualization
    configure_ovn_compute
    configure_libvirt
    create_vm_tools
}

install_virtualization() {
    log_info "Installing virtualization packages..."
    apt-get install -y \
        qemu-kvm \
        qemu-utils \
        libvirt-daemon-system \
        libvirt-clients \
        virtinst \
        bridge-utils \
        openvswitch-switch \
        openvswitch-common \
        ovn-host \
        cloud-image-utils
    
    # Add user to libvirt and kvm groups
    usermod -a -G libvirt,kvm $SUDO_USER
    
    systemctl enable --now openvswitch-switch
    systemctl enable --now libvirtd
}

configure_ovn_compute() {
    log_info "Configuring OVS bridges..."
    ovs-vsctl add-br br-int -- set Bridge br-int fail-mode=secure
    ovs-vsctl add-br br-ex -- set Bridge br-ex fail-mode=standalone
    
    # Configure OVN host
    log_info "Configuring OVN host..."
    ovs-vsctl set open . external-ids:ovn-remote=tcp://$CONTROLLER_IP:6642
    ovs-vsctl set open . external-ids:ovn-encap-type=geneve
    ovs-vsctl set open . external-ids:ovn-encap-ip=$INTERNAL_IP
    ovs-vsctl set open . external-ids:system-id=$(hostname)
    ovs-vsctl set open . external-ids:hostname=$(hostname)
    
    systemctl enable --now ovn-controller
}

configure_libvirt() {
    log_info "Configuring libvirt..."
    
    cat > /tmp/ovn-network.xml <<EOF
<network>
  <name>ovn</name>
  <forward mode='bridge'/>
  <bridge name='br-int'/>
  <virtualport type='openvswitch'/>
</network>
EOF
    
    virsh net-define /tmp/ovn-network.xml
    virsh net-start ovn
    virsh net-autostart ovn
    
    # Disable default network
    virsh net-destroy default 2>/dev/null || true
    virsh net-autostart default --disable 2>/dev/null || true
    
    # Configure storage pool
    mkdir -p /var/lib/libvirt/images
    virsh pool-define-as default dir - - - - "/var/lib/libvirt/images"
    virsh pool-start default
    virsh pool-autostart default
    
    # Download Ubuntu cloud image
    log_info "Downloading Ubuntu cloud image..."
    CLOUD_IMAGE="/var/lib/libvirt/images/ubuntu-22.04-server-cloudimg-amd64.img"
    if [[ ! -f "$CLOUD_IMAGE" ]]; then
        wget -q https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img -O "$CLOUD_IMAGE"
    fi
}

create_vm_tools() {
    log_info "Creating VM management tools..."
    
    cat > /usr/local/bin/create-vm.sh <<'EOF'
#!/bin/bash
if [[ $# -lt 4 ]]; then
    echo "Usage: $0 <vm-name> <tenant-id> <mac-address> <ip-address>"
    echo "Example: $0 vm1 1 00:00:00:00:00:01 172.16.1.10"
    exit 1
fi

VM_NAME=$1
TENANT_ID=$2
MAC_ADDR=$3
IP_ADDR=$4
TENANT_NET="tenant-$TENANT_ID-net"

# Create logical port in OVN
ovn-nbctl lsp-add $TENANT_NET ${VM_NAME}-port
ovn-nbctl lsp-set-addresses ${VM_NAME}-port "$MAC_ADDR $IP_ADDR"
ovn-nbctl lsp-set-port-security ${VM_NAME}-port "$MAC_ADDR $IP_ADDR"

# Create cloud-init ISO
CLOUD_INIT_DIR="/var/lib/libvirt/cloud-init/$VM_NAME"
mkdir -p $CLOUD_INIT_DIR

cat > $CLOUD_INIT_DIR/network-config <<NETCFG
version: 2
ethernets:
  eth0:
    match:
      macaddress: "$MAC_ADDR"
    addresses:
      - $IP_ADDR/24
    gateway4: 172.16.$TENANT_ID.1
    nameservers:
      addresses: [8.8.8.8, 1.1.1.1]
NETCFG

cat > $CLOUD_INIT_DIR/user-data <<USERDATA
#cloud-config
hostname: $VM_NAME
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh-authorized-keys:
      - ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQD... user@host
USERDATA

cloud-localds $CLOUD_INIT_DIR/cloud-init.iso $CLOUD_INIT_DIR/user-data

# Create VM
VM_IMAGE="/var/lib/libvirt/images/${VM_NAME}.qcow2"
cp /var/lib/libvirt/images/ubuntu-22.04-server-cloudimg-amd64.img $VM_IMAGE
qemu-img resize $VM_IMAGE 10G

virt-install \
    --name $VM_NAME \
    --memory 1024 \
    --vcpus 1 \
    --disk $VM_IMAGE,format=qcow2 \
    --disk $CLOUD_INIT_DIR/cloud-init.iso,device=cdrom \
    --network network=ovn,model=virtio,mac=$MAC_ADDR \
    --graphics none \
    --console pty,target_type=serial \
    --os-type linux \
    --os-variant ubuntu22.04 \
    --import \
    --noautoconsole

echo "VM $VM_NAME created"
EOF
    
    chmod +x /usr/local/bin/create-vm.sh
    
    cat > /usr/local/bin/compute-status.sh <<'EOF'
#!/bin/bash
echo "=== Compute Node Status ==="
echo "Hostname: $(hostname)"
echo "IP: $(hostname -I)"
echo ""
echo "OVS Status:"
ovs-vsctl show
echo ""
echo "Running VMs:"
virsh list
EOF
    chmod +x /usr/local/bin/compute-status.sh
    
    # Firewall rules
    ufw allow from 10.0.1.0/24  # OVN tunnel network
    ufw allow from 10.0.2.0/24  # Storage network
    ufw reload
    
    log_success "Compute installation completed"
}

# Main
load_config
run_compute_install