# Proxmox VE NFS Appliance

Portable Debian 13 Proxmox VE LXC appliance, with NFS, SFTP and Samba sharing the **same `/srv/nfs` directory**.

## Endpoints

- **NFS for PVE/Linux**: `CT-IP:/srv/nfs` (TCP 2049; existing wildcard `no_root_squash` export retained)
- **Windows Samba**: `\\CT-IP\nfs` (TCP 445; authenticated as `nfs-upload`)
- **SFTP**: `sftp nfs-upload@CT-IP` (TCP 22; `/nfs` directory inside a `/srv` chroot)
- **Root SSH**: `ssh root@CT-IP` (SSH key or password)

All data is in `/srv/nfs`. Updates do **not** delete it.

## First-time installation

Run **inside Debian 13 CT as root**:

```bash
apt-get update && apt-get install -y git
git clone https://github.com/pulipulichen/proxmox-ve-nfs-appliance.git /opt/proxmox-ve-nfs-appliance
cd /opt/proxmox-ve-nfs-appliance
./start.sh
```

`start.sh` is idempotent and generates initial passwords once, at `/root/.config/proxmox-ve-nfs-appliance/credentials` (mode 0600). Root password is generated only if the existing root account is locked. The existing root password, if active, is preserved.

To read **initial** credentials locally from the PVE host (change 104 to the CT ID):

```bash
pct exec 104 -- cat /root/.config/proxmox-ve-nfs-appliance/credentials
```

Passwords are **never stored in GitHub**. If manually changed later, the initial credentials file is not automatically updated.

## Updating

```bash
cd /opt/proxmox-ve-nfs-appliance
./update.sh
```

`update.sh` runs `git pull --ff-only origin main` and reapplies the installer configuration without deleting `/srv/nfs` or resetting existing active passwords.

## Mount from Windows

Open `\\CT-IP\nfs` in File Explorer, or:

```cmd
net use Z: \\CT-IP\nfs /user:nfs-upload *
```

Enter the generated `NFS_UPLOAD_PASSWORD`. The Samba and SFTP username and password are identical.

## Security

**Trusted networks only.** The original NFS export allows all clients with `no_root_squash`; `/srv/nfs` is world-writable. Root password SSH login is deliberately enabled at the administrator's request. Samba requires an account and disables anonymous guest access and SMB1. **Do not expose TCP 22, 445 or 2049 to the public Internet.**

## Files

- `start.sh`: idempotent installer/configuration for NFS, SFTP, Samba, root SSH and credentials
- `update.sh`: fast-forward-only Git pull, then reapply configuration
- `CHANGELOG.md`: implementation history
