FROM ghcr.io/l-k-m/poltergeist-sshd-modern-base@sha256:c65af9a1e573bde503036e412d2aace7ecec9c11309f15f0691d67f9090bf8e8

# The base carries Alpine and the pinned packages (sshd-modern-base/), frozen
# in GHCR because Alpine drops superseded builds. Only the fixture's own
# files are layered here, so editing them needs no republish.
COPY sshd-common/entrypoint.sh /usr/local/bin/fixture-entrypoint
COPY sshd-common/netem-profile.sh /usr/local/bin/netem-profile
COPY sshd-common/config/ /etc/ssh/fixture/

RUN chmod 0755 \
      /usr/local/bin/fixture-entrypoint \
      /usr/local/bin/netem-profile

EXPOSE 22

ENTRYPOINT ["/usr/local/bin/fixture-entrypoint"]
