# OCI Instance Update And Creation Script

An interactive Bash script for managing OCI compute instance configurations and creation flows via CLI.

## Features

- **OCI Environment Check**: Verify OCI CLI, jq, configuration files, and connectivity
- **Instance Management**: List, view, start, stop instances
- **Instance Creation**: Save key parameters and reuse saved configuration to create new instances
  - Auto-saves progress to a draft file so you can resume after interruption
  - Only overwrites the confirmed config after final confirmation
  - Provides recommended defaults for quick VCN creation
  - Query and select availability domains, shapes, images, and subnets
  - Shows an operating system list before listing versions and matching images
  - Create a VCN inline during subnet creation when no suitable VCN exists
  - Create a subnet inline during the flow when the required subnet does not exist
  - Supports configuring boot volume size and boot volume performance (10-120, in steps of 10)
  - Support one-time foreground creation or background retry-based creation
  - Prints a success summary with instance OCID, status, private IP, and public IP
- **Configuration Update**: Update instance OCPU and memory settings
  - Direct update (without stopping instance)
  - Full update flow (stop → update → start)
- **Background Tasks**: Create and manage background tasks with auto-retry
- **Email Notification**: Get notified when updates or creations succeed (SMTP)
- **Config File Support**: Use JSON config files for batch updates
- **Task Resume**: Resume stopped tasks with execution count preserved

## Requirements

- Bash 3.x+ (macOS compatible)
- [OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/Concepts/cliconcepts.htm)
- [jq](https://stedolan.github.io/jq/)
- curl (for email notifications)
- `column` (optional, used for aligned table output; the script falls back to plain text if it is missing)

## Dependency Installation

### Debian / Ubuntu

```bash
sudo apt update
sudo apt install -y bash curl jq bsdextrautils
```

Notes:
- `bsdextrautils` provides `column`
- `OCI CLI` should be installed separately by following Oracle's official documentation

### macOS

```bash
brew install jq
```

Notes:
- macOS already includes `bash` and `curl`
- `column` is typically available by default
- `OCI CLI` should be installed separately by following Oracle's official documentation

## Quick Start

```bash
# Option 1: run locally after downloading
./oracle_oci_tool.sh

# Option 2: run directly from the remote source
bash <(curl -sL https://raw.githubusercontent.com/yhj945/tools/main/oracle/oracle_oci_tool.sh)
```

No matter which launch method you use, the script stores its data in `~/.oracle_oci_tool` by default, so tasks, email settings, and creation configs are not lost when you switch execution methods.

## Main Menu

| Option | Description |
|--------|-------------|
| 1 | Check OCI environment |
| 2 | Initialize OCI configuration |
| 3 | View OCI configuration |
| 4 | Manage instances |
| 5 | Create instance |
| 6 | Manage background tasks |
| 7 | Configure email notification |
| h | Help information |
| 0 | Exit |

## Configuration

### OCI CLI Configuration

1. Login to [OCI Console](https://cloud.oracle.com)
2. Go to User Settings → API Keys
3. Add or view API key to get:
   - User OCID
   - Fingerprint
   - Tenant OCID
4. Download or create private key file (e.g., `~/.oci/oci_api_key.pem`)

### Email Notification (Optional)

Configure through menu option `[7]`:
- SMTP server (e.g., `smtp.qq.com`)
- SMTP port (e.g., `465` for SSL)
- Sender email
- SMTP password/authorization code
- Recipient email

## Data Directory

Default data directory:

```text
~/.oracle_oci_tool/
├── email_config.conf
├── tasks/
├── update_instance_config.json
├── create_instance_config.json
└── create_instance_config.draft.json
```

Notes:
- Local execution with `./oracle_oci_tool.sh` and remote execution with `bash <(curl ...)` share the same data directory
- On the first run of the updated script, common configs and tasks will be migrated automatically if they still exist next to the script
- You can override the location by setting the `OCI_TOOL_HOME` environment variable before launch

## Script File

```text
./
└── oracle_oci_tool.sh      # Main script
```

## Background Tasks

- Tasks run in background with auto-retry
- Supports both instance update tasks and instance creation tasks
- Execution count is preserved across restarts
- Support resume stopped tasks
- Real-time log viewing

## Instance Creation Config Notes

- `create_instance_config.draft.json` stores in-progress draft values during the setup flow
- `create_instance_config.json` is overwritten only after final confirmation
- Boot volume size and performance are preserved in the saved config and reused for both foreground creation and background retry tasks
- For `Flex` shapes, CPU and memory are configured through `shape-config`, while boot volume settings are supplied through the instance launch source settings

## ⚠️ Important Notices & Disclaimer

### Disclaimer

1. **Account Responsibility**: The user is solely responsible for any account suspension, termination, or other consequences resulting from the use of this script. **The author assumes no liability.**

2. **No Backdoors**: All data generated by this script is stored **locally only**. There are **no remote servers, backdoors, or data collection mechanisms**.

3. **Use at Your Own Risk**: This script interacts with OCI APIs. Improper use may violate OCI's Terms of Service. Please review OCI's policies before use.

4. **No Warranty**: This software is provided "as is" without warranty of any kind, express or implied.

### Security Notes

- Email configuration file (`email_config.conf`) contains sensitive SMTP credentials
- All sensitive files are automatically added to `.gitignore`
- **Never commit** `email_config.conf` or `tasks/` directory to version control

## License

MIT License
