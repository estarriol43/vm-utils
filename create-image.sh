#!/bin/bash
set -e

# Defaults
IMAGE_NAME="cloud.img"
IMAGE_SIZE="20G"
NETCFG_FILE="01-netcfg-l1.yaml"

usage() {
    echo "Usage: $0 [-n IMAGE_NAME] [-s IMAGE_SIZE] [-c NETCFG_FILE] [-k SSH_KEY]"
    echo "  -n  Output image filename  (default: $IMAGE_NAME)"
    echo "  -s  Image size             (default: $IMAGE_SIZE)"
    echo "  -c  Netplan config file    (default: $NETCFG_FILE)"
    echo "  -k  SSH public key file    (default: auto-detected)"
    exit 1
}

while getopts "n:k:c:s:h" opt; do
    case "$opt" in
        n) IMAGE_NAME="$OPTARG" ;;
        s) IMAGE_SIZE="$OPTARG" ;;
        c) NETCFG_FILE="$OPTARG" ;;
        k) SSH_KEY_INPUT="$OPTARG" ;;
        h|*) usage ;;
    esac
done

# Derived configuration
UBUNTU_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64-root.tar.xz"
TARBALL_NAME=$(basename "$UBUNTU_URL")
MOUNT_POINT="/mnt" # Using /mnt as requested for simplicity

echo "Using Ubuntu image URL: $UBUNTU_URL"

# Create a cloud image of size 20G
echo "Creating image $IMAGE_NAME..."
qemu-img create -f raw "$IMAGE_NAME" "$IMAGE_SIZE"

# Format the image with ext4 file system
# -F forces formatting even if it's not a block device (since it's a file)
echo "Formatting image..."
mkfs.ext4 -F "$IMAGE_NAME"

# Mount the image to /mnt
echo "Mounting image to $MOUNT_POINT..."
sudo mount -o loop "$IMAGE_NAME" "$MOUNT_POINT"

# Download the Ubuntu base image
echo "Downloading Ubuntu base image..."
if [ ! -f "$TARBALL_NAME" ]; then
    wget "$UBUNTU_URL"
else
    echo "Image $TARBALL_NAME already exists, skipping download."
fi

# Move the tarball to the mount point as requested originally
# However, to be cleaner, we can just extract directly. But sticking to original flow:
# "sudo mv ... /mnt" -> We will just extract it there.

# Extract the tarball into the mounted image
echo "Extracting rootfs..."
sudo tar -xvf "$TARBALL_NAME" -C "$MOUNT_POINT"
sync

# Disable cloud-init
echo "Disabling cloud-init..."
sudo touch "$MOUNT_POINT/etc/cloud/cloud-init.disabled"

# Disable root password login
# Replaces the first line of /etc/passwd with 'root::0:0:root:/root:/bin/bash'
echo "Configuring root access..."
if [ -f "$MOUNT_POINT/etc/passwd" ]; then
    sudo sed -i '1s|^.*$|root::0:0:root:/root:/bin/bash|' "$MOUNT_POINT/etc/passwd"
else
    echo "Warning: $MOUNT_POINT/etc/passwd not found in image"
fi

# Enable SSH root login and add host's ssh key
echo "Configuring SSH root login with host key..."
SSH_KEY=""

if [ -n "$SSH_KEY_INPUT" ]; then
    if [ -f "$SSH_KEY_INPUT" ]; then
        SSH_KEY="$SSH_KEY_INPUT"
    else
        echo "Error: Specified SSH key file $SSH_KEY_INPUT not found."
        exit 1
    fi
else
    # Detect real user's home directory to find SSH keys if running with sudo
    if [ -n "$SUDO_USER" ]; then
        USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    else
        USER_HOME="$HOME"
    fi

    # Check for common key types in real user's home
    for key in "$USER_HOME/.ssh/id_rsa.pub" "$USER_HOME/.ssh/id_ed25519.pub" "$USER_HOME/.ssh/id_ecdsa.pub"; do
        if [ -f "$key" ]; then
            SSH_KEY="$key"
            break
        fi
    done
fi

if [ -z "$SSH_KEY" ]; then
    echo "Error: No SSH public key found in $USER_HOME/.ssh/"
    echo "Warning: Skipping SSH key injection."
else
    echo "Using public key: $SSH_KEY"
    sudo mkdir -p "$MOUNT_POINT/root/.ssh"
    sudo chmod 700 "$MOUNT_POINT/root/.ssh"
    sudo cp "$SSH_KEY" "$MOUNT_POINT/root/.ssh/authorized_keys"
    sudo chmod 600 "$MOUNT_POINT/root/.ssh/authorized_keys"
    
    if [ -f "$MOUNT_POINT/etc/ssh/sshd_config" ]; then
        sudo sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' "$MOUNT_POINT/etc/ssh/sshd_config"
        sudo sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' "$MOUNT_POINT/etc/ssh/sshd_config"
    else
        echo "Warning: $MOUNT_POINT/etc/ssh/sshd_config not found in image"
    fi
fi

# Generate SSH host keys locally and copy to image
echo "Generating SSH host keys locally..."
TEMP_KEYS_DIR=$(mktemp -d)

echo "Generating new host keys in $TEMP_KEYS_DIR..."
# Generating keys with empty passphrase, suppressing output
ssh-keygen -t rsa -b 4096 -f "$TEMP_KEYS_DIR/ssh_host_rsa_key" -N "" >/dev/null 2>&1
ssh-keygen -t ecdsa -f "$TEMP_KEYS_DIR/ssh_host_ecdsa_key" -N "" >/dev/null 2>&1
ssh-keygen -t ed25519 -f "$TEMP_KEYS_DIR/ssh_host_ed25519_key" -N "" >/dev/null 2>&1

echo "Copying host keys to image..."
sudo cp "$TEMP_KEYS_DIR/ssh_host_"* "$MOUNT_POINT/etc/ssh/"

# Fix permissions
# Public keys: 644
sudo chmod 644 "$MOUNT_POINT/etc/ssh/ssh_host_"*.pub
# Private keys: 600
for key in "$MOUNT_POINT/etc/ssh/ssh_host_"*; do
    if [[ "$key" != *.pub ]]; then
        sudo chmod 600 "$key"
    fi
done

rm -rf "$TEMP_KEYS_DIR"

# Enable SSH service
echo "Enabling ssh service..."
# Create the symlink directly since we can't run systemctl in chroot easily without /proc etc.
# Usually enabling ssh service means creating a symlink in /etc/systemd/system/multi-user.target.wants/
sudo ln -sf /lib/systemd/system/ssh.service "$MOUNT_POINT/etc/systemd/system/multi-user.target.wants/ssh.service" || \
sudo ln -sf /lib/systemd/system/sshd.service "$MOUNT_POINT/etc/systemd/system/multi-user.target.wants/sshd.service"

# Install netplan config
echo "Installing netplan configuration..."
sudo mkdir -p "$MOUNT_POINT/etc/netplan"
sudo cp "$NETCFG_FILE" "$MOUNT_POINT/etc/netplan/$NETCFG_FILE"
sudo chmod 644 "$MOUNT_POINT/etc/netplan/$NETCFG_FILE"

# Clean up
echo "Unmounting image..."
sudo umount "$MOUNT_POINT"

echo "Cloud image created successfully at $(pwd)/$IMAGE_NAME"
