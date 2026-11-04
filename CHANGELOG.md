# Changelog

## 2026-11-05

- Added GitHub-managed, idempotent Debian 13 LXC provisioning (`start.sh`).
- Added `update.sh` to fast-forward pull the main branch and reapply configuration.
- Preserved existing NFS export (`/srv/nfs`) and data.
- Added authenticated Samba share `\\CT-IP\nfs` using SMB2+ and `nfs-upload`.
- Added chrooted SFTP user `nfs-upload` on SSH port 22, sharing the NFS directory.
- Enabled root password/key SSH login as requested; generates a one-time initial root password if the root account is locked.
- Passwords are generated inside the CT and stored at `/root/.config/proxmox-ve-nfs-appliance/credentials`, never committed to Git.
- **Security warning:** NFS remains wide open, and root password SSH login is enabled. Restrict network access to trusted networks.

## Operational notes

- Running `start.sh` again does not delete stored data.
- Existing unlocked passwords are not reset on reinstall.
- Credentials file records initially generated passwords, not later manual changes.
- Restore a CT backup to migrate the appliance, then invoke `update.sh`.
