#!/usr/bin/env bash
# Collects AKS Edge Essentials Linux node diagnostics into a tarball.
# Read-only: no service restart, repair, mount or configuration change.
# Run as root inside the Linux node (SSH, hcsdiag console/exec, or local console login).
set -u

usage() {
    cat <<'EOF'
Usage: collect-aksedge-linux-logs.sh [options]
  --output-dir DIR      Where the tarball is written (default /tmp)
  --name NAME           Archive base name (default aksedge-linux-logs-<host>-<utc>)
  --since-epoch SECS    Also export the journal since this UNIX time (UTC)
  --lines N             Max lines per journal section (default 20000)
  --timeout SECS        Per-command timeout (default 60)
  --max-journal-mb MB   Copy raw journal files when total <= MB (default 256, 0 = skip)
  --max-file-mb MB      Skip /var/log files larger than MB (default 20)
EOF
}

OUT_DIR=/tmp
NAME=
SINCE_EPOCH=
LINES=20000
CMD_TIMEOUT=60
MAX_JOURNAL_MB=256
MAX_FILE_MB=20
while [ $# -gt 0 ]; do
    case "$1" in
        --output-dir) OUT_DIR="$2"; shift 2 ;;
        --name) NAME="$2"; shift 2 ;;
        --since-epoch) SINCE_EPOCH="$2"; shift 2 ;;
        --lines) LINES="$2"; shift 2 ;;
        --timeout) CMD_TIMEOUT="$2"; shift 2 ;;
        --max-journal-mb) MAX_JOURNAL_MB="$2"; shift 2 ;;
        --max-file-mb) MAX_FILE_MB="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done
for value in "$LINES" "$CMD_TIMEOUT" "$MAX_JOURNAL_MB" "$MAX_FILE_MB" ${SINCE_EPOCH:+"$SINCE_EPOCH"}; do
    case "$value" in ''|*[!0-9]*) echo "Numeric option expected, got '$value'" >&2; exit 2 ;; esac
