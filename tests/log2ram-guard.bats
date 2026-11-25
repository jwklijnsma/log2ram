#!/usr/bin/env bats
# Tests for log2ram-guard.sh against a temp dir posing as the log2ram tmpfs.
# df/mountpoint/journalctl/systemctl/log2ram are stubbed (tests/stubs); every
# path the script writes to is redirected into $T. Needs root (the script
# refuses otherwise): run with `sudo -E bats tests` in CI.

setup() {
    T=$(mktemp -d)
    export MOUNT=$T/log CALLS=$T/calls FAKE_SIZE_MB=10 THRESHOLD=65
    export LOG2RAM_GUARD_CONF=$T/default LOG2RAM_GUARD_BIN=$T/bin/log2ram-guard
    export LOG2RAM_GUARD_UNIT=$T/systemd/log2ram-guard LOG2RAM_GUARD_JDROP=$T/journald.conf.d/50.conf
    export LOG2RAM_CONF=$T/log2ram.conf LOG2RAM_GUARD_TMPDIR=$T
    export PATH="$BATS_TEST_DIRNAME/stubs:$PATH"
    mkdir -p "$MOUNT/journal" "$T/systemd" "$T/bin"
    : > "$CALLS"
    SCRIPT="$BATS_TEST_DIRNAME/../log2ram-guard.sh"
}

teardown() {
    [[ -n ${HOLDER:-} ]] && kill "$HOLDER" 2>/dev/null
    rm -rf "$T"
}

# mkfile PATH MIB — real (non-sparse) data, so it counts as used space
mkfile() { mkdir -p "$(dirname "$1")"; head -c "$(( $2 * 1048576 ))" /dev/urandom > "$1"; }
usage() { df --output=pcent "$MOUNT" | tail -1 | tr -dc '0-9'; }

@test "--help prints the usage" {
    run "$SCRIPT" --help
    [ "$status" -eq 0 ]
    [[ $output == *"--dry-run"* && $output == *"--install"* ]]
}

@test "unknown options exit 2" {
    run "$SCRIPT" --bogus
    [ "$status" -eq 2 ]
    [[ $output == *"unknown option"* ]]
}

@test "below the threshold nothing happens" {
    mkfile "$MOUNT/syslog" 2          # 20%
    mkfile "$MOUNT/syslog.1" 1
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -f "$MOUNT/syslog.1" ]
    ! grep -q journalctl "$CALLS"
}

@test "not a mountpoint: nothing to do" {
    mkfile "$MOUNT/syslog.1" 9
    FAKE_MOUNTED=0 run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ $output == *"not a mountpoint"* ]]
    [ -f "$MOUNT/syslog.1" ]
}

@test "step 1 vacuums the journal first, to half the journald cap (at least 16M)" {
    mkfile "$MOUNT/syslog.gz" 8
    run "$SCRIPT"
    grep -qx "journalctl --vacuum-size=16M -q" "$CALLS"      # 10M * 25% / 2 -> floor 16M
    [ "$(head -1 "$CALLS" | cut -d' ' -f1)" == journalctl ] || [ "$(grep -v '^logger' "$CALLS" | head -1 | cut -d' ' -f1)" == journalctl ]
}

@test "step 1 target scales with the tmpfs and JOURNAL_PCT" {
    mkfile "$MOUNT/syslog.gz" 9
    FAKE_SIZE_MB=12 JOURNAL_PCT=50 run "$SCRIPT" || true      # 12*50/100/2 = 3 -> 16
    grep -qx "journalctl --vacuum-size=16M -q" "$CALLS"
    : > "$CALLS"
    mkfile "$MOUNT/more.gz" 1
    # a "1000M" tmpfs that is 95% full is easier to fake by shrinking the threshold
    FAKE_SIZE_MB=1000 THRESHOLD=0 run "$SCRIPT"
    grep -qx "journalctl --vacuum-size=125M -q" "$CALLS"     # 1000 * 25% / 2
}

