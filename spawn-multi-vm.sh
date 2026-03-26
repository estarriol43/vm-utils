#!/bin/bash
set -e

# Configuration
NUM_VMS=2
CUSTOM_VM_OPTS=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--num)
            NUM_VMS="$2"
            shift 2
            ;;
        -o|--opts)
            CUSTOM_VM_OPTS="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [-n num_vms] [-o \"custom vm options\"]"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

SESSION_NAME="vms"
BASE_DISK=~/ubuntu-2404-no-network.img
UPLINK="end0"
BRIDGE="br0"
USERNAME="root"

# Prompt for sudo password so we can automatically fill it in the tmux window
echo -n "Enter sudo password for $USER: "
read -s SUDO_PASS
echo ""

echo "Spawning $NUM_VMS VMs..."

# Dependencies Check
if ! command -v tmux &> /dev/null; then
    echo "Error: tmux is not installed. Please install it first."
    exit 1
fi

if ! command -v expect &> /dev/null; then
    echo "Error: expect is not installed. Please install it first."
    exit 1
fi

# Reset tmux session
tmux kill-session -t $SESSION_NAME 2>/dev/null || true
tmux new-session -d -s $SESSION_NAME

for i in $(seq 0 $((NUM_VMS - 1))); do
    TAP="tap${i}"
    VM_DISK="/home/jianlin/ubuntu-vm${i}.img"
    WINDOW_NAME="vm${i}"

    echo "=== Setting up VM ${i} ==="
    
    # 1. Setup network
    echo "Configuring network: $TAP -> $BRIDGE -> $UPLINK"
    echo $SUDO_PASS | sudo -S ./bridge-l0.sh -t $TAP -b $BRIDGE -u $UPLINK
    
    # 2. Prepare independent disk image
    # Note: KVM needs independent read-write disk copies so images don't get corrupted
    if [ ! -f "$VM_DISK" ]; then
        if [ -f "$BASE_DISK" ]; then
            echo "Copying base disk $BASE_DISK to $VM_DISK (this may take a moment)..."
            cp "$BASE_DISK" "$VM_DISK"
        else
            echo "Warning: Base disk $BASE_DISK not found. Using $BASE_DISK directly."
            VM_DISK="$BASE_DISK"
        fi
    fi

    # 3. Create expect script inside tmux
    echo "Starting VM ${i} in tmux window: $WINDOW_NAME"
    
    VM_CMD="sudo ./run-vm.sh -d $VM_DISK -t $TAP $CUSTOM_VM_OPTS"
    EXP_SCRIPT="/tmp/spawn_vm_${i}.exp"
    cat <<EOF > "$EXP_SCRIPT"
set timeout -1
spawn $VM_CMD
expect {
    "password for" {
        sleep 0.5
        send "$SUDO_PASS\r"
        exp_continue
    }
    "ubuntu login:" {
        sleep 0.5
        send "${USERNAME}\r"
        exp_continue
    }
    "root@ubuntu:~#" {
        sleep 0.5
        send "ip addr add 10.10.0.$((i + 100))/24 dev enp0s1\r"
        sleep 0.5
        send "ip link set enp0s1 up\r"
        sleep 0.5
        send "ip route add default via 10.10.0.10 dev enp0s1\r"
        sleep 0.5
        send "echo \"nameserver 8.8.8.8\" > /etc/resolv.conf\r"
    }
}
interact
EOF

    EXPECT_CMD="expect $EXP_SCRIPT"

    if [ $i -eq 0 ]; then
        tmux rename-window -t ${SESSION_NAME}:0 "$WINDOW_NAME"
        tmux send-keys -t ${SESSION_NAME}:0 "$EXPECT_CMD" C-m
    else
        tmux new-window -t ${SESSION_NAME} -n "$WINDOW_NAME"
        tmux send-keys -t ${SESSION_NAME}:"${WINDOW_NAME}" "$EXPECT_CMD" C-m
    fi
done

echo ""
echo "Successfully configured and spawned $NUM_VMS VMs!"
echo "Attach to the tmux session to view VM consoles:"
echo "    tmux attach -t $SESSION_NAME"
