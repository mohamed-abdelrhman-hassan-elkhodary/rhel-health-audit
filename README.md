# RHEL Health Audit (Bash)

A read-only health and security audit script for RHEL-family servers (RHEL, Rocky, AlmaLinux, CentOS Stream, Fedora). It checks 11 areas, prints a colour-coded result, saves a plain-text report, and ends with a per-section summary table.

This is a training project from my RHCSA study and Linux/Bash practice. It is not a production monitoring tool.

## Design rules
1. **Read-only.** No installs, restarts, edits or deletes. The only file it writes is its own report.
2. **Safe without root.** Checks that need root are skipped and labelled `[SKIP]`.
3. **Every finding maps to a standard command** (`df`, `ss`, `getenforce`, `firewall-cmd`, `dnf`, `sshd -T`, `journalctl`), so each result can be checked by hand.
4. **Automation friendly.** Exit code `0` = no warnings, `1` = warnings, `2` = usage error. Usable from cron or CI.

## What it checks
| Section | Checks |
|---|---|
| system | OS, kernel, uptime, NTP sync, reboot needed |
| cpu_mem | core count vs load average, memory use, swap, top processes |
| disk | filesystem and inode use against a threshold, block devices, LVM |
| users | login shells, extra UID 0 accounts, wheel members, empty passwords, recent logins |
| services | failed systemd units, status of sshd, chronyd, firewalld, auditd, crond, rsyslog |
| network | addresses, routes, DNS, listening sockets, default gateway ping |
| firewall | firewalld running state, default zone, rules |
| selinux | current mode, configured mode, AVC denials today |
| updates | pending updates and security advisories (dnf/yum) |
| ssh | root login, password authentication, empty passwords, port |
| logs | error-level journal entries in the last 24h, failed SSH logins |

## Usage
```bash
chmod +x rhel-health-audit.sh
./rhel-health-audit.sh -n                 # dry run, shows what would be checked
./rhel-health-audit.sh                    # full audit as a normal user
sudo ./rhel-health-audit.sh               # full audit including root-only checks
./rhel-health-audit.sh -s disk,selinux    # only some sections
./rhel-health-audit.sh -t 90 -o /tmp/rep  # 90% threshold, custom report folder
./rhel-health-audit.sh -q                 # write the report only
./rhel-health-audit.sh -C                 # no colour
./rhel-health-audit.sh -V                 # version
```

## Example summary (from a test run, no root)
```
=== Summary ===
Section         OK  INFO  WARN  SKIP
-------        ---  ----  ----  ----
System           1     5     0     0
CPU              2     2     0     0
Disk             1     0     0     0
Users            1     2     0     1
Services         1     4     2     0
...
Result: 3 warning(s). Review the [WARN] lines above.
```
Colours (green OK, yellow WARN, grey SKIP) show only on a terminal. The saved report is always plain text.

## Testing status
- Syntax checked with `bash -n`.
- Run on a real RHEL system by the author. It worked as expected.
- Compare the output with the commands it wraps (`getenforce`, `firewall-cmd --list-all`, `dnf check-update`, `systemctl --failed`) when you run it on your own systems.

## Ideas to extend it
- Compare `/etc/fstab` with mounted filesystems
- Report sudoers entries and world-writable files
- JSON output
- Email the report
