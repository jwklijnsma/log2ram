#!/usr/bin/env bash
# log2ram-guard — keep the log2ram tmpfs (/var/log) at or below a max usage %.
#
#   log2ram-guard.sh             run a cleanup pass (only acts when over threshold)
#   log2ram-guard.sh --dry-run   show what would happen, change nothing
#   log2ram-guard.sh --install   install to /usr/local/sbin, add systemd timer (every 5 min)
#                                and a journald size cap derived from the log2ram size
#   log2ram-guard.sh --uninstall remove timer, service, journald drop-in and script
#   log2ram-guard.sh --journald  (re)write only the journald size cap
#
# Settings are read from /etc/default/log2ram-guard if it exists.
#
# Cleanup order (stops as soon as usage <= threshold):
#   1. vacuum the systemd journal
#   2. delete rotated logs (*.gz, *.1, *.old, dated files, ...)
#   3. release space held by deleted-but-still-open log files
#   4. shrink the largest logs to their last KEEP_TAIL bytes (inode preserved)
#   5. last resort: empty the largest logs completely

set -uo pipefail

CONF="${LOG2RAM_GUARD_CONF:-/etc/default/log2ram-guard}"
# shellcheck source=/dev/null
[[ -r $CONF ]] && . "$CONF"

THRESHOLD="${THRESHOLD:-65}"           # max % usage of /var/log
MOUNT="${MOUNT:-/var/log}"
KEEP_TAIL="${KEEP_TAIL:-2M}"           # bytes kept per file in step 4
JOURNAL_PCT="${JOURNAL_PCT:-25}"       # journald cap as % of log2ram size (--install)
INTERVAL="${INTERVAL:-5min}"           # timer interval (--install)
SYNC_AFTER="${SYNC_AFTER:-1}"          # run 'log2ram write' after a cleanup
DRY=0

# Paths can be overridden from the environment (the test suite points them at a temp dir).
BIN="${LOG2RAM_GUARD_BIN:-/usr/local/sbin/log2ram-guard}"
UNIT="${LOG2RAM_GUARD_UNIT:-/etc/systemd/system/log2ram-guard}"
JDROP="${LOG2RAM_GUARD_JDROP:-/etc/systemd/journald.conf.d/50-log2ram-guard.conf}"
L2R_CONF="${LOG2RAM_CONF:-/etc/log2ram.conf}"
TMPDIR_GUARD="${LOG2RAM_GUARD_TMPDIR:-/run}"

log() { echo "log2ram-guard: $*"; logger -t log2ram-guard -- "$*" 2>/dev/null || true; }
run() { if (( DRY )); then echo "  [dry-run] $*"; else "$@"; fi; }

