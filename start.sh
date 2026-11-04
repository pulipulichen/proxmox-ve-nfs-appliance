#!/usr/bin/env bash
set -Eeuo pipefail

# Debian 13 LXC: NFS + root SSH/SFTP + root SMB + PBS (no-subscription).
# Re-runnable: does not remove /srv/nfs or existing PBS datastore data.
if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root inside the Debian 13 container." >&2
  exit 1
fi
if [ "$(. /etc/os-release; printf '%s' "${VERSION_CODENAME:-}")" != trixie ]; then
  echo "This appliance requires Debian 13 (trixie)." >&2
  exit 1
fi

DATA_DIR=/srv/nfs
PBS_ROOT=/srv/pbs
PBS_DATASTORE=backup
PBS_PATH=$PBS_ROOT/$PBS_DATASTORE
CREDS_DIR=/root/.config/proxmox-ve-nfs-appliance
CREDS_FILE=$CREDS_DIR/credentials
export DEBIAN_FRONTEND=noninteractive

echo "[1/8] Installing Debian components"
# PBS installation can create pbs-enterprise.sources. Disable it *before*
# the first apt-get update, otherwise later reruns fail with 401 Unauthorized.
if [ -f /etc/apt/sources.list.d/pbs-enterprise.sources ]; then
  mv /etc/apt/sources.list.d/pbs-enterprise.sources /etc/apt/sources.list.d/pbs-enterprise.sources.disabled-by-appliance
fi
apt-get update
apt-get install -y nfs-kernel-server openssh-server samba smbclient git openssl ca-certificates wget

echo "[2/8] Preserving share and consolidating one root password"
install -d -m 0700 "$CREDS_DIR"
mkdir -p "$DATA_DIR" "$PBS_ROOT"
chown root:root /srv "$DATA_DIR"
chmod 0755 /srv
chmod 0777 "$DATA_DIR"
# The PBS daemon writes as user:group backup:backup. A root:root /srv/pbs
# with mode 0700 blocks access to the datastore even when .chunks is owned
# by backup. Keep the parent private but traversable by the backup group.
if getent group backup >/dev/null 2>&1; then
  chown root:backup "$PBS_ROOT"
  chmod 0710 "$PBS_ROOT"
else
  # Before PBS installation, the backup group may not exist yet.
  chown root:root "$PBS_ROOT"
  chmod 0700 "$PBS_ROOT"
fi

# Retain the ROOT_PASSWORD from the earlier two-password installer.
# A supplied ROOT_PASSWORD environment variable explicitly rotates the password.
override_password="${ROOT_PASSWORD:-}"
if [ -s "$CREDS_FILE" ]; then
  # Local root-owned, mode-0600 credentials created by this appliance.
  if [ "$(stat -c %u "$CREDS_FILE")" != 0 ] || [ "$(stat -c %a "$CREDS_FILE")" != 600 ]; then
    echo "Unsafe credentials owner/permissions: $CREDS_FILE" >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  . "$CREDS_FILE"
fi
if [ -n "$override_password" ]; then
  ROOT_PASSWORD=$override_password
fi
if [ -z "${ROOT_PASSWORD:-}" ]; then
  ROOT_PASSWORD="$(openssl rand -hex 18)"
fi
unset override_password NFS_UPLOAD_PASSWORD
# %q escapes characters (including spaces and !), safe for a future bash source.
(umask 077; printf 'ROOT_PASSWORD=%q\n' "$ROOT_PASSWORD" > "$CREDS_FILE.new")
mv -f "$CREDS_FILE.new" "$CREDS_FILE"
chmod 0600 "$CREDS_FILE"
printf 'root:%s\n' "$ROOT_PASSWORD" | chpasswd

echo "[3/8] Configuring NFS (legacy permissive export)"
if ! grep -Eq '^/srv/nfs[[:space:]]' /etc/exports 2>/dev/null; then
  printf '/srv/nfs *(rw,sync,no_subtree_check,no_root_squash,insecure)\n' >> /etc/exports
fi
systemctl enable --now nfs-kernel-server
exportfs -ra

echo "[4/8] Enabling root SSH and SFTP"
install -d -m 0755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-nfs-appliance-root.conf <<'SSH'
# Trusted networks only. SFTP is available with the same root credentials.
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
SSH
# Remove the restricted nfs-upload SFTP rule used by older appliance releases.
if [ -f /etc/ssh/sshd_config ]; then
  sed -i '/^# BEGIN NFS-APPLIANCE SFTP$/,/^# END NFS-APPLIANCE SFTP$/d' /etc/ssh/sshd_config
fi
install -d -m 0755 /run/sshd
/usr/sbin/sshd -t
systemctl disable --now ssh.socket >/dev/null 2>&1 || true
systemctl enable ssh
systemctl restart ssh

echo "[5/8] Configuring root-only Samba"
if [ ! -e /etc/samba/smb.conf.before-nfs-appliance ] && [ -f /etc/samba/smb.conf ]; then
  cp -a /etc/samba/smb.conf /etc/samba/smb.conf.before-nfs-appliance
