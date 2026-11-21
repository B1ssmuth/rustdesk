#!/bin/sh
set -eu
cp /client.pub /home/sftp-test/.ssh/authorized_keys
chown sftp-test:sftp-test /home/sftp-test/.ssh/authorized_keys
chmod 600 /home/sftp-test/.ssh/authorized_keys
ssh-keygen -A
if [ "${1:-}" != disabled ]; then
  echo 'Subsystem sftp internal-sftp' >> /etc/ssh/yesdesk.conf
fi
exec /usr/sbin/sshd -D -e -f /etc/ssh/yesdesk.conf
