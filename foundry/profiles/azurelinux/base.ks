# KVM-Smelter Kickstart Profile for Azure Linux 4.0 (Base)
keyboard us
lang en_US.UTF-8

# Configure DHCP network interface
network --bootproto=dhcp --device=link --activate

# Use the xattr-stripped squashfs served from the host over HTTP.
# __LIVEIMG_URL__ is substituted at build time with http://BRIDGE_IP:PORT/clean_squashfs.img.
# HTTP delivery avoids the EBUSY loop-device conflict (can't loop-mount a copy of
# the squashfs that is already the live rootfs). The squashfs is pre-repacked without
# xattrs so rsync -X has nothing to fail on (fixes rsync exit 23).
liveimg --url=__LIVEIMG_URL__

# Enable shadow passwords and SHA512 hashing
authselect --useshadow --passalgo=sha512

# Avoid security xattr policy conflicts during image copy in live installs.
selinux --disabled

# Set Root Password
rootpw --plaintext __PASSWORD__

# Run the Setup Agent on first boot
firstboot --disable

# Set system timezone
timezone __TIMEZONE__ --utc

# Create a default user in wheel group
user --name=__USERNAME__ --plaintext --password=__PASSWORD__ --groups=wheel

# Partitioning configuration
bootloader --location=mbr
clearpart --all --initlabel
autopart --type=plain

# Power off VM automatically when installation is complete
poweroff

# Packages to install
%packages
@core
openssh-server
qemu-guest-agent
dnf
curl
wget
sudo
%end

# Post-installation scripting
%post --log=/var/log/anaconda/post-install.log
# Set up passwordless sudo for user
echo "__USERNAME__ ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/__USERNAME__
chmod 0440 /etc/sudoers.d/__USERNAME__

# Setup default user SSH directory and authorized_keys
mkdir -p /home/__USERNAME__/.ssh
echo "__SSH_KEY__" >> /home/__USERNAME__/.ssh/authorized_keys
chmod 700 /home/__USERNAME__/.ssh
chmod 600 /home/__USERNAME__/.ssh/authorized_keys
chown -R __USERNAME__:__USERNAME__ /home/__USERNAME__/.ssh

# Setup root SSH directory and authorized_keys
mkdir -p /root/.ssh
echo "__SSH_KEY__" >> /root/.ssh/authorized_keys
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys

# Best-effort service enablement. Some liveimg variants may not provide all unit
# files at the services module stage, which can hard-fail installation.
if systemctl list-unit-files 2>/dev/null | grep -q '^sshd\.service'; then
	systemctl enable sshd || true
fi
if systemctl list-unit-files 2>/dev/null | grep -q '^qemu-guest-agent\.service'; then
	systemctl enable qemu-guest-agent || true
fi
%end
