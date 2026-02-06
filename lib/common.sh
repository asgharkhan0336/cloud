#!/bin/bash
# /opt/cloud-provider/lib/common.sh

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration file
CONFIG_FILE="/etc/cloud-provider/node.conf"
LOG_FILE=""
PHASE_LOG_DIR="/var/log/cloud-provider/phases"

# Initialize logging
init_logging() {
    local timestamp=$(date +%Y%m%d-%H%M%S)
    LOG_FILE="/var/log/cloud-provider-install-${timestamp}.log"
    mkdir -p "$(dirname "$LOG_FILE")"
    mkdir -p "$PHASE_LOG_DIR"
    
    exec 3>&1 4>&2
    trap 'exec 2>&4 1>&3' 0 1 2 3
    exec 1> >(tee -a "$LOG_FILE") 2>&1
}

# Logging functions
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local color=""
    
    case "$level" in
        "INFO") color="$BLUE" ;;
        "SUCCESS") color="$GREEN" ;;
        "WARNING") color="$YELLOW" ;;
        "ERROR") color="$RED" ;;
        "DEBUG") color="$MAGENTA" ;;
        "HEADER") color="$CYAN" ;;
        *) color="$NC" ;;
    esac
    
    echo -e "${color}[${level}]${NC} ${message}"
    echo "${timestamp} - [${level}] ${message}" | sed -r "s/\x1B\[([0-9]{1,3}(;[0-9]{1,2})?)?[mGK]//g" >> "$LOG_FILE"
}

log_info() { log "INFO" "$1"; }
log_success() { log "SUCCESS" "$1"; }
log_warning() { log "WARNING" "$1"; }
log_error() { log "ERROR" "$1"; exit 1; }
log_debug() { log "DEBUG" "$1"; }
log_header() { log "HEADER" "===[ $1 ]==="; }

# Phase execution
run_phase() {
    local phase_script="$1"
    local phase_name="$2"
    local phase_log="${PHASE_LOG_DIR}/$(basename "${phase_script%.sh}").log"
    
    log_header "Starting phase: $phase_name"
    
    if [[ -f "$phase_script" ]]; then
        if bash "$phase_script" 2>&1 | tee "$phase_log"; then
            log_success "Phase completed: $phase_name"
            return 0
        else
            log_error "Phase failed: $phase_name"
        fi
    else
        log_error "Phase script not found: $phase_script"
    fi
}

# Load configuration
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        log_debug "Configuration loaded from $CONFIG_FILE"
        return 0
    else
        log_warning "Configuration file not found: $CONFIG_FILE"
        return 1
    fi
}

# Save configuration
save_config() {
    local config_dir=$(dirname "$CONFIG_FILE")
    mkdir -p "$config_dir"
    
    cat > "$CONFIG_FILE" <<EOF
# Cloud Provider Node Configuration
# Generated on $(date)
NODE_TYPE="$NODE_TYPE"
MGMT_IP="$MGMT_IP"
INTERNAL_IP="$INTERNAL_IP"
STORAGE_IP="$STORAGE_IP"
PHYSICAL_INTERFACE="$PHYSICAL_INTERFACE"
CONTROLLER_IP="$CONTROLLER_IP"
PUBLIC_IP_BLOCK="${PUBLIC_IP_BLOCK:-}"
PUBLIC_GATEWAY="${PUBLIC_GATEWAY:-}"
CEPH_NETWORK="${CEPH_NETWORK:-}"
CEPH_PUBLIC_NETWORK="${CEPH_PUBLIC_NETWORK:-}"
CEPH_DISKS="${CEPH_DISKS:-}"
EOF
    
    chmod 600 "$CONFIG_FILE"
    log_info "Configuration saved to $CONFIG_FILE"
}

# Validation functions
validate_ip() {
    local ip="$1"
    if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        IFS='.' read -r i1 i2 i3 i4 <<< "$ip"
        if [[ $i1 -le 255 && $i2 -le 255 && $i3 -le 255 && $i4 -le 255 ]]; then
            return 0
        fi
    fi
    return 1
}

validate_cidr() {
    local cidr="$1"
    if [[ $cidr =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
        return 0
    fi
    return 1
}

# User input with validation
get_input() {
    local prompt="$1"
    local default="$2"
    local validation_func="$3"
    local input
    
    while true; do
        if [[ -n "$default" ]]; then
            read -p "$prompt [$default]: " input
            input="${input:-$default}"
        else
            read -p "$prompt: " input
        fi
        
        if [[ -z "$input" ]]; then
            log_warning "Input cannot be empty"
            continue
        fi
        
        if [[ -n "$validation_func" ]]; then
            if $validation_func "$input"; then
                break
            else
                log_warning "Invalid input. Please try again."
            fi
        else
            break
        fi
    done
    
    echo "$input"
}

# Detect network interface
detect_interface() {
    local interface=$(ip route | grep default | awk '{print $5}' | head -1)
    
    if [[ -z "$interface" ]]; then
        interface=$(ip link show | grep -E '^[0-9]+:' | grep -v lo | awk -F: '{print $2}' | tr -d ' ' | head -1)
    fi
    
    if [[ -z "$interface" ]]; then
        log_error "Cannot detect network interface"
    fi
    
    echo "$interface"
}