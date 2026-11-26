# RHEL Health Check

A simple read-only Bash script that checks the health and basic security of a RHEL-family server (RHEL, Rocky, AlmaLinux). It does not change anything on the system. This is a training project from my RHCSA study and Linux/Bash practice, not a production monitoring tool.

## Run it
```bash
chmod +x rhel-health-check.sh
./rhel-health-check.sh        # use sudo to also read the SSH config
```

## Sections
1. **System**: host name, uptime, kernel, OS name
2. **Disk usage**: warns when a filesystem is 80% full or more
3. **Memory and CPU load**: warns when memory use is 90% or more, or the 1-minute load is higher than the number of cores
4. **Services**: failed services, and whether `sshd`, `chronyd` and `firewalld` are running
5. **Security**: SELinux mode, firewalld state, and whether SSH allows root login

Each line starts with `[ OK ]` or `[WARN]`, and the last line gives the number of warnings. The two limits are variables at the top of the script.

## Testing status
- The script passes `bash -n` (syntax check).
- Run on a real RHEL-family system by the author. It worked as expected.
