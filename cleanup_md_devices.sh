#!/bin/bash

# MD Device Cleanup Script (Local + Remote Execution)
# This script removes RAID metadata from drives and converts them to direct SCSI access
# Based on Section 5.4 MD Device Cleanup Procedure
#
# Usage:
#   Local:  cleanup_md_devices.sh [--yes]
#   Remote: cleanup_md_devices.sh --remote <hostname> [--yes]
#
# Options:
#   --remote <hostname>  Execute on remote server via SSH
#   --yes                Skip confirmation prompts (auto-proceed)

set -e

# Parse arguments
AUTO_YES=false
REMOTE_MODE=false
REMOTE_HOST=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -y|--yes)
            AUTO_YES=true
            shift
            ;;
        -r|--remote)
            REMOTE_MODE=true
            REMOTE_HOST="$2"
            shift 2
            ;;
        *)
            if [[ "$REMOTE_MODE" == "true" && -z "$REMOTE_HOST" ]]; then
                REMOTE_HOST="$1"
                shift
            else
                echo "Unknown option: $1"
                echo "Usage: $0 [--remote <hostname>] [--yes]"
                exit 1
            fi
            ;;
    esac
done

# ============================================
# REMOTE EXECUTION MODE
# ============================================
if [[ "$REMOTE_MODE" == "true" ]]; then
    if [[ -z "$REMOTE_HOST" ]]; then
        echo "Error: --remote requires a hostname"
        echo "Usage: $0 --remote <hostname> [--yes]"
        exit 1
    fi

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    SCRIPT_PATH="${BASH_SOURCE[0]}"

    echo "========================================"
    echo "  Remote MD Device Cleanup"
    echo "  Target: $REMOTE_HOST"
    echo "========================================"
    echo ""

    # Check if we can SSH to the server
    echo "Testing SSH connection to $REMOTE_HOST..."
    if ! ssh -o ConnectTimeout=15 "$REMOTE_HOST" "echo 'Connection successful'" 2>/dev/null; then
        echo "Error: Cannot connect to $REMOTE_HOST via SSH"
        exit 1
    fi

    echo "Connection successful!"
    echo ""

    # Copy script to remote server
    echo "Copying cleanup script to $REMOTE_HOST..."
    scp "$SCRIPT_PATH" "$REMOTE_HOST:/tmp/cleanup_md_devices.sh" || {
        echo "Error: Failed to copy script to remote server"
        exit 1
    }

    echo "Script copied successfully"
    echo ""

    # Ask for confirmation before executing (unless --yes is specified)
    if [[ "$AUTO_YES" != "true" ]]; then
        echo "This will:"
        echo "  1. Stop Docker and unmount data drives"
        echo "  2. Stop all MD devices"
        echo "  3. Clear RAID superblocks"
        echo "  4. Reboot the server"
        echo ""
        read -p "Proceed with cleanup on $REMOTE_HOST? (yes/no): " CONFIRM
        if [[ "$CONFIRM" != "yes" ]]; then
            echo "Cleanup cancelled"
            ssh "$REMOTE_HOST" "rm -f /tmp/cleanup_md_devices.sh" 2>/dev/null || true
            exit 0
        fi
    fi

    # Execute script on remote server
    echo ""
    echo "Executing cleanup script on $REMOTE_HOST..."
    echo "========================================"
    echo ""

    # Record uptime before running script to detect if reboot happened
    UPTIME_BEFORE=$(ssh "$REMOTE_HOST" "cat /proc/uptime | cut -d' ' -f1" 2>/dev/null)

    # Build remote command with --yes if needed
    REMOTE_CMD="chmod +x /tmp/cleanup_md_devices.sh && /tmp/cleanup_md_devices.sh"
    if [[ "$AUTO_YES" == "true" ]]; then
        REMOTE_CMD="$REMOTE_CMD --yes"
    fi

    ssh -t "$REMOTE_HOST" "$REMOTE_CMD"

    EXIT_CODE=$?

    echo ""
    echo "========================================"

    if [[ $EXIT_CODE -eq 0 ]]; then
        # Check if server is still reachable (might be rebooting)
        sleep 5

        if ! ssh -o ConnectTimeout=5 "$REMOTE_HOST" "echo test" >/dev/null 2>&1; then
            echo "Server appears to be rebooting..."
            echo "Waiting for server to come back online (max 5 minutes)..."

            # Wait for server to come back
            SERVER_ONLINE=false
            for i in {1..60}; do
                sleep 5
                if ssh -o ConnectTimeout=5 "$REMOTE_HOST" "echo test" >/dev/null 2>&1; then
                    echo ""
                    echo "Server is back online!"
                    sleep 10  # Give it a bit more time to fully boot
                    SERVER_ONLINE=true
                    break
                fi
                echo -n "."
            done
            echo ""

            if [[ "$SERVER_ONLINE" != "true" ]]; then
                echo "Warning: Server did not come back online within 5 minutes"
                echo "Please check the server manually"
                exit 1
            fi

            # Keep trying to verify drive mapping for up to 2 more minutes
            echo "Waiting for drive mapping to be available..."
            MAPPING_VERIFIED=false
            for attempt in {1..24}; do
                if ssh -o ConnectTimeout=10 "$REMOTE_HOST" "ls -l /dev/disk/by-label/ 2>/dev/null | grep -q 'data_1'" 2>/dev/null; then
                    echo "Drive mapping is available, verifying..."
                    echo ""
                    if ssh -o ConnectTimeout=10 "$REMOTE_HOST" "ls -l /dev/disk/by-label/ 2>/dev/null | grep -E 'data_|fast_'" 2>/dev/null; then
                        echo ""
                        echo "Verification complete - check that all drives show /dev/sd* (not /dev/md*)"
                        MAPPING_VERIFIED=true
                        break
                    fi
                fi

                if [[ $attempt -lt 24 ]]; then
                    echo -n "."
                    sleep 5
                fi
            done

            if [[ "$MAPPING_VERIFIED" != "true" ]]; then
                echo ""
                echo "Warning: Could not verify drive mapping after waiting"
                echo "The server may still be initializing. Please check manually with:"
                echo "  ssh $REMOTE_HOST 'ls -l /dev/disk/by-label/'"
            fi
        else
            # Server didn't reboot - check uptime to confirm
            UPTIME_AFTER=$(ssh "$REMOTE_HOST" "cat /proc/uptime | cut -d' ' -f1" 2>/dev/null)

            if (( $(echo "$UPTIME_AFTER < $UPTIME_BEFORE" | bc -l 2>/dev/null || echo 0) )); then
                echo "Server was rebooted"
            else
                echo "Cleanup completed (no reboot performed)"
            fi
        fi
    else
        echo "Cleanup exited with code $EXIT_CODE"
    fi

    # Cleanup
    ssh "$REMOTE_HOST" "rm -f /tmp/cleanup_md_devices.sh" 2>/dev/null || true

    exit 0
