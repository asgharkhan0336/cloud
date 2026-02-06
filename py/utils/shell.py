#!/usr/bin/env python3
"""
utils/shell.py - Shell command execution utilities
"""

import subprocess
import shlex
import logging
from dataclasses import dataclass
from typing import Optional, List, Union
from pathlib import Path

logger = logging.getLogger(__name__)


@dataclass
class CommandResult:
    """Result of command execution"""
    success: bool
    returncode: int
    stdout: str
    stderr: str
    command: str


def run_command(
    cmd: Union[str, List[str]],
    check: bool = True,
    cwd: Optional[Path] = None,
    env: Optional[dict] = None,
    timeout: Optional[int] = 300,
    capture_output: bool = True,
) -> CommandResult:
    """
    Run shell command with proper error handling and logging
    
    Args:
        cmd: Command to run (string or list)
        check: Raise exception if command fails
        cwd: Working directory
        env: Environment variables
        timeout: Command timeout in seconds
        capture_output: Capture stdout/stderr
    
    Returns:
        CommandResult object
    """
    # Convert command to list if it's a string
    if isinstance(cmd, str):
        cmd_str = cmd
        cmd_list = shlex.split(cmd)
    else:
        cmd_str = ' '.join(cmd)
        cmd_list = cmd
    
    logger.debug(f"Executing: {cmd_str}")
    
    try:
        # Prepare subprocess arguments
        kwargs = {
            'cwd': str(cwd) if cwd else None,
            'env': env,
            'timeout': timeout,
        }
        
        if capture_output:
            kwargs['stdout'] = subprocess.PIPE
            kwargs['stderr'] = subprocess.PIPE
            kwargs['text'] = True
        
        # Execute command
        result = subprocess.run(cmd_list, **kwargs)
        
        # Create result object
        cmd_result = CommandResult(
            success=result.returncode == 0,
            returncode=result.returncode,
            stdout=result.stdout.strip() if capture_output else '',
            stderr=result.stderr.strip() if capture_output else '',
            command=cmd_str,
        )
        
        # Log result
        if cmd_result.success:
            if cmd_result.stdout:
                logger.debug(f"Command output: {cmd_result.stdout[:200]}...")
        else:
            logger.error(f"Command failed (exit={cmd_result.returncode}): {cmd_str}")
            if cmd_result.stderr:
                logger.error(f"Error output: {cmd_result.stderr}")
        
        # Raise exception if check is True and command failed
        if check and not cmd_result.success:
            raise subprocess.CalledProcessError(
                cmd_result.returncode,
                cmd_list,
                cmd_result.stdout,
                cmd_result.stderr,
            )
        
        return cmd_result
        
    except subprocess.TimeoutExpired as e:
        logger.error(f"Command timed out after {timeout}s: {cmd_str}")
        raise
        
    except FileNotFoundError as e:
        logger.error(f"Command not found: {cmd_str}")
        raise
        
    except Exception as e:
        logger.error(f"Command execution failed: {e}")
        raise


def command_exists(cmd: str) -> bool:
    """Check if command exists in PATH"""
    try:
        result = run_command(f"command -v {cmd}", check=False, capture_output=False)
        return result.success
    except Exception:
        return False


def apt_install(packages: List[str], update: bool = True) -> bool:
    """Install packages using apt"""
    try:
        if update:
            logger.info("Updating package lists...")
            run_command("apt-get update")
        
        logger.info(f"Installing packages: {', '.join(packages)}")
        run_command(f"apt-get install -y {' '.join(packages)}")
        return True
        
    except Exception as e:
        logger.error(f"Failed to install packages: {e}")
        return False


def systemctl(service: str, action: str) -> bool:
    """Control systemd service"""
    valid_actions = ['start', 'stop', 'restart', 'enable', 'disable', 'status']
    
    if action not in valid_actions:
        raise ValueError(f"Invalid action. Must be one of: {valid_actions}")
    
    try:
        result = run_command(f"systemctl {action} {service}", check=False)
        
        if action == 'status':
            return result.success
        else:
            # Verify service is in desired state
            if action in ['start', 'enable']:
                result = run_command(f"systemctl is-active {service}", check=False)
                return result.success
            elif action == 'disable':
                result = run_command(f"systemctl is-enabled {service}", check=False)
                return not result.success  # Should be disabled
            
        return True
        
    except Exception as e:
        logger.error(f"Failed to {action} service {service}: {e}")
        return False


def create_service_file(name: str, content: str) -> bool:
    """Create systemd service file"""
    service_path = Path(f"/etc/systemd/system/{name}.service")
    
    try:
        # Backup existing file
        if service_path.exists():
            backup_path = service_path.with_suffix('.service.backup')
            service_path.rename(backup_path)
            logger.debug(f"Backed up existing service file to {backup_path}")
        
        # Write new service file
        service_path.parent.mkdir(parents=True, exist_ok=True)
        service_path.write_text(content)
        logger.info(f"Created service file: {service_path}")
        
        # Reload systemd
        run_command("systemctl daemon-reload")
        
        return True
        
    except Exception as e:
        logger.error(f"Failed to create service file {name}: {e}")
        return False