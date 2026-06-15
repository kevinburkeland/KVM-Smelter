#!/bin/bash
set -euo pipefail

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
source "${SCRIPT_DIR}/common.sh"

# Force libguestfs to run QEMU directly (as root) to prevent host permission / AppArmor / SELinux blockages
export LIBGUESTFS_BACKEND=direct

# Global variables for cleanup
VM_NAME=""
TEMP_DIR=""
ISO_MOUNT=""
SQUASHFS_MOUNT=""
HTTP_PID=""
TARGET_DISK=""

undefine_vm_domain() {
    local domain="$1"

    # UEFI guests create NVRAM entries that require --nvram for undefine.
    if ! virsh undefine "$domain" &>/dev/null; then
        virsh undefine "$domain" --nvram &>/dev/null || true
    fi
}

wait_for_vm_shutdown() {
    local domain="$1"
    local timeout="${SMELTER_INSTALL_TIMEOUT_SEC:-7200}"
    local elapsed=0
    local state=""

    log_info "Waiting for installer VM to fully power off..."
    while [ "$elapsed" -lt "$timeout" ]; do
        if ! virsh dominfo "$domain" &>/dev/null; then
            # Domain no longer exists, which is equivalent to finished for transient guests.
            return 0
        fi

        state=$(virsh domstate "$domain" 2>/dev/null | tr -d '\r' | xargs)
        case "$state" in
            "shut off"|"crashed"|"pmsuspended")
                return 0
                ;;
        esac

        sleep 2
        elapsed=$((elapsed + 2))
    done

    log_err "Timeout waiting for VM '$domain' to shut down after ${timeout}s."
    return 1
}

cleanup() {
    local rc=$?

    # Stop HTTP server if running
    if [ -n "${HTTP_PID:-}" ] && kill -0 "${HTTP_PID}" 2>/dev/null; then
        kill "${HTTP_PID}" &>/dev/null || true
    fi

    # Unmount squashfs if it was kept mounted
    if [ -n "${SQUASHFS_MOUNT:-}" ] && mountpoint -q "${SQUASHFS_MOUNT}" 2>/dev/null; then
        umount "${SQUASHFS_MOUNT}" &>/dev/null || true
    fi

    # Unmount ISO if it was kept mounted
    if [ -n "${ISO_MOUNT:-}" ] && mountpoint -q "${ISO_MOUNT}" 2>/dev/null; then
        umount "${ISO_MOUNT}" &>/dev/null || true
    fi

    # Check if the VM is still defined/running in libvirt
    if [ -n "${VM_NAME:-}" ] && virsh dominfo "$VM_NAME" &>/dev/null; then
        log_info "Cleaning up transient VM: $VM_NAME"
        virsh destroy "$VM_NAME" &>/dev/null || true
        undefine_vm_domain "$VM_NAME"
    fi

    # Clean up temporary VM install disk
    if [ -n "${TARGET_DISK:-}" ] && [ -f "${TARGET_DISK}" ]; then
        if [ "$rc" -ne 0 ] && [ "${SMELTER_KEEP_FAILED_TEMP:-1}" = "1" ]; then
            log_info "Build failed; preserving temporary VM disk at: $TARGET_DISK"
        else
            rm -f -- "$TARGET_DISK"
        fi
    fi
    
    # Clean up temp disk & configs
    if [ -n "${TEMP_DIR:-}" ] && [ -d "${TEMP_DIR}" ]; then
        if [ "$rc" -ne 0 ] && [ "${SMELTER_KEEP_FAILED_TEMP:-1}" = "1" ]; then
            log_info "Build failed; preserving temporary files at: $TEMP_DIR"
            log_info "Set SMELTER_KEEP_FAILED_TEMP=0 to always auto-clean temp files."
        else
            log_info "Cleaning up temporary files..."
            rm -rf -- "$TEMP_DIR"
        fi
    fi
}
trap cleanup EXIT

