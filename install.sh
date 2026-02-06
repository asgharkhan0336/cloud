#!/bin/bash
# /opt/cloud-provider/install.sh
# Main installer - orchestrates all phases

set -euo pipefail

# Set up paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
PHASES_DIR="$SCRIPT_DIR/phases"

# Source libraries
source "$LIB_DIR/common.sh"
source "$LIB_DIR/config-manager.sh"

# Display banner
show_banner() {
    clear
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║         CLOUD PROVIDER INSTALLATION SYSTEM               ║"
    echo "║                Ubuntu 22.04 LTS                          ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
}

# Main menu
show_menu() {
    echo ""
    echo "Main Menu:"
    echo "1) Fresh Installation"
    echo "2) Continue Installation"
    echo "3) Reconfigure Node"
    echo "4) Verify Installation"
    echo "5) Exit"
    echo ""
    echo -n "Enter choice [1-5]: "
}

# Fresh installation
fresh_installation() {
    log_header "Starting Fresh Installation"
    
    # Collect configuration
    collect_configuration
    
    # Run phases in sequence
    local phases=(
        "00-preflight.sh:Pre-flight Checks"
        "01-system-prep.sh:System Preparation"
        "02-network.sh:Network Configuration"
        "03-controller.sh:Controller Installation"
        "04-compute.sh:Compute Installation"
        "05-storage.sh:Storage Installation"
        "06-post-install.sh:Post-install Configuration"
        "07-verification.sh:Verification"
    )
    
    for phase_info in "${phases[@]}"; do
        local phase_file="${phase_info%%:*}"
        local phase_name="${phase_info#*:}"
        
        run_phase "$PHASES_DIR/$phase_file" "$phase_name"
        
        # Ask to continue after each phase
        if [[ "$phase_file" != "07-verification.sh" ]]; then
            echo ""
            read -p "Continue to next phase? (Y/n): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Nn]$ ]]; then
                log_info "Installation paused after $phase_name"
                exit 0
            fi
        fi
    done
    
    log_success "Installation completed successfully!"
    show_completion_message
}

# Continue installation
continue_installation() {
    log_header "Continuing Installation"
    
    if ! load_config; then
        log_error "No configuration found. Please run fresh installation first."
    fi
    
    # Determine which phases to run based on current state
    local phases_to_run=()
    
    # Check network configuration
    if ! ip addr show mgmt >/dev/null 2>&1; then
        phases_to_run+=("02-network.sh:Network Configuration")
    fi
    
    # Check controller services
    if [[ "$NODE_TYPE" == "controller" || "$NODE_TYPE" == "combined" ]]; then
        if ! systemctl is-active --quiet ovn-northd 2>/dev/null; then
            phases_to_run+=("03-controller.sh:Controller Installation")
        fi
    fi
    
    # Check compute services
    if [[ "$NODE_TYPE" == "compute" || "$NODE_TYPE" == "combined" ]]; then
        if ! systemctl is-active --quiet ovn-controller 2>/dev/null; then
            phases_to_run+=("04-compute.sh:Compute Installation")
        fi
    fi
    
    if [[ ${#phases_to_run[@]} -eq 0 ]]; then
        log_info "All phases appear to be installed. Running verification..."
        phases_to_run+=("07-verification.sh:Verification")
    fi
    
    # Run remaining phases
    for phase_info in "${phases_to_run[@]}"; do
        local phase_file="${phase_info%%:*}"
        local phase_name="${phase_info#*:}"
        
        run_phase "$PHASES_DIR/$phase_file" "$phase_name"
    done
    
    log_success "Installation continuation completed"
}

# Reconfigure node
reconfigure_node() {
    log_header "Reconfiguring Node"
    
    # Backup existing config
    if [[ -f "$CONFIG_FILE" ]]; then
        local backup_file="${CONFIG_FILE}.backup.$(date +%Y%m%d-%H%M%S)"
        cp "$CONFIG_FILE" "$backup_file"
        log_info "Backed up configuration to $backup_file"
    fi
    
    # Collect new configuration
    collect_configuration
    
    # Ask which phases to rerun
    echo ""
    echo "Select phases to rerun:"
    echo "1) Network only"
    echo "2) Network + Services"
    echo "3) All phases"
    echo ""
    
    read -p "Enter choice [1-3]: " rerun_choice
    
    case $rerun_choice in
        1)
            run_phase "$PHASES_DIR/02-network.sh" "Network Configuration"
            ;;
        2)
            run_phase "$PHASES_DIR/02-network.sh" "Network Configuration"
            run_phase "$PHASES_DIR/03-controller.sh" "Controller Installation"
            run_phase "$PHASES_DIR/04-compute.sh" "Compute Installation"
            ;;
        3)
            fresh_installation
            ;;
        *)
            log_error "Invalid choice"
            ;;
    esac
}

# Verification
run_verification() {
    log_header "Running Verification"
    run_phase "$PHASES_DIR/07-verification.sh" "Verification"
}

# Show completion message
show_completion_message() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║         INSTALLATION COMPLETE!                           ║"
    echo "╠══════════════════════════════════════════════════════════╣"
    echo "║                                                          ║"
    echo "║  Node Type:       $NODE_TYPE"
    echo "║  Management IP:   $MGMT_IP"
    echo "║                                                          ║"
    
    case "$NODE_TYPE" in
        "controller")
            echo "║  Access URLs:                                        ║"
            echo "║    • API:          http://$MGMT_IP:8000             ║"
            echo "║    • Prometheus:   http://$MGMT_IP:9090             ║"
            echo "║    • Grafana:      http://$MGMT_IP:3000             ║"
            echo "║      (admin/admin)                                  ║"
            ;;
        "compute")
            echo "║  Connected to Controller: $CONTROLLER_IP            ║"
            echo "║  Use 'create-vm.sh' to create VMs                   ║"
            ;;
        "combined")
            echo "║  Access URLs:                                        ║"
            echo "║    • API:          http://$MGMT_IP:8000             ║"
            echo "║    • Use 'create-vm.sh' to create VMs               ║"
            ;;
        "storage")
            echo "║  Storage IP:       $STORAGE_IP                      ║"
            echo "║  Ceph Disks:       $CEPH_DISKS                      ║"
            ;;
    esac
    
    echo "║                                                          ║"
    echo "║  Log file:       $LOG_FILE                               ║"
    echo "║  Config file:    $CONFIG_FILE                            ║"
    echo "║                                                          ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
}

# Main function
main() {
    show_banner
    
    # Initialize logging
    init_logging
    
    # Check if running interactively
    if [[ $- == *i* ]]; then
        # Interactive mode
        while true; do
            show_menu
            read choice
            
            case $choice in
                1)
                    fresh_installation
                    break
                    ;;
                2)
                    continue_installation
                    break
                    ;;
                3)
                    reconfigure_node
                    break
                    ;;
                4)
                    run_verification
                    break
                    ;;
                5)
                    log_info "Exiting..."
                    exit 0
                    ;;
                *)
                    echo "Invalid choice. Please enter 1-5."
                    ;;
            esac
        done
    else
        # Non-interactive mode
        log_info "Running in non-interactive mode"
        fresh_installation
    fi
}

# Run main
main "$@"