fi

# ============================================
# LOCAL EXECUTION MODE
# ============================================

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_step() {
    echo -e "${BLUE}==>${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

# Check if we're running as root or with sudo access
if [[ $EUID -ne 0 ]] && ! sudo -n true 2>/dev/null; then
    print_error "This script requires root privileges or passwordless sudo access"
    exit 1
fi

# Ensure sudo is used for all commands
SUDO=""
if [[ $EUID -ne 0 ]]; then
    SUDO="sudo"
fi

echo "========================================"
echo "  MD Device Cleanup Script"
echo "========================================"
echo ""

# Step 1: Check current MD device status
print_step "Step 1: Checking for MD devices..."
echo ""

# Count and display SD devices
SD_DEVICES=$(ls /dev/sd* 2>/dev/null | grep -E "^/dev/sd[a-z]$" || true)
SD_COUNT=$(echo "$SD_DEVICES" | grep -v "^$" | wc -l)
echo "Total SD devices found: $SD_COUNT"
if [[ $SD_COUNT -gt 0 ]]; then
    echo "$SD_DEVICES" | while read dev; do
        SIZE=$(lsblk -dno SIZE "$dev" 2>/dev/null || echo "unknown")
        MODEL=$(lsblk -dno MODEL "$dev" 2>/dev/null | xargs || echo "unknown")
        echo "  - $(basename $dev): $SIZE ($MODEL)"
    done
fi
echo ""

echo "Current drive mapping:"
ls -l /dev/disk/by-label/ | grep -E "data_|fast_" || true
echo ""

if ! cat /proc/mdstat > /dev/null 2>&1; then
    print_success "No MD devices present - system already clean!"
    exit 0
fi

echo "MD device status:"
cat /proc/mdstat
echo ""

# Check if there are any active MD devices
if ! grep -q "^md" /proc/mdstat 2>/dev/null; then
    print_success "No active MD devices found - system is clean!"
    exit 0
fi

# Count MD devices in by-label
MD_COUNT=$(ls -l /dev/disk/by-label/ 2>/dev/null | grep -c "md[0-9]" || echo 0)
if [[ $MD_COUNT -eq 0 ]]; then
    print_success "No MD devices in /dev/disk/by-label/ - system appears clean"
    exit 0
fi

print_warning "Found $MD_COUNT drive(s) mapped to MD devices"
echo ""

# Ask for confirmation (unless --yes was specified)
if [[ "$AUTO_YES" != "true" ]]; then
    read -t 30 -p "Do you want to proceed with MD device cleanup? (yes/no): " CONFIRM || {
        echo ""
        print_error "No input received (timeout after 30 seconds)"
        exit 1
    }
    if [[ "$CONFIRM" != "yes" ]]; then
        print_warning "Cleanup cancelled by user"
        exit 0
    fi
else
    print_step "Auto-proceeding with cleanup (--yes flag specified)"
fi

echo ""

# Step 2: Stop Docker
print_step "Step 2: Stopping Docker..."
if systemctl is-active --quiet docker 2>/dev/null; then
    $SUDO systemctl stop docker
    print_success "Docker stopped"
else
    print_warning "Docker is not running"
fi
echo ""

# Step 3: Unmount data drives
print_step "Step 3: Unmounting data drives..."
$SUDO systemctl stop 'mnt-data*' 2>/dev/null || true
print_success "Data drives unmounted"
echo ""

# Step 4: Stop MD devices
print_step "Step 4: Stopping MD devices..."
STOP_OUTPUT=$($SUDO mdadm --stop /dev/md* 2>&1 || true)

# Check if we got the "device still open" error
if echo "$STOP_OUTPUT" | grep -q "Cannot get exclusive access"; then
    print_warning "Some devices are still in use - applying troubleshooting steps..."
    echo ""

    print_step "Stopping kubelet..."
    $SUDO systemctl stop kubelet 2>/dev/null || print_warning "Kubelet not running or not present"

    print_step "Restarting Docker temporarily..."
    $SUDO systemctl start docker 2>/dev/null || true

    print_step "Waiting 15 seconds..."
    sleep 15

    print_step "Stopping Docker again..."
    $SUDO systemctl stop docker 2>/dev/null || true

    print_step "Retrying MD device stop..."
    $SUDO mdadm --stop /dev/md* 2>&1 | grep -v "does not appear to be an md device" | grep -v "No such device" || true
fi

print_success "MD devices stopped"
echo ""

# Step 5: Verify MD devices are stopped
print_step "Step 5: Verifying MD devices are stopped..."
echo ""
cat /proc/mdstat
echo ""

if grep -q "^md" /proc/mdstat 2>/dev/null; then
    print_error "Some MD devices are still active!"
    print_error "Please manually investigate and stop them before continuing"
    exit 1
fi

if ! grep -q "unused devices: <none>" /proc/mdstat 2>/dev/null; then
    print_warning "Unexpected mdstat output - please verify manually"
fi

print_success "All MD devices are stopped"
echo ""

# Step 6: Clear RAID superblocks
print_step "Step 6: Clearing RAID superblocks from affected drives..."
echo ""

# Find drives with ddf_raid_member
RAID_DRIVES=$(lsblk -f | grep ddf_raid_member | awk '{print $1}' || true)

if [[ -z "$RAID_DRIVES" ]]; then
    print_warning "No drives with ddf_raid_member found"
else
    echo "Clearing superblocks from the following drives:"
    echo "$RAID_DRIVES"
    echo ""

    cd /dev
    for drive in $RAID_DRIVES; do
        echo "Clearing /dev/$drive..."
        $SUDO mdadm --zero-superblock /dev/$drive 2>/dev/null || print_warning "Could not clear $drive (may be already clean)"
    done

    print_success "RAID superblocks cleared"
fi
echo ""

# Step 7: Ask about reboot
print_step "Step 7: Reboot required"
echo ""
print_warning "The server needs to be rebooted for changes to take full effect"
echo ""

if [[ "$AUTO_YES" == "true" ]]; then
    print_step "Auto-rebooting server (--yes flag specified)..."
    $SUDO reboot
else
    read -t 30 -p "Do you want to reboot now? (yes/no): " REBOOT || REBOOT="no"
    if [[ "$REBOOT" == "yes" ]]; then
        print_step "Rebooting server..."
        $SUDO reboot
    else
        print_warning "Reboot postponed - please reboot manually when ready"
        echo ""
        echo "After reboot, verify with:"
        echo "  ls -l /dev/disk/by-label/"
        echo "  cat /proc/mdstat"
    fi
fi

echo ""
print_success "MD device cleanup completed successfully!"
