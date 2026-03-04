#!/bin/bash

MEM="4096"
SMP="8"
REALM=""
NESTED=""
PVM=""
KVM_MODE="protected"

ROOT="/home/jianlin/nested"
KERNEL="${ROOT}/linux-l0/arch/arm64/boot/Image"
KVMTOOL_PATH="${ROOT}/kvmtool-l1/lkvm-static"
DISK_PATH="${ROOT}/ubuntu-2404.img"

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
      --pvm             Enable protected VM mode (--protected)
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
            PVM="--protected"
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

$KVMTOOL_PATH run \
    -c $SMP \
    -m $MEM \
    -k $KERNEL \
    -d $DISK_PATH \
    -p "kvm-arm.mode=$KVM_MODE rw swiotlb=force" \
    --loglevel=debug \
    -n mode=tap,tapif=tap0,vhost=1 \
    $PVM $NESTED $REALM
