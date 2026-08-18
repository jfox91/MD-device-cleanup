# MD Device Cleanup Scripts

A collection of bash scripts for cleaning up and managing MD RAID devices on Linux servers. These scripts help remove RAID metadata from drives and convert them to direct SCSI access.

## Scripts

### cleanup_md_devices.sh

Main cleanup script that removes RAID metadata from drives and converts them to direct SCSI access.

**Features:**
- Local execution on the current system
- Remote execution via SSH on specified servers
- Automatic Docker stopping and data drive unmounting
- MD device detection and cleanup
- RAID superblock clearing
- Automatic reboot handling with verification

**Usage:**

```bash
# Local execution
./cleanup_md_devices.sh [--yes]

# Remote execution
./cleanup_md_devices.sh --remote <hostname> [--yes]
```

**Options:**
- `--remote <hostname>` - Execute cleanup on a remote server via SSH
- `--yes` - Skip confirmation prompts (auto-proceed)

**What it does:**
1. Checks for MD devices in the system
2. Stops Docker services
3. Unmounts data drives
4. Stops all MD devices
5. Clears RAID superblocks from affected drives
6. Optionally reboots the system
7. For remote execution: monitors reboot and verifies drive mapping

### verify_md_devices.sh

Verification script that checks multiple servers to ensure no MD devices are present.

**Features:**
- Parallel checking of multiple servers
- Configurable SSH timeout and parallelism
- Color-coded output for easy status identification
- Summary report of all checked servers

**Usage:**

```bash
# Check servers listed in ./md_cleanup file
./verify_md_devices.sh

# Use custom host file
./verify_md_devices.sh --file /path/to/hostfile

# Custom parallel count and timeout
./verify_md_devices.sh --parallel 20 --timeout 15
```

**Options:**
- `--file <hostfile>` - Path to file containing hostnames (default: ./md_cleanup)
- `--parallel <count>` - Number of parallel checks (default: 10)
- `--timeout <seconds>` - SSH timeout in seconds (default: 10)

### md_cleanup

Plain text file containing a list of server hostnames (one per line) to be checked or cleaned up. Used by the verify script.

## Requirements

- Bash 4.0 or higher
- Root or passwordless sudo access (for cleanup script)
- SSH access to remote servers (for remote operations)
- Standard Linux utilities: `mdadm`, `lsblk`, `systemctl`

## Safety Features

- Confirmation prompts before destructive operations (unless `--yes` is used)
- Verification of MD device status before and after operations
- Automatic detection of devices still in use
- Troubleshooting steps for locked devices
- Remote execution monitoring and reboot verification

## License

This project is provided as-is for server administration purposes.

## Author

Created for managing RAID device cleanup across multiple servers.
