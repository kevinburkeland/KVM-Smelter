#!/bin/bash
# Azure Linux 4.0 distro configuration for KVM-Smelter

# ==========================================
# Function: get_installer_type
# Returns the installation configuration type (kickstart/preseed/autoinstall)
# ==========================================
get_installer_type() {
    echo "kickstart"
}

# ==========================================
# Function: get_distro_iso_defaults
# Returns distro-specific ISO details
# ==========================================
get_distro_iso_defaults() {
    ISO_NAME="AzureLinux-${VERSION}-x86_64.iso"
    DEFAULT_URL="https://aka.ms/azurelinux-${VERSION}-x86_64.iso"
    
    # Azure Linux 4.0 is rebased on Fedora, so fedora40 serves as a robust compatibility variant
    OS_VARIANT_ARG="fedora40"
    # Kernel and initrd paths inside the ISO structure
    ISO_KERNEL_PATH="boot/x86_64/loader/linux"
    ISO_INITRD_PATH="boot/x86_64/loader/initrd"
    
    # Live-media parameters required for the Azure Linux direct-boot installer
    # NOTE: Do NOT include inst.repo=cdrom here — liveimg in the kickstart IS the installation source.
    # inst.repo=cdrom tells Anaconda to configure a package-based repo from CDROM (which doesn't exist
    # on a live ISO), causing the "installation source not set up" interactive menu failure.
    EXTRA_ARGS_OVERRIDE="console=ttyS0,115200 root=live:CDLABEL=CDROM rd.live.image azl.autoinstall selinux=0 enforcing=0 audit=0 ima_appraise=off evm=0"
    CUSTOM_INITRD="true"
    
    export ISO_NAME DEFAULT_URL OS_VARIANT_ARG ISO_KERNEL_PATH ISO_INITRD_PATH EXTRA_ARGS_OVERRIDE CUSTOM_INITRD
}
