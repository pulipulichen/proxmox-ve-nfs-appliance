# Changelog

## 2026-11-05: Fix PBS datastore unavailable (EACCES)

- Fixed `/srv/pbs` ownership from `root:root` to `root:backup` and mode from `0700` to `0710` after PBS installation. The previous setting prevented the PBS service account `backup` from reaching `/srv/pbs/backup/.chunks` and caused `Datastore is not available` / `Permission denied (os error 13)` in the UI.
- On subsequent runs, preserve `backup` group traversal instead of resetting access to `root:root` during early provisioning.
- Verify that the `backup` account can read and write `.chunks` before declaring provisioning successful; retain datastore files and private access isolation.


## 2026-11-05: Save PBS certificate fingerprint beside root credentials

- Automatically read the actual TLS SHA-256 certificate fingerprint of the running PBS instance into `PBS_FINGERPRINT`.
- Preserve **only one password variable**, `ROOT_PASSWORD`, while storing the non-secret `PBS_FINGERPRINT` in the same mode-0600 local `credentials` file.
- Recompute and update the fingerprint after PBS has started on each `start.sh` run, so PVE storage configuration is easier.
- Display the fingerprint at the end of provisioning and document the correct PVE username `root@pam`.
- Fix repeated deployment: disable PBS Enterprise APT source before the *first* APT refresh, because the PBS package may recreate the source and cause HTTP 401 on subsequent runs.

## 2026-11-05: Unified root credentials and Proxmox Backup Server

- Made **ROOT_PASSWORD** the only saved password variable. The installer migrates the existing ROOT_PASSWORD in the local root-owned credentials file and removes NFS_UPLOAD_PASSWORD.
- Samba now authenticates as **root** using the same password as SSH and SFTP. The obsolete nfs-upload Samba account is disabled, and its SFTP Match rule removed. Existing files are preserved.
- **Migration notice:** previously configured PVE CIFS storage using nfs-upload needs username/password updated to root/ROOT_PASSWORD; otherwise the old CIFS storage is inactive.
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
