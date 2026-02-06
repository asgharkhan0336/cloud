#!/bin/bash
# /opt/cloud-provider/phases/03-controller.sh

source "$(dirname "$0")/../lib/common.sh"

run_controller_install() {
    log_header "Controller Installation"
    
    # Only run if node type is controller or combined
    if [[ "$NODE_TYPE" != "controller" && "$NODE_TYPE" != "combined" ]]; then
        log_info "Skipping controller installation (node type: $NODE_TYPE)"
        return 0
    fi
    
    install_ovn
    configure_ovn_controller
    install_metadata_service
    install_management_api
    install_monitoring
    create_utilities
}

install_ovn() {
    log_info "Installing OVS and OVN..."
    apt-get install -y \
        openvswitch-switch \
        openvswitch-common \
        ovn-central \
        ovn-host \
        python3-netifaces \
        python3-ovsdbapp
    
    systemctl enable --now openvswitch-switch
    systemctl enable --now ovn-northd
}

configure_ovn_controller() {
    log_info "Configuring OVS bridges..."
    ovs-vsctl add-br br-int -- set Bridge br-int fail-mode=secure
    ovs-vsctl add-br br-ex -- set Bridge br-ex fail-mode=standalone
    
    # Add external VLAN interface to br-ex
    ovs-vsctl add-port br-ex external \
        vlan_mode=trunk \
        trunks=4000 \
        -- set interface external type=internal
    
    # Set IP on br-ex for management
    ip addr add "${MGMT_IP%.*}.100/24" dev br-ex 2>/dev/null || true
    ip link set br-ex up
    
    # Create patch ports
    ovs-vsctl add-port br-int patch-br-ex-to-int \
        -- set interface patch-br-ex-to-int type=patch \
        options:peer=patch-br-int-to-ex
    ovs-vsctl add-port br-ex patch-br-int-to-ex \
        -- set interface patch-br-int-to-ex type=patch \
        options:peer=patch-br-ex-to-int
    
    # Configure OVN databases
    log_info "Configuring OVN databases..."
    ovn-nbctl set-connection ptcp:6641:$MGMT_IP
    ovn-sbctl set-connection ptcp:6642:$MGMT_IP
    
    # Create provider networks
    log_info "Creating provider networks..."
    ovn-nbctl ls-add external-net
    ovn-nbctl lsp-add external-net external-localnet
    ovn-nbctl lsp-set-type external-localnet localnet
    ovn-nbctl lsp-set-addresses external-localnet unknown
    ovn-nbctl lsp-set-options external-localnet network_name=external
    
    # Public router
    ovn-nbctl lr-add public-router
    ovn-nbctl lrp-add public-router public-to-external 02:00:00:00:00:01 $PUBLIC_GATEWAY/24
    
    # Connect router to external network
    ovn-nbctl lsp-add external-net external-router-lsp
    ovn-nbctl lsp-set-type external-router-lsp router
    ovn-nbctl lsp-set-addresses external-router-lsp router
    ovn-nbctl lsp-set-options external-router-lsp router-port=public-to-external
}

install_metadata_service() {
    log_info "Installing metadata service..."
    apt-get install -y python3-flask
    
    mkdir -p /opt/cloud-provider/metadata/store
    cat > /opt/cloud-provider/metadata/metadata.py <<'EOF'
#!/usr/bin/env python3
from flask import Flask, jsonify
import json
import os

app = Flask(__name__)
METADATA_DIR = "/opt/cloud-provider/metadata/store"

@app.route('/<version>/meta-data/<instance_id>')
def get_metadata(version, instance_id):
    meta_file = os.path.join(METADATA_DIR, instance_id, "meta-data.json")
    if os.path.exists(meta_file):
        with open(meta_file, 'r') as f:
            return jsonify(json.load(f))
    return jsonify({"instance-id": instance_id, "hostname": instance_id})

@app.route('/<version>/user-data/<instance_id>')
def get_userdata(version, instance_id):
    user_file = os.path.join(METADATA_DIR, instance_id, "user-data")
    if os.path.exists(user_file):
        with open(user_file, 'r') as f:
            return f.read(), 200, {'Content-Type': 'text/plain'}
    return "#cloud-config\nusers:\n  - name: ubuntu\n    sudo: ALL=(ALL) NOPASSWD:ALL", 200

@app.route('/health')
def health():
    return "OK", 200

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=80, debug=False)
EOF
    
    chmod +x /opt/cloud-provider/metadata/metadata.py
    
    cat > /etc/systemd/system/metadata.service <<EOF
[Unit]
Description=Cloud Provider Metadata Service
After=network.target

[Service]
Type=simple
User=nobody
Group=nogroup
WorkingDirectory=/opt/cloud-provider/metadata
ExecStart=/usr/bin/python3 /opt/cloud-provider/metadata/metadata.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable --now metadata.service
}

