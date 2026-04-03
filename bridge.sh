#!/bin/bash
set -e

# Default Configuration
MODE="tuntap"
WAN_IFACE="enP2p1s0"
SUBNET="10.10.0.0/24"
BRIDGE_PORT="mgbe0_0"

BRIDGE_DEV_SET=0
BRIDGE_DEV_TUNTAP="br0"
BRIDGE_DEV_MACVTAP="mgbe0_0"
BRIDGE_IP="10.10.0.10/24"
TAP_DEV="tap0"
FORWARD_ONLY=0
CLEAN_ALL=0

# For L1 VM
# WAN_IFACE="enp0s1"
# BRIDGE_PORT="enp0s1"

usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -m, --mode <tuntap|macvtap>  Mode to use (default: tuntap)"
    echo "  -w, --wan <iface>            WAN interface for NAT (default: enP2p1s0)"
    echo "  -b, --bridge-dev <dev>       Bridge device (default: br0 for tuntap, mgbe0_0 for macvtap)"
    echo "  -t, --tap <dev>              Tap device (default: tap0)"
    echo "  -p, --port <iface>           Physical port to add to the bridge (optional, for tuntap only)"
    echo "  -f, --forward-only           Only set up forwarding rules (skips interface creation)"
    echo "  -c, --clean-all              Clean up tap device and bridge device"
    echo "  -h, --help                   Show this help message"
}

setup_forwarding() {
    if [[ "$WAN_IFACE" == "$BRIDGE_PORT" ]]; then
        return
    fi

    # Enable IPv4 forwarding
    sudo sysctl -w net.ipv4.ip_forward=1

    # NAT: guest subnet -> uplink
    sudo iptables -t nat -C POSTROUTING -s $SUBNET -o $WAN_IFACE -j MASQUERADE 2>/dev/null || \
    sudo iptables -t nat -A POSTROUTING -s $SUBNET -o $WAN_IFACE -j MASQUERADE

    # Forwarding rules
    sudo iptables -C FORWARD -i $BRIDGE_DEV -o $WAN_IFACE -j ACCEPT 2>/dev/null || \
    sudo iptables -A FORWARD -i $BRIDGE_DEV -o $WAN_IFACE -j ACCEPT

    sudo iptables -C FORWARD -i $WAN_IFACE -o $BRIDGE_DEV -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    sudo iptables -A FORWARD -i $WAN_IFACE -o $BRIDGE_DEV -m state --state RELATED,ESTABLISHED -j ACCEPT
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -m|--mode)
            MODE="$2"
            shift 2
            ;;
        -w|--wan)
            WAN_IFACE="$2"
            shift 2
            ;;
        -b|--bridge-dev)
            BRIDGE_DEV="$2"
            BRIDGE_DEV_SET=1
            shift 2
            ;;
        -t|--tap)
            TAP_DEV="$2"
            shift 2
            ;;
        -p|--port)
            BRIDGE_PORT="$2"
            shift 2
            ;;
        -f|--forward-only)
            FORWARD_ONLY=1
            shift 1
            ;;
        -c|--clean-all)
            CLEAN_ALL=1
            shift 1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

if [[ "$MODE" != "tuntap" && "$MODE" != "macvtap" ]]; then
    echo "Error: Mode must be either 'tuntap' or 'macvtap'."
    usage
    exit 1
fi

# Set defaults based on mode if not explicitly set
if [[ "$MODE" == "macvtap" ]]; then
    [[ $BRIDGE_DEV_SET -eq 0 ]] && BRIDGE_DEV="$BRIDGE_DEV_MACVTAP"
else
    [[ $BRIDGE_DEV_SET -eq 0 ]] && BRIDGE_DEV="$BRIDGE_DEV_TUNTAP"
fi

if [[ $FORWARD_ONLY -eq 1 ]]; then
    echo "Setting up forwarding rules only..."
    setup_forwarding
    echo "Forwarding rules set up successfully."
    exit 0
fi

if [[ $CLEAN_ALL -eq 1 ]]; then
    echo "Cleaning up devices..."
    
    # Remove all tap devices enslaved to the bridge
    for dev_info in $(ip -brief link show master $BRIDGE_DEV 2>/dev/null | awk '{print $1}'); do
        dev=${dev_info%%@*}
        # Check if it's a virtual device via sysfs. Physical devices won't be in this directory.
        if [[ -d "/sys/devices/virtual/net/$dev" ]]; then
            echo "Removing virtual tap device $dev..."
            sudo ip link set $dev down 2>/dev/null || true
            sudo ip link delete $dev 2>/dev/null || true
        else
            echo "Keeping physical device $dev..."
        fi
    done
    
    # We only want to delete the BRIDGE_DEV if it is actually a virtual device
    if [[ -d "/sys/devices/virtual/net/$BRIDGE_DEV" ]]; then
        echo "Removing virtual bridge device $BRIDGE_DEV..."
        sudo ip link set $BRIDGE_DEV down 2>/dev/null || true
        sudo ip link delete $BRIDGE_DEV 2>/dev/null || true
    fi

    # Remove all macvtap devices linked across the system
    for dev_info in $(ip -brief link show type macvtap 2>/dev/null | awk '{print $1}'); do
        dev=${dev_info%%@*}
        echo "Removing macvtap device $dev..."
        sudo ip link set $dev down 2>/dev/null || true
        sudo ip link delete $dev 2>/dev/null || true
    done
    
    echo "Cleanup complete."
    exit 0