main() {
    # Check for required tools
    check_and_install_dependencies "yq" "virt-install" "qemu-img" "virt-sysprep" "virt-sparsify" "wget" "sha256sum" "libvirt-daemon" "cpio" "zstd" "file" "mksquashfs"

    # Ensure guestfs appliance can read host kernels (especially on Ubuntu/Debian where default permissions are 600 or 700)
    # Since this script runs as root, we can automatically fix the permissions if needed.
    if [ -z "${BATS_RUNNING:-}" ]; then
        log_info "Checking host kernel permissions in /boot..."
        local k
        for k in /boot/vmlinuz-*; do
            if [ -f "$k" ]; then
                if ! stat -c '%A' "$k" | grep -q 'r..$' ; then
                    log_info "Updating permissions on $k to make it world-readable for libguestfs..."
                    chmod 644 "$k"
                fi
            fi
        done
    fi

    # Make sure we have the required arguments set (in case called directly)
    if [ -z "${DISTRO:-}" ]; then
        parse_smelter_args "$@"
    fi

    # Load distro configuration
    DISTRO_MODULE="${SCRIPT_DIR}/distros/${DISTRO}.sh"
    if [ ! -f "$DISTRO_MODULE" ]; then
        log_err "Distro module not found at $DISTRO_MODULE"
        exit 1
    fi
    source "$DISTRO_MODULE"

    # Load distro-specific defaults
    get_distro_iso_defaults

    # Resolve ISO path (handle downloads if URL)
    local local_iso=""
    if [[ "$ISO_PATH" =~ ^https?:// ]]; then
        local download_dir="${SMELTER_ROOT}/downloads"
        mkdir -p "$download_dir"
        local_iso="${download_dir}/${ISO_NAME}"
        
        if [ ! -f "$local_iso" ]; then
            log_info "Downloading ISO from $ISO_PATH..."
            wget -q "$ISO_PATH" -O "$local_iso"
        else
            log_info "Using cached ISO at $local_iso"
        fi
    else
        local_iso="$ISO_PATH"
        if [ ! -f "$local_iso" ]; then
            log_err "Local ISO file not found at $local_iso"
            exit 1
        fi
    fi

    # Sync ISO to libvirt storage pool to prevent QEMU permission/AppArmor/SELinux issues
    local libvirt_iso="/var/lib/libvirt/images/${ISO_NAME}"
    # If running inside unit tests, bypass physical sync to preserve mock expectations
    if [ -z "${BATS_RUNNING:-}" ]; then
        if [ ! -f "$libvirt_iso" ] || ! cmp -s "$local_iso" "$libvirt_iso"; then
            log_info "Syncing ISO to libvirt images storage pool: $libvirt_iso"
            mkdir -p /var/lib/libvirt/images
            install -m 644 -- "$local_iso" "$libvirt_iso"
        fi
        local_iso="$libvirt_iso"
    fi

    # Locate and validate template profile
    local inst_type
    inst_type=$(get_installer_type)
    
    local template_ext=""
    case "$inst_type" in
        kickstart) template_ext="ks" ;;
        preseed) template_ext="cfg" ;;
        autoinstall) template_ext="yaml" ;;
        *) log_err "Unknown installer type: $inst_type"; exit 1 ;;
    esac

    local template_file="${SMELTER_ROOT}/foundry/profiles/${DISTRO}/${PROFILE}.${template_ext}"
    if [ ! -f "$template_file" ]; then
        log_err "Template profile not found at $template_file"
        exit 1
    fi

    # Read SSH key
    if [ -z "${SMELTER_SSH_KEY_PATH:-}" ] || [ ! -f "$SMELTER_SSH_KEY_PATH" ]; then
        log_err "SSH public key file not configured or not found. Please run setup.sh first."
        exit 1
    fi
    local ssh_key
    ssh_key=$(cat "$SMELTER_SSH_KEY_PATH")

    # Define variables for VM setup
    local random_id="${RANDOM}"
    VM_NAME="smelter-${DISTRO}-${VERSION}-${PROFILE}-${random_id}"
    
    # Establish a clean, isolated temp directory.
    # Default to a repo-local transient path to avoid exhausting small /tmp tmpfs mounts.
    local temp_root="${SMELTER_TEMP_ROOT:-${SMELTER_ROOT}/tmp}"
    mkdir -p "$temp_root"
    mkdir -p "${temp_root}/libguestfs-cache"
    TEMP_DIR=$(mktemp -d -p "$temp_root" smelter_XXXXXX)
    chmod 755 "$TEMP_DIR"

    # Keep libguestfs and related tools off small system /tmp mounts.
    export TMPDIR="$temp_root"
    export LIBGUESTFS_TMPDIR="$temp_root"
    export LIBGUESTFS_CACHEDIR="${temp_root}/libguestfs-cache"

    # Determine host bridge IP and a free port for HTTP serving.
    # For CUSTOM_INITRD distros (e.g. Azure Linux live ISO), the squashfs is served
    # from the host over HTTP so Anaconda can fetch it without a loop-device conflict.
    local bridge_if="${SMELTER_BRIDGE_IF:-virbr0}"
    local bridge_ip="192.168.122.1"
    local http_port=8089
    if [ -z "${BATS_RUNNING:-}" ]; then
        local resolved_ip
        resolved_ip=$(ip -o -4 addr show dev "$bridge_if" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
        if [ -n "$resolved_ip" ]; then
            bridge_ip="$resolved_ip"
        fi
        local port
        for port in $(seq 8080 8180); do
            if ! ss -tuln | grep -q ":${port} " 2>/dev/null; then
                http_port=$port
                break
            fi
        done
    fi
    # The liveimg URL points to a xattr-stripped squashfs served from TEMP_DIR.
    # Azure Linux's squashfs carries security.ima and security.evm xattrs on every
    # file. rsync with -X (used by pyanaconda) tries to copy these to the target, but
    # EVM rejects the write → rsync exits 23. Stripping xattrs via mksquashfs -no-xattrs
    # before serving eliminates these failures entirely.
    local liveimg_url="http://${bridge_ip}:${http_port}/clean_squashfs.img"

    log_info "Generating unattended installation configuration..."
    
    # Replace placeholders in the template profile
    local inst_config="${TEMP_DIR}/installer-config.${template_ext}"
    cp "$template_file" "$inst_config"
    
    # Perform substitutions safely using python3 literal replace to avoid delimiter conflicts (e.g. '@' in SSH keys)
    EXPORT_USERNAME="${SMELTER_DEFAULT_USER:-azureuser}" \
    EXPORT_PASSWORD="${SMELTER_DEFAULT_PASSWORD:-azurelinux}" \
    EXPORT_SSH_KEY="${ssh_key}" \
    EXPORT_TIMEZONE="${SMELTER_TIMEZONE:-America/Los_Angeles}" \
    EXPORT_LIVEIMG_URL="${liveimg_url}" \
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

    # Resolve os variant
    local resolved_os
    resolved_os=$(resolve_supported_os_variant "$OS_VARIANT_ARG")

    log_info "Creating blank target disk image (size: ${DISK_SIZE}G)..."
    local temp_disk="${TEMP_DIR}/target_disk.qcow2"
    if [ -z "${BATS_RUNNING:-}" ]; then
        temp_disk="/var/lib/libvirt/images/${VM_NAME}-target.qcow2"
    fi
    TARGET_DISK="$temp_disk"
    rm -f -- "$temp_disk"
    qemu-img create -f qcow2 "$temp_disk" "${DISK_SIZE}G" > /dev/null
    chmod 666 "$temp_disk"

    log_info "Launching unattended OS installation in KVM..."
    log_info "VM Name: $VM_NAME"
    log_info "Using OS Variant: $resolved_os"

    # Select bridge interface
    local network_arg="network=default"
    local bridge_if="${SMELTER_BRIDGE_IF:-virbr0}"
    if ip link show "$bridge_if" &>/dev/null; then
        network_arg="bridge=${bridge_if}"
    fi

    # Assemble extra arguments depending on installer type
    local extra_args=""
    case "$inst_type" in
        kickstart)
            if [ "${CUSTOM_INITRD:-}" = "true" ]; then
                extra_args="inst.ks=/installer-config.${template_ext} console=ttyS0"
                if [ -n "${EXTRA_ARGS_OVERRIDE:-}" ]; then
                    extra_args="inst.ks=/installer-config.${template_ext} ${EXTRA_ARGS_OVERRIDE}"
                fi
            else
                extra_args="inst.ks=file:/run/initramfs/installer-config.${template_ext} console=ttyS0"
                if [ -n "${EXTRA_ARGS_OVERRIDE:-}" ]; then
                    extra_args="inst.ks=file:/run/initramfs/installer-config.${template_ext} ${EXTRA_ARGS_OVERRIDE}"
                fi
            fi
            ;;
        *)
            log_err "Distro installer type '$inst_type' is not yet implemented in smelter_image.sh"
            exit 1
            ;;
    esac

    # Handle custom initrd unpacking and customization if required
    local custom_kernel=""
    local custom_initrd=""
    if [ "${CUSTOM_INITRD:-}" = "true" ]; then
        log_info "Preparing customized initrd for offline installation..."
        custom_kernel="${TEMP_DIR}/vmlinuz"
        custom_initrd="${TEMP_DIR}/custom_initrd"
        
        if [ -n "${BATS_RUNNING:-}" ]; then
            # Under BATS tests, create mock files to satisfy tests
            touch "$custom_kernel" "$custom_initrd"
        else
            # 1. Mount the ISO to extract kernel, initrd, and the squashfs source
            local iso_mount="${TEMP_DIR}/iso_mount"
            mkdir -p "$iso_mount"
            log_info "Mounting ISO to extract kernel and initrd..."
            mount -o loop,ro "$local_iso" "$iso_mount"
            ISO_MOUNT="$iso_mount"

            # 2. Copy kernel and initrd
            cp "${iso_mount}/${ISO_KERNEL_PATH}" "$custom_kernel"
            local orig_initrd="${TEMP_DIR}/orig_initrd"
            cp "${iso_mount}/${ISO_INITRD_PATH}" "$orig_initrd"

            # 3. Repack the squashfs without xattrs to fix rsync exit 23.
            # Azure Linux's squashfs has security.ima and security.evm xattrs on every file.
            # pyanaconda runs: rsync -pogAXtlHrDx ...
            # The -X flag tries to copy those xattrs to the target, but EVM/IMA block
            # them → rsync exits 23 (partial transfer). Stripping xattrs before serving
            # makes rsync's -X a silent no-op (no xattrs = nothing to fail on).
            local squashfs_src="${iso_mount}/LiveOS/squashfs.img"
            local squashfs_mount="${TEMP_DIR}/squashfs_mount"
            local clean_squashfs="${TEMP_DIR}/clean_squashfs.img"
            mkdir -p "$squashfs_mount"
            log_info "Mounting squashfs to repack without xattrs (this takes a few minutes)..."
            mount -o loop,ro "$squashfs_src" "$squashfs_mount"
            SQUASHFS_MOUNT="$squashfs_mount"
            mksquashfs "$squashfs_mount" "$clean_squashfs" -no-xattrs -comp gzip -noappend -quiet
            log_info "Clean squashfs ready: $(du -sh "$clean_squashfs" | cut -f1)"
            umount "$squashfs_mount"
            rmdir "$squashfs_mount"
            SQUASHFS_MOUNT=""

            # 4. Unmount ISO — kernel, initrd, and clean squashfs already extracted
            umount "$iso_mount"
            rmdir "$iso_mount"
            ISO_MOUNT=""

            # 5. Start HTTP server serving TEMP_DIR (where clean_squashfs.img lives)
            log_info "Starting HTTP server to serve clean squashfs at: $liveimg_url"
            python3 -m http.server --directory "${TEMP_DIR}" --bind "$bridge_ip" "$http_port" &>/dev/null &
            HTTP_PID=$!
            local http_wait=5
            while [ "$http_wait" -gt 0 ]; do
                if ss -tuln | grep -q ":${http_port} " 2>/dev/null; then break; fi
                sleep 0.5
                http_wait=$((http_wait - 1))
            done
            log_info "HTTP server (PID $HTTP_PID) ready at http://${bridge_ip}:${http_port}"
            
            # 3. Create temp directory to unpack initrd
            local initrd_unpack="${TEMP_DIR}/initrd_unpack"
            mkdir -p "$initrd_unpack"
            
            log_info "Unpacking installer initrd..."
            local file_type
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
            
            # 4. Inject pre-pivot hook script
            local hook_dir="${initrd_unpack}/var/lib/dracut/hooks/pre-pivot"
            mkdir -p "$hook_dir"
            
            cat << 'EOF' > "${hook_dir}/99-patch-anaconda.sh"
