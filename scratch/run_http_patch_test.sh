#!/bin/bash
set -euo pipefail

SCRATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRATCH_DIR")"

echo "=== Setting up test paths ==="
TEST_DIR="/tmp/smelter-test-http"
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"
chmod 777 "$TEST_DIR"

ISO_MOUNT="${TEST_DIR}/iso_mount"
mkdir -p "$ISO_MOUNT"

echo "=== Mounting ISO to extract kernel and initrd ==="
sudo mount -o loop,ro /var/lib/libvirt/images/AzureLinux-4.0-x86_64.iso "$ISO_MOUNT"

# Copy original kernel and initrd
cp "${ISO_MOUNT}/boot/x86_64/loader/linux" "${TEST_DIR}/linux"
cp "${ISO_MOUNT}/boot/x86_64/loader/initrd" "${TEST_DIR}/initrd"

sudo umount "$ISO_MOUNT"

echo "=== Creating custom initrd hook ==="
HOOK_SRC_DIR="${TEST_DIR}/hook_dir"
mkdir -p "${HOOK_SRC_DIR}/usr/lib/dracut/hooks/pre-pivot"

cat << 'EOF' > "${HOOK_SRC_DIR}/usr/lib/dracut/hooks/pre-pivot/99-patch-anaconda.sh"
#!/bin/sh
# Dracut hook to patch anaconda-launcher.sh to wait for network online in guest
if [ -f /sysroot/usr/local/bin/anaconda-launcher.sh ]; then
    echo "=== smelter: Patching anaconda-launcher.sh ==="
    cat << 'SUBEOF' > /tmp/netwait.sh
if grep -q 'inst\.ks=http' /proc/cmdline; then
    echo "=== smelter: Waiting for network/DHCP to be online ==="
    i=0
    while [ $i -lt 30 ]; do
        if ip route show | grep -q default; then
            echo "=== smelter: Network is online! ==="
            break
        fi
        sleep 1
        i=$((i + 1))
    done
fi
SUBEOF
    # Insert the netwait helper on line 2
    sed -i '2r /tmp/netwait.sh' /sysroot/usr/local/bin/anaconda-launcher.sh
    rm -f /tmp/netwait.sh
    echo "=== smelter: Patch applied successfully! ==="
fi
EOF
chmod +x "${HOOK_SRC_DIR}/usr/lib/dracut/hooks/pre-pivot/99-patch-anaconda.sh"

echo "=== Appending hook to custom initrd ==="
cp "${TEST_DIR}/initrd" "${TEST_DIR}/custom_initrd"
(cd "$HOOK_SRC_DIR" && find usr | cpio -o -H newc | zstd) >> "${TEST_DIR}/custom_initrd"
chmod 666 "${TEST_DIR}/linux" "${TEST_DIR}/custom_initrd"

# Substitutions for kickstart
USERNAME="kevin"
PASSWORD="azurelinux"
SSH_KEY=$(cat /home/kevin/.ssh/id_ed25519.pub)
TIMEZONE="America/Los_Angeles"

echo "=== Generating kickstart file ==="
template_file="${ROOT_DIR}/foundry/profiles/azurelinux/base.ks"
inst_config="${TEST_DIR}/installer-config.ks"

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

echo "=== Starting HTTP server ==="
BRIDGE_IP="192.168.122.1"
resolved_ip=$(ip -o -4 addr show dev virbr0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
if [ -n "$resolved_ip" ]; then
    BRIDGE_IP="$resolved_ip"
fi

HTTP_PORT=8089
for port in $(seq 8080 8180); do
    if ! ss -tuln | grep -q ":${port} " 2>/dev/null; then
        HTTP_PORT=$port
        break
    fi
done

echo "Starting host HTTP server at http://${BRIDGE_IP}:${HTTP_PORT}..."
python3 -m http.server --directory "$TEST_DIR" --bind "$BRIDGE_IP" "$HTTP_PORT" &>/dev/null &
http_pid=$!

cleanup() {
    echo "Terminating HTTP server..."
    kill "$http_pid" &>/dev/null || true
}
trap cleanup EXIT

# Settle HTTP
sleep 1

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
VM_NAME="test-uefi-http"

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
    --disk path=/var/lib/libvirt/images/AzureLinux-4.0-x86_64.iso,device=cdrom,readonly=on \
    --install kernel="${TEST_DIR}/linux",initrd="${TEST_DIR}/custom_initrd" \
    --extra-args "console=ttyS0,115200 root=live:CDLABEL=CDROM rd.live.image azl.autoinstall inst.ks=http://${BRIDGE_IP}:${HTTP_PORT}/installer-config.ks" \
    --graphics none \
    --osinfo name=fedora40 \
    --network "$NETWORK_ARG" \
    --boot loader=/usr/share/OVMF/OVMF_CODE_4M.fd,loader.type=pflash,nvram.template=/usr/share/OVMF/OVMF_VARS_4M.fd \
    --serial file,path="$CONSOLE_LOG" \
    --noreboot \
    --wait=-1 \
    --noautoconsole

echo "=== VM execution completed! ==="
