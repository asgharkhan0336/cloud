/opt/cloud-sdn/
├── install.sh                    # Main installer
├── config.env                    # Global configuration
├── requirements.txt              # Python dependencies
│
├── controllers/
│   ├── install-controller.sh     # Controller installation
│   ├── controller-config.yaml    # Controller config template
│   ├── ha-setup.sh               # High availability setup
│   └── backup-controller.sh      # Backup/restore
│
├── compute/
│   ├── install-compute.sh        # Compute node installation
│   ├── compute-config.yaml       # Compute config template
│   ├── storage-setup.sh          # Storage configuration
│   └── migrate-vms.sh            # VM migration utilities
│
├── common/
│   ├── setup-common.sh           # Common packages
│   ├── network-templates/        # Network configs
│   └── monitoring-setup.sh       # Monitoring stack
│
└── tools/
    ├── cluster-status.sh         # Cluster health check
    ├── add-node.sh               # Add new node
    └── disaster-recovery.sh      # DR procedures