#!/bin/sh
# Dracut pre-pivot hook: copy kickstart into sysroot before pivot_root.
# NOTE: squashfs is no longer staged here — it is fetched by Anaconda over
# HTTP from the host, which avoids the EBUSY loop-device conflict that occurs
# when trying to loop-mount a copy of the squashfs that is already the live root.
echo "=== KVM-Smelter: pre-pivot hook starting ==="

if [ -f /installer-config.ks ]; then
    cp /installer-config.ks /sysroot/installer-config.ks
    chmod 644 /sysroot/installer-config.ks
    echo "=== KVM-Smelter: Copied installer-config.ks to /sysroot ==="
else
    echo "=== KVM-Smelter: WARNING: /installer-config.ks not found in initramfs ==="
fi

echo "=== KVM-Smelter: pre-pivot hook complete ==="
EOF
            chmod +x "${hook_dir}/99-patch-anaconda.sh"
            
            # 5. Copy kickstart file into unpacked initrd root
            cp "$inst_config" "${initrd_unpack}/installer-config.${template_ext}"
            
            # 6. Repack the custom initrd
            log_info "Repacking custom initrd..."
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
            
            # Clean up unpacked directory and original initrd to free space
            rm -rf "$initrd_unpack" "$orig_initrd"
        fi
    fi

    # For non-CUSTOM_INITRD distros: start HTTP server to host the kickstart file.
    # (For CUSTOM_INITRD distros like Azure Linux, the HTTP server is already started
    # above in the CUSTOM_INITRD block to serve the squashfs from the ISO mount.)
    if [ "${CUSTOM_INITRD:-}" != "true" ]; then
        log_info "Starting temporary host HTTP server at http://${bridge_ip}:${http_port} to serve kickstart..."
        python3 -m http.server --directory "$TEMP_DIR" --bind "$bridge_ip" "$http_port" &>/dev/null &
        HTTP_PID=$!

        local http_timeout=5
        while [ "$http_timeout" -gt 0 ]; do
            if ss -tuln | grep -q ":${http_port} " 2>/dev/null; then break; fi
            sleep 0.5
            http_timeout=$((http_timeout - 1))
        done

        if [ -n "$HTTP_PID" ] && kill -0 "$HTTP_PID" 2>/dev/null; then
            extra_args=$(echo "$extra_args" | sed "s|file:/run/initramfs/installer-config.${template_ext}|http://${bridge_ip}:${http_port}/installer-config.${template_ext}|g")
            log_info "Redirected inst.ks to: http://${bridge_ip}:${http_port}/installer-config.${template_ext}"
        else
            log_err "Failed to start HTTP server, falling back to local file path."
        fi
    fi

    # Run virt-install
    # --wait=-1 blocks execution until the guest VM powers off (triggered by 'poweroff' in kickstart)
    local virt_install_args=(
        --name "$VM_NAME"
        --memory "$MEMORY"
        --vcpus "$VCPU"
        --disk path="$temp_disk",format=qcow2
        --graphics none
        --osinfo "name=$resolved_os"
        --network "$network_arg"
        --serial file,path="${TEMP_DIR}/console.log"
        --wait=-1
        --noreboot
        --noautoconsole
        --quiet
    )
    
    if [ "${CUSTOM_INITRD:-}" = "true" ]; then
        local boot_opts="uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no"
        if [ -f "/usr/share/OVMF/OVMF_CODE_4M.fd" ] && [ -f "/usr/share/OVMF/OVMF_VARS_4M.fd" ]; then
            boot_opts="loader=/usr/share/OVMF/OVMF_CODE_4M.fd,loader.type=pflash,nvram.template=/usr/share/OVMF/OVMF_VARS_4M.fd"
        elif [ -f "/usr/share/edk2/ovmf/OVMF_CODE.fd" ]; then
            boot_opts="loader=/usr/share/edk2/ovmf/OVMF_CODE.fd,loader.type=pflash"
        fi
        virt_install_args+=(
            --disk path="$local_iso",device=cdrom,readonly=on
            --install kernel="$custom_kernel",initrd="$custom_initrd"
            --boot "$boot_opts"
        )
    else
        local location_arg="$local_iso"
        if [ -n "${ISO_KERNEL_PATH:-}" ] && [ -n "${ISO_INITRD_PATH:-}" ]; then
            location_arg="${local_iso},kernel=${ISO_KERNEL_PATH},initrd=${ISO_INITRD_PATH}"
        fi
        virt_install_args+=(
            --location "$location_arg"
            --initrd-inject "$inst_config"
            --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=yes
        )
    fi

    virt-install "${virt_install_args[@]}" --extra-args "$extra_args"

    # Some virt-install/libvirt combinations can return before the guest is fully done.
    # Gate the rest of the pipeline on actual VM power-off state.
    if ! wait_for_vm_shutdown "$VM_NAME"; then
        if [ -f "${TEMP_DIR}/console.log" ]; then
            log_err "=== GUEST CONSOLE LOG (tail) ==="
            tail -n 120 "${TEMP_DIR}/console.log" >&2 || true
            log_err "=== END GUEST CONSOLE LOG ==="
        fi
        exit 1
    fi

    # Terminate the HTTP server and unmount the ISO immediately after virt-install exits
    # (cleanup() will also handle this on error paths via the EXIT trap)
    if [ -n "${HTTP_PID:-}" ] && kill -0 "$HTTP_PID" 2>/dev/null; then
        kill "$HTTP_PID" &>/dev/null || true
        HTTP_PID=""
    fi
    if [ -n "${ISO_MOUNT:-}" ] && mountpoint -q "$ISO_MOUNT" 2>/dev/null; then
        umount "$ISO_MOUNT" &>/dev/null || true
        ISO_MOUNT=""
    fi

    log_info "Installation complete! VM has powered off."
    
    # Force destroy the VM if it auto-started or rebooted, then undefine it
    virsh destroy "$VM_NAME" &>/dev/null || true
    undefine_vm_domain "$VM_NAME"
    
    log_info "Waiting for VM process to release disk lock..."
    local lock_timeout=30
    local elapsed=0
    local err_msg=""
    while [ "$elapsed" -lt "$lock_timeout" ]; do
        # qemu-img info will fail if an exclusive write lock is still held on the image
        if err_msg=$(qemu-img info "$temp_disk" 2>&1 >/dev/null); then
            break
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    if [ "$elapsed" -eq "$lock_timeout" ]; then
        log_err "Timeout waiting for disk lock to be released on $temp_disk"
        log_err "Last lock check error: $err_msg"
        exit 1
    fi
    sleep 1 # Settle time

    log_info "Running virt-sysprep to sanitize the guest image..."
    if ! virt-sysprep -a "$temp_disk" --quiet; then
        log_err "virt-sysprep failed. Re-running with debugging enabled to capture the issue..."
        if [ -f "${TEMP_DIR}/console.log" ]; then
            log_err "=== GUEST CONSOLE LOG (from installation phase) ==="
            cat "${TEMP_DIR}/console.log" >&2
            log_err "=== END GUEST CONSOLE LOG ==="
        fi
        LIBGUESTFS_DEBUG=1 LIBGUESTFS_TRACE=1 virt-sysprep -a "$temp_disk" || true
        exit 1
    fi

    log_info "Running virt-sparsify to compress and optimize target image..."
    # Ensure parent directory of output exists
    local out_dir
    out_dir=$(dirname "$OUTPUT_PATH")
    mkdir -p "$out_dir"
    
    local sparsify_tmpdir_check="${SMELTER_SPARSIFY_TMPDIR_CHECK:-continue}"
    if ! virt-sparsify --tmp "$temp_root" --check-tmpdir "$sparsify_tmpdir_check" --compress "$temp_disk" "$OUTPUT_PATH" --quiet; then
        log_err "virt-sparsify failed. Re-running with debugging enabled to capture the issue..."
        LIBGUESTFS_DEBUG=1 LIBGUESTFS_TRACE=1 virt-sparsify --tmp "$temp_root" --check-tmpdir "$sparsify_tmpdir_check" --compress "$temp_disk" "$OUTPUT_PATH" || true
        exit 1
    fi

    log_info "Generating SHA256 checksum fingerprint..."
    local final_filename
    final_filename=$(basename "$OUTPUT_PATH")
    local final_dir
    final_dir=$(cd "$out_dir" && pwd)
    
    (cd "$final_dir" && sha256sum "$final_filename" > "${final_filename}.sha256")

    log_info "Successfully smelted cloud image!"
    log_info "Image Path: $(realpath "$OUTPUT_PATH")"
    log_info "Fingerprint: $(realpath "${OUTPUT_PATH}.sha256")"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
