#!/bin/bash
set -euo pipefail

SCRATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRATCH_DIR")"

echo "=== Setting up test paths ==="
TEST_DIR="/tmp/smelter-test-cdrom"
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"
chmod 777 "$TEST_DIR"

ISO_DIR="${TEST_DIR}/iso_dir"
mkdir -p "$ISO_DIR"

# Substitutions for kickstart
USERNAME="kevin"
PASSWORD="azurelinux"
SSH_KEY=$(cat /home/kevin/.ssh/id_ed25519.pub)
TIMEZONE="America/Los_Angeles"

echo "=== Generating kickstart file ==="
template_file="${ROOT_DIR}/foundry/profiles/azurelinux/base.ks"
inst_config="${ISO_DIR}/installer-config.ks"

EXPORT_USERNAME="$USERNAME" \
EXPORT_PASSWORD="$PASSWORD" \
EXPORT_SSH_KEY="$SSH_KEY" \
EXPORT_TIMEZONE="$TIMEZONE" \
python3 -c '
import os, sys
with open(sys.argv[1], "r") as f:
    content = f.read()
content = content.replace("__USERNAME__", os.environ.get("EXPORT_USERNAME", ""))
content = content.replace("__PASSWORD__", os.environ.get("EXPORT_PASSWORD", ""))
content = content.replace("__SSH_KEY__", os.environ.get("EXPORT_SSH_KEY", ""))
content = content.replace("__TIMEZONE__", os.environ.get("EXPORT_TIMEZONE", ""))
with open(sys.argv[2], "w") as f:
    f.write(content)
' "$template_file" "$inst_config"

echo "=== Building Kickstart ISO ==="
KS_ISO="${TEST_DIR}/kickstart.iso"
rm -f "$KS_ISO"
genisoimage -output "$KS_ISO" -volid "OEMDRV" -rational-rock -joliet "$ISO_DIR"
chmod 666 "$KS_ISO"

echo "=== Creating target disk image ==="
TARGET_DISK="${TEST_DIR}/target_disk.qcow2"
rm -f "$TARGET_DISK"
qemu-img create -f qcow2 "$TARGET_DISK" 10G
chmod 666 "$TARGET_DISK"

echo "=== Preparing console log ==="
CONSOLE_LOG="${TEST_DIR}/console.log"
rm -f "$CONSOLE_LOG"
touch "$CONSOLE_LOG"
chmod 666 "$CONSOLE_LOG"

echo "=== Starting VM via virt-install ==="
VM_NAME="test-uefi-cdrom"

# Check if VM already exists and destroy it
if sudo virsh dominfo "$VM_NAME" &>/dev/null; then
    echo "Destroying existing VM $VM_NAME..."
    sudo virsh destroy "$VM_NAME" &>/dev/null || true
    sudo virsh undefine "$VM_NAME" --nvram &>/dev/null || true
fi

# Detect network
NETWORK_ARG="bridge=virbr0"

sudo virt-install \
    --name "$VM_NAME" \
    --memory 4096 \
    --vcpus 2 \
    --disk path="$TARGET_DISK",format=qcow2 \
    --disk path="$KS_ISO",device=cdrom,readonly=on \
    --location /var/lib/libvirt/images/AzureLinux-4.0-x86_64.iso,kernel=boot/x86_64/loader/linux,initrd=boot/x86_64/loader/initrd \
    --extra-args "console=ttyS0,115200 root=live:CDLABEL=CDROM rd.live.image azl.autoinstall inst.ks=cdrom:/installer-config.ks" \
    --graphics none \
    --osinfo name=fedora40 \
    --network "$NETWORK_ARG" \
    --boot loader=/usr/share/OVMF/OVMF_CODE_4M.fd,loader.type=pflash,nvram.template=/usr/share/OVMF/OVMF_VARS_4M.fd \
    --serial file,path="$CONSOLE_LOG" \
    --noreboot \
    --wait=-1 \
    --noautoconsole

echo "=== VM execution completed! ==="
