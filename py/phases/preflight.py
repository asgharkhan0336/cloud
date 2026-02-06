#!/usr/bin/env python3
"""
phases/preflight.py - Preflight checks phase
"""

import sys
import platform
import shutil
from pathlib import Path

from .base_phase import BasePhase


class PreflightPhase(BasePhase):
    """Preflight checks phase"""
    
    def execute(self) -> bool:
        self.logger.info("Running preflight checks...")
        
        checks = [
            self._check_os,
            self._check_cpu_virtualization,
            self._check_memory,
            self._check_disk_space,
            self._check_network,
            self._check_existing_installation,
        ]
        
        all_passed = True
        for check_func in checks:
            if not check_func():
                all_passed = False
                if self.config.node_type in ['compute', 'combined']:
                    self.logger.warning("Check failed, but continuing...")
                else:
                    self.logger.error("Critical check failed")
                    return False
        
        return all_passed
    
    def _check_os(self) -> bool:
        """Check OS requirements"""
        self.logger.info("Checking OS...")
        
        # Check if Ubuntu 22.04
        try:
            with open('/etc/os-release', 'r') as f:
                os_release = f.read()
            
            if 'Ubuntu' in os_release and '22.04' in os_release:
                self.logger.info("✓ OS: Ubuntu 22.04 LTS")
                return True
            else:
                self.logger.error("✗ OS: Not Ubuntu 22.04 LTS")
                return False
                
        except FileNotFoundError:
            self.logger.error("✗ Cannot determine OS")
            return False
    
    def _check_cpu_virtualization(self) -> bool:
        """Check CPU virtualization support"""
        self.logger.info("Checking CPU virtualization...")
        
        try:
            with open('/proc/cpuinfo', 'r') as f:
                cpuinfo = f.read()
            
            if 'vmx' in cpuinfo or 'svm' in cpuinfo:
                self.logger.info("✓ CPU virtualization: Supported")
                return True
            else:
                self.logger.warning("⚠ CPU virtualization: Not detected (KVM may not work)")
                return True  # Not critical for controller/storage nodes
                
        except Exception as e:
            self.logger.warning(f"⚠ Could not check CPU virtualization: {e}")
            return True
    
    def _check_memory(self) -> bool:
        """Check memory requirements"""
        self.logger.info("Checking memory...")
        
        try:
            with open('/proc/meminfo', 'r') as f:
                for line in f:
                    if 'MemTotal' in line:
                        mem_kb = int(line.split()[1])
                        mem_gb = mem_kb / 1024 / 1024
                        
                        min_memory = {
                            'controller': 4,
                            'compute': 8,
                            'storage': 8,
                            'combined': 12,
                        }.get(self.config.node_type, 4)
                        
                        if mem_gb >= min_memory:
                            self.logger.info(f"✓ Memory: {mem_gb:.1f}GB (≥ {min_memory}GB required)")
                            return True
                        else:
                            self.logger.warning(
                                f"⚠ Memory: {mem_gb:.1f}GB (< {min_memory}GB recommended)"
                            )
                            return True  # Not critical, but warn
                        
            self.logger.warning("⚠ Could not determine memory size")
            return True
            
        except Exception as e:
            self.logger.warning(f"⚠ Could not check memory: {e}")
            return True
    
    def _check_disk_space(self) -> bool:
        """Check disk space"""
        self.logger.info("Checking disk space...")
        
        try:
            stat = shutil.disk_usage('/')
            free_gb = stat.free / (1024**3)
            
            min_free = {
                'controller': 20,
                'compute': 50,
                'storage': 100,
                'combined': 70,
            }.get(self.config.node_type, 20)
            
            if free_gb >= min_free:
                self.logger.info(f"✓ Disk space: {free_gb:.1f}GB free (≥ {min_free}GB required)")
                return True
            else:
                self.logger.warning(f"⚠ Disk space: {free_gb:.1f}GB free (< {min_free}GB recommended)")
                return True  # Not critical, but warn
                
        except Exception as e:
            self.logger.warning(f"⚠ Could not check disk space: {e}")
            return True
    
    def _check_network(self) -> bool:
        """Check network connectivity"""
        self.logger.info("Checking network connectivity...")
        
        # Try to ping Google DNS
        result = self.run_command("ping -c 2 -W 1 8.8.8.8", check=False)
        
        if result.success:
            self.logger.info("✓ Network connectivity: OK")
        else:
            self.logger.warning("⚠ Network connectivity: No internet access")
        
        return True  # Not critical
    
    def _check_existing_installation(self) -> bool:
        """Check for existing installation"""
        self.logger.info("Checking for existing installation...")
        
        # Check for OVN services
        result = self.run_command("systemctl is-active ovn-northd 2>/dev/null || true", check=False)
        if result.success and result.stdout.strip() == 'active':
            self.logger.warning("⚠ OVN services detected - might be already installed")
        
        # Check for libvirt
        result = self.run_command("systemctl is-active libvirtd 2>/dev/null || true", check=False)
        if result.success and result.stdout.strip() == 'active':
            self.logger.warning("⚠ Libvirt detected - might be already installed")
        
        return True