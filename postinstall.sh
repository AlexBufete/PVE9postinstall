#!/usr/bin/env bash
#===============================================================================
#  Proxmox 9 — Post-Installation Script
#===============================================================================

set -euo pipefail

#=================================
# DO THIS PART!
#=================================
NEW_USER="Username"
NEW_USER_PASSWORD="Password"
SSH_PUBLIC_KEY="Your .Pub SSH Key"
SSH_PORT=22
#^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

ENTERPRISE_LIST="/etc/apt/sources.list.d/pve-enterprise.list"
[[ -f "$ENTERPRISE_LIST" ]] && sed -i 's/^deb/#deb/' "$ENTERPRISE_LIST"

CEPH_ENTERPRISE="/etc/apt/sources.list.d/ceph.list"
[[ -f "$CEPH_ENTERPRISE" ]] && sed -i 's/^deb/#deb/' "$CEPH_ENTERPRISE"

NO_SUB_LIST="/etc/apt/sources.list.d/pve-no-subscription.list"
grep -qs "pve-no-subscription" "$NO_SUB_LIST" 2>/dev/null || \
    echo "deb http://download.proxmox.com/debian/pve trixie pve-no-subscription" > "$NO_SUB_LIST"

NAG_FILE="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
if [[ -f "$NAG_FILE" ]] && grep -q "No valid subscription" "$NAG_FILE"; then
    cp "$NAG_FILE" "${NAG_FILE}.bak"
    sed -i "s/Ext.Msg.show({/void({ \/\//g" "$NAG_FILE"
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get dist-upgrade -y -qq

apt-get install -y -qq \
    sudo curl wget git htop iotop tmux vim net-tools dnsutils \
    iputils-ping traceroute rsync unzip jq fail2ban ufw \
    lm-sensors smartmontools ethtool ncdu tree bash-completion \
    ca-certificates gnupg lsb-release

if ! id "$NEW_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$NEW_USER"
    echo "${NEW_USER}:${NEW_USER_PASSWORD}" | chpasswd
fi

usermod -aG sudo "$NEW_USER"

SSH_DIR="/home/${NEW_USER}/.ssh"
mkdir -p "$SSH_DIR"
echo "$SSH_PUBLIC_KEY" > "${SSH_DIR}/authorized_keys"
chmod 700 "$SSH_DIR"
chmod 600 "${SSH_DIR}/authorized_keys"
chown -R "${NEW_USER}:${NEW_USER}" "$SSH_DIR"

ROOT_SSH_DIR="/root/.ssh"
mkdir -p "$ROOT_SSH_DIR"
grep -qF "$SSH_PUBLIC_KEY" "${ROOT_SSH_DIR}/authorized_keys" 2>/dev/null || \
    echo "$SSH_PUBLIC_KEY" >> "${ROOT_SSH_DIR}/authorized_keys"
chmod 700 "$ROOT_SSH_DIR"
chmod 600 "${ROOT_SSH_DIR}/authorized_keys"

pveum user add "${NEW_USER}@pam" --comment "Core admin user" 2>/dev/null || true
pveum aclmod / -user "${NEW_USER}@pam" -role Administrator 2>/dev/null || true

cat > /etc/ssh/sshd_config.d/99-hardened.conf <<SSHEOF
Port ${SSH_PORT}
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
X11Forwarding no
MaxAuthTries 5
MaxSessions 10
ClientAliveInterval 300
ClientAliveCountMax 3
AllowUsers root ${NEW_USER}
Protocol 2
SSHEOF

systemctl restart sshd

echo "y" | ufw reset >/dev/null 2>&1
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow "${SSH_PORT}/tcp" >/dev/null
ufw allow 8006/tcp >/dev/null
ufw allow 5900:5999/tcp >/dev/null
ufw allow 3128/tcp >/dev/null
echo "y" | ufw enable >/dev/null

cat > /etc/fail2ban/jail.local <<F2BEOF
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5
banaction = ufw

[sshd]
enabled  = true
port     = ${SSH_PORT}
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 3
bantime  = 7200

[proxmox]
enabled  = true
port     = 8006
filter   = proxmox
logpath  = /var/log/daemon.log
maxretry = 5
bantime  = 3600
F2BEOF

mkdir -p /etc/fail2ban/filter.d
cat > /etc/fail2ban/filter.d/proxmox.conf <<FILTEOF
[Definition]
failregex = pvedaemon\[.*authentication (verification )?failure; rhost=<HOST>
ignoreregex =
FILTEOF

systemctl enable fail2ban --now
systemctl restart fail2ban

cat > /etc/sysctl.d/99-proxmox-hardened.conf <<SYSEOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.tcp_syncookies = 1
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
vm.swappiness = 10
vm.overcommit_memory = 1
fs.file-max = 2097152
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0
SYSEOF

sysctl --system -q
timedatectl set-timezone America/Los_Angeles #Or whichever timezone you want!
systemctl enable smartd --now 2>/dev/null || true
systemctl enable fstrim.timer --now 2>/dev/null || true
apt-get autoremove -y -qq
apt-get clean -qq

reboot #Don't necessarily need to reboot if you don't want.
