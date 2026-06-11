# OCI Instance Configuration Tool

An interactive Bash script for managing OCI compute instance configuration and instance creation flows through the OCI CLI.

## Features

- **OCI environment check**: verifies OCI CLI, jq, config files, and connectivity
  - Automatically attempts to install common missing dependencies
- **Instance management**: list, view, start, and stop instances
- **One-click instance configuration update**: defaults to 4 OCPU / 24 GB memory and tries to expand the boot volume to 200 GB
- **Instance creation**: save key parameters and reuse saved config to create new instances
  - One-click creation defaults to Ubuntu 24.04, A1.Flex, 4 OCPU, 24 GB memory, 200 GB boot volume, and 120 VPU/GB
  - One-click creation reuses the default compartment and queries availability domain, subnet, and image ID in the same way as "Get key parameters and save"
  - If availability domain, subnet, or image ID cannot be queried, the script stops and asks for manual handling
  - If no SSH public key is found, the script automatically generates an instance login key pair in the data directory
  - Setup progress is auto-saved to a draft file and can be resumed after interruption
  - The confirmed config is overwritten only after final confirmation
  - New VCN creation provides recommended defaults and supports quick public VCN creation
  - Query and select availability domains, shapes, images, and subnets
  - Image lookup first shows operating systems, then versions and matching images
  - Subnet creation can create a VCN inline when no suitable VCN exists
  - Missing subnets can be created inline during the flow
  - Supports boot volume size and performance settings (10-120, in steps of 10)
  - Supports one-time foreground creation or background retry-based creation
  - Prints a success summary with instance OCID, status, private IP, and public IP
- **Configuration update**: update instance OCPU and memory settings
  - Direct update without stopping the instance
  - Full flow: stop -> update -> start
- **Background tasks**: create and manage background tasks with auto-retry
- **Notifications**: success notifications through email (SMTP) or Telegram bot
- **Config file support**: use JSON config files for batch updates
- **Task resume**: resume stopped tasks with execution count preserved
- **Uninstall flow**: interactively remove OCI config, logs, script data, and dependencies installed by the script

## Requirements

