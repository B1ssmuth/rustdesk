FROM alpine:3.21
RUN --mount=type=secret,id=fixture_ca,target=/run/fixture-ca \
    if [ -r /run/fixture-ca ]; then export SSL_CERT_FILE=/run/fixture-ca; fi && \
    apk add --no-cache openssh && \
    adduser -D sftp-test && passwd -d sftp-test && \
    mkdir -p /home/sftp-test/.ssh /home/sftp-test/denied && \
    chown sftp-test:sftp-test /home/sftp-test/.ssh && \
    chmod 700 /home/sftp-test/.ssh /home/sftp-test/denied && \
    printf '%s\n' 'PasswordAuthentication no' 'PermitRootLogin no' \
      'AllowUsers sftp-test' 'AllowTcpForwarding no' 'X11Forwarding no' \
      'AllowAgentForwarding no' 'MaxSessions 4' > /etc/ssh/yesdesk.conf
COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]
