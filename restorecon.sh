#!/bin/bash

# ==============================================================================
# Parallel SELinux Relabeling Script (V2 - Filesystem Boundary Aware)
# ==============================================================================
# Description:
# This script speeds up SELinux file context relabeling by running multiple
# 'restorecon' processes in parallel.
#
# KEY IMPROVEMENT (V2):
# Uses the '-x' flag with 'restorecon' to prevent crossing filesystem
# boundaries. This solves the redundancy problem where the job for the root
# filesystem ('/') would descend into and relabel other filesystems (/home,
# /var, etc.) that already have their own dedicated relabeling jobs.
#
# Logic:
# 1. Checks for root privileges and 'permissive' SELinux mode.
# 2. Determines the optimal number of parallel jobs based on available CPU cores.
# 3. Identifies all mounted, physical filesystems (xfs, ext4, btrfs, etc.).
# 4. For each filesystem, launches a 'restorecon -R -x' job, ensuring each job
#    stays within its assigned filesystem.
# 5. Manages all jobs in a pool to not exceed the CPU core limit.
# ==============================================================================

set -eo pipefail # Exit on error

# --- Configuration ---
RESERVED_CORES=2
# Add other physical filesystem types if needed, comma-separated.
FILESYSTEM_TYPES="xfs,ext4,btrfs,ext3,ext2"


# --- Safety Checks ---
echo "--- Running Pre-flight Checks ---"

# 1. Check for root privileges
if [[ $EUID -ne 0 ]]; then
   echo "❌ Error: This script must be run as root."
   exit 1
fi
echo "✅ Root privileges confirmed."

# 2. Check if SELinux is in Permissive mode
SELINUX_MODE=$(getenforce)
if [[ "$SELINUX_MODE" != "Permissive" ]]; then
    echo "❌ Error: SELinux is not in Permissive mode. Current mode: $SELINUX_MODE"
    echo "💡 Please run 'sudo setenforce 0' and then re-run this script."
    exit 1
fi
echo "✅ SELinux is in Permissive mode."


# --- Core Logic ---
echo -e "\n--- Starting Parallel Relabeling Process ---"

# 1. Calculate the number of parallel jobs
NUM_CORES=$(nproc)
let MAX_JOBS=$NUM_CORES-$RESERVED_CORES

if [[ "$MAX_JOBS" -lt 1 ]]; then
    MAX_JOBS=1
fi

echo "Detected $NUM_CORES CPU cores. Reserving $RESERVED_CORES."
echo "➡️  Will run a maximum of $MAX_JOBS 'restorecon' jobs in parallel."

# 2. Get the list of target mount points, sorted by path length to process deeper paths first
# Although with '-x' this is not strictly necessary, it can be a good practice.
echo "Finding mount points for filesystem types: $FILESYSTEM_TYPES..."
mapfile -t MOUNTS < <(findmnt -n -o TARGET -t "$FILESYSTEM_TYPES" | awk '{ print length, $0 }' | sort -rn | cut -d" " -f2-)

if [ ${#MOUNTS[@]} -eq 0 ]; then
    echo "⚠️ No filesystems of the specified types were found. Exiting."
    exit 0
fi

echo "Found ${#MOUNTS[@]} filesystems to relabel (will be processed independently):"
printf " - %s\n" "${MOUNTS[@]}"
echo ""


# 3. Run and manage the parallel jobs
start_time=$(date +%s)
log_dir="/var/log/parallel_relabel"
mkdir -p "$log_dir"
echo "Log files for each job will be stored in $log_dir"

for mount_point in "${MOUNTS[@]}"; do
    # Ensure there's a slot in the job pool before starting a new job
    while [[ $(jobs -r -p | wc -l) -ge $MAX_JOBS ]]; do
        # Wait for any single job to finish
        wait -n
    done

    # Sanitize mount point for use in a filename
    log_filename=$(echo "$mount_point" | sed 's|^/|root|; s|/|_|g').log
    log_path="$log_dir/$log_filename"

    echo "[$(date +'%H:%M:%S')] Starting job for: '$mount_point'. Log: $log_path"
    
    # Run restorecon recursively (-R), without crossing filesystems (-x),
    # and with verbosity (-v) redirected to a log file.
    restorecon -R -v -x "$mount_point" > "$log_path" 2>&1 &
done

# Wait for all remaining background jobs to complete
echo -e "\n--- All relabeling tasks have been launched. Waiting for all jobs to complete... ---"
wait
end_time=$(date +%s)
duration=$((end_time - start_time))

echo -e "\n🎉 \033[1;32mAll filesystems have been relabeled successfully!\033[0m"
echo "Total execution time: $(($duration / 3600))h $((($duration / 60) % 60))m $(($duration % 60))s"


# --- Final Instructions ---
echo -e "\n--- Next Steps ---"
echo "1. Check for any errors by reviewing the logs in '$log_dir'."
echo "   Example: grep -i -E 'error|failed' $log_dir/*.log"
echo ""
echo "2. Verify there are no new SELinux denials:"
echo "   sudo ausearch -m AVC,USER_AVC,SELINUX_ERR -ts recent"
echo ""
