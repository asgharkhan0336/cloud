from .. import db
import uuid
from datetime import datetime
import ipaddress

class Network(db.Model):
    __tablename__ = 'networks'
    
    id = db.Column(db.String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    name = db.Column(db.String(100), nullable=False)
    tenant_id = db.Column(db.String(36), db.ForeignKey('tenants.id'), nullable=False)
    cidr = db.Column(db.String(18), nullable=False)  # e.g., "10.0.0.0/16"
    gateway_ip = db.Column(db.String(15))
    dns_servers = db.Column(db.String(200))  # Comma-separated DNS servers
    status = db.Column(db.String(20), default='active')  # active, inactive, pending
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    
    # Relationships
    subnets = db.relationship('Subnet', backref='network', lazy=True, cascade='all, delete-orphan')
    
    def to_dict(self):
        return {
            'id': self.id,
            'name': self.name,
            'tenant_id': self.tenant_id,
            'cidr': self.cidr,
            'gateway_ip': self.gateway_ip,
            'dns_servers': self.dns_servers.split(',') if self.dns_servers else [],
            'status': self.status,
            'created_at': self.created_at.isoformat(),
            'updated_at': self.updated_at.isoformat(),
            'subnet_count': len(self.subnets)
        }
    
    def validate_cidr(self):
        """Validate the CIDR notation"""
        try:
            network = ipaddress.ip_network(self.cidr)
            return True
        except ValueError:
            return False

class Subnet(db.Model):
    __tablename__ = 'subnets'
    
    id = db.Column(db.String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    name = db.Column(db.String(100), nullable=False)
    network_id = db.Column(db.String(36), db.ForeignKey('networks.id'), nullable=False)
    cidr = db.Column(db.String(18), nullable=False)  # e.g., "10.0.1.0/24"
    start_ip = db.Column(db.String(15))
    end_ip = db.Column(db.String(15))
    gateway_ip = db.Column(db.String(15))
    dhcp_enabled = db.Column(db.Boolean, default=True)
    dns_servers = db.Column(db.String(200))
    status = db.Column(db.String(20), default='active')
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    
    def to_dict(self):
        return {
            'id': self.id,
            'name': self.name,
            'network_id': self.network_id,
            'cidr': self.cidr,
            'start_ip': self.start_ip,
            'end_ip': self.end_ip,
            'gateway_ip': self.gateway_ip,
            'dhcp_enabled': self.dhcp_enabled,
            'dns_servers': self.dns_servers.split(',') if self.dns_servers else [],
            'status': self.status,
            'created_at': self.created_at.isoformat(),
            'updated_at': self.updated_at.isoformat()
        }