install_management_api() {
    log_info "Installing management API..."
    apt-get install -y python3-fastapi python3-uvicorn python3-sqlalchemy
    
    mkdir -p /opt/cloud-provider/api
    cat > /opt/cloud-provider/api/main.py <<'EOF'
from fastapi import FastAPI
app = FastAPI(title="Cloud Provider API")

@app.get("/")
def read_root():
    return {"status": "online", "service": "cloud-provider"}

@app.get("/health")
def health_check():
    return {"status": "healthy"}
EOF
    
    cat > /etc/systemd/system/cloud-api.service <<EOF
[Unit]
Description=Cloud Provider Management API
After=network.target metadata.service

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=/opt/cloud-provider/api
ExecStart=/usr/bin/uvicorn main:app --host 0.0.0.0 --port 8000
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl enable --now cloud-api.service
}

install_monitoring() {
    log_info "Installing monitoring stack..."
    
    # Prometheus
    apt-get install -y prometheus
    cat > /etc/prometheus/prometheus.yml <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'node'
    static_configs:
      - targets: ['$MGMT_IP:9100']
        
  - job_name: 'api'
    static_configs:
      - targets: ['$MGMT_IP:8000']
EOF
    systemctl enable --now prometheus
    
    # Grafana
    wget -q -O - https://packages.grafana.com/gpg.key | apt-key add -
    echo "deb https://packages.grafana.com/oss/deb stable main" > /etc/apt/sources.list.d/grafana.list
    apt-get update
    apt-get install -y grafana
    systemctl enable --now grafana-server
    
    # OVN metrics exporter
    git clone https://github.com/ovn-org/ovn-metrics.git /opt/ovn-metrics 2>/dev/null || true
    pip3 install -r /opt/ovn-metrics/requirements.txt 2>/dev/null || true
    
    cat > /etc/systemd/system/ovn-metrics.service <<EOF
[Unit]
Description=OVN Metrics Exporter
After=ovn-northd.service

[Service]
Type=simple
User=nobody
Group=nogroup
WorkingDirectory=/opt/ovn-metrics
ExecStart=/usr/bin/python3 /opt/ovn-metrics/ovn_metrics_exporter.py \
    --ovn-nb-host 127.0.0.1 \
    --ovn-nb-port 6641 \
    --ovn-sb-host 127.0.0.1 \
    --ovn-sb-port 6642 \
    --listen-port 9473
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl enable --now ovn-metrics.service
    
    # Firewall rules
    ufw allow from 10.0.0.0/24 to any port 6641  # OVN NB
    ufw allow from 10.0.0.0/24 to any port 6642  # OVN SB
    ufw allow from 10.0.0.0/24 to any port 8000  # API
    ufw allow from 10.0.0.0/24 to any port 9090  # Prometheus
    ufw allow from 10.0.0.0/24 to any port 3000  # Grafana
    ufw allow from 10.0.1.0/24  # OVN tunnel network
    ufw reload
}

create_utilities() {
    log_info "Creating utility scripts..."
    
    cat > /usr/local/bin/create-tenant.sh <<'EOF'
#!/bin/bash
if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <tenant-id> <subnet>"
    echo "Example: $0 1 172.16.1.0/24"
    exit 1
fi

TENANT_ID=$1
SUBNET=$2
TENANT_NAME="tenant-$TENANT_ID"
GATEWAY=$(echo $SUBNET | sed 's/0\/.*/1/')

ovn-nbctl lr-add $TENANT_NAME-router
ovn-nbctl ls-add $TENANT_NAME-net

ovn-nbctl lrp-add $TENANT_NAME-router $TENANT_NAME-router-port 02:01:00:00:00:$TENANT_ID $GATEWAY/24
ovn-nbctl lsp-add $TENANT_NAME-net $TENANT_NAME-switch-port
ovn-nbctl lsp-set-type $TENANT_NAME-switch-port router
ovn-nbctl lsp-set-addresses $TENANT_NAME-switch-port router
ovn-nbctl lsp-set-options $TENANT_NAME-switch-port router-port=$TENANT_NAME-router-port

ovn-nbctl lrp-add public-router public-to-$TENANT_NAME 02:02:00:00:00:$TENANT_ID 192.168.100.$((TENANT_ID + 10))/24
ovn-nbctl lrp-add $TENANT_NAME-router $TENANT_NAME-to-public 02:03:00:00:00:$TENANT_ID 192.168.100.$((TENANT_ID + 100))/24

ovn-nbctl lr-route-add public-router $SUBNET 192.168.100.$((TENANT_ID + 100))
ovn-nbctl lr-route-add $TENANT_NAME-router 0.0.0.0/0 192.168.100.$((TENANT_ID + 10))

echo "Created tenant $TENANT_NAME with network $SUBNET"
EOF
    
    chmod +x /usr/local/bin/create-tenant.sh
    
    cat > /usr/local/bin/ovn-status.sh <<'EOF'
#!/bin/bash
echo "=== OVN Status ==="
ovn-nbctl show
echo ""
echo "=== Chassis ==="
ovn-sbctl list chassis
EOF
    chmod +x /usr/local/bin/ovn-status.sh
    
    log_success "Controller installation completed"
}

# Main
load_config
run_controller_install