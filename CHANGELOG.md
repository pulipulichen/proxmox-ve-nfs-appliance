# Changelog

## 2026-11-05: Unified root credentials and Proxmox Backup Server

- Made **ROOT_PASSWORD** the only saved password variable. The installer migrates the existing ROOT_PASSWORD in the local root-owned credentials file and removes NFS_UPLOAD_PASSWORD.
- Samba now authenticates as **root** using the same password as SSH and SFTP. The obsolete nfs-upload Samba account is disabled, and its SFTP Match rule removed. Existing files are preserved.
- Root Linux password is synchronized to saved ROOT_PASSWORD on every installer run, so PBS PAM login as **root@pam** uses the same password.
- Added **PBS 4 / Debian 13** installation via official **pbs-no-subscription** apt repository; enterprise repository is disabled if present.
- PBS datastore **backup** at `/srv/pbs/backup` is initialized once and remains separate from writable `/srv/nfs`. Automatically enables PBS services and validates them.
- Does not auto-delete backups or configure a prune schedule. Garbage collection is scheduled daily.
- Extended README with PVE storage integration, root credential rotation, storage sizing, LXC limitations, security and failure-domain warnings.
- Testing must ensure PBS is reachable on 8007, datastore can accept backups, PVE can connect, and existing NFS/SMB contents remain intact.

## 2026-11-05: Original NFS + SMB + SFTP appliance

- Added GitHub-managed, idempotent Debian 13 LXC provisioning (`start.sh`).
- Added `update.sh` to fast-forward pull the main branch and reapply configuration.
- Preserved existing NFS export (`/srv/nfs`) and data.
- Added authenticated Samba share `\\\\CT-IP\\nfs` originally using `nfs-upload`.
- Added chrooted SFTP user `nfs-upload` on SSH port 22.
- Enabled root password/key SSH login; generated a one-time initial root password when locked.
- Passwords stored locally in `/root/.config/proxmox-ve-nfs-appliance/credentials`, never in Git.
- **Security warning:** wildcard NFS, root password SSH, and root SMB require trusted-network-only exposure.

## Operational notes

- Re-running `start.sh` does not delete stored NFS data or PBS datastore data.
- Credential upgrades reapply the saved ROOT_PASSWORD, unlike the original unlock-only behavior.
- Restore the **entire** CT backup (including datastore root filesystem) before invoking `update.sh`.
