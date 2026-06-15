#!/usr/bin/env bats

setup() {
    export BATS_RUNNING="true"
    export MOCK_DIR="${BATS_TEST_DIRNAME}/mock_bin"
    mkdir -p "$MOCK_DIR"
    export PATH="${MOCK_DIR}:$PATH"

    # Set up transient workspace environment
    export SMELTER_ROOT="${BATS_TEST_DIRNAME}/.."
    
    # Mock smelter configuration variables
    export SMELTER_DEFAULT_USER="testuser"
    export SMELTER_DEFAULT_PASSWORD="testpassword"
    export SMELTER_TIMEZONE="Europe/London"
    
    # Create temporary mock public key
    export MOCK_KEY_FILE="${MOCK_DIR}/mock_key.pub"
    echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPtestkey" > "$MOCK_KEY_FILE"
    export SMELTER_SSH_KEY_PATH="$MOCK_KEY_FILE"

    # Track invocations in log files
    export VIRT_INSTALL_LOG="${MOCK_DIR}/virt_install.log"
    export QEMU_IMG_LOG="${MOCK_DIR}/qemu_img.log"
    export VIRSH_LOG="${MOCK_DIR}/virsh.log"
    export WGET_LOG="${MOCK_DIR}/wget.log"
    export SYSPREP_LOG="${MOCK_DIR}/virt_sysprep.log"
    export SPARSIFY_LOG="${MOCK_DIR}/virt_sparsify.log"

    # Create mock virt-install
    cat << 'EOF' > "${MOCK_DIR}/virt-install"
#!/bin/bash
echo "virt-install called with: $*" >> "$VIRT_INSTALL_LOG"
exit 0
EOF
    chmod +x "${MOCK_DIR}/virt-install"

    # Create mock qemu-img
    cat << 'EOF' > "${MOCK_DIR}/qemu-img"
#!/bin/bash
echo "qemu-img called with: $*" >> "$QEMU_IMG_LOG"
# Create dummy file to represent created image
for arg in "$@"; do
    if [[ "$arg" == *.qcow2 ]]; then
        touch "$arg"
    fi
done
exit 0
EOF
    chmod +x "${MOCK_DIR}/qemu-img"

    # Create mock virt-sysprep
    cat << 'EOF' > "${MOCK_DIR}/virt-sysprep"
#!/bin/bash
echo "virt-sysprep called with: $*" >> "$SYSPREP_LOG"
exit 0
EOF
    chmod +x "${MOCK_DIR}/virt-sysprep"

    # Create mock virt-sparsify
    cat << 'EOF' > "${MOCK_DIR}/virt-sparsify"
#!/bin/bash
echo "virt-sparsify called with: $*" >> "$SPARSIFY_LOG"
for arg in "$@"; do
    if [[ "$arg" == *.qcow2 ]] && [[ "$arg" != *"target_disk"* ]]; then
        touch "$arg"
    fi
done
exit 0
EOF
    chmod +x "${MOCK_DIR}/virt-sparsify"

    # Create mock virsh
    cat << 'EOF' > "${MOCK_DIR}/virsh"
#!/bin/bash
echo "virsh called with: $*" >> "$VIRSH_LOG"
if [[ "$*" == *"dominfo"* ]]; then
    # Return failure (not running) to mock clean state
    exit 1
fi
exit 0
EOF
    chmod +x "${MOCK_DIR}/virsh"

    # Create mock wget
    cat << 'EOF' > "${MOCK_DIR}/wget"
#!/bin/bash
echo "wget called with: $*" >> "$WGET_LOG"
# Create file
for ((i=1; i<=$#; i++)); do
    if [[ "${!i}" == "-O" ]]; then
        val=$((i+1))
        touch "${!val}"
    fi
done
exit 0
EOF
    chmod +x "${MOCK_DIR}/wget"

    # Create mock sha256sum
    cat << 'EOF' > "${MOCK_DIR}/sha256sum"
#!/bin/bash
if [ -f "$1" ]; then
    echo "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef  $1"
else
    echo "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef  stdin"
fi
exit 0
EOF
    chmod +x "${MOCK_DIR}/sha256sum"
}

teardown() {
    rm -rf "$MOCK_DIR"
    rm -rf "${SMELTER_ROOT}/downloads"
}

@test "smelt_image.sh executes full workflow for local ISO" {
    # Target files
    local dummy_iso="${MOCK_DIR}/dummy.iso"
    touch "$dummy_iso"
    
    local output_img="${MOCK_DIR}/output.qcow2"
    rm -f "$output_img" "${output_img}.sha256"
    
    # Configure variables that smelt_image expects
    export DISTRO="azurelinux"
    export VERSION="4.0"
    export ISO_PATH="$dummy_iso"
    export OUTPUT_PATH="$output_img"
    export PROFILE="base"
    export VCPU=4
    export MEMORY=8192
    export DISK_SIZE=30
    
    # Run core script
    run "${SMELTER_ROOT}/lib/smelt_image.sh"
    
    [ "$status" -eq 0 ]
    
    # Verify outputs
    [ -f "$output_img" ]
    [ -f "${output_img}.sha256" ]
    
    # Assert mock calls happened
    [ -f "$VIRT_INSTALL_LOG" ]
    [ -f "$QEMU_IMG_LOG" ]
    [ -f "$SYSPREP_LOG" ]
    [ -f "$SPARSIFY_LOG" ]
    
    # Verify virt-install options
    local virt_install_content
    virt_install_content=$(cat "$VIRT_INSTALL_LOG")
    [[ "$virt_install_content" == *"--name smelter-azurelinux-4.0-base"* ]]
    [[ "$virt_install_content" == *"--memory 8192"* ]]
    [[ "$virt_install_content" == *"--vcpus 4"* ]]
    [[ "$virt_install_content" == *"--install kernel="* ]]
    [[ "$virt_install_content" == *"--disk path=$dummy_iso,device=cdrom,readonly=on"* ]]
    [[ "$virt_install_content" == *"--osinfo name=fedora40"* ]]
    [[ "$virt_install_content" == *"--wait=-1"* ]]
}

@test "smelt_image.sh downloads remote URL and caches it" {
    local output_img="${MOCK_DIR}/output.qcow2"
    rm -f "$output_img"
    
    export DISTRO="azurelinux"
    export VERSION="4.0"
    export ISO_PATH="http://example.com/AzureLinux-4.0-x86_64.iso"
    export OUTPUT_PATH="$output_img"
    export PROFILE="base"
    export VCPU=2
    export MEMORY=4096
    export DISK_SIZE=20

    # Ensure downloads dir doesn't exist
    rm -rf "${SMELTER_ROOT}/downloads"

    run "${SMELTER_ROOT}/lib/smelt_image.sh"
    [ "$status" -eq 0 ]

    # Verify download was triggered
    [ -f "$WGET_LOG" ]
    local wget_content
    wget_content=$(cat "$WGET_LOG")
    [[ "$wget_content" == *"http://example.com/AzureLinux-4.0-x86_64.iso"* ]]
    
    # Verify cached file is inside downloads dir
    [ -f "${SMELTER_ROOT}/downloads/AzureLinux-4.0-x86_64.iso" ]
    
    # Run a second time to verify cache is used (no additional wget log additions)
    rm -f "$WGET_LOG"
    run "${SMELTER_ROOT}/lib/smelt_image.sh"
    [ "$status" -eq 0 ]
    [ ! -f "$WGET_LOG" ]
}
