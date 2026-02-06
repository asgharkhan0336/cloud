#!/usr/bin/env python3
"""
Cloud Provider Installer - Main Entry Point
"""

import os
import sys
import argparse
import logging
from pathlib import Path

# Add project root to Python path
sys.path.insert(0, str(Path(__file__).parent))

from config.node_config import NodeConfig
from utils.logging import setup_logging, ColorFormatter
from phases import (
    PreflightPhase,
    SystemPrepPhase,
    NetworkPhase,
    ControllerPhase,
    ComputePhase,
    PostInstallPhase,
    VerificationPhase,
)


class CloudInstaller:
    """Main installer orchestrator"""
    
    def __init__(self, interactive=True):
        self.interactive = interactive
        self.config = NodeConfig()
        self.logger = logging.getLogger(__name__)
        
        # Define available phases
        self.phases = {
            'preflight': PreflightPhase,
            'system_prep': SystemPrepPhase,
            'network': NetworkPhase,
            'controller': ControllerPhase,
            'compute': ComputePhase,
            'post_install': PostInstallPhase,
            'verification': VerificationPhase,
        }
        
    def print_banner(self):
        """Print installation banner"""
        banner = """
╔══════════════════════════════════════════════════════════╗
║         CLOUD PROVIDER INSTALLATION SYSTEM               ║
║                    (Python Edition)                      ║
║                Ubuntu 22.04 LTS                          ║
╚══════════════════════════════════════════════════════════╝
        """
        print(banner)
    
    def run_interactive(self):
        """Run interactive installation"""
        self.print_banner()
        
        # Load existing config or collect new
        if self.config.exists() and self.ask_yes_no(
            "Existing configuration found. Load it?", default=True
        ):
            self.config.load()
            print("\nLoaded existing configuration:")
            self.config.print_summary()
            
            if not self.ask_yes_no("Continue with this configuration?", default=True):
                self.config.collect_interactive()
        else:
            self.config.collect_interactive()
        
        # Save configuration
        self.config.save()
        
        # Select phases to run
        phases_to_run = self.select_phases()
        
        # Run selected phases
        self.run_phases(phases_to_run)
        
        # Show completion message
        self.show_completion()
    
    def run_non_interactive(self, config_file=None):
        """Run non-interactive installation"""
        if config_file:
            self.config.load_from_file(config_file)
        elif self.config.exists():
            self.config.load()
        else:
            self.logger.error("No configuration provided and no existing config found")
            sys.exit(1)
        
        # Run all phases
        self.run_phases(list(self.phases.keys()))
    
    def select_phases(self):
        """Select which phases to run"""
        print("\n" + "="*60)
        print("PHASE SELECTION")
        print("="*60)
        
        phases_info = {
            'preflight': "Pre-flight checks and validation",
            'system_prep': "System preparation and updates",
            'network': "Network configuration",
            'controller': "Controller components installation",
            'compute': "Compute components installation",
            'post_install': "Post-install configuration",
            'verification': "Verification and testing",
        }
        
        # Show available phases
        for i, (phase_id, description) in enumerate(phases_info.items(), 1):
            print(f"{i}. {phase_id:15} - {description}")
        
        print("\nOptions:")
        print("  [1-7]    - Run specific phase")
        print("  all      - Run all phases (default)")
        print("  skip:X   - Run all phases except X")
        print("  only:X   - Run only phase X")
        
        choice = input("\nSelect phases to run [all]: ").strip().lower()
        
        if not choice or choice == 'all':
            return list(self.phases.keys())
        elif choice.startswith('skip:'):
            skip_phase = choice.split(':', 1)[1]
            return [p for p in self.phases.keys() if p != skip_phase]
        elif choice.startswith('only:'):
            only_phase = choice.split(':', 1)[1]
            if only_phase in self.phases:
                return [only_phase]
            else:
                print(f"Unknown phase: {only_phase}")
                return self.select_phases()
        elif choice.isdigit() and 1 <= int(choice) <= len(self.phases):
            phase_idx = int(choice) - 1
            phase_id = list(self.phases.keys())[phase_idx]
            return [phase_id]
        else:
            print("Invalid selection")
            return self.select_phases()
    
    def run_phases(self, phase_ids):
        """Run specified phases"""
        print(f"\nRunning {len(phase_ids)} phase(s)...")
        
        for phase_id in phase_ids:
            if phase_id not in self.phases:
                self.logger.error(f"Unknown phase: {phase_id}")
                continue
            
            phase_class = self.phases[phase_id]
            phase = phase_class(self.config)
            
            print(f"\n{'='*60}")
            print(f"PHASE: {phase.name.upper()}")
            print(f"{'='*60}")
            
            try:
                if phase.run():
                    self.logger.info(f"✓ Phase '{phase.name}' completed successfully")
                else:
                    self.logger.error(f"✗ Phase '{phase.name}' failed")
                    if self.interactive and not self.ask_yes_no(
                        "Continue to next phase?", default=False
                    ):
                        break
            except KeyboardInterrupt:
                self.logger.warning("Phase interrupted by user")
                if not self.ask_yes_no("Continue installation?", default=False):
                    sys.exit(0)
            except Exception as e:
                self.logger.error(f"Phase '{phase.name}' failed with error: {e}")
                if self.interactive and not self.ask_yes_no(
                    "Continue to next phase?", default=False
                ):
                    break
    
    def show_completion(self):
        """Show installation completion message"""
        print("\n" + "="*60)
        print("INSTALLATION COMPLETE!")
        print("="*60)
        
        print(f"\nNode Type:       {self.config.node_type}")
        print(f"Management IP:   {self.config.mgmt_ip}")
        
        if self.config.node_type in ['controller', 'combined']:
            print("\nAccess URLs:")
            print(f"  • API:          http://{self.config.mgmt_ip}:8000")
            print(f"  • Prometheus:   http://{self.config.mgmt_ip}:9090")
            print(f"  • Grafana:      http://{self.config.mgmt_ip}:3000")
            print("      (admin/admin)")
        
        if self.config.node_type in ['compute', 'combined']:
            print("\nVM Management:")
            print("  Use 'create-vm.sh' to create VMs")
        
        print(f"\nConfiguration:   {self.config.config_file}")
        print(f"Logs:            /var/log/cloud-provider/")
        print("\nNext steps:")
        print("  1. Verify installation: sudo cloud-install --verify")
        print("  2. Check status: cloud-status.sh")
        print("  3. Create first tenant: create-tenant.sh 1 172.16.1.0/24")
    
    @staticmethod
    def ask_yes_no(question, default=True):
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


