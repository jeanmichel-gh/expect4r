#!/bin/sh
set -eu
ssh-keygen -A >/dev/null 2>&1
cat > /run/playground-sshd.conf <<'CONFIG'
ListenAddress 127.0.0.1
Port 2222
HostKey /etc/ssh/ssh_host_ed25519_key
PasswordAuthentication yes
KbdInteractiveAuthentication no
UsePAM no
PermitRootLogin no
AllowUsers lab
PidFile /run/playground-sshd.pid
PrintMotd no
CONFIG
/usr/sbin/sshd -f /run/playground-sshd.conf
# Trust the locally generated key directly, without a network key scan.
printf '[127.0.0.1]:2222 ' > /run/playground-known-hosts
cat /etc/ssh/ssh_host_ed25519_key.pub >> /run/playground-known-hosts
busybox telnetd -b 127.0.0.1 -p 2323 -l /bin/login
exec "$@"
