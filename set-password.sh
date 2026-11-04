#!/usr/bin/env bash
set -Eeuo pipefail

# Safely rotate the one appliance password without reinstalling anything.
# Run interactively as root INSIDE the CT. Never pass a password on argv.
if [[ $(id -u) -ne 0 ]]; then
  echo "Run as root in the appliance CT." >&2
  exit 1
fi
if [[ ! -r /dev/tty ]]; then
  echo "An interactive CT console is required; use pct enter <CTID> first." >&2
  exit 1
fi

CREDS_DIR=/root/.config/proxmox-ve-nfs-appliance
CREDS_FILE=$CREDS_DIR/credentials
install -d -m 0700 "$CREDS_DIR"
if [[ -e "$CREDS_FILE" ]]; then
  if [[ $(stat -c %u "$CREDS_FILE") != 0 || $(stat -c %a "$CREDS_FILE") != 600 ]]; then
    echo "Unsafe credentials owner or permissions: $CREDS_FILE" >&2
    exit 1
  fi
fi

new_password=''
confirm_password=''
temp_file=''
cleanup() {
  unset new_password confirm_password
  if [[ -n "$temp_file" && -f "$temp_file" ]]; then
    rm -f -- "$temp_file"
  fi
}
trap cleanup EXIT

IFS= read -r -s -p 'New unified root password: ' new_password </dev/tty
printf '\n'
IFS= read -r -s -p 'Confirm new password: ' confirm_password </dev/tty
printf '\n'
if [[ -z "$new_password" || "$new_password" != "$confirm_password" ]]; then
  echo "Empty or mismatching password; no changes made." >&2
  exit 1
fi
# chpasswd and smbpasswd read from stdin, never command-line arguments.
printf 'root:%s\n' "$new_password" | chpasswd
printf '%s\n%s\n' "$new_password" "$new_password" | smbpasswd -a -s root >/dev/null
smbpasswd -e root >/dev/null

fingerprint=''
if [[ -s /etc/proxmox-backup/proxy.pem ]]; then
  fingerprint="$(openssl x509 -in /etc/proxmox-backup/proxy.pem -noout -fingerprint -sha256 | sed -n 's/^sha256 Fingerprint=//Ip')"
fi
if [[ ! "$fingerprint" =~ ^([[:xdigit:]]{2}:){31}[[:xdigit:]]{2}$ ]]; then
  echo "PBS certificate fingerprint unavailable. Keep current password, do not overwrite credentials." >&2
  exit 1
fi
umask 077
temp_file="$(mktemp "$CREDS_FILE.XXXXXXXX")"
printf 'ROOT_PASSWORD=%q\nPBS_FINGERPRINT=%q\n' "$new_password" "$fingerprint" > "$temp_file"
chmod 0600 "$temp_file"
mv -f -- "$temp_file" "$CREDS_FILE"
temp_file=''
echo "Updated Linux root, Samba root, and local credentials."
echo "PBS root@pam uses the updated Linux root password automatically."
echo "SSH/SFTP root use the same password; no service restarts required."
echo "Update PVE Datacenter > Storage > PBS password if its saved password differs."
