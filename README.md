# vm-utils

This repository contains utilities for managing and spawning virtual machines (VMs) using `kvmtool`. This guide provides instructions on how to use the two primary scripts: `run-vm.sh` and `spawn-multi-vm.sh`.

## 1. `run-vm.sh`

`run-vm.sh` is a wrapper script for `kvmtool` (`lkvm-static`) that simplifies configuring and starting a single KVM virtual machine. It allows you to easily customize the VM's hardware components, network setup, and virtualization mode (such as nested virtualization or protected modes).

### Usage

```bash
./run-vm.sh [OPTIONS]
```

### Key Options

* **Hardware & Resources:**
  * `-k, --kernel PATH`: Path to the kernel Image.
  * `-d, --disk PATH`: Path to the disk image.
  * `-s, --smp N`: Number of vCPUs to allocate (default: 4).
  * `-m, --mem MB`: Memory size in MB (default: 12288 MB).
  * `-p`: Additional kernel command-line parameters.

* **Virtualization Modes:**
  * `--kvm MODE`: Set the KVM mode (default: `protected`).
  * `--realm`: Enable Arm CCA Realm mode.
  * `--nested`: Enable Nested Virtualization.
  * `--pvm`: Enable protected VM (pKVM) mode.
  * `--kvmtool PATH`: Custom path to the `lkvm-static` binary.

* **Networking:**
  * `-n, --net MODE`: Network mode (`tuntap`, `macvtap`, or `none`). Default is `tuntap`.
  * `-t, --tap DEV`: Name of the tap device to use/create (default: `tap0`).
  * `-b, --bridge BRIDGE`: Network bridge interface to attach the tap to (default: `br0`).

### Example
Start a basic VM with 2 vCPUs, 2048 MB memory, and no network:
```bash
sudo ./run-vm.sh -s 2 -m 2048 -n none
```

---

## 2. `spawn-multi-vm.sh`

`spawn-multi-vm.sh` orchestrates the creation of multiple concurrent virtual machines. To isolate execution, it launches each VM in its own `tmux` window and uses an `expect` script to automatically log in and configure the VM's network (e.g., assigning a static IP corresponding to its VM index). 

> **Prerequisites:** This script requires `tmux` and `expect` to be installed on your system.

### Usage

```bash
./spawn-multi-vm.sh [OPTIONS]
```

### Key Options

* `-n, --num`: Number of VMs to spawn (default: 2).
* `-o, --opts`: Custom options to pass down to `run-vm.sh` (e.g., `-o "--nested --pvm"`). 
* `-d, --disk`: Base disk image template. The script automatically copies this base image for each VM (e.g., `ubuntu-vm0.img`, `ubuntu-vm1.img`) to prevent KVM disk corruption.
* `-b, --bridge`: Host bridge interface for the VMs' network (default: `mgbe0_0`).
* `-u, --uplink`: Host uplink interface (default: `enP2p1s0`).

### Under the Hood
1. **Network Setup:** It creates individual `macvtap` devices (`tap0`, `tap1`, etc.) via `bridge.sh`.
2. **Launch & Automate:** It starts a new `tmux` session named `vms`. For each VM, it runs `run-vm.sh` inside a devoted window and sends standard commands through `expect` (login as root, setup `enp0s1` interface, add gateway, dns, etc.).

### Example
Spawn 3 VMs utilizing nested virtualization and provide a custom base image:
```bash
./spawn-multi-vm.sh -n 3 -o "--nested" -d /path/to/base-image.img
```

Once the script finishes executing, you can connect to the created `tmux` session to view and interact with the consoles of all spawned VMs:
```bash
tmux attach -t vms
```

---

## 3. `bridge.sh`

`bridge.sh` is a specialized networking script that automates the creation and teardown of virtual network bridges, `macvtap` interfaces, and `tap` devices. The other helper scripts (`run-vm.sh` and `spawn-multi-vm.sh`) periodically call `bridge.sh` to construct the networking pipeline.

### Usage

```bash
./bridge.sh [OPTIONS]
```

### Key Options

* **Mode & Interfaces:**
  * `-m, --mode MODE`: The device mode. Can be `tuntap` or `macvtap` (default: `tuntap`).
  * `-t, --tap DEV`: Name of the virtual tap interface to produce (default: `tap0`).
  * `-b, --bridge-dev DEV`: Name of the target bridge (default: `br0` for tuntap, `mgbe0_0` for macvtap).
  * `-p, --port IFACE`: The host's physical network port to enslave to the software bridge (default: `mgbe0_0`). IP addresses, DNS settings, and routing tables on this port are automatically migrated to the bridge object.

* **Forwarding Setup:**
  * `-f, --forward-only`: Re-applies IP forwarding (sysctl) and sets up NAT/iptables rules without managing interface devices.
  * `-w, --wan IFACE`: Dictates the upstream WAN interface for NAT when using the `--forward-only` mode (default: `enP2p1s0`).

* **State Reset Mechanism:**
  * `-c, --clean-all`: Teardown utility that locates and deletes all virtual taps, bridges, macvtaps created, and removes injected iptables forwarding rules. Crucial for wiping the network state clean.

### Examples

**Create a MacVTap Device**:
This generates a `macvtap` named `tap1` and hooks it onto host's `mgbe0_0`:
```bash
sudo ./bridge.sh -m macvtap -t tap1 -b mgbe0_0
```

**Total Cleanup**:
Remove all virtual interfaces created (tap, macvtap, vi-bridge) along with masquerading rules:
```bash
sudo ./bridge.sh --clean-all
```
