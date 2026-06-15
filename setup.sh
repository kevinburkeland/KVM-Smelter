#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the common library functions
source "${SCRIPT_DIR}/lib/common.sh"

# Ensure 'gum' is installed for interactive prompts
check_and_install_dependencies "gum"

mkdir -p "${SCRIPT_DIR}/config"
ENV_FILE="${SCRIPT_DIR}/config/smelter.env"

# Display a stylized header
gum style --foreground 99 --border-foreground 99 --border double --align center --width 50 --margin "1 2" --padding "1 4" 'KVM-Smelter Setup'

echo "We need to configure some global preferences for image smelting."
echo ""

# Get the actual user home (in case running under sudo)
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

# Default User and Passwords
echo -e "\n--- Default VM Credentials ---"
echo "These will be configured in the OS via Kickstart/installer templates."
SMELTER_DEFAULT_USER=$(gum input --prompt "Default VM Username: " --placeholder "azureuser" --value "${SMELTER_DEFAULT_USER:-$REAL_USER}")
SMELTER_DEFAULT_PASSWORD=$(gum input --prompt "Default VM Password: " --placeholder "azurelinux" --password --value "${SMELTER_DEFAULT_PASSWORD:-azurelinux}")

# System preferences
echo -e "\n--- System Settings ---"
DETECTED_TZ=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || readlink /etc/localtime | awk -F'/zoneinfo/' '{print $2}' || echo "GMT")
[ -z "$DETECTED_TZ" ] && DETECTED_TZ="GMT"
SMELTER_TIMEZONE=$(gum input --prompt "Timezone: " --placeholder "$DETECTED_TZ" --value "${SMELTER_TIMEZONE:-$DETECTED_TZ}")

# SSH Key Setup
echo -e "\n--- SSH Authentication ---"
echo "KVM-Smelter will inject an SSH public key into the VM for root and the default user."
SSH_CHOICE=$(gum choose "Use existing public key" "Generate a new ED25519 keypair")

if [ "$SSH_CHOICE" == "Use existing public key" ]; then
    DEFAULT_KEY_PATH="${REAL_HOME}/.ssh/id_ed25519.pub"
    if [ ! -f "$DEFAULT_KEY_PATH" ]; then
        DEFAULT_KEY_PATH="${REAL_HOME}/.ssh/id_rsa.pub"
    fi
    SMELTER_SSH_KEY_PATH=$(gum input --prompt "Path to public key: " --value "$DEFAULT_KEY_PATH")
    
    # Expand tilde
    SMELTER_SSH_KEY_PATH="${SMELTER_SSH_KEY_PATH/#\~/$REAL_HOME}"
    if [ ! -f "$SMELTER_SSH_KEY_PATH" ]; then
        log_err "Key file not found at $SMELTER_SSH_KEY_PATH"
        exit 1
    fi
else
    KEY_PATH="${REAL_HOME}/.ssh/id_ed25519_kvmsmelter"
    if [ -f "$KEY_PATH" ]; then
        echo "A key already exists at $KEY_PATH."
        if gum confirm "Do you want to overwrite it?"; then
            rm -f "$KEY_PATH" "${KEY_PATH}.pub"
            ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -q
            # Fix ownership since we are running as root
            chown "$REAL_USER:$REAL_USER" "$KEY_PATH" "${KEY_PATH}.pub"
            log_info "Generated new key pair at $KEY_PATH"
        else
            log_info "Keeping existing key pair at $KEY_PATH"
        fi
    else
        ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -q
        chown "$REAL_USER:$REAL_USER" "$KEY_PATH" "${KEY_PATH}.pub"
        log_info "Generated new key pair at $KEY_PATH"
    fi
    SMELTER_SSH_KEY_PATH="${KEY_PATH}.pub"
fi

# Optional: Default ISO Path
echo -e "\n--- ISO Defaults ---"
DEFAULT_ISO_DIR="${REAL_HOME}/Downloads"
DEFAULT_ISO_FILE="${DEFAULT_ISO_DIR}/AzureLinux-4.0-x86_64.iso"
SMELTER_DEFAULT_ISO=$(gum input --prompt "Default ISO Path/URL (optional): " --placeholder "$DEFAULT_ISO_FILE" --value "${SMELTER_DEFAULT_ISO:-$DEFAULT_ISO_FILE}")

# Atomic write env file
TMP_ENV_FILE=$(mktemp)
trap 'rm -f "${TMP_ENV_FILE:-}"' EXIT

cat > "$TMP_ENV_FILE" <<EOF
SMELTER_DEFAULT_USER="$SMELTER_DEFAULT_USER"
SMELTER_DEFAULT_PASSWORD="$SMELTER_DEFAULT_PASSWORD"
SMELTER_TIMEZONE="$SMELTER_TIMEZONE"
SMELTER_SSH_KEY_PATH="$SMELTER_SSH_KEY_PATH"
SMELTER_DEFAULT_ISO="$SMELTER_DEFAULT_ISO"
EOF

install -m 600 -o "$REAL_USER" -g "$REAL_USER" "$TMP_ENV_FILE" "$ENV_FILE"
rm -f "$TMP_ENV_FILE"

log_info "Setup complete! Configuration saved to $ENV_FILE"
