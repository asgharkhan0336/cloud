from flask import Blueprint, request, jsonify
from .. import db
from ..models import Tenant, Network, Subnet, SecurityGroup, SecurityRule
from ..utils.ipam import IPAddressManager
import uuid

network_bp = Blueprint('network', __name__)

# Tenant Management
@network_bp.route('/tenants', methods=['POST'])
def create_tenant():
    """Create a new tenant"""
    data = request.get_json()
    
    if not data or 'name' not in data:
        return jsonify({'error': 'Tenant name is required'}), 400
    
    # Check if tenant already exists
    existing = Tenant.query.filter_by(name=data['name']).first()
    if existing:
        return jsonify({'error': 'Tenant with this name already exists'}), 409
    
    tenant = Tenant(
        name=data['name'],
        description=data.get('description', '')
    )
    
    db.session.add(tenant)
    db.session.commit()
    
    return jsonify(tenant.to_dict()), 201

@network_bp.route('/tenants', methods=['GET'])
def list_tenants():
    """List all tenants"""
    tenants = Tenant.query.all()
    return jsonify([tenant.to_dict() for tenant in tenants])

@network_bp.route('/tenants/<tenant_id>', methods=['GET'])
def get_tenant(tenant_id):
    """Get tenant details"""
    tenant = Tenant.query.get(tenant_id)
    if not tenant:
        return jsonify({'error': 'Tenant not found'}), 404
    
    return jsonify(tenant.to_dict())

@network_bp.route('/tenants/<tenant_id>', methods=['DELETE'])
def delete_tenant(tenant_id):
    """Delete a tenant"""
    tenant = Tenant.query.get(tenant_id)
    if not tenant:
        return jsonify({'error': 'Tenant not found'}), 404
    
    db.session.delete(tenant)
    db.session.commit()
    
    return jsonify({'message': 'Tenant deleted successfully'}), 200

# Network Management
@network_bp.route('/tenants/<tenant_id>/networks', methods=['POST'])
def create_network(tenant_id):
    """Create a network for a tenant"""
    tenant = Tenant.query.get(tenant_id)
    if not tenant:
        return jsonify({'error': 'Tenant not found'}), 404
    
    data = request.get_json()
    
    if not data or 'name' not in data or 'cidr' not in data:
        return jsonify({'error': 'Network name and CIDR are required'}), 400
    
    # Validate CIDR
    if not IPAddressManager.validate_cidr(data['cidr']):
        return jsonify({'error': 'Invalid CIDR notation'}), 400
    
    # Check if network name already exists for this tenant
    existing = Network.query.filter_by(tenant_id=tenant_id, name=data['name']).first()
    if existing:
        return jsonify({'error': 'Network with this name already exists for this tenant'}), 409
    
    network = Network(
        name=data['name'],
        tenant_id=tenant_id,
        cidr=data['cidr'],
        gateway_ip=data.get('gateway_ip'),
        dns_servers=','.join(data.get('dns_servers', ['8.8.8.8', '8.8.4.4'])),
        status=data.get('status', 'active')
    )
    
    db.session.add(network)
    db.session.commit()
    
    return jsonify(network.to_dict()), 201

@network_bp.route('/tenants/<tenant_id>/networks', methods=['GET'])
def list_networks(tenant_id):
    """List all networks for a tenant"""
    tenant = Tenant.query.get(tenant_id)
    if not tenant:
        return jsonify({'error': 'Tenant not found'}), 404
    
    networks = Network.query.filter_by(tenant_id=tenant_id).all()
    return jsonify([network.to_dict() for network in networks])

@network_bp.route('/networks/<network_id>', methods=['GET'])
def get_network(network_id):
    """Get network details"""
    network = Network.query.get(network_id)
    if not network:
        return jsonify({'error': 'Network not found'}), 404
    
    return jsonify(network.to_dict())

@network_bp.route('/networks/<network_id>', methods=['DELETE'])
def delete_network(network_id):
    """Delete a network"""
    network = Network.query.get(network_id)
    if not network:
        return jsonify({'error': 'Network not found'}), 404
    
    db.session.delete(network)
    db.session.commit()
    
    return jsonify({'message': 'Network deleted successfully'}), 200

