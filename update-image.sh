#!/bin/bash

IMAGE=$1
FILE_LIST=$2

e2fsck -y -f $IMAGE

# Mount the partition
sudo mount $IMAGE /mnt

while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip empty lines and comments
    [[ -z "$line" || "$line" == \#* ]] && continue
    echo "Copying $line ..."
    sudo cp -r $line /mnt/root
done < "$FILE_LIST"

sync

# Umount the partition
sudo umount /mnt