usage_pct() { df --output=pcent "$MOUNT" | tail -1 | tr -dc '0-9'; }
size_mb()   { df --output=size -BM "$MOUNT" | tail -1 | tr -dc '0-9'; }
ok()        { (( $(usage_pct) <= THRESHOLD )); }
need_root() { [[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }; }

# Largest regular files by allocated space (skip binary journal + sparse lastlog)
largest_files() {
    find "$MOUNT" -xdev -type f \
        ! -path "$MOUNT/journal/*" ! -name lastlog ! -name '*.journal' ! -name '*.journal~' \
        -printf '%b %p\n' 2>/dev/null | sort -rn | awk '$1 > 2048 {sub(/^[0-9]+ /,""); print}'
    # $1 = 512-byte blocks; > 2048 blocks = > 1 MiB
}

step_journal() {
    command -v journalctl >/dev/null || return 0
    local target=$(( $(size_mb) * JOURNAL_PCT / 100 / 2 ))   # aggressive: half the cap
    (( target < 16 )) && target=16
    log "step 1: journal vacuum to ${target}M"
    run journalctl --vacuum-size="${target}M" -q
}

step_rotated() {
    log "step 2: removing rotated logs"
    find "$MOUNT" -xdev -type f \( \
        -name '*.gz' -o -name '*.xz' -o -name '*.bz2' -o -name '*.zst' \
        -o -name '*.[0-9]' -o -name '*.[0-9].log' -o -name '*.old' \
        -o -regextype posix-extended -regex '.*-[0-9]{8}(\.gz)?' \) \
        ! -path "$MOUNT/journal/*" -print0 2>/dev/null |
    while IFS= read -r -d '' f; do run rm -f -- "$f"; done
}

step_deleted_open() {
    log "step 3: releasing deleted-but-open files"
    local fd tgt
    for fd in /proc/[0-9]*/fd/*; do
        tgt=$(readlink "$fd" 2>/dev/null) || continue
        [[ $tgt == "$MOUNT/"*' (deleted)' ]] || continue
        log "  truncating ${tgt% (deleted)} via $fd"
        (( DRY )) || : > "$fd" 2>/dev/null || true
    done
}

shrink_file() {   # keep last $2 bytes, preserve inode so writers keep working
    local f=$1 keep=$2 tmp
    if [[ $keep == 0 ]]; then
        run truncate -s 0 -- "$f"; return
    fi
    (( DRY )) && { echo "  [dry-run] keep last $keep of $f"; return; }
    tmp=$(mktemp "$TMPDIR_GUARD/log2ram-guard.XXXXXX") || return
    tail -c "$keep" -- "$f" > "$tmp" 2>/dev/null && cat "$tmp" > "$f"
    rm -f "$tmp"
}

step_shrink() {   # $1 = bytes to keep
    log "step $2: shrinking largest logs (keep ${1})"
    local f
    while IFS= read -r f; do
        ok && return 0
        log "  $(du -h -- "$f" | cut -f1)  $f"
        shrink_file "$f" "$1"
    done < <(largest_files)
}

cleanup() {
    need_root
    mountpoint -q "$MOUNT" || { log "$MOUNT is not a mountpoint, nothing to do"; exit 0; }
    local before; before=$(usage_pct)
    if (( before <= THRESHOLD )); then
        (( DRY )) && echo "usage ${before}% <= ${THRESHOLD}%, nothing to do"
        exit 0
    fi
    log "usage ${before}% > ${THRESHOLD}%, cleaning"

    step_journal;       ok || \
    step_rotated;       ok || \
    step_deleted_open;  ok || \
    step_shrink "$KEEP_TAIL" 4; ok || \
    { step_journal; step_shrink 0 5; }

    local after; after=$(usage_pct)
    log "done: ${before}% -> ${after}%"
    (( after > THRESHOLD )) && log "WARNING: still above ${THRESHOLD}% — increase SIZE in /etc/log2ram.conf or find the noisy service"

    if (( SYNC_AFTER && ! DRY )) && command -v log2ram >/dev/null; then
        log2ram write >/dev/null 2>&1 || true
    fi
}

write_journald() {   # journald cap derived from the log2ram tmpfs size
    need_root
    local size cap
    if mountpoint -q "$MOUNT"; then
        size=$(size_mb)
    else
        # log2ram not mounted (yet): fall back to SIZE from log2ram.conf, else 128M
        size=$(sed -n 's/^SIZE=\([0-9]*\)M.*/\1/p' "$L2R_CONF" 2>/dev/null | tail -1)
        size=${size:-128}
    fi
    cap=$(( size * JOURNAL_PCT / 100 ))
    (( cap < 32 )) && cap=32
    mkdir -p "$(dirname "$JDROP")"
    cat > "$JDROP" <<EOF
# managed by log2ram-guard: keep journal well below the log2ram tmpfs size (${size}M)
[Journal]
SystemMaxUse=${cap}M
SystemKeepFree=$(( size * (100 - THRESHOLD) / 100 ))M
SystemMaxFileSize=$(( cap / 4 > 8 ? cap / 4 : 8 ))M
RuntimeMaxUse=${cap}M
EOF
    systemctl restart systemd-journald 2>/dev/null || true
    log "journald capped at ${cap}M (log2ram ${size}M)"
}

install_guard() {
    need_root
    install -m 0755 "$(readlink -f "$0")" "$BIN"
    write_journald
    local cap=$(( $(size_mb) * JOURNAL_PCT / 100 ))

    cat > "$UNIT.service" <<EOF
[Unit]
Description=Keep log2ram /var/log below ${THRESHOLD}%
After=log2ram.service
ConditionPathIsMountPoint=${MOUNT}

[Service]
Type=oneshot
Environment=THRESHOLD=${THRESHOLD} KEEP_TAIL=${KEEP_TAIL} JOURNAL_PCT=${JOURNAL_PCT}
ExecStart=${BIN}
Nice=10
IOSchedulingClass=idle
EOF
    cat > "$UNIT.timer" <<EOF
[Unit]
Description=Run log2ram-guard every ${INTERVAL}

[Timer]
OnBootSec=2min
OnUnitActiveSec=${INTERVAL}
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now log2ram-guard.timer
    log "installed: threshold ${THRESHOLD}%, journal cap ${cap}M, every ${INTERVAL}"
    "$BIN"   # immediate first pass
    echo; df -h "$MOUNT"; systemctl list-timers log2ram-guard.timer --no-pager
}

uninstall_guard() {
    need_root
    systemctl disable --now log2ram-guard.timer 2>/dev/null || true
    rm -f "$UNIT.service" "$UNIT.timer" "$JDROP" "$BIN"
    systemctl daemon-reload
    systemctl restart systemd-journald
    log "uninstalled"
}

case "${1:-}" in
    --install)   install_guard ;;
    --uninstall) uninstall_guard ;;
    --journald)  write_journald ;;
    --dry-run)   DRY=1; SYNC_AFTER=0; cleanup ;;
    ""|--run)    cleanup ;;
    -h|--help)   sed -n '2,/^$/p' "$0" ;;
    *)           echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
esac
