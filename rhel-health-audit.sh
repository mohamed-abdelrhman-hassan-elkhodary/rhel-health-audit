#!/usr/bin/env bash
#
# ============================================================================
#  rhel-health-audit.sh  -  Read-only health and security audit for RHEL
# ============================================================================
#  Works on RHEL, Rocky Linux, AlmaLinux, CentOS Stream and Fedora.
#
#  WHAT IT DOES
#    Checks 11 areas of a Linux server (system, CPU/memory, disk, users,
#    services, network, firewall, SELinux, updates, SSH, logs), prints a
#    colour-coded result to the screen, saves a plain-text report, and ends
#    with a per-section summary table.
#
#  DESIGN RULES
#    1. READ-ONLY. It never installs, removes, restarts, edits or deletes
#       anything. The only file it writes is its own report.
#    2. SAFE WITHOUT ROOT. Checks that need root are skipped and labelled
#       [SKIP] instead of failing.
#    3. EVERY FINDING IS A COMMAND YOU CAN RUN YOURSELF. Each check wraps a
#       standard tool (df, ss, getenforce, firewall-cmd, dnf, sshd -T, ...).
#    4. AUTOMATION FRIENDLY. Exit code 0 = no warnings, 1 = warnings found,
#       2 = usage error, so it can run from cron or a CI job.
#
#  USAGE
#    ./rhel-health-audit.sh [options]
#
#  OPTIONS
#    -o DIR   Output directory for the report      (default: ./audit-reports)
#    -s LIST  Comma-separated sections to run      (default: all)
#             system,cpu_mem,disk,users,services,network,firewall,
#             selinux,updates,ssh,logs
#    -t PCT   Disk/inode warning threshold percent (default: 80)
#    -n       Dry run: show what would be checked, run nothing
#    -q       Quiet: write the report file only
#    -C       No colour (colour is automatic only on a terminal)
#    -V       Print version
#    -h       Help
#
#  EXAMPLES
#    ./rhel-health-audit.sh -n                  # dry run
#    sudo ./rhel-health-audit.sh                # full audit incl. root checks
#    ./rhel-health-audit.sh -s disk,selinux -t 90
#
#  TESTING STATUS
#    Syntax checked (bash -n) and run on Ubuntu 22.04, where the RHEL-only
#    checks correctly report "not installed". Not yet tested on a real
#    RHEL-family system. Training project, see README.md.
# ============================================================================

set -u
set -o pipefail

VERSION="1.1"
OUT_DIR="./audit-reports"
DISK_WARN=80
SECTIONS="system,cpu_mem,disk,users,services,network,firewall,selinux,updates,ssh,logs"
DRY_RUN=0
QUIET=0
COLOR=auto
CUR_SECTION="start"
declare -A C_OK C_INFO C_WARN C_SKIP
SECTION_ORDER=()
WARNINGS=0
HOST="$(hostname -s 2>/dev/null || echo unknown-host)"
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT=""

usage() {
    # Print the "USAGE" and "OPTIONS" part of the header comment.
    sed -n '/^#  USAGE/,/^#  TESTING STATUS/p' "$0" | sed '$d' | sed 's/^# \{0,2\}//' | sed '/^$/d;/^#$/d'
}

# ---------------------------------------------------------------- helpers
have() { command -v "$1" >/dev/null 2>&1; }
is_root() { [ "$(id -u)" -eq 0 ]; }

# Colour is used on the screen only; the report file stays plain text.
use_color() { [ "$COLOR" = "yes" ] || { [ "$COLOR" = "auto" ] && [ -t 1 ]; }; }

# Write one line: plain text to the report, optionally coloured to the screen.
# $1 = colour code (may be empty), rest = text
emit_c() {
    local code="$1"; shift
    printf '%s\n' "$*" >>"$REPORT"
    [ "$QUIET" -eq 1 ] && return 0
    if [ -n "$code" ] && use_color; then
        printf '\033[%sm%s\033[0m\n' "$code" "$*"
    else
        printf '%s\n' "$*"
    fi
}
emit() { emit_c "" "$*"; }

header() {
    CUR_SECTION="${1%% *}"      # short key for the summary table (first word)
    SECTION_ORDER+=("$CUR_SECTION")
    C_OK["$CUR_SECTION"]=0; C_INFO["$CUR_SECTION"]=0; C_WARN["$CUR_SECTION"]=0; C_SKIP["$CUR_SECTION"]=0
    emit ""
    emit_c "1;36" "=== $* ==="
}
ok()   { C_OK["$CUR_SECTION"]=$(( ${C_OK["$CUR_SECTION"]:-0} + 1 ));     emit_c "32" "[ OK ]  $*"; }
info() { C_INFO["$CUR_SECTION"]=$(( ${C_INFO["$CUR_SECTION"]:-0} + 1 )); emit_c ""   "[INFO]  $*"; }
skip() { C_SKIP["$CUR_SECTION"]=$(( ${C_SKIP["$CUR_SECTION"]:-0} + 1 )); emit_c "90" "[SKIP]  $*"; }
warn() {
    C_WARN["$CUR_SECTION"]=$(( ${C_WARN["$CUR_SECTION"]:-0} + 1 ))
    WARNINGS=$((WARNINGS + 1))
    emit_c "1;33" "[WARN]  $*"
}

