# paqet deploy script

This script installs [paqet](https://github.com/hanselime/paqet) on your server and configures it to run as a
background service.

## Installation

Run this command to install paqet server:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/SCP002/paqet-deploy/main/installer.sh)
```

## Service check

```bash
systemctl status paqet-server
```
