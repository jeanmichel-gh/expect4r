FROM ruby:4.0.6
RUN apt-get update && apt-get install -y --no-install-recommends openssh-server openssh-client busybox-static inetutils-telnet sqlite3 python3 less tini && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY . .
RUN gem build expect4r.gemspec --output /tmp/expect4r.gem && gem install /tmp/expect4r.gem --no-document && cd applications/routers && gem build expect4r-routers.gemspec --output /tmp/routers.gem && gem install /tmp/routers.gem --no-document
RUN useradd -m -s /bin/bash lab && echo 'lab:lab-password' | chpasswd && mkdir -p /run/sshd /opt/playground && cp -r playground/* /opt/playground/ && chmod +x /opt/playground/start.sh && printf '\nexport PS1="lab> "\nexport TERM=dumb\n' >> /home/lab/.bashrc
ENV TERM=dumb
WORKDIR /opt/playground
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/playground/start.sh"]
CMD ["sleep", "infinity"]