fi
cat > /etc/samba/smb.conf <<'SMB'
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
   valid users = root
   force user = root
   create mask = 0666
   force create mode = 0666
   directory mask = 0777
   force directory mode = 0777
SMB
testparm -s /etc/samba/smb.conf >/dev/null
printf '%s\n%s\n' "$ROOT_PASSWORD" "$ROOT_PASSWORD" | smbpasswd -a -s root >/dev/null
smbpasswd -e root >/dev/null
# Deactivate the obsolete nfs-upload identity; preserve its files.
if pdbedit -L -u nfs-upload 2>/dev/null | grep -q '^nfs-upload:'; then
  smbpasswd -d nfs-upload >/dev/null || true
fi
if id -u nfs-upload >/dev/null 2>&1; then
  usermod -L nfs-upload >/dev/null 2>&1 || true
fi
systemctl disable --now nmbd >/dev/null 2>&1 || true
systemctl enable smbd
systemctl restart smbd

echo "[6/8] Installing Proxmox Backup Server from no-subscription repository"
install -d -m 0755 /usr/share/keyrings
key_tmp="$(mktemp)"
trap 'rm -f "$key_tmp"' EXIT
wget -q --https-only https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg -O "$key_tmp"
test -s "$key_tmp"
install -m 0644 "$key_tmp" /usr/share/keyrings/proxmox-archive-keyring.gpg
rm -f "$key_tmp"
trap - EXIT
cat > /etc/apt/sources.list.d/proxmox-pbs-no-subscription.sources <<'PBS_REPO'
Types: deb
URIs: http://download.proxmox.com/debian/pbs
Suites: trixie
Components: pbs-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
PBS_REPO
if [ -f /etc/apt/sources.list.d/pbs-enterprise.sources ]; then
  mv /etc/apt/sources.list.d/pbs-enterprise.sources /etc/apt/sources.list.d/pbs-enterprise.sources.disabled-by-appliance
fi
apt-get update
apt-get install -y proxmox-backup-server

echo "[7/8] Initializing private PBS datastore"
if ! grep -Eq "^datastore: ${PBS_DATASTORE}$" /etc/proxmox-backup/datastore.cfg 2>/dev/null; then
  proxmox-backup-manager datastore create "$PBS_DATASTORE" "$PBS_PATH" \
    --gc-schedule daily --comment "Private PBS backup storage (not exported via NFS or SMB)"
fi
systemctl enable --now proxmox-backup-proxy
systemctl start proxmox-backup
# PBS stores chunks as the backup service account. Allow only root and the
# backup group to traverse the private parent directory (not SMB/NFS users).
chown root:backup "$PBS_ROOT"
chmod 0710 "$PBS_ROOT"
# Fail provisioning if backup cannot read/write its own chunk store.
su -s /bin/sh -c 'test -r /srv/pbs/backup/.chunks && test -w /srv/pbs/backup/.chunks' backup

echo "[8/8] Verifying services"
for service in nfs-kernel-server ssh smbd proxmox-backup-proxy proxmox-backup; do
  systemctl is-active --quiet "$service" || { echo "Failed: $service" >&2; exit 1; }
done
/usr/sbin/sshd -T | grep -E '^(permitrootlogin|passwordauthentication) '
testparm -s /etc/samba/smb.conf >/dev/null
proxmox-backup-manager datastore list

# The PBS TLS certificate fingerprint is public metadata, not a second password.
# Refresh it after PBS installation and on every rerun (including certificate renewal).
PBS_FINGERPRINT="$(openssl x509 -in /etc/proxmox-backup/proxy.pem -noout -fingerprint -sha256 | sed -n 's/^sha256 Fingerprint=//Ip')"
if [[ ! "$PBS_FINGERPRINT" =~ ^([[:xdigit:]]{2}:){31}[[:xdigit:]]{2}$ ]]; then
  echo "Could not read a valid PBS certificate SHA-256 fingerprint." >&2
  exit 1
fi
(umask 077; printf 'ROOT_PASSWORD=%q\nPBS_FINGERPRINT=%q\n' "$ROOT_PASSWORD" "$PBS_FINGERPRINT" > "$CREDS_FILE.new")
mv -f "$CREDS_FILE.new" "$CREDS_FILE"
chmod 0600 "$CREDS_FILE"

CT_IP="$(hostname -I | awk '{print $1}')"
echo "NFS:   ${CT_IP}:/srv/nfs"
echo "SMB:   \\\\${CT_IP}\\nfs (root)"
echo "SSH:   ssh root@${CT_IP}"
echo "SFTP:  sftp root@${CT_IP} (browse /srv/nfs)"
echo "PBS:   https://${CT_IP}:8007 (root@pam, datastore: ${PBS_DATASTORE})"
echo "PBS fingerprint: $PBS_FINGERPRINT"
echo "One password variable: ROOT_PASSWORD; local file (includes PBS_FINGERPRINT): $CREDS_FILE"
echo "Preserved: $DATA_DIR and $PBS_PATH"