# Run a command, capture output into the report, never abort the script.
run() {
    local out
    out="$("$@" 2>&1)" || true
    [ -n "$out" ] && emit "$out"
}

want() { case ",$SECTIONS," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

# --------------------------------------------------------------- sections
sec_system() {
    header "System"
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        info "OS: ${PRETTY_NAME:-unknown}"
    else
        warn "/etc/os-release not readable"
    fi
    info "Kernel: $(uname -r)"
    info "Architecture: $(uname -m)"
    info "Uptime: $(uptime -p 2>/dev/null || uptime)"
    info "Date: $(date)"
    if have timedatectl; then
        local sync
        sync="$(timedatectl show -p NTPSynchronized --value 2>/dev/null)"
        if [ "$sync" = "yes" ]; then ok "Clock is NTP synchronized"
        else warn "Clock is not NTP synchronized (chronyd running?)"; fi
    fi
    if [ -f /var/run/reboot-required ] || \
       { have needs-restarting && ! needs-restarting -r >/dev/null 2>&1; }; then
        warn "A reboot is recommended (kernel or core libraries updated)"
    fi
}

sec_cpu_mem() {
    header "CPU and memory"
    local cores load1
    cores="$(nproc 2>/dev/null || echo 1)"
    load1="$(cut -d' ' -f1 /proc/loadavg)"
    info "CPU cores: $cores, load average (1/5/15): $(cut -d' ' -f1-3 /proc/loadavg)"
    # awk handles the float comparison: warn if 1-min load > cores
    if awk -v l="$load1" -v c="$cores" 'BEGIN{exit !(l > c)}'; then
        warn "1-minute load ($load1) is higher than core count ($cores)"
    else
        ok "Load average is within core count"
    fi
    run free -h
    local mem_pct
    mem_pct="$(free | awk '/^Mem:/ {printf "%d", ($3/$2)*100}')"
    if [ -n "$mem_pct" ] && [ "$mem_pct" -ge 90 ]; then
        warn "Memory use is ${mem_pct}%"
    else
        ok "Memory use is ${mem_pct:-?}%"
    fi
    local swap_total
    swap_total="$(free | awk '/^Swap:/ {print $2}')"
    if [ "${swap_total:-0}" -eq 0 ]; then info "No swap configured"; fi
    emit "Top 5 processes by memory:"
    run bash -c "ps -eo pid,user,%mem,%cpu,comm --sort=-%mem | head -6"
}

sec_disk() {
    header "Disk and filesystems"
    run df -hT -x tmpfs -x devtmpfs -x squashfs
    # Warn on any filesystem at or above the threshold.
    while read -r pct mount; do
        pct="${pct%\%}"
        if [ "$pct" -ge "$DISK_WARN" ]; then
            warn "Filesystem $mount is ${pct}% full (threshold ${DISK_WARN}%)"
        fi
    done < <(df -P -x tmpfs -x devtmpfs -x squashfs | awk 'NR>1 {print $5, $6}')
    # Inodes can run out before space does.
    while read -r pct mount; do
        pct="${pct%\%}"
        case "$pct" in ''|-) continue ;; esac
        if [ "$pct" -ge "$DISK_WARN" ]; then
            warn "Inode use on $mount is ${pct}%"
        fi
    done < <(df -Pi -x tmpfs -x devtmpfs -x squashfs | awk 'NR>1 {print $5, $6}')
    if [ "$(printf '%s' "${C_WARN[$CUR_SECTION]:-0}")" -eq 0 ]; then
        ok "All filesystems and inode counts are below ${DISK_WARN}%"
    fi
    emit "Block devices:"
    run lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
    if have vgs; then
        emit "LVM volume groups:"
        if is_root; then run vgs; else skip "vgs needs root"; fi
    fi
}

