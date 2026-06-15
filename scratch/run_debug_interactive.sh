#!/bin/bash
set -euo pipefail

SCRATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRATCH_DIR")"

TEST_DIR="/tmp/smelter-debug-interactive"
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"
chmod 777 "$TEST_DIR"

ISO_PATH="/var/lib/libvirt/images/AzureLinux-4.0-x86_64.iso"

# Cleanup handler
HTTP_PID=""
SQUASHFS_MOUNT=""
ISO_MOUNT=""
cleanup_debug() {
    [ -n "$HTTP_PID" ] && kill "$HTTP_PID" &>/dev/null || true
    [ -n "$SQUASHFS_MOUNT" ] && umount "$SQUASHFS_MOUNT" &>/dev/null || true
    [ -n "$ISO_MOUNT" ] && umount "$ISO_MOUNT" &>/dev/null || true
    virsh destroy "smelter-debug-interactive" &>/dev/null || true
}
trap cleanup_debug EXIT

# Determine bridge IP and free port
BRIDGE_IP=$(ip -o -4 addr show dev virbr0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
BRIDGE_IP="${BRIDGE_IP:-192.168.122.1}"
HTTP_PORT=8082
for p in $(seq 8080 8180); do
    if ! ss -tuln | grep -q ":${p} " 2>/dev/null; then
        HTTP_PORT=$p
        break
    fi
done
LIVEIMG_URL="http://${BRIDGE_IP}:${HTTP_PORT}/clean_squashfs.img"

# Mount ISO
ISO_MOUNT_DIR="${TEST_DIR}/iso_mount"
mkdir -p "$ISO_MOUNT_DIR"
echo "=== Mounting ISO ==="
mount -o loop,ro "$ISO_PATH" "$ISO_MOUNT_DIR"
ISO_MOUNT="$ISO_MOUNT_DIR"

custom_kernel="${TEST_DIR}/vmlinuz"
orig_initrd="${TEST_DIR}/orig_initrd"
cp "${ISO_MOUNT_DIR}/boot/x86_64/loader/linux" "$custom_kernel"
cp "${ISO_MOUNT_DIR}/boot/x86_64/loader/initrd" "$orig_initrd"
echo "=== Kernel and initrd extracted ==="

# Mount squashfs and repack without xattrs to fix rsync exit 23.
# Azure Linux squashfs has security.ima and security.evm xattrs on every file.
# pyanaconda runs: rsync -pogAXtlHrDx ...
# The -X flag tries to copy those xattrs to the target; EVM/IMA block the write
# causing rsync exit 23 (partial transfer). Stripping xattrs at source fixes this.
SQUASHFS_MOUNT_DIR="${TEST_DIR}/squashfs_mount"
CLEAN_SQUASHFS="${TEST_DIR}/clean_squashfs.img"
mkdir -p "$SQUASHFS_MOUNT_DIR"
echo "=== Mounting squashfs from ISO ==="
mount -o loop,ro "${ISO_MOUNT_DIR}/LiveOS/squashfs.img" "$SQUASHFS_MOUNT_DIR"
SQUASHFS_MOUNT="$SQUASHFS_MOUNT_DIR"

echo "=== Repacking squashfs without xattrs (this takes a few minutes) ==="
mksquashfs "$SQUASHFS_MOUNT_DIR" "$CLEAN_SQUASHFS" -no-xattrs -comp gzip -noappend -quiet
echo "=== Clean squashfs ready: $(du -sh "$CLEAN_SQUASHFS" | cut -f1) ==="

umount "$SQUASHFS_MOUNT_DIR"
rmdir "$SQUASHFS_MOUNT_DIR"
SQUASHFS_MOUNT=""

# ISO no longer needed
umount "$ISO_MOUNT_DIR"
rmdir "$ISO_MOUNT_DIR"
ISO_MOUNT=""

# Start HTTP server serving TEST_DIR (where clean_squashfs.img lives)
echo "=== Starting HTTP server at http://${BRIDGE_IP}:${HTTP_PORT} ==="
python3 -m http.server --directory "$TEST_DIR" --bind "$BRIDGE_IP" "$HTTP_PORT" &>/dev/null &
HTTP_PID=$!
for _ in 1 2 3 4 5; do
    if ss -tuln | grep -q ":${HTTP_PORT} " 2>/dev/null; then break; fi
    sleep 0.5
done
echo "=== HTTP server ready: $LIVEIMG_URL ==="

# Prepare kickstart with HTTP liveimg URL substituted
USERNAME="kevin"
PASSWORD="azurelinux"
SSH_KEY=""
if [ -f /home/kevin/.ssh/id_ed25519.pub ]; then
    SSH_KEY=$(cat /home/kevin/.ssh/id_ed25519.pub)
elif [ -f /home/kevin/.ssh/id_rsa.pub ]; then
    SSH_KEY=$(cat /home/kevin/.ssh/id_rsa.pub)
fi
TIMEZONE="America/Los_Angeles"

template_file="${ROOT_DIR}/foundry/profiles/azurelinux/base.ks"
inst_config="${TEST_DIR}/installer-config.ks"

EXPORT_USERNAME="$USERNAME" \
EXPORT_PASSWORD="$PASSWORD" \
EXPORT_SSH_KEY="$SSH_KEY" \
EXPORT_TIMEZONE="$TIMEZONE" \
EXPORT_LIVEIMG_URL="$LIVEIMG_URL" \
python3 -c '
import os, sys
with open(sys.argv[1], "r") as f:
    content = f.read()
content = content.replace("__USERNAME__", os.environ.get("EXPORT_USERNAME", ""))
content = content.replace("__PASSWORD__", os.environ.get("EXPORT_PASSWORD", ""))
content = content.replace("__SSH_KEY__", os.environ.get("EXPORT_SSH_KEY", ""))
content = content.replace("__TIMEZONE__", os.environ.get("EXPORT_TIMEZONE", ""))
content = content.replace("__LIVEIMG_URL__", os.environ.get("EXPORT_LIVEIMG_URL", ""))
with open(sys.argv[2], "w") as f:
    f.write(content)
' "$template_file" "$inst_config"

echo "=== Kickstart generated ==="
grep -E "^liveimg" "$inst_config" || echo "  WARNING: no liveimg line found!"

# Unpack initrd
initrd_unpack="${TEST_DIR}/initrd_unpack"
mkdir -p "$initrd_unpack"
echo "=== Unpacking original initrd ==="
file_type=$(file -b "$orig_initrd")
cd "$initrd_unpack"
if [[ "$file_type" == *"Zstandard"* ]]; then
    zstd -d -c "$orig_initrd" | cpio -id --quiet
elif [[ "$file_type" == *"gzip"* ]]; then
    gzip -d -c "$orig_initrd" | cpio -id --quiet
elif [[ "$file_type" == *"XZ"* ]]; then
    xz -d -c "$orig_initrd" | cpio -id --quiet
else
    cpio -id --quiet < "$orig_initrd"
fi
cd - >/dev/null

# Inject pre-pivot hook (copies kickstart only; squashfs is served via HTTP)
hook_dir="${initrd_unpack}/var/lib/dracut/hooks/pre-pivot"
mkdir -p "$hook_dir"
cat << 'EOF' > "${hook_dir}/99-patch-anaconda.sh"
#!/bin/sh
echo "=== KVM-Smelter: pre-pivot hook starting ==="
if [ -f /installer-config.ks ]; then
    cp /installer-config.ks /sysroot/installer-config.ks
    chmod 644 /sysroot/installer-config.ks
    echo "=== KVM-Smelter: Copied installer-config.ks to /sysroot ==="
else
    echo "=== KVM-Smelter: WARNING: /installer-config.ks not found ==="
fi
echo "=== KVM-Smelter: pre-pivot hook complete ==="
EOF
chmod +x "${hook_dir}/99-patch-anaconda.sh"
cp "$inst_config" "${initrd_unpack}/installer-config.ks"

# Repack initrd
custom_initrd="${TEST_DIR}/custom_initrd"
echo "=== Repacking customized initrd ==="
cd "$initrd_unpack"
if [[ "$file_type" == *"Zstandard"* ]]; then
    find . | cpio -o -H newc --quiet | zstd -o "$custom_initrd"
elif [[ "$file_type" == *"gzip"* ]]; then
    find . | cpio -o -H newc --quiet | gzip -c > "$custom_initrd"
elif [[ "$file_type" == *"XZ"* ]]; then
    find . | cpio -o -H newc --quiet | xz -c > "$custom_initrd"
else
    find . | cpio -o -H newc --quiet > "$custom_initrd"
fi
cd - >/dev/null
rm -rf "$initrd_unpack" "$orig_initrd"

# Target disk
TARGET_DISK="${TEST_DIR}/target_disk.qcow2"
qemu-img create -f qcow2 "$TARGET_DISK" 20G
chmod 666 "$TARGET_DISK"

VM_NAME="smelter-debug-interactive"
if virsh dominfo "$VM_NAME" &>/dev/null; then
    virsh destroy "$VM_NAME" &>/dev/null || true
    virsh undefine "$VM_NAME" --nvram &>/dev/null || true
fi

NETWORK_ARG="bridge=virbr0"
boot_opts="loader=/usr/share/OVMF/OVMF_CODE_4M.fd,loader.type=pflash,nvram.template=/usr/share/OVMF/OVMF_VARS_4M.fd"

echo "=== Starting VM (blocking until completion) ==="
echo "=== liveimg URL: $LIVEIMG_URL ==="
echo "=== Console log: ${TEST_DIR}/console.log ==="
virt-install \
    --name "$VM_NAME" \
    --memory 8192 \
    --vcpus 4 \
    --disk path="$TARGET_DISK",format=qcow2 \
    --disk path="$ISO_PATH",device=cdrom,readonly=on \
    --install kernel="$custom_kernel",initrd="$custom_initrd" \
    --boot "$boot_opts" \
    --extra-args "inst.ks=/installer-config.ks console=ttyS0,115200 root=live:CDLABEL=CDROM rd.live.image azl.autoinstall enforcing=0 audit=0" \
    --graphics none \
    --osinfo name=fedora40 \
    --network "$NETWORK_ARG" \
    --serial file,path="${TEST_DIR}/console.log" \
    --noreboot \
    --wait=-1 \
    --noautoconsole

echo "=== VM finished — cleaning up ==="
kill "$HTTP_PID" &>/dev/null || true
HTTP_PID=""
virsh undefine "$VM_NAME" --nvram &>/dev/null || true

echo "=== Final Console Output ==="
cat "${TEST_DIR}/console.log"
