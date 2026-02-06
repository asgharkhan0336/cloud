#!/usr/bin/env python3
"""
phases/base_phase.py - Base phase class
"""

import abc
import logging
from pathlib import Path
from typing import Dict, Any, Optional
from datetime import datetime

from utils.shell import run_command, CommandResult
from utils.logging import PhaseLogger


class BasePhase(abc.ABC):
    """Base class for all installation phases"""
    
    def __init__(self, config):
        self.config = config
        self.name = self.__class__.__name__.replace('Phase', '').lower()
        self.logger = logging.getLogger(f"phase.{self.name}")
        self.phase_logger = PhaseLogger(self.name)
        
        # Phase metadata
        self.started_at = None
        self.completed_at = None
        self.success = False
    
    def run(self) -> bool:
        """Run the phase"""
        self.started_at = datetime.now()
        self.phase_logger.start()
        
        self.logger.info(f"Starting phase: {self.name}")
        
        try:
            # Run pre-check
            if not self.pre_check():
                self.logger.error(f"Pre-check failed for phase: {self.name}")
                return False
            
            # Execute phase
            result = self.execute()
            
            # Run post-check
            if result:
                result = self.post_check()
            
            self.success = result
            return result
            
        except Exception as e:
            self.logger.error(f"Phase '{self.name}' failed with error: {e}")
            import traceback
            self.logger.debug(traceback.format_exc())
            return False
            
        finally:
            self.completed_at = datetime.now()
            self.phase_logger.end(self.success)
            
            if self.success:
                self.logger.info(f"Phase '{self.name}' completed successfully")
            else:
                self.logger.error(f"Phase '{self.name}' failed")
    
    @abc.abstractmethod
    def execute(self) -> bool:
        """Execute phase logic - to be implemented by subclasses"""
        pass
    
    def pre_check(self) -> bool:
        """Run pre-execution checks"""
        # Default implementation - check if running as root
        import os
        if os.geteuid() != 0:
            self.logger.error("This phase must be run as root")
            return False
        return True
    
    def post_check(self) -> bool:
        """Run post-execution verification"""
        return True
    
    def run_command(self, cmd: str, check: bool = True, **kwargs) -> CommandResult:
        """Run shell command with logging"""
        self.logger.debug(f"Running command: {cmd}")
        return run_command(cmd, check=check, **kwargs)
    
    def write_file(self, path: str, content: str, mode: str = 'w'):
        """Write content to file with backup"""
        file_path = Path(path)
        
        # Backup existing file
        if file_path.exists():
            backup_path = file_path.with_suffix(f"{file_path.suffix}.backup")
            try:
                file_path.rename(backup_path)
                self.logger.debug(f"Backed up {path} to {backup_path}")
            except Exception as e:
                self.logger.warning(f"Failed to backup {path}: {e}")
        
        # Create directory if needed
        file_path.parent.mkdir(parents=True, exist_ok=True)
        
        # Write file
        with open(file_path, mode) as f:
            f.write(content)
        
        self.logger.debug(f"Wrote file: {path}")
    
    def template_render(self, template: str, **kwargs) -> str:
        """Render template with configuration"""
        context = {
            'config': self.config,
            **kwargs
        }
        
        # Simple template rendering
        result = template
        for key, value in context.items():
            if isinstance(value, dict):
                # Handle nested dicts
                for subkey, subvalue in value.items():
                    result = result.replace(f'${{config.{key}.{subkey}}}', str(subvalue))
            else:
                result = result.replace(f'${{config.{key}}}', str(value))
        
        return result
    
    def get_netplan_config(self) -> str:
        """Get Netplan configuration based on node type"""
        templates = {
            'controller': self._get_controller_netplan,
            'compute': self._get_compute_netplan,
            'storage': self._get_storage_netplan,
            'combined': self._get_combined_netplan,
        }
        
        if self.config.node_type in templates:
            return templates[self.config.node_type]()
        else:
            raise ValueError(f"Unknown node type: {self.config.node_type}")
    
    def _get_controller_netplan(self) -> str:
        return f"""network:
  version: 2
  renderer: networkd
  ethernets:
    {self.config.physical_interface}:
      dhcp4: no
      dhcp6: no
      
  vlans:
    mgmt:
      id: 4003
      link: {self.config.physical_interface}
      addresses: [{self.config.mgmt_ip}/24]
      routes:
        - to: 0.0.0.0/0
          via: 10.0.0.1
      nameservers:
        addresses: [8.8.8.8, 1.1.1.1]
      
    external:
      id: 4000
      link: {self.config.physical_interface}
      addresses: []
      mtu: 1500
      
    internal:
      id: 4001
      link: {self.config.physical_interface}
      addresses: [{self.config.internal_ip}/24]
      mtu: 9000
      
    storage:
      id: 4002
      link: {self.config.physical_interface}
      addresses: [{self.config.storage_ip}/24]
      mtu: 9000
"""
    
    def _get_compute_netplan(self) -> str:
        return f"""network:
  version: 2
  renderer: networkd
  ethernets:
    {self.config.physical_interface}:
      dhcp4: no
      dhcp6: no
      
  vlans:
    mgmt:
      id: 4003
      link: {self.config.physical_interface}
      addresses: [{self.config.mgmt_ip}/24]
      routes:
        - to: 0.0.0.0/0
          via: 10.0.0.1
      nameservers:
        addresses: [8.8.8.8, 1.1.1.1]
      
    internal:
      id: 4001
      link: {self.config.physical_interface}
      addresses: [{self.config.internal_ip}/24]
      mtu: 9000
      
    storage:
      id: 4002
      link: {self.config.physical_interface}
      addresses: [{self.config.storage_ip}/24]
      mtu: 9000
"""
    
    def _get_storage_netplan(self) -> str:
        return f"""network:
  version: 2
  renderer: networkd
  ethernets:
    {self.config.physical_interface}:
      dhcp4: no
      dhcp6: no
      
  vlans:
    mgmt:
      id: 4003
      link: {self.config.physical_interface}
      addresses: [{self.config.mgmt_ip}/24]
      routes:
        - to: 0.0.0.0/0
          via: 10.0.0.1
      nameservers:
        addresses: [8.8.8.8, 1.1.1.1]
      
    storage:
      id: 4002
      link: {self.config.physical_interface}
      addresses: [{self.config.storage_ip}/24]
      mtu: 9000
"""
    
    def _get_combined_netplan(self) -> str:
        return self._get_controller_netplan()