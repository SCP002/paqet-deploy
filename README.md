# paqet deploy script

This script installs [paqet](https://github.com/hanselime/paqet) on your server and configures it to run as a
background service.

## Installation

Run this command to install paqet server:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/SCP002/paqet-deploy/main/installer.sh)
```

## Upgrade

Replace the paqet binary with the latest release, keeping the existing config and key, and restart the service:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/SCP002/paqet-deploy/main/installer.sh) --upgrade
```

Running the installer without `--upgrade` on a server that already has paqet will also offer to upgrade.

## Service check

```bash
systemctl status paqet-server
```
