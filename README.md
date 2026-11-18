# log2ram-guard

Keeps the [log2ram](https://github.com/azlux/log2ram) tmpfs (`/var/log`) below a maximum usage (default **65%**), so it never hits 100% and services stop logging.

## Install

### Debian package (recommended)

Download the `.deb` from [Releases](https://github.com/jwklijnsma/log2ram/releases) or the latest CI artifact, then:

```bash
sudo apt install ./log2ram-guard_*_all.deb
```

This installs `/usr/sbin/log2ram-guard`, enables `log2ram-guard.timer` and writes the journald cap.
Settings live in `/etc/default/log2ram-guard` (kept on upgrade). After changing `THRESHOLD` or
`JOURNAL_PCT`, run `sudo log2ram-guard --journald`.

Remove: `sudo apt purge log2ram-guard`

### Build the package yourself

```bash
./build-deb.sh                  # version from VERSION file
VERSION=1.0.0 ./build-deb.sh    # explicit version -> dist/log2ram-guard_1.0.0_all.deb
```

Releasing: bump `VERSION` and push to `main`. GitHub Actions builds the package and, if release `v<VERSION>` doesn't exist yet, creates the tag and release with the `.deb` attached. Pushing a `v*` tag works too.

### Without packaging

```bash
git clone https://github.com/jwklijnsma/log2ram
cd log2ram
sudo ./log2ram-guard.sh --dry-run   # show what it would do
sudo ./log2ram-guard.sh --install
```

`--install` does:

- copies the script to `/usr/local/sbin/log2ram-guard`
- adds `log2ram-guard.timer` (every 5 min, first run 2 min after boot)
- adds `/etc/systemd/journald.conf.d/50-log2ram-guard.conf` capping the journal at 25% of the log2ram size

Remove with `sudo ./log2ram-guard.sh --uninstall`.

## What a pass does

Only acts when usage is above the threshold, and stops as soon as it is back under:

1. `journalctl --vacuum-size`
2. delete rotated logs (`*.gz`, `*.1`, `*.old`, `*-YYYYMMDD`, …)
3. release space held by deleted-but-still-open log files
4. shrink the largest logs to their last 2 MB (inode kept, writers keep working)
5. last resort: empty the largest logs

Afterwards it runs `log2ram write` so the disk copy is clean too.

## Settings

Environment variables (pass at `--install` time, they end up in the service unit):

| Variable      | Default    | Meaning                                  |
|---------------|------------|------------------------------------------|
| `THRESHOLD`   | `65`       | max % usage of `/var/log`                |
| `KEEP_TAIL`   | `2M`       | bytes kept per file in step 4            |
| `JOURNAL_PCT` | `25`       | journald cap as % of log2ram size        |
| `INTERVAL`    | `5min`     | timer interval                           |
| `MOUNT`       | `/var/log` | mountpoint to guard                      |

```bash
sudo THRESHOLD=60 KEEP_TAIL=1M INTERVAL=2min ./log2ram-guard.sh --install
```

## Logs

```bash
journalctl -t log2ram-guard
```

If the same file gets shrunk every run, that service is logging too much. Fix it at the source.
