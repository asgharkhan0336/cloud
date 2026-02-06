#!/usr/bin/env python3
"""
config/node_config.py - Configuration management
"""

import os
import json
import yaml
import socket
import netifaces
from dataclasses import dataclass, asdict, field
from pathlib import Path
from typing import Optional, List, Dict, Any
import logging

logger = logging.getLogger(__name__)


@dataclass
class NodeConfig:
    """Node configuration data class"""
    
    # Node identity
    node_type: str = ""  # controller, compute, storage, combined
    hostname: str = ""
    
    # Network configuration
    mgmt_ip: str = ""
    internal_ip: str = ""
    storage_ip: str = ""
    physical_interface: str = ""
    
    # Controller connection (for compute/storage nodes)
    controller_ip: str = ""
    
    # Public networking (for controller nodes)
    public_ip_block: str = "203.0.113.0/24"
    public_gateway: str = "203.0.113.254"
    
    # Storage configuration
    ceph_network: str = "10.0.2.0/24"
    ceph_public_network: str = "10.0.2.0/24"
    ceph_disks: List[str] = field(default_factory=list)
    
    # Derived properties
    @property
    def mgmt_network(self) -> str:
        """Get management network from IP"""
        if self.mgmt_ip:
            parts = self.mgmt_ip.split('.')
            return f"{parts[0]}.{parts[1]}.{parts[2]}.0/24"
        return "10.0.0.0/24"
    
    @property
    def internal_network(self) -> str:
        """Get internal network from IP"""
        if self.internal_ip:
            parts = self.internal_ip.split('.')
            return f"{parts[0]}.{parts[1]}.{parts[2]}.0/24"
        return "10.0.1.0/24"
    
    @property
    def storage_network(self) -> str:
        """Get storage network from IP"""
        if self.storage_ip:
            parts = self.storage_ip.split('.')
            return f"{parts[0]}.{parts[1]}.{parts[2]}.0/24"
        return "10.0.2.0/24"
    
    @property
    def config_file(self) -> Path:
        """Get configuration file path"""
        return Path("/etc/cloud-provider/node.json")
    
    def __post_init__(self):
        """Initialize derived properties"""
        if not self.hostname:
            self.hostname = socket.gethostname()
    
    def collect_interactive(self):
        """Collect configuration interactively"""
        from utils.validators import (
            validate_ip, validate_cidr, validate_interface
        )
        
        print("\n" + "="*60)
        print("CLOUD PROVIDER CONFIGURATION")
        print("="*60)
        
        # Node type
        self.collect_node_type()
        
        # Network configuration
        self.collect_network_config()
        
        # Controller IP (for compute/storage nodes)
        if self.node_type in ['compute', 'storage']:
            self.controller_ip = self._ask_with_validation(
                "Enter controller node IP address",
                "10.0.0.10",
                validate_ip
            )
        
        # Public IP block (for controller/combined nodes)
        if self.node_type in ['controller', 'combined']:
            self.public_ip_block = self._ask_with_validation(
                "Enter public IP block (CIDR)",
                "203.0.113.0/24",
                validate_cidr
            )
            self.public_gateway = self._ask_with_validation(
                "Enter public gateway IP",
                "203.0.113.254",
                validate_ip
            )
        
        # Storage configuration
        if self.node_type in ['storage', 'combined']:
            self.collect_storage_config()
        
        # Show summary
        self.print_summary()
        
        # Confirm
        if not self._ask_yes_no("Proceed with this configuration?", default=True):
            print("Configuration cancelled")
            exit(0)
    
    def collect_node_type(self):
        """Collect node type interactively"""
        print("\nSelect node type:")
        print("  1. Controller (OVN Central, API, Monitoring)")
        print("  2. Compute (KVM, OVN Host, VM Hosting)")
        print("  3. Storage (Ceph, Object/Block Storage)")
        print("  4. Combined (Controller + Compute)")
        
        while True:
            choice = input("\nEnter choice [1-4]: ").strip()
            if choice == '1':
                self.node_type = 'controller'
                break
            elif choice == '2':
                self.node_type = 'compute'
                break
            elif choice == '3':
                self.node_type = 'storage'
                break
            elif choice == '4':
                self.node_type = 'combined'
                break
            else:
                print("Invalid choice. Please enter 1-4.")
    
    def collect_network_config(self):
        """Collect network configuration"""
        print("\nNetwork Configuration:")
        print("  VLAN 4003 (mgmt): 10.0.0.0/24")
        print("  VLAN 4001 (internal): 10.0.1.0/24")
        print("  VLAN 4002 (storage): 10.0.2.0/24")
        
        from utils.validators import validate_ip, validate_interface
        
        # Management IP
        self.mgmt_ip = self._ask_with_validation(
            "Enter management IP address (VLAN 4003)",
            "",
            validate_ip
        )
        
        # Calculate derived IPs
        ip_parts = self.mgmt_ip.split('.')
        self.internal_ip = f"10.0.1.{ip_parts[3]}"
        self.storage_ip = f"10.0.2.{ip_parts[3]}"
        
        print(f"  Internal IP (auto): {self.internal_ip}")
        print(f"  Storage IP (auto): {self.storage_ip}")
        
        # Physical interface
        detected = self._detect_network_interface()
        self.physical_interface = self._ask_with_validation(
            "Enter physical network interface",
            detected,
            validate_interface
        )
    
    def collect_storage_config(self):
        """Collect storage configuration"""
        print("\nStorage Configuration:")
        
        from utils.validators import validate_cidr
        
        self.ceph_network = self._ask_with_validation(
            "Enter Ceph cluster network",
            "10.0.2.0/24",
            validate_cidr
        )
        
        self.ceph_public_network = self._ask_with_validation(
            "Enter Ceph public network",
            "10.0.2.0/24",
            validate_cidr
        )
        
        # Show available disks
        print("\nAvailable disks (excluding system disk):")
        self._show_available_disks()
        
        disks = input("\nEnter disk names for Ceph (comma-separated, e.g., sdb,sdc): ")
        self.ceph_disks = [d.strip() for d in disks.split(',') if d.strip()]
    
    def print_summary(self):
        """Print configuration summary"""
        print("\n" + "="*60)
        print("CONFIGURATION SUMMARY")
        print("="*60)
        
        summary = f"""
        Node Type:        {self.node_type}
        Management IP:    {self.mgmt_ip}
        Internal IP:      {self.internal_ip}
        Storage IP:       {self.storage_ip}
        Physical Intf:    {self.physical_interface}
        """
        
        if self.node_type in ['compute', 'storage']:
            summary += f"        Controller IP:    {self.controller_ip}\n"
        
        if self.node_type in ['controller', 'combined']:
            summary += f"        Public IP Block:  {self.public_ip_block}\n"
            summary += f"        Public Gateway:   {self.public_gateway}\n"
        
        if self.node_type in ['storage', 'combined']:
            summary += f"        Ceph Network:     {self.ceph_network}\n"
            summary += f"        Ceph Disks:       {', '.join(self.ceph_disks)}\n"
        
        print(summary)
    
    def save(self) -> bool:
        """Save configuration to file"""
        try:
            config_dir = self.config_file.parent
            config_dir.mkdir(parents=True, exist_ok=True)
            
            # Convert to dict
            config_dict = asdict(self)
            
            # Save as JSON
            with open(self.config_file, 'w') as f:
                json.dump(config_dict, f, indent=2)
            
            # Also save as YAML for readability
            yaml_file = self.config_file.with_suffix('.yaml')
            with open(yaml_file, 'w') as f:
                yaml.dump(config_dict, f, default_flow_style=False)
            
            logger.info(f"Configuration saved to {self.config_file}")
            return True
            
        except Exception as e:
            logger.error(f"Failed to save configuration: {e}")
            return False
    
    def load(self) -> bool:
        """Load configuration from file"""
        try:
            if not self.config_file.exists():
                logger.warning(f"Configuration file not found: {self.config_file}")
                return False
            
            with open(self.config_file, 'r') as f:
                config_dict = json.load(f)
            
            # Update fields
            for key, value in config_dict.items():
                if hasattr(self, key):
                    setattr(self, key, value)
            
            logger.info(f"Configuration loaded from {self.config_file}")
            return True
            
        except Exception as e:
            logger.error(f"Failed to load configuration: {e}")
            return False
    
    def load_from_file(self, config_file: str) -> bool:
        """Load configuration from specified file"""
        try:
            config_path = Path(config_file)
            if not config_path.exists():
                logger.error(f"Configuration file not found: {config_file}")
                return False
            
            with open(config_path, 'r') as f:
                if config_path.suffix.lower() == '.yaml':
                    config_dict = yaml.safe_load(f)
                else:
                    config_dict = json.load(f)
            
            # Update fields
            for key, value in config_dict.items():
                if hasattr(self, key):
                    setattr(self, key, value)
            
            logger.info(f"Configuration loaded from {config_file}")
            return True
            
        except Exception as e:
            logger.error(f"Failed to load configuration from {config_file}: {e}")
            return False
    
    def exists(self) -> bool:
        """Check if configuration file exists"""
        return self.config_file.exists()
    
    def _ask_with_validation(self, prompt, default, validator):
        """Ask for input with validation"""
        while True:
            if default:
                value = input(f"{prompt} [{default}]: ").strip()
                if not value:
                    value = default
            else:
                value = input(f"{prompt}: ").strip()
            
            if validator(value):
                return value
            else:
                print("Invalid input. Please try again.")
    
    @staticmethod
    def _ask_yes_no(question, default=True):
        """Ask yes/no question"""
        suffix = "[Y/n]" if default else "[y/N]"
        while True:
            response = input(f"{question} {suffix}: ").strip().lower()
            if not response:
                return default
            if response in ['y', 'yes']:
                return True
            if response in ['n', 'no']:
                return False
            print("Please answer 'y' or 'n'")
    
    @staticmethod
    def _detect_network_interface() -> str:
        """Detect primary network interface"""
        try:
            # Try to get default route interface
            gateways = netifaces.gateways()
            if 'default' in gateways and netifaces.AF_INET in gateways['default']:
                interface = gateways['default'][netifaces.AF_INET][1]
                return interface
            
            # Fallback: first non-loopback interface
            interfaces = netifaces.interfaces()
            for iface in interfaces:
                if iface != 'lo' and not iface.startswith('docker') and not iface.startswith('veth'):
                    return iface
            
            return "eth0"
            
        except Exception:
            return "eth0"
    
    @staticmethod
    def _show_available_disks():
        """Show available disks"""
        import subprocess
        try:
            result = subprocess.run(
                ['lsblk', '-d', '-o', 'NAME,SIZE,TYPE,MODEL'],
                capture_output=True,
                text=True
            )
            for line in result.stdout.strip().split('\n')[1:]:  # Skip header
                if 'disk' in line.lower() and not any(x in line.lower() for x in ['sda', 'vda', 'loop', 'rom']):
                    print(f"  {line}")
        except Exception as e:
            print(f"  Error listing disks: {e}")