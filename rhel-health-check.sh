#!/bin/bash
# Simple read-only health check for RHEL-family servers.
# It only reads information and never changes anything.
# Usage: ./rhel-health-check.sh   (use sudo to also read the SSH config)

DISK_LIMIT=80   # warn above this % disk use
MEM_LIMIT=90    # warn above this % memory use
warnings=0

title() { echo; echo "=== $1 ==="; }
ok()    { echo "[ OK ] $1"; }
warn()  { echo "[WARN] $1"; warnings=$((warnings + 1)); }

# 1. System
title "1. System"
echo "Host:   $(hostname)"
echo "Uptime: $(uptime -p)"
echo "Kernel: $(uname -r)"
if [ -r /etc/os-release ]; then
    . /etc/os-release
    echo "OS:     $PRETTY_NAME"
fi

# 2. Disk
title "2. Disk usage"
# skip the df header, then read use% and mount point
df -P -x tmpfs -x devtmpfs | tail -n +2 | while read -r fs size used avail pct mount; do
    num=${pct%\%}   # remove the % sign
    if [ "$num" -ge "$DISK_LIMIT" ]; then
        echo "[WARN] $mount is $pct full"
    else
        echo "[ OK ] $mount is $pct full"
    fi
done

# 3. Memory and load
title "3. Memory and CPU load"
mem_total=$(free -m | awk '/^Mem:/ {print $2}')
mem_used=$(free -m | awk '/^Mem:/ {print $3}')
mem_pct=$((mem_used * 100 / mem_total))
if [ "$mem_pct" -ge "$MEM_LIMIT" ]; then
    warn "Memory use is ${mem_pct}% (${mem_used} of ${mem_total} MB)"
else
    ok "Memory use is ${mem_pct}% (${mem_used} of ${mem_total} MB)"
fi

cores=$(nproc)
load=$(awk '{print $1}' /proc/loadavg)
echo "Load (1 min): $load, CPU cores: $cores"
# awk compares the decimal load with the core count
if [ "$(awk -v l="$load" -v c="$cores" 'BEGIN {print (l > c)}')" -eq 1 ]; then
    warn "Load is higher than the number of cores"
else
    ok "Load is fine"
fi

# 4. Services
title "4. Services"
if command -v systemctl > /dev/null; then
    failed=$(systemctl --failed --no-legend | wc -l)
    if [ "$failed" -gt 0 ]; then
        warn "$failed failed service(s):"
        systemctl --failed --no-legend
    else
        ok "No failed services"
    fi
    for svc in sshd chronyd firewalld; do
        if systemctl is-active --quiet "$svc"; then
            ok "$svc is running"
        else
            warn "$svc is not running"
        fi
    done
else
    warn "systemctl not found"
fi

# 5. Security
title "5. Security"
# SELinux should be Enforcing
if command -v getenforce > /dev/null; then
    mode=$(getenforce)
    if [ "$mode" = "Enforcing" ]; then
        ok "SELinux is Enforcing"
    else
        warn "SELinux is $mode"
    fi
else
    warn "getenforce not found"
fi

# firewalld state
if command -v firewall-cmd > /dev/null; then
    if [ "$(firewall-cmd --state 2>/dev/null)" = "running" ]; then
        ok "firewalld is running, services: $(firewall-cmd --list-services)"
    else
        warn "firewalld is not running"
    fi
else
    warn "firewall-cmd not found"
fi

# SSH root login (the config may need root to read)
if [ -r /etc/ssh/sshd_config ]; then
    if grep -Eiq '^\s*PermitRootLogin\s+yes' /etc/ssh/sshd_config; then
        warn "SSH allows root login"
    else
        ok "SSH does not allow root login"
    fi
else
    echo "[SKIP] Cannot read /etc/ssh/sshd_config (try sudo)"
fi

# Summary
echo
if [ "$warnings" -eq 0 ]; then
    echo "Result: everything looks fine."
else
    echo "Result: $warnings warning(s), see the [WARN] lines above."
fi