sec_users() {
    header "Users and groups"
    info "Local accounts with a login shell:"
    run awk -F: '$7 !~ /(nologin|false|sync|shutdown|halt)$/ {print "  " $1 " (uid " $3 ", shell " $7 ")"}' /etc/passwd
    # Any non-root account with UID 0 is a serious finding.
    local extra_root
    extra_root="$(awk -F: '$3 == 0 && $1 != "root" {print $1}' /etc/passwd)"
    if [ -n "$extra_root" ]; then
        warn "Extra UID 0 accounts: $extra_root"
    else
        ok "Only root has UID 0"
    fi
    info "Members of wheel (sudo-capable): $(getent group wheel | cut -d: -f4)"
    if is_root; then
        local empty
        empty="$(awk -F: '($2 == "" ) {print $1}' /etc/shadow)"
        if [ -n "$empty" ]; then warn "Accounts with an empty password: $empty"
        else ok "No accounts with an empty password"; fi
    else
        skip "Empty-password check needs root (reads /etc/shadow)"
    fi
    emit "Last 5 logins:"
    run bash -c "last -n 5 2>/dev/null | head -6"
    if have lastb && is_root; then
        local failed
        failed="$(lastb 2>/dev/null | grep -vc -e '^$' -e 'btmp begins' || true)"
        info "Failed login records in btmp: ${failed:-0}"
    fi
}

sec_services() {
    header "Services (systemd)"
    if ! have systemctl; then skip "systemctl not found"; return; fi
    local failed
    failed="$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}')"
    if [ -n "$failed" ]; then
        warn "Failed units: $(echo "$failed" | tr '\n' ' ')"
    else
        ok "No failed systemd units"
    fi
    local svc
    for svc in sshd chronyd firewalld auditd crond rsyslog; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            ok "$svc is active"
        elif systemctl list-unit-files "${svc}.service" --no-legend 2>/dev/null | grep -q "$svc"; then
            warn "$svc is installed but not active"
        else
            info "$svc is not installed"
        fi
    done
    emit "Enabled services:"
    run bash -c "systemctl list-unit-files --state=enabled --type=service --no-legend | awk '{print \"  \" \$1}'"
}

sec_network() {
    header "Network"
    run ip -brief address
    run ip route
    if [ -r /etc/resolv.conf ]; then
        info "DNS servers: $(awk '/^nameserver/ {printf "%s ", $2}' /etc/resolv.conf)"
    fi
    emit "Listening TCP/UDP sockets:"
    if have ss; then
        if is_root; then run ss -tulnp; else run ss -tuln; fi
    fi
    local gw
    gw="$(ip route 2>/dev/null | awk '/^default/ {print $3; exit}')"
    if [ -n "$gw" ]; then
        if ping -c 1 -W 2 "$gw" >/dev/null 2>&1; then ok "Default gateway $gw answers ping"
        else warn "Default gateway $gw does not answer ping (may be filtered)"; fi
    else
        warn "No default route"
    fi
}

sec_firewall() {
    header "Firewall (firewalld)"
    if ! have firewall-cmd; then skip "firewall-cmd not installed"; return; fi
    if ! systemctl is-active --quiet firewalld 2>/dev/null; then
        warn "firewalld is not running"
        return
    fi
    ok "firewalld is running"
    if ! is_root; then skip "Rule listing needs root"; return; fi
    run firewall-cmd --get-default-zone
    run firewall-cmd --list-all
}

sec_selinux() {
    header "SELinux"
    if ! have getenforce; then skip "getenforce not found"; return; fi
    local mode
    mode="$(getenforce)"
    case "$mode" in
        Enforcing)  ok "SELinux is Enforcing" ;;
        Permissive) warn "SELinux is Permissive (logs but does not block)" ;;
        Disabled)   warn "SELinux is Disabled" ;;
        *)          info "SELinux mode: $mode" ;;
    esac
    if [ -r /etc/selinux/config ]; then
        info "Configured at boot: $(awk -F= '/^SELINUX=/ {print $2}' /etc/selinux/config)"
    fi
    if have ausearch && is_root; then
        local denials
        denials="$(ausearch -m avc -ts today 2>/dev/null | grep -c 'type=AVC' || true)"
        info "AVC denials today: ${denials:-0}"
    fi
}

sec_updates() {
    header "Package updates"
    local pm=""
    if have dnf; then pm="dnf"; elif have yum; then pm="yum"; fi
    if [ -z "$pm" ]; then skip "No dnf/yum found"; return; fi
    # check-update exits 100 when updates exist, 0 when none, 1 on error.
    local out rc
    out="$($pm -q check-update --refresh 2>&1)"; rc=$?
    case "$rc" in
        0)   ok "System is up to date" ;;
        100) warn "Updates are available"
             emit "$(echo "$out" | awk 'NF==3 {print "  " $1 " -> " $2}' | head -20)"
             if [ "$pm" = "dnf" ]; then
                 local sec
                 sec="$(dnf -q updateinfo list security 2>/dev/null | grep -c . || true)"
                 info "Security advisories pending: ${sec:-0}" 
             fi ;;
        *)   skip "Could not check updates (no repo access or not subscribed)" ;;
    esac
    if have rpm; then info "Installed packages: $(rpm -qa | wc -l)"; fi
}