- Bash 3.x+ (macOS compatible)
- [OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/Concepts/cliconcepts.htm)
- [jq](https://stedolan.github.io/jq/)
- curl (for notifications and automatic installation)
- Python 3 and venv (for OCI CLI installation)
- ssh-keygen (for automatic instance login key generation)
- `column` (optional, used for aligned table output; the script falls back to plain text if missing)

## Dependency Installation

### Debian / Ubuntu

```bash
sudo apt update
sudo apt install -y bash curl jq python3 python3-venv openssh-client bsdextrautils
```

Notes:
- `python3-venv` is used by the official OCI CLI installer
- `openssh-client` provides `ssh-keygen`
- `bsdextrautils` provides `column`
- OCI CLI can be installed automatically from the script's "Check OCI environment" menu
- The "Check OCI environment" menu also automatically attempts to install missing dependencies

### macOS

```bash
brew install jq openssh
```

Notes:
- macOS already includes `bash` and `curl`
- `column` is usually available by default
- `openssh` provides a newer `ssh-keygen`
- OCI CLI can be installed automatically from the script's "Check OCI environment" menu
- The "Check OCI environment" menu also automatically attempts to install missing dependencies

When automatically installing system dependencies, the script uses the available package manager:
`apt-get`, `dnf`, `yum`, `pacman`, `zypper`, `apk`, or `brew`.
It attempts to install missing `jq`, `curl`, Python 3/venv, `ssh-keygen`, `column`, and OCI CLI.
Packages installed by the script are recorded and cleaned up during uninstall; packages that were already installed are not recorded and are not automatically removed.

## Quick Start

```bash
# Option 1: run locally after downloading
./oracle_oci_tool.sh

# Option 2: run directly from the remote source
bash <(curl -sL https://raw.githubusercontent.com/yhj945/tools/main/oracle/oracle_oci_tool.sh)
```

No matter which launch method is used, script data is stored in `~/.oracle_oci_tool` by default, so tasks, notification settings, and creation configs are shared across local and remote execution.

## Main Menu

| Option | Description |
|--------|-------------|
| 1 | Check OCI environment |
| 2 | Initialize OCI configuration |
| 3 | View OCI configuration |
| 4 | Manage instances |
| 5 | Create instance |
| 6 | Manage background tasks |
| 7 | Configure notifications |
| 8 | Uninstall script |
| h | Help information |
| 0 | Exit |

## Configuration

### OCI CLI Configuration

1. Log in to the [OCI Console](https://cloud.oracle.com)
2. Go to User Settings -> API Keys
3. Add or view an API key to get:
   - User OCID
   - Fingerprint
   - Tenancy OCID
4. Download or create a private key file (default: `~/.oracle_oci_tool/oci/oci_api_key.pem`)

### Notifications (Optional)

Configure notification settings from menu option `[7] Configure notifications`:

- Email: built-in defaults for QQ mail `smtp.qq.com:465` and 163 mail `smtp.163.com:465`; the SMTP password is usually an app password or authorization code, not the login password
- Telegram: open `@BotFather` in Telegram, send `/newbot`, create a bot, and copy the returned token as the TG Bot ID/Token; after sending any message to the bot, the script can try to auto-detect the Chat ID
- You can choose email, Telegram, email + Telegram, or disable notifications

## Data Directory

Default data directory:

```text
~/.oracle_oci_tool/
├── bin/
│   └── oci
├── oracle-cli/
│   └── installations/
├── oci/
│   ├── config
│   └── oci_api_key.pem
├── ssh/
│   ├── oci_instance_key
│   └── oci_instance_key.pub
├── notification_config.conf
├── tasks/
├── update_instance_config.json
├── create_instance_config.json
├── create_instance_beginner.json
└── create_instance_config.draft.json
```

Notes:
- Local execution with `./oracle_oci_tool.sh` and remote execution with `bash <(curl ...)` use the same data directory
- On first run of the updated script, common configs and tasks next to the script are migrated automatically to `~/.oracle_oci_tool`
- If old `~/.oci/config` exists and the data directory does not yet have OCI config, it is copied to `~/.oracle_oci_tool/oci/config`
- If old `email_config.conf` is found, it is migrated to `notification_config.conf`
- The script uses the data-directory OCI config through temporary runtime environment variables and does not write to shell rc files
- You can override the location by setting `OCI_TOOL_HOME` before launch
- The uninstall flow can optionally remove this entire data directory

## Script File

```text
./
└── oracle_oci_tool.sh      # Main script
```

## Background Tasks

- Tasks run in the background with auto-retry
- Supports both instance update tasks and instance creation tasks
- Execution count is preserved across restarts
- Supports resuming stopped tasks
- Supports real-time log viewing

## Uninstall Notes

- The main menu provides `[8] Uninstall script`
- You can interactively choose whether to stop background tasks, remove the data directory, remove OCI config, remove private keys, and clean up old `~/.oci`
- The script tries to remove common OCI CLI installation files
- The script automatically uninstalls system dependencies it previously recorded as installed, such as `jq`, `curl`, Python 3/venv, and the package that provides `column`

## Instance Creation Config Notes

- One-click creation reuses the default compartment and queries availability domain, subnet, and image ID; if a saved value is still present in the query results, it is reused, otherwise the first query result is used
- If no subnet is found, one-click creation asks whether to create one; subnet creation defaults to a public subnet, and you can also cancel and skip setting `subnetId`
- If other required resources cannot be queried, one-click creation stops and asks for manual handling; if no SSH public key is found, a key pair is generated in the data directory
- `create_instance_config.draft.json` stores in-progress draft values during setup
- `create_instance_config.json` is overwritten only after final confirmation
- Boot volume size and performance are written through OCI CLI launch source settings and are used by both foreground creation and background retry tasks
- For `Flex` shapes, CPU and memory are configured through `shape-config`; boot volume size and performance are configured through the instance launch source settings

## Important Notices And Disclaimer

### Disclaimer

1. **Account responsibility**: the user is solely responsible for any account suspension, service termination, or other consequences resulting from use of this script. The author assumes no liability.

2. **No backdoors**: all data generated by this script is stored locally only. There are no remote servers, backdoors, or data collection mechanisms.

3. **Use at your own risk**: this script interacts with OCI APIs. Improper use may violate OCI service terms. Review OCI policies before use.

4. **No warranty**: this software is provided "as is" without warranty of any kind, express or implied.

### Security Notes

- The notification config file (`notification_config.conf`) may contain SMTP credentials and Telegram Bot ID/Token
- Sensitive files are automatically added to `.gitignore`
- Never commit `notification_config.conf`, old `email_config.conf`, or the `tasks/` directory to version control

## License

MIT License
