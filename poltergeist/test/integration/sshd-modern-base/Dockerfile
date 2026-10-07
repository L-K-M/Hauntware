FROM alpine:20260805@sha256:020dfcbaaf4cc1078bf2d9c7ba31a8466e334061dcd2f248001d68f79e52c000

# The modern fixture's frozen base: Alpine plus the pinned packages. Alpine
# serves only the newest build of each package, so these pins stop
# resolving whenever it moves on. The integration jobs therefore never build
# this file: the "Fixture images" workflow builds it on pull requests that
# change it and publishes it from main, and sshd-modern/Dockerfile builds on
# that image by digest.
RUN apk add --no-cache \
      iproute2=7.2.0-r0 \
      openssh-client-common=10.6_p1-r0 \
      openssh-server-pam=10.6_p1-r0 \
      openssh-sftp-server=10.6_p1-r0
