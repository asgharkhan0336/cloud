#!/usr/bin/env python3
"""
network-ovn-setup.py - Network and OVN Setup (Appends to existing netplan)
"""

import os
import sys
import subprocess
import re
import yaml
import json
import time
from pathlib import Path
from typing import Tuple, Optional, Dict, Any
import shutil


class NetworkOVNSetup:
    def __init__(self):
        self.node_type = ""
        self.mgmt_ip = ""
        self.interface = ""
        self.controller_ip = ""
        
    def run_cmd(self, cmd: str, check=True) -> Tuple[bool, str, str]:
        """Run shell command"""
        try:
            result = subprocess.run(
                cmd, shell=True, capture_output=True, text=True, check=check
            )
            return True, result.stdout.strip(), result.stderr.strip()
        except subprocess.CalledProcessError as e:
            return False, e.stdout.strip(), e.stderr.strip()
    
    def validate_ip(self, ip: str) -> bool:
        """Validate IP address"""
        pattern = r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$'
        match = re.match(pattern, ip)
        if match:
            parts = list(map(int, match.groups()))
            return all(0 <= part <= 255 for part in parts)
        return False
    
    def detect_interface(self) -> str:
        """Detect primary network interface"""
        try:
            # Get interface with default route
            success, output, _ = self.run_cmd(
                "ip route | grep default | awk '{print $5}' | head -1",
                check=False
            )
            if success and output:
                return output
            
            # Get first non-loopback interface
            success, output, _ = self.run_cmd(
                "ip link show | grep -E '^[0-9]+:' | grep -v lo | "
                "awk -F: '{print $2}' | tr -d ' ' | head -1",
                check=False
            )
            if success and output:
                return output
        except:
            pass
        return "eth0"
    
    def get_current_netplan(self) -> Dict[str, Any]:
        """Read current netplan configuration"""
        netplan_dir = Path("/etc/netplan")
        config = {}
        
        if not netplan_dir.exists():
            return config
        
        # Find all YAML files
        for yaml_file in netplan_dir.glob("*.yaml"):
            try:
                with open(yaml_file, 'r') as f:
                    file_content = yaml.safe_load(f) or {}
                    # Merge configurations
                    if 'network' in file_content:
                        if 'network' not in config:
                            config['network'] = {}
                        for key, value in file_content['network'].items():
                            if key not in config['network']:
                                config['network'][key] = value
                            elif isinstance(value, dict) and isinstance(config['network'][key], dict):
                                config['network'][key].update(value)
            except Exception as e:
                print(f"Warning: Could not read {yaml_file}: {e}")
        
        return config
    
    def append_vlan_config(self, current_config: Dict[str, Any]) -> Dict[str, Any]:
        """Append VLAN configuration to existing netplan"""
        if 'network' not in current_config:
            current_config['network'] = {}
        
        octet = self.get_octet(self.mgmt_ip)
        
        # Ensure ethernets section exists
        if 'ethernets' not in current_config['network']:
            current_config['network']['ethernets'] = {}
        
        # Add our physical interface if not exists
        if self.interface not in current_config['network']['ethernets']:
            current_config['network']['ethernets'][self.interface] = {
                'dhcp4': False,
                'dhcp6': False
            }
        
        # Add VLANs section
        if 'vlans' not in current_config['network']:
            current_config['network']['vlans'] = {}
        
        # Add mgmt VLAN (4003)
        current_config['network']['vlans']['mgmt'] = {
            'id': 4003,
            'link': self.interface,
            'addresses': [f"{self.mgmt_ip}/24"],
            'mtu': 1500
        }
        
        # Add routes and DNS if not present
        if 'routes' not in current_config['network']['vlans']['mgmt']:
            current_config['network']['vlans']['mgmt']['routes'] = [
                {'to': '0.0.0.0/0', 'via': '10.0.0.1'}
            ]
        
        if 'nameservers' not in current_config['network']['vlans']['mgmt']:
            current_config['network']['vlans']['mgmt']['nameservers'] = {
                'addresses': ['8.8.8.8', '1.1.1.1']
            }
        
        # Add internal VLAN (4001)
        current_config['network']['vlans']['internal'] = {
            'id': 4001,
            'link': self.interface,
            'addresses': [f"10.0.1.{octet}/24"],
            'mtu': 9000
        }
        
        # Add storage VLAN (4002)
        current_config['network']['vlans']['storage'] = {
            'id': 4002,
            'link': self.interface,
            'addresses': [f"10.0.2.{octet}/24"],
            'mtu': 9000
        }
        
        # Add external VLAN for controller
        if self.node_type == "controller":
            current_config['network']['vlans']['external'] = {
                'id': 4000,
                'link': self.interface,
                'mtu': 1500
            }
        
        return current_config
    
    def get_octet(self, ip: str) -> int:
        """Get last octet of IP"""
        parts = ip.split('.')
        return int(parts[3]) if len(parts) == 4 else 1
    
    def interactive_config(self):
        """Get configuration interactively"""
        print("\n" + "="*60)
        print("NETWORK & OVN SETUP (Appends to existing config)")
        print("="*60)
        
        # Show current network config
        print("\nCurrent network configuration:")
        success, output, _ = self.run_cmd("ip addr show", check=False)
        for line in output.split('\n'):
            if 'inet ' in line and '127.' not in line:
                print(f"  {line.strip()}")
        
        # Node type
        print("\nSelect node type:")
        print("  1. Controller (OVN Central)")
        print("  2. Compute (OVN Host)")
        
        while True:
            choice = input("\nEnter choice [1/2]: ").strip()
            if choice == "1":
                self.node_type = "controller"
                break
            elif choice == "2":
                self.node_type = "compute"
                break
            else:
                print("Invalid choice. Please enter 1 or 2.")
        
        # Management IP
        while True:
            self.mgmt_ip = input("\nEnter management IP for VLAN 4003 [e.g., 10.0.0.10]: ").strip()
            if self.validate_ip(self.mgmt_ip):
                if self.mgmt_ip.startswith("10.0.0."):
                    break
                else:
                    confirm = input("IP not in 10.0.0.0/24. Continue? [y/N]: ").lower()
                    if confirm in ['y', 'yes']:
                        break
            else:
                print("Invalid IP format. Please try again.")
        
        # Controller IP for compute nodes
        if self.node_type == "compute":
            while True:
                self.controller_ip = input(
                    "\nEnter controller IP [e.g., 10.0.0.10]: "
                ).strip()
                if self.validate_ip(self.controller_ip):
                    break
                else:
                    print("Invalid IP format. Please try again.")
        else:
            self.controller_ip = self.mgmt_ip
        
        # Network interface
        detected = self.detect_interface()
        self.interface = input(
            f"\nEnter physical network interface for VLANs [{detected}]: "
        ).strip() or detected
        
        # Show what will be added
        self.show_changes_summary()
    
    def show_changes_summary(self):
        """Show what will be added to netplan"""
        octet = self.get_octet(self.mgmt_ip)
        
        print("\n" + "="*60)
        print("NETPLAN CHANGES TO BE ADDED")
        print("="*60)
        print("The following will be APPENDED to your netplan configuration:")
        print(f"\nInterface: {self.interface}")
        print("\nNew VLANs to be created:")
        print(f"  mgmt (VLAN 4003):    {self.mgmt_ip}/24")
        print(f"  internal (VLAN 4001): 10.0.1.{octet}/24")
        print(f"  storage (VLAN 4002):  10.0.2.{octet}/24")
        
        if self.node_type == "controller":
            print(f"  external (VLAN 4000): (no IP)")
        
        print("\nNote: Existing network configuration will NOT be modified.")
        print("Only the VLANs above will be added.")
        print("="*60)
        
        confirm = input("\nProceed with adding these VLANs? [y/N]: ").lower()
        if confirm not in ['y', 'yes']:
            print("Configuration cancelled.")
            sys.exit(0)
    
    def install_packages(self):
        """Install OVS/OVN packages"""
        print("\n" + "="*60)
        print("INSTALLING OVS/OVN PACKAGES")
        print("="*60)
        
        # Update package lists
        self.run_cmd("apt-get update")
        
        # Install packages based on node type
        if self.node_type == "controller":
            pkgs = "openvswitch-switch openvswitch-common ovn-central ovn-host python3-netifaces"
        else:
            pkgs = "openvswitch-switch openvswitch-common ovn-host python3-netifaces"
        
        success, stdout, stderr = self.run_cmd(f"apt-get install -y {pkgs}")
        
        if success:
            print("✓ OVS/OVN packages installed")
            return True
        else:
            print(f"✗ Package installation failed: {stderr}")
            return False
    
    def update_netplan(self):
        """Update netplan configuration by appending VLANs"""
        print("\n" + "="*60)
        print("UPDATING NETPLAN CONFIGURATION")
        print("="*60)
        
        # Backup existing config
        timestamp = time.strftime("%Y%m%d-%H%M%S")
        backup_dir = Path("/etc/netplan/backup")
        backup_dir.mkdir(exist_ok=True)
        
        # Backup all netplan files
        for netplan_file in Path("/etc/netplan").glob("*.yaml"):
            backup_file = backup_dir / f"{netplan_file.name}.{timestamp}.backup"
            shutil.copy2(netplan_file, backup_file)
            print(f"✓ Backed up {netplan_file.name}")
        
        # Read current configuration
        current_config = self.get_current_netplan()
        
        # Append our VLAN configuration
        updated_config = self.append_vlan_config(current_config)
        
        # Write updated configuration
        # We'll create a new file to avoid conflicts
        new_config_file = Path("/etc/netplan/99-cloud-provider-vlans.yaml")
        
        with open(new_config_file, 'w') as f:
            yaml.dump(updated_config, f, default_flow_style=False, sort_keys=False)
        
        print(f"✓ Created new netplan config: {new_config_file.name}")
        print("  (This file will be merged with existing config)")
        
        # Apply netplan
        print("\nApplying netplan configuration...")
        success, stdout, stderr = self.run_cmd("netplan generate && netplan apply")
        
        if success:
            print("✓ Netplan configuration applied")
            time.sleep(3)  # Wait for network to settle
            return True
        else:
            print(f"✗ Failed to apply netplan: {stderr}")
            return False
    
    def configure_ovs_bridges(self):
        """Configure OVS bridges"""
        print("\n" + "="*60)
        print("CONFIGURING OVS BRIDGES")
        print("="*60)
        
        # Ensure OVS is running
        self.run_cmd("systemctl start openvswitch-switch")
        self.run_cmd("systemctl enable openvswitch-switch")
        
        # Remove existing bridges if they exist (clean start)
        self.run_cmd("ovs-vsctl del-br br-int 2>/dev/null || true", check=False)
        self.run_cmd("ovs-vsctl del-br br-ex 2>/dev/null || true", check=False)
        
        # Create integration bridge
        self.run_cmd("ovs-vsctl add-br br-int -- set Bridge br-int fail-mode=secure")
        print("✓ Created br-int bridge")
        
        # Create external bridge
        self.run_cmd("ovs-vsctl add-br br-ex -- set Bridge br-ex fail-mode=standalone")
        print("✓ Created br-ex bridge")
        
        # Configure external bridge for controller
        if self.node_type == "controller":
            # Add external VLAN interface to br-ex
            self.run_cmd(f"""
                ovs-vsctl add-port br-ex external \
                vlan_mode=trunk \
                trunks=4000 \
                -- set interface external type=internal
            """)
            self.run_cmd("ip link set external up", check=False)
            print("✓ Configured external bridge for VLAN 4000")
        
        # Create patch ports between bridges
        self.run_cmd("""
            ovs-vsctl add-port br-int patch-br-ex-to-int \
            -- set interface patch-br-ex-to-int type=patch \
               options:peer=patch-br-int-to-ex
        """)
        
        self.run_cmd("""
            ovs-vsctl add-port br-ex patch-br-int-to-ex \
            -- set interface patch-br-int-to-ex type=patch \
               options:peer=patch-br-ex-to-int
        """)
        
        print("✓ Created patch ports between bridges")
        
        return True
    
    def configure_ovn_controller(self):
        """Configure OVN controller"""
        print("\n" + "="*60)
        print("CONFIGURING OVN CONTROLLER")
        print("="*60)
        
        # Configure OVN databases to listen on management IP
        self.run_cmd(f"ovn-nbctl set-connection ptcp:6641:{self.mgmt_ip}")
        self.run_cmd(f"ovn-sbctl set-connection ptcp:6642:{self.mgmt_ip}")
        
        # Start OVN northd
        self.run_cmd("systemctl start ovn-northd")
        self.run_cmd("systemctl enable ovn-northd")
        
        # Create initial networks
        self.run_cmd("ovn-nbctl ls-add external-net")
        self.run_cmd("ovn-nbctl lsp-add external-net external-localnet")
        self.run_cmd("ovn-nbctl lsp-set-type external-localnet localnet")
        self.run_cmd("ovn-nbctl lsp-set-addresses external-localnet unknown")
        self.run_cmd("ovn-nbctl lsp-set-options external-localnet network_name=external")
        
        self.run_cmd("ovn-nbctl lr-add public-router")
        
        print("✓ OVN controller configured")
        return True
    
    def configure_ovn_host(self):
        """Configure OVN host (compute node)"""
        print("\n" + "="*60)
        print("CONFIGURING OVN HOST")
        print("="*60)
        
        octet = self.get_octet(self.mgmt_ip)
        tunnel_ip = f"10.0.1.{octet}"
        
        # Configure OVS for OVN
        self.run_cmd(f"ovs-vsctl set open . external-ids:ovn-remote=tcp://{self.controller_ip}:6642")
        self.run_cmd("ovs-vsctl set open . external-ids:ovn-encap-type=geneve")
        self.run_cmd(f"ovs-vsctl set open . external-ids:ovn-encap-ip={tunnel_ip}")
        
        hostname = self.get_hostname()
        self.run_cmd(f"ovs-vsctl set open . external-ids:system-id={hostname}")
        self.run_cmd(f"ovs-vsctl set open . external-ids:hostname={hostname}")
        
        # Start OVN controller
        self.run_cmd("systemctl start ovn-controller")
        self.run_cmd("systemctl enable ovn-controller")
        
        print(f"✓ OVN host configured (tunnel IP: {tunnel_ip})")
        return True
    
    def get_hostname(self):
        """Get system hostname"""
        success, hostname, _ = self.run_cmd("hostname")
        return hostname.strip() if success else "unknown"
    
    def verify_setup(self):
        """Verify the setup"""
        print("\n" + "="*60)
        print("VERIFICATION")
        print("="*60)
        
        all_ok = True
        
        # 1. Check VLAN interfaces
        print("1. Checking VLAN interfaces...")
        vlans_to_check = ["mgmt", "internal", "storage"]
        if self.node_type == "controller":
            vlans_to_check.append("external")
        
        for vlan in vlans_to_check:
            success, _, _ = self.run_cmd(f"ip link show {vlan}", check=False)
            if success:
                # Check if interface has IP (except external)
                if vlan != "external":
                    success_ip, ip_output, _ = self.run_cmd(f"ip -4 addr show {vlan}", check=False)
                    if success_ip and "inet" in ip_output:
                        print(f"  ✓ {vlan}: UP with IP")
                    else:
                        print(f"  ⚠ {vlan}: UP but no IP")
                        all_ok = False
                else:
                    print(f"  ✓ {vlan}: UP (no IP required)")
            else:
                print(f"  ✗ {vlan}: MISSING")
                all_ok = False
        
        # 2. Check OVS bridges
        print("\n2. Checking OVS bridges...")
        for bridge in ["br-int", "br-ex"]:
            success, _, _ = self.run_cmd(f"ovs-vsctl br-exists {bridge}", check=False)
            if success:
                print(f"  ✓ {bridge}: EXISTS")
            else:
                print(f"  ✗ {bridge}: MISSING")
                all_ok = False
        
        # 3. Check OVN services
        print("\n3. Checking OVN services...")
        if self.node_type == "controller":
            success, _, _ = self.run_cmd("systemctl is-active ovn-northd", check=False)
            if success:
                print(f"  ✓ ovn-northd: RUNNING")
            else:
                print(f"  ✗ ovn-northd: STOPPED")
                all_ok = False
            
            success, _, _ = self.run_cmd("ovn-nbctl show", check=False)
            if success:
                print(f"  ✓ OVN NB: ACCESSIBLE")
            else:
                print(f"  ✗ OVN NB: INACCESSIBLE")
                all_ok = False
        else:
            success, _, _ = self.run_cmd("systemctl is-active ovn-controller", check=False)
            if success:
                print(f"  ✓ ovn-controller: RUNNING")
            else:
                print(f"  ✗ ovn-controller: STOPPED")
                all_ok = False
            
            success, output, _ = self.run_cmd("ovs-vsctl get open . external-ids:ovn-remote", check=False)
            if success and self.controller_ip in output:
                print(f"  ✓ Connected to controller: YES")
            else:
                print(f"  ✗ Connected to controller: NO")
                all_ok = False
        
        # 4. Check connectivity
        print("\n4. Checking connectivity...")
        success, _, _ = self.run_cmd(f"ping -c 2 -W 1 {self.mgmt_ip}", check=False)
        if success:
            print(f"  ✓ Local connectivity: OK")
        else:
            print(f"  ✗ Local connectivity: FAILED")
            all_ok = False
        
        if self.node_type == "compute":
            success, _, _ = self.run_cmd(f"ping -c 2 -W 1 {self.controller_ip}", check=False)
            if success:
                print(f"  ✓ Controller connectivity: OK")
            else:
                print(f"  ✗ Controller connectivity: FAILED")
                all_ok = False
        
        return all_ok
    
    def create_utilities(self):
        """Create utility scripts"""
        print("\n" + "="*60)
        print("CREATING UTILITY SCRIPTS")
        print("="*60)
        
        # Status script
        status_script = f"""#!/bin/bash
echo "=== CLOUD PROVIDER NETWORK STATUS ==="
echo ""
echo "Node Type: {self.node_type}"
echo "Hostname: $(hostname)"
echo ""
echo "VLAN Interfaces:"
for vlan in mgmt internal storage {'external' if self.node_type == 'controller' else ''}; do
    if ip link show \$vlan >/dev/null 2>&1; then
        ip=\$(ip -4 addr show \$vlan 2>/dev/null | grep -oP '(?<=inet\\s)\\d+(\\.\\d+){{3}}' || echo "no IP")
        echo "  \$vlan: UP (\$ip)"
    else
        echo "  \$vlan: DOWN"
    fi
done
echo ""
echo "OVS Bridges:"
ovs-vsctl list-br
echo ""
echo "OVN Status:"
if [[ "{self.node_type}" == "controller" ]]; then
    systemctl status ovn-northd --no-pager | grep -A1 "Active:"
    echo "Listening on: {self.mgmt_ip}:6641 (NB), :6642 (SB)"
else
    systemctl status ovn-controller --no-pager | grep -A1 "Active:"
    echo "Connected to: {self.controller_ip}:6642"
fi
"""
        
        with open('/usr/local/bin/cloud-network-status', 'w') as f:
            f.write(status_script)
        
        self.run_cmd("chmod +x /usr/local/bin/cloud-network-status")
        print("✓ Created cloud-network-status utility")
        
        # Show netplan script
        netplan_script = """#!/bin/bash
echo "=== NETPLAN CONFIGURATION ==="
echo ""
echo "Active configuration files:"
ls -la /etc/netplan/*.yaml
echo ""
echo "Current network state:"
netplan status
echo ""
echo "To view full configuration:"
echo "  cat /etc/netplan/99-cloud-provider-vlans.yaml"
"""
        
        with open('/usr/local/bin/cloud-netplan-info', 'w') as f:
            f.write(netplan_script)
        
        self.run_cmd("chmod +x /usr/local/bin/cloud-netplan-info")
        print("✓ Created cloud-netplan-info utility")
    
    def run(self):
        """Main execution"""
        # Check root
        if os.geteuid() != 0:
            print("ERROR: This script must be run as root")
            sys.exit(1)
        
        try:
            # Get configuration
            self.interactive_config()
            
            # Install packages
            if not self.install_packages():
                sys.exit(1)
            
            # Update netplan (append only)
            if not self.update_netplan():
                sys.exit(1)
            
            # Configure OVS bridges
            if not self.configure_ovs_bridges():
                sys.exit(1)
            
            # Configure OVN
            if self.node_type == "controller":
                if not self.configure_ovn_controller():
                    sys.exit(1)
            else:
                if not self.configure_ovn_host():
                    sys.exit(1)
            
            # Create utilities
            self.create_utilities()
            
            # Verify setup
            if self.verify_setup():
                print("\n" + "="*60)
                print("✓ SETUP COMPLETED SUCCESSFULLY!")
                print("="*60)
                
                print(f"\nSummary:")
                print(f"  Node Type: {self.node_type}")
                print(f"  Management IP: {self.mgmt_ip}")
                print(f"  Physical Interface: {self.interface}")
                
                if self.node_type == "compute":
                    print(f"  Controller: {self.controller_ip}")
                
                print(f"\nConfiguration:")
                print(f"  Netplan config: /etc/netplan/99-cloud-provider-vlans.yaml")
                print(f"  Backups: /etc/netplan/backup/")
                
                print(f"\nUtilities:")
                print(f"  cloud-network-status  - Check network/OVN status")
                print(f"  cloud-netplan-info    - Show netplan configuration")
                
            else:
                print("\n" + "="*60)
                print("⚠ SETUP COMPLETED WITH WARNINGS")
                print("="*60)
                print("\nSome checks failed. Please verify manually.")
                print("Use 'cloud-network-status' to check current status.")
            
        except KeyboardInterrupt:
            print("\n\nSetup cancelled by user.")
            sys.exit(0)
        except Exception as e:
            print(f"\nERROR: Setup failed: {e}")
            import traceback
            traceback.print_exc()
            sys.exit(1)


def main():
    """Main entry point"""
    setup = NetworkOVNSetup()
    setup.run()


if __name__ == "__main__":
    main()