# Subnet Management
@network_bp.route('/networks/<network_id>/subnets', methods=['POST'])
def create_subnet(network_id):
    """Create a subnet within a network"""
    network = Network.query.get(network_id)
    if not network:
        return jsonify({'error': 'Network not found'}), 404
    
    data = request.get_json()
    
    if not data or 'name' not in data or 'cidr' not in data:
        return jsonify({'error': 'Subnet name and CIDR are required'}), 400
    
    # Validate CIDR
    if not IPAddressManager.validate_cidr(data['cidr']):
        return jsonify({'error': 'Invalid CIDR notation'}), 400
    
    # Check if subnet is within network
    if not IPAddressManager.is_subnet_of(network.cidr, data['cidr']):
        return jsonify({'error': 'Subnet must be within the parent network CIDR'}), 400
    
    # Check if subnet name already exists in this network
    existing = Subnet.query.filter_by(network_id=network_id, name=data['name']).first()
    if existing:
        return jsonify({'error': 'Subnet with this name already exists in this network'}), 409
    
    subnet = Subnet(
        name=data['name'],
        network_id=network_id,
        cidr=data['cidr'],
        start_ip=data.get('start_ip'),
        end_ip=data.get('end_ip'),
        gateway_ip=data.get('gateway_ip'),
        dhcp_enabled=data.get('dhcp_enabled', True),
        dns_servers=','.join(data.get('dns_servers', ['8.8.8.8', '8.8.4.4'])),
        status=data.get('status', 'active')
    )
    
    db.session.add(subnet)
    db.session.commit()
    
    return jsonify(subnet.to_dict()), 201

@network_bp.route('/networks/<network_id>/subnets', methods=['GET'])
def list_subnets(network_id):
    """List all subnets in a network"""
    network = Network.query.get(network_id)
    if not network:
        return jsonify({'error': 'Network not found'}), 404
    
    subnets = Subnet.query.filter_by(network_id=network_id).all()
    return jsonify([subnet.to_dict() for subnet in subnets])

@network_bp.route('/subnets/<subnet_id>', methods=['GET'])
def get_subnet(subnet_id):
    """Get subnet details"""
    subnet = Subnet.query.get(subnet_id)
    if not subnet:
        return jsonify({'error': 'Subnet not found'}), 404
    
    return jsonify(subnet.to_dict())

# Security Group Management
@network_bp.route('/tenants/<tenant_id>/security-groups', methods=['POST'])
def create_security_group(tenant_id):
    """Create a security group"""
    tenant = Tenant.query.get(tenant_id)
    if not tenant:
        return jsonify({'error': 'Tenant not found'}), 404
    
    data = request.get_json()
    
    if not data or 'name' not in data:
        return jsonify({'error': 'Security group name is required'}), 400
    
    security_group = SecurityGroup(
        name=data['name'],
        tenant_id=tenant_id,
        description=data.get('description', '')
    )
    
    db.session.add(security_group)
    db.session.commit()
    
    return jsonify(security_group.to_dict()), 201

@network_bp.route('/security-groups/<group_id>/rules', methods=['POST'])
def add_security_rule(group_id):
    """Add a rule to security group"""
    security_group = SecurityGroup.query.get(group_id)
    if not security_group:
        return jsonify({'error': 'Security group not found'}), 404
    
    data = request.get_json()
    
    if not data or 'direction' not in data or 'protocol' not in data:
        return jsonify({'error': 'Direction and protocol are required'}), 400
    
    rule = SecurityRule(
        security_group_id=group_id,
        direction=data['direction'],
        protocol=data['protocol'],
        port_range_min=data.get('port_range_min'),
        port_range_max=data.get('port_range_max'),
        remote_ip_prefix=data.get('remote_ip_prefix'),
        description=data.get('description', '')
    )
    
    db.session.add(rule)
    db.session.commit()
    
    return jsonify(rule.to_dict()), 201

# Utility endpoints
@network_bp.route('/utils/calculate-network/<cidr>', methods=['GET'])
def calculate_network(cidr):
    """Calculate network information"""
    info = IPAddressManager.calculate_network_info(cidr)
    if not info:
        return jsonify({'error': 'Invalid CIDR notation'}), 400
    
    return jsonify(info)

@network_bp.route('/utils/generate-subnets', methods=['POST'])
def generate_subnets():
    """Generate subnets from parent network"""
    data = request.get_json()
    
    if not data or 'parent_cidr' not in data or 'new_prefix' not in data:
        return jsonify({'error': 'parent_cidr and new_prefix are required'}), 400
    
    try:
        subnets = IPAddressManager.generate_subnets(
            data['parent_cidr'],
            int(data['new_prefix']),
            int(data.get('count', 5))
        )
        return jsonify({'subnets': subnets})
    except ValueError as e:
        return jsonify({'error': str(e)}), 400

# Health check
@network_bp.route('/health', methods=['GET'])
def health_check():
    """Health check endpoint"""
    return jsonify({'status': 'healthy', 'service': 'network-manager'})