@test "dated rotated logs (logrotate dateext) are removed" {
    mkfile "$MOUNT/syslog-20261101" 4
    mkfile "$MOUNT/auth.log-20261101.gz" 4
    mkfile "$MOUNT/not-a-date-2026" 1
    run "$SCRIPT"
    [ ! -e "$MOUNT/syslog-20261101" ]
    [ ! -e "$MOUNT/auth.log-20261101.gz" ]
    [ -e "$MOUNT/not-a-date-2026" ]
}

@test "step 2 removes rotated logs and stops when under the threshold" {
    mkfile "$MOUNT/syslog" 2
    for f in syslog.1 kern.log.2.gz messages.old app-20261101 auth.log.1.log dpkg.xz; do
        mkfile "$MOUNT/$f" 1
    done
    mkfile "$MOUNT/journal/abc/system.journal" 1
    [ "$(usage)" -gt 65 ]
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -f "$MOUNT/syslog" ]                                    # live log kept whole
    [ "$(stat -c %s "$MOUNT/syslog")" -eq 2097152 ]
    for f in syslog.1 kern.log.2.gz messages.old app-20261101 auth.log.1.log dpkg.xz; do
        [ ! -e "$MOUNT/$f" ]
    done
    [ -f "$MOUNT/journal/abc/system.journal" ]                # journal files are journald's job
    [[ $output == *"step 2"* && $output != *"step 4"* ]]
    [ "$(usage)" -le 65 ]
}

@test "step 4 shrinks the largest live log to KEEP_TAIL, same inode, keeps the tail" {
    mkfile "$MOUNT/daemon.log" 8
    printf 'THE-LAST-LINE\n' >> "$MOUNT/daemon.log"
    inode=$(stat -c %i "$MOUNT/daemon.log")
    tail_before=$(tail -c 1000 "$MOUNT/daemon.log" | md5sum)
    KEEP_TAIL=1M run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(stat -c %i "$MOUNT/daemon.log")" -eq "$inode" ]      # writers keep their fd
    [ "$(stat -c %s "$MOUNT/daemon.log")" -eq 1048576 ]
    [ "$(tail -c 1000 "$MOUNT/daemon.log" | md5sum)" == "$tail_before" ]
    [[ $output == *"step 4"* ]]
}

@test "step 5 empties the largest logs when keeping the tail is not enough" {
    mkfile "$MOUNT/a.log" 4
    mkfile "$MOUNT/b.log" 4
    KEEP_TAIL=4M run "$SCRIPT"                                 # step 4 cannot help
    [ "$status" -eq 0 ]
    [[ $output == *"step 5"* ]]
    [ "$(usage)" -le 65 ]
    [ "$(stat -c %s "$MOUNT/a.log")" -eq 0 ] || [ "$(stat -c %s "$MOUNT/b.log")" -eq 0 ]
}

@test "small files are never shrunk" {
    for i in 1 2 3 4 5 6 7 8; do head -c 900000 /dev/urandom > "$MOUNT/small$i.log"; done
    THRESHOLD=10 run "$SCRIPT"
    for i in 1 2 3 4 5 6 7 8; do [ "$(stat -c %s "$MOUNT/small$i.log")" -eq 900000 ]; done
    [[ $output == *"WARNING: still above"* ]]
}

@test "step 3 releases space held by a deleted file that is still open" {
    mkfile "$MOUNT/held.log" 8
    # fd 7, and close bats' own fd 3 in the holder so bats does not wait for it
    sleep 300 7<>"$MOUNT/held.log" 3>&- &
    HOLDER=$!
    sleep 0.2
    rm "$MOUNT/held.log"
    [ "$(ls -A "$MOUNT" | grep -v journal | wc -l)" -eq 0 ]
    run "$SCRIPT"
    [[ $output == *"truncating $MOUNT/held.log"* ]]
    [ "$(stat -L -c %s /proc/$HOLDER/fd/7)" -eq 0 ]
}

