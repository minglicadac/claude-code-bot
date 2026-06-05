FROM ubuntu:latest

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
        gnupg \
        cron \
        tini \
        git \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && npm install -g @anthropic-ai/claude-code \
    && rm -rf /var/lib/apt/lists/*

# Non-root user that actually runs `claude` (Claude Code refuses bypass mode as root).
RUN useradd -m -s /bin/bash robot \
    && mkdir -p /workspace /home/robot/.claude/projects \
    && chown -R robot:robot /workspace /home/robot/.claude

COPY cron/claude-robot /etc/cron.d/claude-robot
RUN chmod 0644 /etc/cron.d/claude-robot

COPY scripts/ /usr/local/bin/
RUN chmod 0755 /usr/local/bin/sync-bugs.sh \
               /usr/local/bin/claude.sh \
               /usr/local/bin/entrypoint.sh \
    && chmod 0644 /usr/local/bin/webhook-server.js

RUN touch /var/log/claude-robot.log && chown robot:robot /var/log/claude-robot.log

WORKDIR /workspace

EXPOSE 8080

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/local/bin/entrypoint.sh"]
