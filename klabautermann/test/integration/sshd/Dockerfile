FROM ghcr.io/l-k-m/poltergeist-sshd-modern-base@sha256:c65af9a1e573bde503036e412d2aace7ecec9c11309f15f0691d67f9090bf8e8

# Poltergeist's frozen sshd base (03 §11.3): Alpine and pinned OpenSSH,
# published by fixture-images.yml. The digest is the one
# poltergeist/test/integration/sshd-modern/Dockerfile builds on, which a
# contract test checks. Only this fixture's own files are layered here,
# so the build fetches nothing; the common sshd config is mounted from
# Poltergeist's tree by docker-compose.yml.
COPY entrypoint.sh /usr/local/bin/fixture-entrypoint
COPY samplers.sh /usr/local/bin/fixture-samplers
# Ahead of BusyBox's /bin/df on every login PATH.
COPY slow-df.sh /usr/local/bin/df
COPY sshd_config.target sshd_config.jump /etc/klabautermann/

RUN chmod 0755 \
      /usr/local/bin/fixture-entrypoint \
      /usr/local/bin/fixture-samplers \
      /usr/local/bin/df

EXPOSE 22

ENTRYPOINT ["/usr/local/bin/fixture-entrypoint"]