def main():
    """Main entry point"""
    parser = argparse.ArgumentParser(
        description='Cloud Provider Installation System'
    )
    
    parser.add_argument(
        '--non-interactive', '-n',
        action='store_true',
        help='Run in non-interactive mode'
    )
    
    parser.add_argument(
        '--config', '-c',
        type=str,
        help='Configuration file for non-interactive mode'
    )
    
    parser.add_argument(
        '--verify', '-v',
        action='store_true',
        help='Run verification only'
    )
    
    parser.add_argument(
        '--reconfigure',
        action='store_true',
        help='Reconfigure node'
    )
    
    parser.add_argument(
        '--phase',
        type=str,
        help='Run specific phase only'
    )
    
    parser.add_argument(
        '--debug', '-d',
        action='store_true',
        help='Enable debug logging'
    )
    
    args = parser.parse_args()
    
    # Setup logging
    log_level = logging.DEBUG if args.debug else logging.INFO
    setup_logging(log_level)
    
    # Create installer
    installer = CloudInstaller(interactive=not args.non_interactive)
    
    try:
        if args.verify:
            # Run verification only
            phase = VerificationPhase(installer.config)
            phase.run()
        elif args.phase:
            # Run specific phase
            if args.phase in installer.phases:
                phase_class = installer.phases[args.phase]
                phase = phase_class(installer.config)
                phase.run()
            else:
                print(f"Unknown phase: {args.phase}")
                print(f"Available phases: {', '.join(installer.phases.keys())}")
                sys.exit(1)
        elif args.non_interactive:
            # Non-interactive mode
            installer.run_non_interactive(args.config)
        else:
            # Interactive mode
            installer.run_interactive()
    except KeyboardInterrupt:
        print("\n\nInstallation cancelled by user")
        sys.exit(0)
    except Exception as e:
        logging.error(f"Installation failed: {e}")
        if args.debug:
            import traceback
            traceback.print_exc()
        sys.exit(1)


if __name__ == '__main__':
    main()