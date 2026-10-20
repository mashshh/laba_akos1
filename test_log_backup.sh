#!/usr/bin/env bash
# Tests for log_backup.sh. Run: ./test_log_backup.sh
# Everything is created in a temporary folder and removed at the end. No root needed.
# About 0.7 GB of free disk space is required.

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/log_backup.sh"
ROOT="$(mktemp -d)"
LOG="$ROOT/log"
BK="$ROOT/backup"
trap 'rm -rf "$ROOT"' EXIT

FILES=10                  # number of files in the folder
FILE_MB=55                # file size: 10 x 55 MB = 550 MB (>= 0.5 GB)
THR="1G"                  # threshold used by the tests -> logs = 53.7% of it
THR_BYTES=1073741824
unset LAB1_MAX_COMPRESSION

PASSED=0
FAILED=0
OUT=""
CODE=0

# --- free space check ---
FREE_KB=$(df -P -k "$ROOT" | awk 'NR==2 {print $4}')
if (( FREE_KB < 700 * 1024 )); then
    echo "Not enough disk space: ~700 MB must be free." >&2
    exit 2
fi

# Relative path of file number i (some files live in a subfolder)
relpath() {
    local n; n=$(printf '%02d' "$1")
    if (( $1 == 4 || $1 == 8 )); then echo "sub/app log_$n.log"; else echo "app log_$n.log"; fi
}

# Environment setup: 10 files of 55 MB, file 1 is the oldest
setup() {
    rm -rf "$LOG" "$BK"
    mkdir -p "$LOG/sub" "$BK"
    local i f
    for (( i = 1; i <= FILES; i++ )); do
        f="$LOG/$(relpath "$i")"
        dd if=/dev/zero of="$f" bs=1M count=$FILE_MB status=none
        touch -d "2020-01-$(printf '%02d' "$i") 00:00:00" "$f"
    done
}

# Run script #1; output and exit code are saved
run() {
    OUT="$("$SCRIPT" "$@" 2>&1)"
    CODE=$?
}

# Test report: report "name" <0 on success>
report() {
    if [[ "$2" == "0" ]]; then
        echo "  [PASS] $1"; PASSED=$(( PASSED + 1 ))
    else
        echo "  [FAIL] $1"; FAILED=$(( FAILED + 1 ))
        echo "         exit code: $CODE; script output:"
        echo "$OUT" | sed 's/^/         | /'
    fi
}

archive_path() { ls "$BK"/log_backup_*."$1" 2>/dev/null | head -n1; }

echo "Testing $SCRIPT"
echo "(each test: ${FILES} files x ${FILE_MB} MB = $(( FILES * FILE_MB )) MB, threshold $THR)"
echo

# ---------------- Test 1: below the limit - nothing happens ----------------
setup
run "$LOG" 80 "$BK" "$THR"
ok=0
(( CODE == 0 )) || ok=1
[[ -z "$(ls -A "$BK")" ]] || ok=1
(( $(find "$LOG" -type f | wc -l) == FILES )) || ok=1
report "1. Below N% of threshold: no archive created, files untouched" $ok

# ---------------- Test 2: above the limit - archive created, limit reached ----------------
setup
run "$LOG" 30 "$BK" "$THR"
ok=0
(( CODE == 0 )) || ok=1
[[ -n "$(archive_path tar.gz)" ]] || ok=1
used=$(find "$LOG" -type f -printf '%s\n' | awk '{s+=$1} END {printf "%.0f", s}')
(( used <= THR_BYTES * 30 / 100 )) || ok=1
report "2. Above N% of threshold: .tar.gz archive created, usage <= 30% of threshold" $ok

# ---------------- Test 3: exactly the oldest files are archived ----------------
setup
run "$LOG" 30 "$BK" "$THR"
ok=0
A="$(archive_path tar.gz)"
expected="$(for i in 1 2 3 4 5; do relpath "$i"; done | sort)"
actual="$(tar -tzf "$A" 2>/dev/null | sort)"
[[ "$expected" == "$actual" ]] || ok=1
for i in 1 2 3 4 5;  do [[ ! -e "$LOG/$(relpath "$i")" ]] || ok=1; done   # old files removed
for i in 6 7 8 9 10; do [[   -e "$LOG/$(relpath "$i")" ]] || ok=1; done   # new files kept
report "3. Archive contains exactly the 5 oldest files, newest files remain" $ok

# ---------------- Test 4: invalid arguments ----------------
ok=0
run "$ROOT/no_such_folder" 50 "$BK" "$THR";  (( CODE != 0 )) || ok=1
run "$LOG" abc "$BK" "$THR";                 (( CODE != 0 )) || ok=1
run "$LOG" 150 "$BK" "$THR";                 (( CODE != 0 )) || ok=1
run "$LOG" 50 "$BK" abc;                     (( CODE != 0 )) || ok=1
run;                                         (( CODE != 0 )) || ok=1
report "4. Invalid arguments (no folder, N = abc / 150, threshold abc, no arguments) -> error" $ok

# ---------------- Test 5: archive integrity ----------------
setup
run "$LOG" 30 "$BK" "$THR"
ok=0
A="$(archive_path tar.gz)"
gzip -t "$A" 2>/dev/null || ok=1
mkdir -p "$ROOT/restore"
tar -xzf "$A" -C "$ROOT/restore" 2>/dev/null || ok=1
(( $(find "$ROOT/restore" -type f | wc -l) == 5 )) || ok=1
for i in 1 2 3 4 5; do
    sz=$(stat -c %s "$ROOT/restore/$(relpath "$i")" 2>/dev/null || echo 0)
    (( sz == FILE_MB * 1024 * 1024 )) || ok=1
done
rm -rf "$ROOT/restore"
report "5. Archive is readable, files extract intact (names with spaces, subfolders)" $ok

# ---------------- Test 6: LAB1_MAX_COMPRESSION=1 -> lzma ----------------
setup
LAB1_MAX_COMPRESSION=1 run "$LOG" 30 "$BK" "$THR"
ok=0
A="$(archive_path tar.lzma)"
[[ -n "$A" ]] || ok=1
if [[ -n "$A" ]]; then
    tar --lzma -tf "$A" >/dev/null 2>&1 || ok=1
    file "$A" 2>/dev/null | grep -qi 'lzma' || ok=1
fi
[[ -z "$(archive_path tar.gz)" ]] || ok=1
report "6. LAB1_MAX_COMPRESSION=1: .tar.lzma archive created, lzma format" $ok

# ---------------- Test 7: the percentage is relative to the given threshold ----------------
setup
run "$LOG" 30 "$BK" 2G
ok=0
(( CODE == 0 )) || ok=1
[[ -z "$(ls -A "$BK")" ]] || ok=1
(( $(find "$LOG" -type f | wc -l) == FILES )) || ok=1
report "7. Same files, threshold 2G: 550 MB is below 30% of it, nothing archived" $ok

# ---------------- Summary ----------------
echo
echo "Summary: passed $PASSED of $(( PASSED + FAILED ))"
(( FAILED == 0 ))