fi

if ip link show $TAP_DEV >/dev/null 2>&1; then
    echo "Cleaning up existing $TAP_DEV..."
    sudo ip link set $TAP_DEV down
    sudo ip link delete $TAP_DEV
fi

if [[ "$MODE" == "macvtap" ]]; then
    # Create a virtual network device for L1
    sudo ip link add link $BRIDGE_DEV name $TAP_DEV type macvtap mode bridge
else
    if ! ip link show $BRIDGE_DEV >/dev/null 2>&1; then
        PORT_IPS=()
        PORT_GWS=()
        PORT_DNS=""
        PORT_DOMAINS=""
        if [[ -n "$BRIDGE_PORT" ]] && ip link show "$BRIDGE_PORT" >/dev/null 2>&1; then
            for ip in $(ip -4 -o addr show dev "$BRIDGE_PORT" | awk '{print $4}'); do
                PORT_IPS+=("$ip")
            done
            for gw in $(ip -4 route show default dev "$BRIDGE_PORT" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}'); do
                PORT_GWS+=("$gw")
            done
            if command -v resolvectl >/dev/null 2>&1; then
                PORT_DNS=$(resolvectl dns "$BRIDGE_PORT" 2>/dev/null | awk -F': ' '{print $2}')
                PORT_DOMAINS=$(resolvectl domain "$BRIDGE_PORT" 2>/dev/null | awk -F': ' '{print $2}')
            fi

            echo "Flushing IP address from $BRIDGE_PORT..."
            sudo ip addr flush dev "$BRIDGE_PORT"
        fi

        echo "Creating bridge device $BRIDGE_DEV..."
        sudo ip link add name "$BRIDGE_DEV" type bridge
        sudo ip link set "$BRIDGE_DEV" up
        
        if [[ ${#PORT_IPS[@]} -gt 0 ]]; then
            echo "Moving IP addresses to $BRIDGE_DEV..."
            for ip in "${PORT_IPS[@]}"; do
                sudo ip addr add "$ip" dev "$BRIDGE_DEV"
            done

            if [[ ${#PORT_GWS[@]} -gt 0 ]]; then
                echo "Restoring default routes on $BRIDGE_DEV..."
                for gw in "${PORT_GWS[@]}"; do
                    sudo ip route add default via "$gw" dev "$BRIDGE_DEV"
                done
            fi

            if command -v resolvectl >/dev/null 2>&1; then
                if [[ -n "$PORT_DNS" ]]; then
                    echo "Restoring DNS settings on $BRIDGE_DEV..."
                    sudo resolvectl dns "$BRIDGE_DEV" $PORT_DNS
                fi
                if [[ -n "$PORT_DOMAINS" ]]; then
                    # - starts testing removing '-*' from domain since it is safe from empty
                    echo "Restoring DNS domains on $BRIDGE_DEV..."
                    sudo resolvectl domain "$BRIDGE_DEV" $PORT_DOMAINS
                fi
            fi
        else
            # Assign an IP so the host can communicate with VMs in the subnet
            sudo ip addr add "$BRIDGE_IP" dev "$BRIDGE_DEV"
        fi
    fi

    if [[ -n "$BRIDGE_PORT" ]]; then
        echo "Adding physical port $BRIDGE_PORT to bridge $BRIDGE_DEV..."
        sudo ip link set $BRIDGE_PORT master $BRIDGE_DEV
    fi

    # Create a virtual network device for L1
    sudo ip tuntap add $TAP_DEV mode tap

    # Put virtual network device under bridge device
    sudo ip link set $TAP_DEV master $BRIDGE_DEV
fi

# Match the MTU size on jetson 10Gbps network interface
sudo ip link set dev $TAP_DEV mtu 1466

# Bring up virtual network device for L1
sudo ip link set $TAP_DEV up

if [[ "$MODE" == "tuntap" ]]; then
    setup_forwarding
fi

echo "Bridge network set up successfully in $MODE mode."
echo "Virtual Network Device: $TAP_DEV"
