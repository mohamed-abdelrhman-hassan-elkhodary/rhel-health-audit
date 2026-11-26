# RHEL Health Check

Two read-only Bash scripts that check the health and basic security of a RHEL-family server (RHEL, Rocky, AlmaLinux). Neither changes anything on the system. This is a training project from my RHCSA study and Linux/Bash practice, not a production monitoring tool.

| Script | What it is |
|---|---|
| `rhel-health-check.sh` | Simple version, 120 lines, 5 sections |
| `rhel-health-audit.sh` | Advanced version, 11 sections, colour output, summary table, options |

## Simple version: rhel-health-check.sh
Run it:
```bash
chmod +x rhel-health-check.sh
./rhel-health-check.sh        # use sudo to also read the SSH config
```

Sections:
1. **System**: host name, uptime, kernel, OS name
2. **Disk usage**: warns when a filesystem is 80% full or more
3. **Memory and CPU load**: warns when memory use is 90% or more, or the 1-minute load is higher than the number of cores
4. **Services**: failed services, and whether `sshd`, `chronyd` and `firewalld` are running
5. **Security**: SELinux mode, firewalld state, and whether SSH allows root login

Each line starts with `[ OK ]` or `[WARN]`, and the last line gives the number of warnings. The limits are two variables at the top of the script.

## Advanced version: rhel-health-audit.sh
The longer version with more checks and options. Run `./rhel-health-audit.sh -h` for the options.

## Testing status
- Both scripts pass `bash -n` (syntax check).
- The advanced version `rhel-health-audit.sh` was run on a real RHEL system by the author and worked as expected.
- The simple version `rhel-health-check.sh` has not been run on a RHEL-family system yet. It was checked on another Linux system, where the RHEL-only checks (SELinux, firewalld) report as not found.
