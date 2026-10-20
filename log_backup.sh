#!/usr/bin/env bash
# Usage: ./log_backup.sh <log_dir> [N_percent=70] [backup_dir=/backup] [threshold=<partition size>]
#
# What it does:
#   1. Calculates what percentage of the given threshold the log folder occupies.
#      The threshold is a size: a number of bytes or a number with a suffix K/M/G
#      (for example 500M or 1G). If it is not given, the size of the partition
#      the folder lives on is used.
#   2. If the folder occupies more than N% of the threshold, archives the oldest
#      files (tar + gz) into the backup folder and deletes them from the log folder.
#      It takes exactly as many files as needed to bring the usage down to N%.
#
# Environment variables:
#   LAB1_MAX_COMPRESSION=1  - use lzma compression instead of gzip

set -euo pipefail

LOG_DIR="${1:-}"
PERCENT_LIMIT="${2:-70}"
BACKUP_DIR="${3:-/backup}"
THRESHOLD_ARG="${4:-}"

# Converts "500M", "1G", "1024" ... to bytes; fails on invalid input
parse_size() {
    local value="$1" num suffix
    if [[ "$value" =~ ^([0-9]+)([KkMmGg]?)$ ]]; then
        num="${BASH_REMATCH[1]}"
        suffix="${BASH_REMATCH[2]}"
        case "$suffix" in
            K|k) echo $(( num * 1024 )) ;;
            M|m) echo $(( num * 1024 * 1024 )) ;;
            G|g) echo $(( num * 1024 * 1024 * 1024 )) ;;
            *)   echo "$num" ;;
        esac
    else
        return 1
    fi
}

# --- Argument validation ---
if [[ -z "$LOG_DIR" ]]; then
    echo "Usage: $0 <log_dir> [N_percent=70] [backup_dir=/backup] [threshold=<partition size>]" >&2
    exit 1
fi
if [[ ! -d "$LOG_DIR" ]]; then
    echo "Error: '$LOG_DIR' is not a directory" >&2
    exit 1
fi
if ! [[ "$PERCENT_LIMIT" =~ ^[0-9]+$ ]] || (( PERCENT_LIMIT < 1 || PERCENT_LIMIT > 100 )); then
    echo "Error: N must be an integer from 1 to 100" >&2
    exit 1
fi

# --- Threshold size (in bytes) ---
if [[ -n "$THRESHOLD_ARG" ]]; then
    if ! THRESHOLD_BYTES=$(parse_size "$THRESHOLD_ARG") || (( THRESHOLD_BYTES == 0 )); then
        echo "Error: threshold must be a positive size such as 500M, 1G or a number of bytes" >&2
        exit 1
    fi
else
    read -r BLOCK_SIZE BLOCKS < <(stat -f -c '%S %b' "$LOG_DIR")
    THRESHOLD_BYTES=$(( BLOCK_SIZE * BLOCKS ))
fi

# --- Choose the compression algorithm ---
if [[ "${LAB1_MAX_COMPRESSION:-0}" == "1" ]]; then
    TAR_FLAG="--lzma"
    EXT="tar.lzma"
    ALGO="lzma"
else
    TAR_FLAG="-z"
    EXT="tar.gz"
    ALGO="gzip"
fi

# --- Size of the log folder (sum of file sizes, in bytes) ---
dir_size() {
    find "$LOG_DIR" -type f -printf '%s\n' | awk '{s+=$1} END {printf "%.0f", s}'
}
percent() {
    awk -v a="$1" -v t="$THRESHOLD_BYTES" 'BEGIN {printf "%.1f", a * 100 / t}'
}
mb() { echo $(( $1 / 1024 / 1024 )); }

SIZE=$(dir_size)

echo "Folder:       $LOG_DIR"
echo "Threshold:    $(mb "$THRESHOLD_BYTES") MB"
echo "Folder usage: $(percent "$SIZE")% of threshold ($(mb "$SIZE") MB of $(mb "$THRESHOLD_BYTES") MB), allowed: ${PERCENT_LIMIT}%"

# --- Limit check: N% of the threshold ---
TARGET=$(( THRESHOLD_BYTES * PERCENT_LIMIT / 100 ))
if (( SIZE <= TARGET )); then
    echo "Usage is within the limit, nothing to archive."
    exit 0
fi

TO_FREE=$(( SIZE - TARGET ))
echo "Need to free: $(mb "$TO_FREE") MB"

# --- Filtering: pick the N oldest files until TO_FREE bytes are collected ---
LIST="$(mktemp)"
trap 'rm -f "$LIST"' EXIT

FREED=0
COUNT=0
# %T@ - modification time, %s - size, %P - path relative to LOG_DIR; separator - \0
while IFS=' ' read -r -d '' _mtime FSIZE RELPATH; do
    printf '%s\0' "$RELPATH" >> "$LIST"
    FREED=$(( FREED + FSIZE ))
    COUNT=$(( COUNT + 1 ))
    (( FREED >= TO_FREE )) && break
done < <(find "$LOG_DIR" -type f -printf '%T@ %s %P\0' | sort -z -n)

if (( COUNT == 0 )); then
    echo "No files to archive in the folder." >&2
    exit 1
fi

# --- Archiving ---
mkdir -p "$BACKUP_DIR"
ARCHIVE="$BACKUP_DIR/log_backup_$(date +%Y%m%d_%H%M%S).$EXT"

echo "Archiving files: $COUNT ($(mb "$FREED") MB), algorithm: $ALGO"
tar "$TAR_FLAG" -cf "$ARCHIVE" -C "$LOG_DIR" --null -T "$LIST"

# --- Deletion (reached only if tar succeeded: set -e would have stopped the script earlier) ---
(cd "$LOG_DIR" && xargs -0 rm -f -- < "$LIST")

# --- Summary ---
NEW_SIZE=$(dir_size)
echo "Archive:      $ARCHIVE"
echo "Done. Folder usage is now: $(percent "$NEW_SIZE")% of threshold"

if (( NEW_SIZE > TARGET )); then
    echo "Warning: limit not reached - no more files left to archive." >&2
fi
