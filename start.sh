#!/usr/bin/env bash
set -Eeuo pipefail

# Idempotent Debian 13 LXC NFS + SMB + SFTP appliance setup.
if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root inside the LXC container." >&2
  exit 1
fi

DATA_DIR=/srv/nfs
UPLOAD_USER=nfs-upload
CREDS_DIR=/root/.config/proxmox-ve-nfs-appliance
CREDS_FILE=$CREDS_DIR/credentials
REPO_URL=https://github.com/pulipulichen/proxmox-ve-nfs-appliance.git
export DEBIAN_FRONTEND=noninteractive

echo "[1/7] Installing required packages"
apt-get update
apt-get install -y nfs-kernel-server openssh-server samba smbclient git openssl ca-certificates

echo "[2/7] Preparing shared storage (never remove existing data)"
mkdir -p "$DATA_DIR" "$CREDS_DIR"
chown root:root /srv
chmod 0755 /srv
# Preserves original appliance semantics: any trusted local client can write.
chmod 0777 "$DATA_DIR"
chmod 0700 "$CREDS_DIR"

echo "[3/7] Configuring NFS"
if ! grep -Eq '^/srv/nfs[[:space:]]' /etc/exports 2>/dev/null; then
  printf '/srv/nfs *(rw,sync,no_subtree_check,no_root_squash,insecure)\n' >> /etc/exports
fi
systemctl enable --now nfs-kernel-server
exportfs -ra

echo "[4/7] Initializing credentials (generated only once)"
if [ ! -s "$CREDS_FILE" ]; then
  (
    umask 077
    printf 'ROOT_PASSWORD=%s\n' "$(openssl rand -hex 18)"
    printf 'NFS_UPLOAD_PASSWORD=%s\n' "$(openssl rand -hex 18)"
  ) > "$CREDS_FILE"
fi
chmod 0600 "$CREDS_FILE"
# Only this root-owned, mode-0600, locally generated file is sourced.
# shellcheck disable=SC1090
. "$CREDS_FILE"

root_state="$(passwd -S root | awk '{print $2}')"
if [ "$root_state" = "L" ]; then
  printf 'root:%s\n' "$ROOT_PASSWORD" | chpasswd
  echo "  Enabled root account with generated password."
else
  echo "  Keeping existing root password."
fi

upload_created=no
if ! id -u "$UPLOAD_USER" >/dev/null 2>&1; then
  useradd --home-dir /nfs --no-create-home --shell /usr/sbin/nologin --user-group "$UPLOAD_USER"
  upload_created=yes
fi
if [ "$upload_created" = yes ]; then
  printf '%s:%s\n' "$UPLOAD_USER" "$NFS_UPLOAD_PASSWORD" | chpasswd
fi

echo "[5/7] Configuring root SSH and restricted SFTP"
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-nfs-appliance-root.conf <<'EOF'
# Appliance administrator access; keep behind a trusted network.
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
EOF

if [ ! -e /etc/ssh/sshd_config.before-nfs-appliance ]; then
  cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.before-nfs-appliance
fi
sed -i '/^# BEGIN NFS-APPLIANCE SFTP$/,/^# END NFS-APPLIANCE SFTP$/d' /etc/ssh/sshd_config
cat >> /etc/ssh/sshd_config <<'EOF'

# BEGIN NFS-APPLIANCE SFTP
Match User nfs-upload
    ChrootDirectory /srv
    ForceCommand internal-sftp -d /nfs
    PermitTTY no
    AllowTcpForwarding no
    X11Forwarding no
# END NFS-APPLIANCE SFTP
EOF

install -d -m 0755 /run/sshd
/usr/sbin/sshd -t
# On Debian 13 socket-activated SSH, SIGHUP may drop inherited listen FDs.
# Prefer a plain ssh.service so future updates can safely restart the daemon.
systemctl disable --now ssh.socket >/dev/null 2>&1 || true
systemctl enable ssh
systemctl restart ssh

echo "[6/7] Configuring Samba (authenticated SMB, port 445)"
if [ ! -e /etc/samba/smb.conf.before-nfs-appliance ] && [ -e /etc/samba/smb.conf ]; then
  cp -a /etc/samba/smb.conf /etc/samba/smb.conf.before-nfs-appliance
fi
cat > /etc/samba/smb.conf <<'EOF'
[global]
   workgroup = WORKGROUP
   server string = Proxmox VE NFS Appliance
   server role = standalone server
   security = user
   map to guest = Never
   usershare allow guests = no
   server min protocol = SMB2_02
   disable netbios = yes
   smb ports = 445
   log file = /var/log/samba/log.%m
   max log size = 1000

[nfs]
   path = /srv/nfs
   browseable = yes
   read only = no
   guest ok = no
   valid users = nfs-upload
   force user = nfs-upload
   create mask = 0666
   force create mode = 0666
   directory mask = 0777
   force directory mode = 0777
EOF
testparm -s /etc/samba/smb.conf >/dev/null
if ! pdbedit -L -u "$UPLOAD_USER" 2>/dev/null | grep -q "^$UPLOAD_USER:"; then
  printf '%s\n%s\n' "$NFS_UPLOAD_PASSWORD" "$NFS_UPLOAD_PASSWORD" | smbpasswd -a -s "$UPLOAD_USER" >/dev/null
fi
smbpasswd -e "$UPLOAD_USER" >/dev/null
systemctl disable --now nmbd >/dev/null 2>&1 || true
systemctl enable smbd
systemctl restart smbd

echo "[7/7] Checking services"
systemctl is-active --quiet nfs-kernel-server
systemctl is-active --quiet ssh
systemctl is-active --quiet smbd
/usr/sbin/sshd -T | grep -E '^(permitrootlogin|passwordauthentication) '
exportfs -v | grep /srv/nfs
echo "NFS:   CT-IP:/srv/nfs"
echo "SFTP:  sftp://$UPLOAD_USER@CT-IP:22/ (starts in /nfs)"
echo "SMB:   \\\\CT-IP\\nfs"
echo "SSH:   ssh root@CT-IP"
echo "Initial credentials (root-only): $CREDS_FILE"
echo "Done. No existing data under $DATA_DIR was deleted."
