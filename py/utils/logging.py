#!/usr/bin/env python3
"""
utils/logging.py - Logging utilities
"""

import logging
import sys
from pathlib import Path
from datetime import datetime
from typing import Optional
import colorlog


class ColorFormatter(colorlog.ColoredFormatter):
    """Custom colored formatter"""
    
    def __init__(self):
        super().__init__(
            fmt='%(log_color)s[%(asctime)s] [%(levelname)-8s] [%(name)s] %(message)s',
            datefmt='%Y-%m-%d %H:%M:%S',
            log_colors={
                'DEBUG': 'cyan',
                'INFO': 'green',
                'WARNING': 'yellow',
                'ERROR': 'red',
                'CRITICAL': 'red,bg_white',
            }
        )


def setup_logging(level=logging.INFO, log_file: Optional[Path] = None):
    """Setup logging configuration"""
    # Create logs directory
    log_dir = Path("/var/log/cloud-provider")
    log_dir.mkdir(parents=True, exist_ok=True)
    
    if log_file is None:
        timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        log_file = log_dir / f"install-{timestamp}.log"
    
    # Configure root logger
    root_logger = logging.getLogger()
    root_logger.setLevel(level)
    
    # Clear existing handlers
    root_logger.handlers.clear()
    
    # Console handler (colored)
    console_handler = logging.StreamHandler(sys.stdout)
    console_handler.setFormatter(ColorFormatter())
    console_handler.setLevel(level)
    root_logger.addHandler(console_handler)
    
    # File handler
    file_handler = logging.FileHandler(log_file)
    file_formatter = logging.Formatter(
        '[%(asctime)s] [%(levelname)-8s] [%(name)s] %(message)s',
        datefmt='%Y-%m-%d %H:%M:%S'
    )
    file_handler.setFormatter(file_formatter)
    file_handler.setLevel(logging.DEBUG)  # Always debug to file
    root_logger.addHandler(file_handler)
    
    # Log startup message
    logging.info(f"Logging initialized. File: {log_file}")


class PhaseLogger:
    """Logger for individual phases"""
    
    def __init__(self, phase_name: str):
        self.phase_name = phase_name
        self.phase_dir = Path("/var/log/cloud-provider/phases")
        self.phase_dir.mkdir(parents=True, exist_ok=True)
        
        self.log_file = self.phase_dir / f"{phase_name}.log"
        self.start_time = None
        self.end_time = None
    
    def start(self):
        """Start phase logging"""
        self.start_time = datetime.now()
        with open(self.log_file, 'a') as f:
            f.write(f"\n{'='*60}\n")
            f.write(f"PHASE: {self.phase_name.upper()}\n")
            f.write(f"START: {self.start_time}\n")
            f.write(f"{'='*60}\n\n")
    
    def end(self, success: bool):
        """End phase logging"""
        self.end_time = datetime.now()
        duration = (self.end_time - self.start_time).total_seconds() if self.start_time else 0
        
        with open(self.log_file, 'a') as f:
            f.write(f"\n{'='*60}\n")
            f.write(f"END: {self.end_time}\n")
            f.write(f"DURATION: {duration:.2f}s\n")
            f.write(f"STATUS: {'SUCCESS' if success else 'FAILED'}\n")
            f.write(f"{'='*60}\n")
    
    def log_command(self, command: str, output: str = "", error: str = ""):
        """Log command execution"""
        with open(self.log_file, 'a') as f:
            f.write(f"$ {command}\n")
            if output:
                f.write(f"{output}\n")
            if error:
                f.write(f"ERROR: {error}\n")
            f.write(f"{'-'*40}\n")