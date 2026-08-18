#!/bin/bash

# MD Device Verification Script
# This script checks multiple servers to verify that no MD devices are present
#
# Usage: verify_md_devices.sh [--file <hostfile>] [--parallel <count>]
#
# Options:
#   --file <hostfile>    Path to file containing hostnames (default: ./md_cleanup)
#   --parallel <count>   Number of parallel checks (default: 10)
#   --timeout <seconds>  SSH timeout in seconds (default: 10)

set -e -o pipefail

# Default values
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST_FILE="${SCRIPT_DIR}/md_cleanup"
PARALLEL_COUNT=10
SSH_TIMEOUT=10

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--file)
            HOST_FILE="$2"
            shift 2
            ;;
        -p|--parallel)
            PARALLEL_COUNT="$2"
            shift 2
            ;;
        -t|--timeout)
            SSH_TIMEOUT="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--file <hostfile>] [--parallel <count>] [--timeout <seconds>]"
            echo ""
            echo "Options:"
            echo "  --file <hostfile>    Path to file containing hostnames (default: ./md_cleanup)"
            echo "  --parallel <count>   Number of parallel checks (default: 10)"
            echo "  --timeout <seconds>  SSH timeout in seconds (default: 10)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
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

# Check if host file exists
if [[ ! -f "$HOST_FILE" ]]; then
    print_error "Host file not found: $HOST_FILE"
    exit 1
fi

# Read hosts from file (skip empty lines and comments)
readarray -t HOSTS < <(grep -v '^\s*$' "$HOST_FILE" | grep -v '^\s*#' | sed 's/\s*#.*//' | xargs -n1 | sort -u)

if [[ ${#HOSTS[@]} -eq 0 ]]; then
    print_error "No hosts found in $HOST_FILE"
    exit 1
fi

# Don't need to export function - will use inline command

# Create temporary file for results
TEMP_RESULTS=$(mktemp)
trap "rm -f $TEMP_RESULTS" EXIT

print_header "MD Device Verification"
echo ""
echo "Host file:       $HOST_FILE"
echo "Total hosts:     ${#HOSTS[@]}"
echo "Parallel checks: $PARALLEL_COUNT"
echo "SSH timeout:     ${SSH_TIMEOUT}s"
echo ""

print_header "Checking Hosts..."
echo ""

# Run checks in parallel - inline the check logic
printf '%s\n' "${HOSTS[@]}" | xargs -P "$PARALLEL_COUNT" -I HOST bash -c '
host="HOST"
result_file="'"$TEMP_RESULTS"'"
SSH_OPTS="-o ConnectTimeout='"$SSH_TIMEOUT"' -o StrictHostKeyChecking=no -o LogLevel=ERROR"

# Try to connect
if ! ssh $SSH_OPTS "$host" "exit" 2>/dev/null; then
    echo "$host|ERROR|Cannot connect via SSH" >> "$result_file"
    exit 0
fi

# Check /proc/mdstat for active MD devices
md_check=$(ssh $SSH_OPTS "$host" "cat /proc/mdstat 2>/dev/null | grep -c '\''^md'\'' || echo 0" 2>/dev/null | tr -d '\''\n\r'\'' | xargs)

if [[ -z "$md_check" ]]; then
    echo "$host|ERROR|Could not read /proc/mdstat" >> "$result_file"
    exit 0
fi

if [[ "$md_check" =~ ^[0-9]+$ ]] && [[ "$md_check" -gt 0 ]]; then
    md_details=$(ssh $SSH_OPTS "$host" "cat /proc/mdstat 2>/dev/null | grep '\''^md'\'' | head -5" 2>/dev/null | tr '\''\n'\'' '\''_;'\'' | sed '\''s/;$//'\'' )
    echo "$host|FOUND|$md_check MD device(s): $md_details" >> "$result_file"
    exit 0
fi

# Check for MD devices in /dev/disk/by-label/
label_check=$(ssh $SSH_OPTS "$host" "ls -l /dev/disk/by-label/ 2>/dev/null | grep -c '\''md[0-9]'\'' || echo 0" 2>/dev/null | tr -d '\''\n\r'\'' | xargs)

if [[ -z "$label_check" ]]; then
    echo "$host|CLEAN|No MD devices (could not check by-label)" >> "$result_file"
    exit 0
fi

if [[ "$label_check" =~ ^[0-9]+$ ]] && [[ "$label_check" -gt 0 ]]; then
    echo "$host|FOUND|$label_check device(s) mapped to MD in /dev/disk/by-label/" >> "$result_file"
    exit 0
fi

echo "$host|CLEAN|No MD devices found" >> "$result_file"
'

echo ""
print_header "Results"
echo ""

# Sort and parse results
sort "$TEMP_RESULTS" > "${TEMP_RESULTS}.sorted"
mv "${TEMP_RESULTS}.sorted" "$TEMP_RESULTS"

CLEAN_COUNT=0
FOUND_COUNT=0
ERROR_COUNT=0

# Read results and display
while IFS='|' read -r host status message || [[ -n "$host" ]]; do
    # Skip empty lines
    [[ -z "$host" ]] && continue

    case "$status" in
        CLEAN)
            print_success "$host: $message" || echo "✓ $host: $message"
            ((CLEAN_COUNT++)) || true
            ;;
        FOUND)
            print_warning "$host: $message" || echo "⚠ $host: $message"
            ((FOUND_COUNT++)) || true
            ;;
        ERROR)
            print_error "$host: $message" || echo "✗ $host: $message"
            ((ERROR_COUNT++)) || true
            ;;
    esac
done < "$TEMP_RESULTS"

echo ""
print_header "Summary"
echo ""
echo "Total hosts checked: ${#HOSTS[@]}"
echo -e "${GREEN}Clean:${NC}               $CLEAN_COUNT"
echo -e "${YELLOW}MD devices found:${NC}    $FOUND_COUNT"
echo -e "${RED}Errors:${NC}              $ERROR_COUNT"
echo ""

# Exit with error if any MD devices were found or errors occurred
if [[ $FOUND_COUNT -gt 0 || $ERROR_COUNT -gt 0 ]]; then
    exit 1
fi

exit 0
