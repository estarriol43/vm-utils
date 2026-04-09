#!/bin/bash

MEM="12288"
SMP="4"
REALM=""
NESTED=""
PVM=""
KVM_MODE="protected"
TAP_DEV="tap0"
NET_MODE="tuntap"
BRIDGE="br0"

ROOT="/home/jianlin/nested"
KERNEL="${ROOT}/linux-l1/arch/arm64/boot/Image"
KVMTOOL_PATH="${ROOT}/kvmtool-l1/lkvm-static"
DISK_PATH="${ROOT}/ubuntu-2404-l1.img"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Run a VM using kvmtool.

Options:
  -k, --kernel PATH     Path to the kernel Image (default: ${KERNEL})
  -d, --disk PATH       Path to the disk image    (default: ${DISK_PATH})
  -s, --smp N           Number of vCPUs           (default: ${SMP})
  -m, --mem MB          Memory size in MB          (default: ${MEM})
      --kvm MODE        KVM mode                   (default: ${KVM_MODE})
      --kvmtool PATH    Path to lkvm binary        (default: ${KVMTOOL_PATH})
      --realm           Enable realm mode (--realm --restricted_mem)
      --nested          Enable nested mode (--nested --e2h0)
      --pvm             Enable protected VM mode (--pkvm)
  -t, --tap DEV         Tap device                 (default: ${TAP_DEV})
  -n, --net MODE        Network mode [tuntap|macvtap|none] (default: ${NET_MODE})
  -b, --bridge BRIDGE   Network device to bridge (default: ${BRIDGE})
  -h, --help            Show this help message and exit
EOF
}

while :
do
    case "$1" in
        -k | --kernel)
            KERNEL="$2"
            shift 2
            ;;
        --kvm)
            KVM_MODE="$2"
            shift 2
            ;;
        --realm)
            REALM="--realm --restricted_mem"
            shift 1
            ;;
        --nested)
            NESTED="--nested --e2h0"
            shift 1
            ;;
        --pvm)
            PVM="--pkvm"
            shift 1
            ;;
        --kvmtool)
            KVMTOOL_PATH="$2"
            shift 2
            ;;
        -d | --disk )
            DISK_PATH="$2"
            shift 2
            ;;
        -s | --smp )
            SMP="$2"
            shift 2
            ;;
        -m | --mem )
            MEM="$2"
            shift 2
            ;;
        -t | --tap )
            TAP_DEV="$2"
            shift 2
            ;;
        -n | --net )
            NET_MODE="$2"
            shift 2
            ;;
        -b | --bridge)
            BRIDGE="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        -* | --* )
            echo "Unknown option: $1" >&2
            echo "Run '$(basename "$0") --help' for usage." >&2
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

if [ "$NET_MODE" != "none" ]; then
    if ! ip link show $TAP_DEV > /dev/null 2>&1; then
        echo "Network interface $TAP_DEV does not exist on $BRIDGE. Auto-creating via bridge.sh..."
        SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
        if [ "$NET_MODE" = "macvtap" ]; then
            bash "$SCRIPT_DIR/bridge.sh" -t "$TAP_DEV" -b $BRIDGE -m macvtap
        else
            bash "$SCRIPT_DIR/bridge.sh" -t "$TAP_DEV" -b $BRIDGE
        fi
    fi
fi

if [ "$NET_MODE" = "none" ]; then
    NET_ARGS="mode=none"
elif [ "$NET_MODE" = "macvtap" ]; then
    TAP_INDEX=$(cat /sys/class/net/$TAP_DEV/ifindex)
    TAP_MAC=$(cat /sys/class/net/$TAP_DEV/address)
    TAP_DEV=/dev/tap$TAP_INDEX
    NET_ARGS="mode=tap,tapif=$TAP_DEV,guest_mac=$TAP_MAC"
else
    NET_ARGS="mode=tap,tapif=$TAP_DEV,vhost=1"
fi

$KVMTOOL_PATH run \
    -c $SMP \
    -m $MEM \
    -k $KERNEL \
    -d $DISK_PATH \
    -p "kvm-arm.mode=$KVM_MODE rw swiotlb=force" \
    --loglevel=debug \
    -n $NET_ARGS \
    --rng \
    $PVM $NESTED $REALM
