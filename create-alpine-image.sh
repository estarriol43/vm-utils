#!/bin/bash
set -e

# Defaults
IMAGE_NAME="alpine.img"
IMAGE_SIZE="20G"

usage() {
    echo "Usage: $0 [-n IMAGE_NAME] [-s IMAGE_SIZE] [-k SSH_KEY]"
    echo "  -n  Output image filename  (default: $IMAGE_NAME)"
    echo "  -s  Image size             (default: $IMAGE_SIZE)"
    echo "  -k  SSH public key file    (default: auto-detected)"
    exit 1
}

while getopts "n:k:s:h" opt; do
    case "$opt" in
        n) IMAGE_NAME="$OPTARG" ;;
        s) IMAGE_SIZE="$OPTARG" ;;
        k) SSH_KEY_INPUT="$OPTARG" ;;
        h|*) usage ;;
    esac
done

ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/cloud/generic_alpine-3.22.4-aarch64-uefi-tiny-r0.qcow2"
TARBALL_NAME=$(basename "$ALPINE_URL")
MOUNT_POINT="/mnt"

echo "Using Alpine image URL: $ALPINE_URL"

# Download the Alpine base image
if [ ! -f "$TARBALL_NAME" ]; then
    echo "Downloading Alpine base image..."
    wget "$ALPINE_URL" -O "$TARBALL_NAME"
else
    echo "Image $TARBALL_NAME already exists, skipping download."
fi

# convert to raw
echo "Converting image to raw..."
qemu-img convert -f qcow2 -O raw "$TARBALL_NAME" "$IMAGE_NAME"

# resize VM disk
echo "Resizing to $IMAGE_SIZE..."
qemu-img resize "$IMAGE_NAME" -f raw "$IMAGE_SIZE"

# resize VM partition
echo "Fixing and resizing partition..."
printf 'Fix\n' | parted ---pretend-input-tty "$IMAGE_NAME" print
parted -s "$IMAGE_NAME" unit % resizepart 2 100% print

# Setup loop device with partitions
echo "Setting up loop device..."
LOOP_DEV=$(sudo losetup -fP --show "$IMAGE_NAME")

# resize filesystem
echo "Resizing filesystem on ${LOOP_DEV}p2..."
sudo e2fsck -f "${LOOP_DEV}p2"
sudo resize2fs "${LOOP_DEV}p2"

echo "Mounting image to $MOUNT_POINT..."
sudo mount "${LOOP_DEV}p2" "$MOUNT_POINT"

echo "Disabling cloud-init..."
sudo mkdir -p "$MOUNT_POINT/etc/cloud"
sudo touch "$MOUNT_POINT/etc/cloud/cloud-init.disabled"

echo "Configuring root access..."
if [ -f "$MOUNT_POINT/etc/passwd" ]; then
    # Ensure root uses /bin/ash instead of bash
    sudo sed -i '1s|^.*$|root:x:0:0:root:/root:/bin/ash|' "$MOUNT_POINT/etc/passwd"
else
    echo "Warning: $MOUNT_POINT/etc/passwd not found in image"
fi

# Ensure password is removed for root in shadow file to allow key login
if [ -f "$MOUNT_POINT/etc/shadow" ]; then
    sudo sed -i 's/^root:[^:]*:/root::/' "$MOUNT_POINT/etc/shadow"
fi

echo "Configuring SSH login..."
SSH_KEY=""

if [ -n "$SSH_KEY_INPUT" ]; then
    if [ -f "$SSH_KEY_INPUT" ]; then
        SSH_KEY="$SSH_KEY_INPUT"
    else
        echo "Error: Specified SSH key file $SSH_KEY_INPUT not found."
        sudo umount "$MOUNT_POINT"
        sudo losetup -d "$LOOP_DEV"
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
    fi
fi

# Generate SSH host keys locally and copy to image
echo "Generating SSH host keys locally..."
TEMP_KEYS_DIR=$(mktemp -d)

# Generating keys with empty passphrase, suppressing output
ssh-keygen -t rsa -b 4096 -f "$TEMP_KEYS_DIR/ssh_host_rsa_key" -N "" >/dev/null 2>&1
ssh-keygen -t ecdsa -f "$TEMP_KEYS_DIR/ssh_host_ecdsa_key" -N "" >/dev/null 2>&1
ssh-keygen -t ed25519 -f "$TEMP_KEYS_DIR/ssh_host_ed25519_key" -N "" >/dev/null 2>&1

echo "Copying host keys to image..."
sudo cp "$TEMP_KEYS_DIR/ssh_host_"* "$MOUNT_POINT/etc/ssh/"

# Fix permissions
sudo chmod 644 "$MOUNT_POINT/etc/ssh/ssh_host_"*.pub
for key in "$MOUNT_POINT/etc/ssh/ssh_host_"*; do
    if [[ "$key" != *.pub ]]; then
        sudo chmod 600 "$key"
    fi
done

rm -rf "$TEMP_KEYS_DIR"

echo "Replacing ttyAMA0 with ttyS0 in inittab..."
if [ -f "$MOUNT_POINT/etc/inittab" ]; then
    sudo sed -i 's/ttyAMA0/ttyS0/g' "$MOUNT_POINT/etc/inittab"
fi

# Clean up
echo "Unmounting image and detaching loop device..."
sudo umount "$MOUNT_POINT"
sudo losetup -d "$LOOP_DEV"

echo "Alpine cloud image created successfully at $(pwd)/$IMAGE_NAME"
