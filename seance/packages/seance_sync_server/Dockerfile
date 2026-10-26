# syntax=docker/dockerfile:1
# Séance sync server — build the single static-ish binary, then a slim runtime.
# Build context is the REPOSITORY ROOT (so the pub workspace resolves):
#   docker build -f packages/seance_sync_server/Dockerfile -t seance-sync .

# ---- build stage ----
FROM dart:stable AS build
# python3 runs the notice generators below; it stays in this stage.
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app

# Copy workspace + member manifests first for dependency-layer caching.
COPY pubspec.yaml pubspec.lock analysis_options.yaml ./
COPY packages/seance_protocol/pubspec.yaml packages/seance_protocol/pubspec.yaml
COPY packages/seance_core/pubspec.yaml packages/seance_core/pubspec.yaml
COPY packages/seance_sync_server/pubspec.yaml packages/seance_sync_server/pubspec.yaml
RUN dart pub get

# Copy sources and compile to a native executable.
COPY packages/seance_protocol packages/seance_protocol
COPY packages/seance_core packages/seance_core
COPY packages/seance_sync_server packages/seance_sync_server
RUN dart pub get
RUN dart compile exe packages/seance_sync_server/bin/seance_sync_server.dart \
      -o /app/seance-sync

# Third-party notices for the binary: the pub packages it compiles in, the
# Dart SDK and the third-party code its AOT runtime embeds. dart:stable
# floats, so the runtime texts are fetched at this SDK's exact revision.
COPY scripts/licenses scripts/licenses
RUN python3 scripts/licenses/dart-runtime-licenses.py --out /tmp/dart-runtime \
    && python3 scripts/licenses/go-dart-notices.py dart --workspace . \
         --package seance_sync_server --runtime-licenses /tmp/dart-runtime \
         --title seance-sync -o /out/notices/Third-Party-Notices.txt

# ---- runtime stage ----
FROM debian:stable-slim AS base

FROM base
RUN apt-get update \
    && apt-get install -y --no-install-recommends libsqlite3-0 ca-certificates \
    && rm -rf /var/lib/apt/lists/*
# OS package notices, right after the package installation: every package
# with its source version, checked for its copyright file.
RUN --mount=type=bind,source=scripts/licenses/os-packages.sh,target=/tmp/os-packages.sh \
    --mount=type=bind,from=base,source=/var/lib/dpkg/status,target=/tmp/base-db \
    sh /tmp/os-packages.sh --image seance-sync --base-db /tmp/base-db \
      /usr/share/doc/seance-sync/OS-Packages.txt
COPY --from=build /app/seance-sync /usr/local/bin/seance-sync
COPY --from=build /out/notices/ /usr/share/doc/seance-sync/
COPY LICENSE /usr/share/doc/seance-sync/LICENSE
# Séance's own code is Unlicense; the rest comes from the notices above
# (scripts/licenses/oci-licenses.py expr). libsqlite3-0 is SQLite's
# blessing, ca-certificates GPL-2.0-or-later with MPL-2.0 certificate data.
LABEL org.opencontainers.image.licenses="Unlicense AND Apache-2.0 AND Apache-2.0 WITH LLVM-exception AND BSD-3-Clause AND GPL-2.0-or-later AND ICU AND MIT AND MPL-2.0 AND NCSA AND Unicode-3.0 AND Zlib AND blessing"

# Sensible, locked-down defaults. Override via env or CLI flags.
ENV SEANCE_BIND=0.0.0.0 \
    SEANCE_PORT=8787 \
    SEANCE_DB_PATH=/data/seance.sqlite \
    SEANCE_OPEN_REGISTRATION=false
RUN mkdir -p /data
VOLUME /data
EXPOSE 8787

# Run as a non-root user.
RUN useradd --system --uid 10001 seance && chown -R seance /data
USER seance

ENTRYPOINT ["/usr/local/bin/seance-sync"]
