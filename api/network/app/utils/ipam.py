import ipaddress
from typing import List, Optional, Tuple

class IPAddressManager:
    """IP Address Management utility"""
    
    @staticmethod
    def validate_cidr(cidr: str) -> bool:
        """Validate CIDR notation"""
        try:
            ipaddress.ip_network(cidr)
            return True
        except ValueError:
            return False
    
    @staticmethod
    def is_subnet_of(parent_cidr: str, subnet_cidr: str) -> bool:
        """Check if subnet is within parent network"""
        try:
            parent_net = ipaddress.ip_network(parent_cidr)
            subnet_net = ipaddress.ip_network(subnet_cidr)
            return subnet_net.subnet_of(parent_net)
        except ValueError:
            return False
    
    @staticmethod
    def generate_subnets(parent_cidr: str, new_prefix: int, count: int) -> List[str]:
        """Generate subnets from a parent network"""
        try:
            parent_net = ipaddress.ip_network(parent_cidr)
            subnets = list(parent_net.subnets(new_prefix=new_prefix))
            return [str(subnet) for subnet in subnets[:count]]
        except ValueError as e:
            raise ValueError(f"Error generating subnets: {str(e)}")
    
    @staticmethod
    def get_available_ip(subnet_cidr: str, used_ips: List[str]) -> Optional[str]:
        """Get an available IP address from subnet"""
        try:
            subnet = ipaddress.ip_network(subnet_cidr)
            used_set = {ipaddress.ip_address(ip) for ip in used_ips}
            
            # Skip network and broadcast addresses
            for host in subnet.hosts():
                if host not in used_set:
                    return str(host)
            return None
        except ValueError:
            return None
    
    @staticmethod
    def calculate_network_info(cidr: str) -> dict:
        """Calculate network information from CIDR"""
        try:
            network = ipaddress.ip_network(cidr)
            return {
                'network_address': str(network.network_address),
                'broadcast_address': str(network.broadcast_address),
                'netmask': str(network.netmask),
                'hostmask': str(network.hostmask),
                'prefixlen': network.prefixlen,
                'num_addresses': network.num_addresses,
                'usable_hosts': network.num_addresses - 2 if network.version == 4 else network.num_addresses,
                'first_usable': str(list(network.hosts())[0]) if list(network.hosts()) else None,
                'last_usable': str(list(network.hosts())[-1]) if list(network.hosts()) else None
            }
        except ValueError:
            return {}