@test "--dry-run reports and changes nothing" {
    mkfile "$MOUNT/syslog.1" 4
    mkfile "$MOUNT/daemon.log" 4
    before=$(find "$MOUNT" -type f -printf '%p %s\n' | sort)
    run "$SCRIPT" --dry-run
    [ "$status" -eq 0 ]
    [[ $output == *"[dry-run] rm -f -- $MOUNT/syslog.1"* ]]
    [[ $output == *"[dry-run] keep last"* ]]
    [ "$(find "$MOUNT" -type f -printf '%p %s\n' | sort)" == "$before" ]
    ! grep -q "journalctl --vacuum" "$CALLS"
    ! grep -q "log2ram write" "$CALLS"
}

@test "--dry-run below the threshold says so" {
    run "$SCRIPT" --dry-run
    [[ $output == *"nothing to do"* ]]
}

@test "after a cleanup it syncs with 'log2ram write' unless SYNC_AFTER=0" {
    mkfile "$MOUNT/x.gz" 8
    run "$SCRIPT"
    grep -qx "log2ram write" "$CALLS"
    : > "$CALLS"; mkfile "$MOUNT/y.gz" 8
    SYNC_AFTER=0 run "$SCRIPT"
    ! grep -q "log2ram write" "$CALLS"
}

@test "settings come from the config file" {
    mkfile "$MOUNT/syslog.1" 5                                 # 50%
    echo "THRESHOLD=40" > "$LOG2RAM_GUARD_CONF"
    run env -u THRESHOLD "$SCRIPT"
    [ ! -e "$MOUNT/syslog.1" ]
}

@test "--journald caps journald from the tmpfs size" {
    FAKE_SIZE_MB=400 run "$SCRIPT" --journald
    [ "$status" -eq 0 ]
    grep -qx "SystemMaxUse=100M" "$LOG2RAM_GUARD_JDROP"         # 25% of 400M
    grep -qx "SystemKeepFree=140M" "$LOG2RAM_GUARD_JDROP"       # (100-65)% of 400M
    grep -qx "SystemMaxFileSize=25M" "$LOG2RAM_GUARD_JDROP"
    grep -qx "RuntimeMaxUse=100M" "$LOG2RAM_GUARD_JDROP"
    grep -qx "systemctl restart systemd-journald" "$CALLS"
}

@test "--journald: at least 32M, and log2ram.conf SIZE when not mounted" {
    run "$SCRIPT" --journald                                   # 10M tmpfs -> floor
    grep -qx "SystemMaxUse=32M" "$LOG2RAM_GUARD_JDROP"
    grep -qx "SystemMaxFileSize=8M" "$LOG2RAM_GUARD_JDROP"
    printf 'SIZE=256M\nLOG_DISK_SIZE=1G\n' > "$LOG2RAM_CONF"
    FAKE_MOUNTED=0 run "$SCRIPT" --journald
    grep -qx "SystemMaxUse=64M" "$LOG2RAM_GUARD_JDROP"
    rm "$LOG2RAM_CONF"
    FAKE_MOUNTED=0 run "$SCRIPT" --journald                    # no conf -> 128M
    grep -qx "SystemMaxUse=32M" "$LOG2RAM_GUARD_JDROP"
}

@test "--install writes the units and runs a first pass; --uninstall removes everything" {
    INTERVAL=10min KEEP_TAIL=3M run "$SCRIPT" --install
    [ "$status" -eq 0 ]
    [ -x "$LOG2RAM_GUARD_BIN" ]
    grep -q "^ConditionPathIsMountPoint=$MOUNT$" "$LOG2RAM_GUARD_UNIT.service"
    grep -q "KEEP_TAIL=3M" "$LOG2RAM_GUARD_UNIT.service"
    grep -qx "OnUnitActiveSec=10min" "$LOG2RAM_GUARD_UNIT.timer"
    grep -q "systemctl enable --now log2ram-guard.timer" "$CALLS"
    [ -f "$LOG2RAM_GUARD_JDROP" ]
    run "$SCRIPT" --uninstall
    [ "$status" -eq 0 ]
    [ ! -e "$LOG2RAM_GUARD_BIN" ] && [ ! -e "$LOG2RAM_GUARD_UNIT.timer" ] && [ ! -e "$LOG2RAM_GUARD_JDROP" ]
    grep -q "systemctl disable --now log2ram-guard.timer" "$CALLS"
}