sec_ssh() {
    header "SSH server configuration"
    if ! have sshd; then skip "sshd not installed"; return; fi
    if ! is_root; then skip "sshd -T needs root"; return; fi
    local cfg
    cfg="$(sshd -T 2>/dev/null)" || { skip "Could not read sshd config"; return; }
    check_ssh() {   # name, bad value, message
        local val
        val="$(echo "$cfg" | awk -v k="$1" '$1 == k {print $2}')"
        if [ "$val" = "$2" ]; then warn "$3 ($1 $val)"; else ok "$1 is ${val:-default}"; fi
    }
    check_ssh permitrootlogin yes "Root login over SSH is allowed"
    check_ssh passwordauthentication yes "Password authentication is on (keys are safer)"
    check_ssh permitemptypasswords yes "Empty passwords are allowed"
    info "SSH port: $(echo "$cfg" | awk '$1 == "port" {print $2}')"
}

sec_logs() {
    header "Logs"
    if have journalctl; then
        local errs
        if is_root || id -nG | grep -qE '\b(wheel|systemd-journal|adm)\b'; then
            errs="$(journalctl -p err -S -24h --no-pager -q 2>/dev/null | wc -l)"
            if [ "${errs:-0}" -gt 0 ]; then
                warn "$errs error-level journal entries in the last 24h"
                emit "Last 10:"
                run bash -c "journalctl -p err -S -24h --no-pager -q | tail -10"
            else
                ok "No error-level journal entries in the last 24h"
            fi
        else
            skip "Journal access needs root or the wheel/adm group"
        fi
    fi
    if [ -r /var/log/secure ]; then
        local bad
        bad="$(grep -c 'Failed password' /var/log/secure 2>/dev/null || true)"
        info "Failed SSH password attempts in /var/log/secure: ${bad:-0}"
    fi
}

# ------------------------------------------------------------------- main
while getopts ":o:s:t:nqCVh" opt; do
    case "$opt" in
        o) OUT_DIR="$OPTARG" ;;
        s) SECTIONS="$OPTARG" ;;
        t) DISK_WARN="$OPTARG" ;;
        n) DRY_RUN=1 ;;
        q) QUIET=1 ;;
        C) COLOR=no ;;
        V) echo "rhel-health-audit.sh $VERSION"; exit 0 ;;
        h) usage; exit 0 ;;
        :) echo "Option -$OPTARG needs a value" >&2; usage; exit 2 ;;
        *) echo "Unknown option -$OPTARG" >&2; usage; exit 2 ;;
    esac
done

case "$DISK_WARN" in ''|*[!0-9]*) echo "-t must be a number" >&2; exit 2 ;; esac

ALL="system cpu_mem disk users services network firewall selinux updates ssh logs"

if [ "$DRY_RUN" -eq 1 ]; then
    echo "Dry run: nothing will be executed or written."
    echo "Report would be written to: $OUT_DIR/audit-$HOST-$STAMP.txt"
    echo "Disk warning threshold: ${DISK_WARN}%"
    echo "Sections that would run:"
    for s in $ALL; do want "$s" && echo "  - $s"; done
    echo "Running as root: $(is_root && echo yes || echo no) (some checks are skipped without root)"
    exit 0
fi

mkdir -p "$OUT_DIR" || { echo "Cannot create $OUT_DIR" >&2; exit 2; }
REPORT="$OUT_DIR/audit-$HOST-$STAMP.txt"
: >"$REPORT"

emit_c "1;36" "RHEL health audit v$VERSION"
emit "Host: $HOST    Date: $(date)"
emit "Run by: $(id -un) (uid $(id -u))    Root checks: $(is_root && echo enabled || echo skipped)"

for s in $ALL; do
    if want "$s"; then "sec_$s"; fi
done

# ---- per-section summary table -------------------------------------------
emit ""
emit_c "1;36" "=== Summary ==="
emit "$(printf '%-12s %5s %5s %5s %5s' Section OK INFO WARN SKIP)"
emit "$(printf '%-12s %5s %5s %5s %5s' ------- --- ---- ---- ----)"
for sec in "${SECTION_ORDER[@]}"; do
    line="$(printf '%-12s %5s %5s %5s %5s' "$sec" "${C_OK[$sec]:-0}" "${C_INFO[$sec]:-0}" "${C_WARN[$sec]:-0}" "${C_SKIP[$sec]:-0}")"
    if [ "${C_WARN[$sec]:-0}" -gt 0 ]; then emit_c "1;33" "$line"; else emit "$line"; fi
done
emit ""
if [ "$WARNINGS" -eq 0 ]; then
    emit_c "1;32" "Result: no warnings."
else
    emit_c "1;33" "Result: $WARNINGS warning(s). Review the [WARN] lines above."
fi
emit "Report saved to: $REPORT"

[ "$WARNINGS" -eq 0 ] && exit 0 || exit 1
