from .. import db
import uuid
from datetime import datetime

class SecurityGroup(db.Model):
    __tablename__ = 'security_groups'
    
    id = db.Column(db.String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    name = db.Column(db.String(100), nullable=False)
    tenant_id = db.Column(db.String(36), db.ForeignKey('tenants.id'), nullable=False)
    description = db.Column(db.String(500))
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    
    # Relationships
    rules = db.relationship('SecurityRule', backref='security_group', lazy=True, cascade='all, delete-orphan')
    
    def to_dict(self):
        return {
            'id': self.id,
            'name': self.name,
            'tenant_id': self.tenant_id,
            'description': self.description,
            'created_at': self.created_at.isoformat(),
            'updated_at': self.updated_at.isoformat(),
            'rule_count': len(self.rules)
        }

class SecurityRule(db.Model):
    __tablename__ = 'security_rules'
    
    id = db.Column(db.String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    security_group_id = db.Column(db.String(36), db.ForeignKey('security_groups.id'), nullable=False)
    direction = db.Column(db.String(10), nullable=False)  # 'ingress' or 'egress'
    protocol = db.Column(db.String(10), nullable=False)  # 'tcp', 'udp', 'icmp', 'any'
    port_range_min = db.Column(db.Integer, nullable=True)
    port_range_max = db.Column(db.Integer, nullable=True)
    remote_ip_prefix = db.Column(db.String(18), nullable=True)  # CIDR notation
    description = db.Column(db.String(500))
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    
    def to_dict(self):
        return {
            'id': self.id,
            'security_group_id': self.security_group_id,
            'direction': self.direction,
            'protocol': self.protocol,
            'port_range': f"{self.port_range_min}-{self.port_range_max}" if self.port_range_min and self.port_range_max else 'any',
            'remote_ip_prefix': self.remote_ip_prefix,
            'description': self.description,
            'created_at': self.created_at.isoformat()
        }