done
case "$NAME" in */*|.*) echo "--name must be a plain file name" >&2; exit 2 ;; esac
[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo) so all journals are readable." >&2; exit 2; }
[ -d "$OUT_DIR" ] || { echo "Output directory $OUT_DIR does not exist." >&2; exit 2; }

export LC_ALL=C
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
NAME=${NAME:-aksedge-linux-logs-$(hostname 2>/dev/null || echo unknown)-$STAMP}
WORK=$(mktemp -d "$OUT_DIR/.$NAME.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT
DIR="$WORK/$NAME"
mkdir -p "$DIR/files"
SECTIONS="$DIR/sections.tsv"
printf 'section\texit\trequired\n' > "$SECTIONS"
REQUIRED_FAILED=0
HAVE_TIMEOUT=0
command -v timeout >/dev/null 2>&1 && HAVE_TIMEOUT=1

# run <required:1|0> <label> <command...>
run() {
    local required="$1" label="$2"
    shift 2
    local out="$DIR/$label.txt" rc
    printf '# %s\n' "$*" > "$out"
    if [ "$HAVE_TIMEOUT" -eq 1 ]; then
        timeout -k 5 "$CMD_TIMEOUT" "$@" >> "$out" 2>&1
    else
        "$@" >> "$out" 2>&1
    fi
    rc=$?
    printf '%s\t%s\t%s\n' "$label" "$rc" "$required" >> "$SECTIONS"
    if [ "$required" -eq 1 ] && [ "$rc" -ne 0 ]; then REQUIRED_FAILED=$((REQUIRED_FAILED + 1)); fi
    return 0
}

has() { command -v "$1" >/dev/null 2>&1; }
J="journalctl --utc --no-pager -o short-precise"

run 1 identity sh -c 'date -u; uname -a; hostname; cat /etc/os-release; cat /proc/sys/kernel/random/boot_id; cat /proc/cmdline; uptime'
run 1 journal-storage sh -c 'for p in /var/log/journal /run/log/journal; do if [ -d "$p" ]; then ls -ld "$p"; du -sh "$p"; else echo "ABSENT $p"; fi; done; journalctl --disk-usage'
run 1 boot-index journalctl --list-boots --no-pager
run 1 journal-current $J -b 0 -n "$LINES"
run 0 journal-previous $J -b -1 -n "$LINES"
if [ -n "$SINCE_EPOCH" ]; then run 1 journal-since $J --since "@$SINCE_EPOCH" -n "$LINES"; fi
run 1 kernel-current $J -b 0 -k -n "$LINES"
run 0 kernel-previous $J -b -1 -k -n "$LINES"
run 1 dmesg dmesg --time-format iso
run 1 failed-units systemctl --failed --no-pager --full
run 1 units systemctl list-units --all --no-pager --full
run 0 boot-timing sh -c 'systemd-analyze; systemd-analyze blame | head -50; systemd-analyze critical-chain'
SERVICES="gcs containerd kubelet k3s k3s-agent kms-plugin etcd sshd systemd-networkd systemd-journald"
for unit in $SERVICES; do
    run 0 "status-$unit" systemctl status "$unit" --no-pager --full -n 0
    run 0 "journal-$unit" $J -u "$unit" -n "$LINES"
done
run 0 coredumps sh -c 'coredumpctl list --no-pager 2>&1; ls -la /var/crash /var/lib/systemd/coredump 2>&1'
run 1 storage sh -c 'df -h; df -i; lsblk -f; findmnt; cat /proc/mounts'
run 0 fs-errors sh -c 'for d in $(findmnt -rn -t ext4 -o SOURCE); do echo "== $d"; tune2fs -l "$d" | grep -Ei "state|error|mount count|last (checked|mount|write)"; done'
run 1 memory-cpu sh -c 'free -m; cat /proc/meminfo; cat /proc/loadavg; top -b -n 1 | head -40'
run 1 network sh -c 'ip addr; ip route; cat /etc/resolv.conf; ss -tulpn'
run 0 containers sh -c 'export CONTAINER_RUNTIME_ENDPOINT=unix:///run/containerd/containerd.sock IMAGE_SERVICE_ENDPOINT=unix:///run/containerd/containerd.sock; crictl ps -a; crictl pods'
for kubeconfig in /etc/rancher/k3s/k3s.yaml /etc/kubernetes/admin.conf; do
    if [ -f "$kubeconfig" ] && has kubectl; then
        run 0 kubernetes sh -c "kubectl --kubeconfig '$kubeconfig' --request-timeout=20s get nodes -o wide; kubectl --kubeconfig '$kubeconfig' --request-timeout=20s get pods -A -o wide; kubectl --kubeconfig '$kubeconfig' --request-timeout=20s get events -A --sort-by=.lastTimestamp"
        break
    fi
done
run 0 datastore-listing sh -c 'ls -la /var/lib/rancher/k3s/server/db /var/lib/etcd /var/lib/rancher/k3s/server/db/etcd 2>&1'
run 1 var-log-listing sh -c 'ls -laR /var/log | head -5000'

# Copy small plain-text logs; skip journal (handled below), container stdout and anything large.
find /var/log -xdev -type f -size -"${MAX_FILE_MB}"M \
    ! -path '/var/log/journal/*' ! -path '/var/log/pods/*' ! -path '/var/log/containers/*' -print0 2>/dev/null |
    while IFS= read -r -d '' file; do
        mkdir -p "$DIR/files$(dirname "$file")" && cp -p "$file" "$DIR/files$file" 2>/dev/null
    done
printf 'var-log-files\t0\t0\n' >> "$SECTIONS"

# Raw journal files allow offline analysis with journalctl --directory, including boots
# that are not reachable from the running system.
if [ "$MAX_JOURNAL_MB" -gt 0 ] && [ -d /var/log/journal ]; then
    journal_mb=$(du -sm /var/log/journal 2>/dev/null | cut -f1)
    if [ -n "$journal_mb" ] && [ "$journal_mb" -le "$MAX_JOURNAL_MB" ]; then
        journalctl --sync >/dev/null 2>&1
        cp -a /var/log/journal "$DIR/journal-files" 2>/dev/null
        printf 'journal-files\t%s\t0\n' "$?" >> "$SECTIONS"
    else
        echo "Skipped raw journal copy: ${journal_mb:-unknown} MB > $MAX_JOURNAL_MB MB" > "$DIR/journal-files-skipped.txt"
        printf 'journal-files\tskipped\t0\n' >> "$SECTIONS"
    fi
fi

cat > "$DIR/manifest.txt" <<EOF
collected_utc=$STAMP
host=$(hostname 2>/dev/null)
boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
since_epoch=${SINCE_EPOCH:-none}
lines=$LINES
command_timeout=$CMD_TIMEOUT
required_failed=$REQUIRED_FAILED
safety=read-only; no service restart, repair, mount or configuration change
EOF

ARCHIVE="$OUT_DIR/$NAME.tar.gz"
# Publish atomically so a host poller never reads a partial archive.
tar -czf "$ARCHIVE.partial" -C "$WORK" "$NAME" || { echo "AKSEDGE_LINUX_LOGS_FAILED tar" >&2; exit 1; }
mv -f "$ARCHIVE.partial" "$ARCHIVE"
echo "AKSEDGE_LINUX_LOGS archive=$ARCHIVE required_failed=$REQUIRED_FAILED"
[ "$REQUIRED_FAILED" -eq 0 ]
