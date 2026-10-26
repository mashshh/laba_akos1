#!/usr/bin/env bash

if [[ -z "${LAB1_IN_NS:-}" ]]; then
    SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    if ! unshare -rm sh -c 'd="$(mktemp -d)" && mount -t tmpfs tmpfs "$d" && umount "$d" && rmdir "$d"' 2>/dev/null; then
        echo "Cannot mount tmpfs without root here (unshare -rm is blocked)." >&2
        echo "Use ./test_log_backup.sh instead (it passes the threshold explicitly)." >&2
        exit 2
    fi
    exec env LAB1_IN_NS=1 unshare -rm bash "$SELF" "$@"
fi

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/log_backup.sh"
ROOT="$(mktemp -d)"
LOG="$ROOT/log"
BK="$ROOT/backup"
trap 'cd /; umount "$LOG" 2>/dev/null; rm -rf "$ROOT"' EXIT

FILES=10
FILE_MB=55
unset LAB1_MAX_COMPRESSION

PASSED=0
FAILED=0
OUT=""
CODE=0

mkdir -p "$LOG"
mount -t tmpfs -o size=1G tmpfs "$LOG"
read -r BLOCK_SIZE BLOCKS < <(stat -f -c '%S %b' "$LOG")
THR_BYTES=$(( BLOCK_SIZE * BLOCKS ))

FREE_KB=$(df -P -k "$ROOT" | awk 'NR==2 {print $4}')
if (( FREE_KB < 700 * 1024 )); then
    echo "Not enough disk space: ~700 MB must be free." >&2
    exit 2
fi

relpath() {
    local n; n=$(printf '%02d' "$1")
    if (( $1 == 4 || $1 == 8 )); then echo "sub/app log_$n.log"; else echo "app log_$n.log"; fi
}

setup() {
    find "$LOG" -mindepth 1 -delete
    rm -rf "$BK"
    mkdir -p "$LOG/sub" "$BK"
    local i f
    for (( i = 1; i <= FILES; i++ )); do
        f="$LOG/$(relpath "$i")"
        dd if=/dev/zero of="$f" bs=1M count=$FILE_MB status=none
        touch -d "2020-01-$(printf '%02d' "$i") 00:00:00" "$f"
    done
}

run() {
    OUT="$("$SCRIPT" "$@" 2>&1)"
    CODE=$?
}

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
echo "(each test: ${FILES} files x ${FILE_MB} MB = $(( FILES * FILE_MB )) MB)"
echo

#Test 1
setup
run "$LOG" 80 "$BK"
ok=0
(( CODE == 0 )) || ok=1
[[ -z "$(ls -A "$BK")" ]] || ok=1
(( $(find "$LOG" -type f | wc -l) == FILES )) || ok=1
report "1. Below N% of threshold: no archive created, files untouched" $ok

#Test 2
setup
run "$LOG" 30 "$BK"
ok=0
(( CODE == 0 )) || ok=1
[[ -n "$(archive_path tar.gz)" ]] || ok=1
used=$(find "$LOG" -type f -printf '%s\n' | awk '{s+=$1} END {printf "%.0f", s}')
(( used <= THR_BYTES * 30 / 100 )) || ok=1
report "2. Above N% of threshold: .tar.gz archive created, usage <= 30% of threshold" $ok

#Test 3
setup
run "$LOG" 30 "$BK"
ok=0
A="$(archive_path tar.gz)"
expected="$(for i in 1 2 3 4 5; do relpath "$i"; done | sort)"
actual="$(tar -tzf "$A" 2>/dev/null | sort)"
[[ "$expected" == "$actual" ]] || ok=1
for i in 1 2 3 4 5;  do [[ ! -e "$LOG/$(relpath "$i")" ]] || ok=1; done
for i in 6 7 8 9 10; do [[   -e "$LOG/$(relpath "$i")" ]] || ok=1; done
report "3. Archive contains exactly the 5 oldest files, newest files remain" $ok

#Test 4
ok=0
run "$ROOT/no_such_folder" 50 "$BK";  (( CODE != 0 )) || ok=1
run "$LOG" abc "$BK";                 (( CODE != 0 )) || ok=1
run "$LOG" 150 "$BK";                 (( CODE != 0 )) || ok=1
run "$LOG" 50 "$BK" abc;                     (( CODE != 0 )) || ok=1
run;                                         (( CODE != 0 )) || ok=1
report "4. Invalid arguments (no folder, N = abc / 150, threshold abc, no arguments) -> error" $ok

#Test 5
setup
run "$LOG" 30 "$BK"
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

#Test 6
setup
LAB1_MAX_COMPRESSION=1 run "$LOG" 30 "$BK"
ok=0
A="$(archive_path tar.lzma)"
[[ -n "$A" ]] || ok=1
if [[ -n "$A" ]]; then
    tar --lzma -tf "$A" >/dev/null 2>&1 || ok=1
    file "$A" 2>/dev/null | grep -qi 'lzma' || ok=1
fi
[[ -z "$(archive_path tar.gz)" ]] || ok=1
report "6. LAB1_MAX_COMPRESSION=1: .tar.lzma archive created, lzma format" $ok

#Test 7
setup
run "$LOG" 30 "$BK" 2G
ok=0
(( CODE == 0 )) || ok=1
[[ -z "$(ls -A "$BK")" ]] || ok=1
(( $(find "$LOG" -type f | wc -l) == FILES )) || ok=1
report "7. Same files, threshold 2G: 550 MB is below 30% of it, nothing archived" $ok

echo
echo "Summary: passed $PASSED of $(( PASSED + FAILED ))"
(( FAILED == 0 ))
