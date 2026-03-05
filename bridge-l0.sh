#!/bin/bash
set -e

# Configuration
UPLINK_IFACE="enP2p1s0"
BRIDGE_IFACE="br0"
SUBNET="10.10.0.0/24"
TAP_DEV="tap0"

if ip link show $TAP_DEV >/dev/null 2>&1; then
    echo "Cleaning up existing $TAP_DEV..."
    sudo ip link set $TAP_DEV down
    # Try deleting as a link first, or specific tuntap delete if needed
    sudo ip link delete $TAP_DEV || sudo ip tuntap del $TAP_DEV mode tap
fi

# Create a virtual network device for L1
sudo ip tuntap add $TAP_DEV mode tap

# Match the MTU size on jetson 10Gbps network interface
sudo ip link set dev $TAP_DEV mtu 1466

# Put virtual network device under bridge interface
sudo ip link set $TAP_DEV master $BRIDGE_IFACE

# Bring up virtual network device for L1
sudo ip link set $TAP_DEV up

# Enable IPv4 forwarding
sudo sysctl -w net.ipv4.ip_forward=1

# NAT: guest subnet -> uplink
sudo iptables -t nat -C POSTROUTING -s $SUBNET -o $UPLINK_IFACE -j MASQUERADE 2>/dev/null || \
sudo iptables -t nat -A POSTROUTING -s $SUBNET -o $UPLINK_IFACE -j MASQUERADE

# Forwarding rules
sudo iptables -C FORWARD -i $BRIDGE_IFACE -o $UPLINK_IFACE -j ACCEPT 2>/dev/null || \
sudo iptables -A FORWARD -i $BRIDGE_IFACE -o $UPLINK_IFACE -j ACCEPT

sudo iptables -C FORWARD -i $UPLINK_IFACE -o $BRIDGE_IFACE -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
sudo iptables -A FORWARD -i $UPLINK_IFACE -o $BRIDGE_IFACE -m state --state RELATED,ESTABLISHED -j ACCEPT

echo "Bridge network set up successfully."
echo "Host Bridge IP:"
ip -4 addr show dev $BRIDGE_IFACE | grep inet
echo "Virtual Network Device: $TAP_DEV"
