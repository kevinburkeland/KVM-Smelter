#!/bin/bash
set -euo pipefail

SCRATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRATCH_DIR")"

TEST_DIR="/tmp/smelter-test-interactive"
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"
chmod 777 "$TEST_DIR"

ISO_MOUNT="${TEST_DIR}/iso_mount"
mkdir -p "$ISO_MOUNT"

echo "=== Mounting ISO to extract kernel and initrd ==="
sudo mount -o loop,ro /var/lib/libvirt/images/AzureLinux-4.0-x86_64.iso "$ISO_MOUNT"
cp "${ISO_MOUNT}/boot/x86_64/loader/linux" "${TEST_DIR}/linux"
cp "${ISO_MOUNT}/boot/x86_64/loader/initrd" "${TEST_DIR}/initrd"
sudo umount "$ISO_MOUNT"

# Create directory to make ISO
ISO_DIR="${TEST_DIR}/iso_dir"
mkdir -p "$ISO_DIR"

# Substitutions for kickstart
USERNAME="kevin"
PASSWORD="azurelinux"
SSH_KEY=$(cat /home/kevin/.ssh/id_ed25519.pub)
TIMEZONE="America/Los_Angeles"

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

# Build Kickstart ISO
KS_ISO="${TEST_DIR}/kickstart.iso"
genisoimage -output "$KS_ISO" -volid "OEMDRV" -rational-rock -joliet "$ISO_DIR"
chmod 666 "$KS_ISO"

# Create target disk
TARGET_DISK="${TEST_DIR}/target_disk.qcow2"
qemu-img create -f qcow2 "$TARGET_DISK" 10G
chmod 666 "$TARGET_DISK"

# Create initrd injection structure
INITRD_DIR="${TEST_DIR}/initrd_dir"
HOOK_DIR="${INITRD_DIR}/usr/lib/dracut/hooks/pre-pivot"
mkdir -p "$HOOK_DIR"

# Create pre-pivot hook script
cat << 'EOF' > "$HOOK_DIR/99-patch-anaconda.sh"
#!/bin/sh
# Dracut hook to mount OEMDRV and copy kickstart to sysroot
echo "=== smelter initrd: searching for OEMDRV ==="
mkdir -p /tmp/oemdrv
if mount -o ro /dev/disk/by-label/OEMDRV /tmp/oemdrv 2>/dev/null || mount -o ro /dev/sr1 /tmp/oemdrv 2>/dev/null || mount -o ro /dev/vdb /tmp/oemdrv 2>/dev/null; then
    echo "=== smelter initrd: OEMDRV mounted successfully ==="
    cp /tmp/oemdrv/installer-config.ks /sysroot/installer-config.ks
    chmod 644 /sysroot/installer-config.ks
    umount /tmp/oemdrv
    echo "=== smelter initrd: copied kickstart to sysroot ==="
else
    echo "=== smelter initrd: failed to mount OEMDRV ==="
fi
EOF
chmod +x "$HOOK_DIR/99-patch-anaconda.sh"

# Build custom initrd
echo "=== Appending hook to custom initrd ==="
cp "${TEST_DIR}/initrd" "${TEST_DIR}/custom_initrd"
(cd "$INITRD_DIR" && find usr | cpio -o -H newc | zstd) >> "${TEST_DIR}/custom_initrd"
chmod 666 "${TEST_DIR}/linux" "${TEST_DIR}/custom_initrd"

VM_NAME="test-uefi-interactive"

# Check if VM already exists and destroy it
if sudo virsh dominfo "$VM_NAME" &>/dev/null; then
    sudo virsh destroy "$VM_NAME" &>/dev/null || true
    sudo virsh undefine "$VM_NAME" --nvram &>/dev/null || true
fi

# Detect network
NETWORK_ARG="bridge=virbr0"

echo "=== Starting VM with serial pty ==="
sudo virt-install \
    --name "$VM_NAME" \
    --memory 4096 \
    --vcpus 2 \
    --disk path="$TARGET_DISK",format=qcow2 \
    --disk path="$KS_ISO",device=disk,readonly=on \
    --disk path=/var/lib/libvirt/images/AzureLinux-4.0-x86_64.iso,device=cdrom,readonly=on \
    --install kernel="${TEST_DIR}/linux",initrd="${TEST_DIR}/custom_initrd" \
    --extra-args "console=ttyS0,115200 root=live:CDLABEL=CDROM rd.live.image azl.autoinstall inst.ks=/installer-config.ks" \
    --graphics none \
    --osinfo name=fedora40 \
    --network "$NETWORK_ARG" \
    --boot loader=/usr/share/OVMF/OVMF_CODE_4M.fd,loader.type=pflash,nvram.template=/usr/share/OVMF/OVMF_VARS_4M.fd \
    --serial pty \
    --noreboot \
    --wait=0 \
    --noautoconsole

echo "=== Waiting for PTY to be allocated ==="
sleep 3
PTY_PATH=$(sudo virsh ttyconsole "$VM_NAME")
echo "PTY is located at: $PTY_PATH"

CONSOLE_LOG="${TEST_DIR}/console.log"
touch "$CONSOLE_LOG"
chmod 666 "$CONSOLE_LOG"

# Start background logger
sudo cat "$PTY_PATH" > "$CONSOLE_LOG" &
logger_pid=$!

echo "=== Waiting for VM to boot and drop to shell (120s) ==="
sleep 120

echo "=== Sending diagnostic commands to guest PTY ==="
# Send Enter to wake up shell
sudo sh -c "echo '' > $PTY_PATH"
sleep 1
sudo sh -c "echo 'blkid' > $PTY_PATH"
sleep 2
sudo sh -c "echo 'mount' > $PTY_PATH"
sleep 2
sudo sh -c "echo 'ls -l /dev/disk/by-label/' > $PTY_PATH"
sleep 2
sudo sh -c "echo 'ls -l /' > $PTY_PATH"
sleep 2
sudo sh -c "echo 'cat /tmp/anaconda.log' > $PTY_PATH"
sleep 5

echo "=== Terminating VM ==="
sudo virsh destroy "$VM_NAME" || true
sudo virsh undefine "$VM_NAME" --nvram || true

sudo kill "$logger_pid" || true

echo "=== Diagnostic log results: ==="
cat "$CONSOLE_LOG"
