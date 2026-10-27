#!/bin/sh
# Spike S8 (04 S8, 03 §7.14 IMG-05): how a digest update check reads the
# registry. Prints what each route answers; writes nothing but a scratch
# registry directory under $TMPDIR when --private is given, and removes
# the container it starts. Needs curl and python3; the daemon and private
# parts need a running Docker daemon and the buildx plugin.
#
#   probe.sh            public registries, then the daemon if one answers
#   probe.sh --private  also a local registry:3 behind basic auth
set -eu

accept='application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.oci.image.manifest.v1+json'
hub_repo=library/alpine
hub_tag=3.22

headers() {
  tr -d '\r' | grep -iE '^(HTTP/[0-9.]+ [0-9]|www-authenticate|docker-content-digest|content-type|ratelimit|docker-ratelimit-source)' |
    grep -v 'Connection Established' || true
}

hub_token() {
  curl -sS --max-time 20 \
    "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$hub_repo:pull" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])'
}

# One line per request: method, status, the source address Docker Hub
# counts against, and the remaining quota it reports for that address.
hub_request() {
  curl -sS -o /dev/null -D - --max-time 20 "$@" \
    -H "Authorization: Bearer $token" -H "Accept: $accept" \
    "https://registry-1.docker.io/v2/$hub_repo/manifests/$hub_tag" |
    tr -d '\r' | awk 'BEGIN { IGNORECASE = 1 }
      /^HTTP\/2/ { status = $2 }
      /^docker-ratelimit-source/ { source = $2 }
      /^ratelimit-remaining/ { remaining = $2 }
      END { print status, source, remaining }'
}

echo "== Docker Hub: anonymous token, then manifest HEAD ($hub_repo:$hub_tag)"
token=$(hub_token)
curl -sS -I --max-time 20 -H "Authorization: Bearer $token" -H "Accept: $accept" \
  "https://registry-1.docker.io/v2/$hub_repo/manifests/$hub_tag" | headers

echo
echo "== Docker Hub: 16 HEADs; an address seen twice shows whether HEAD counts"
i=0
while [ "$i" -lt 16 ]; do
  echo "HEAD $(hub_request -I)"
  i=$((i + 1))
done

echo
echo "== Docker Hub: HEAD that asks for a single-platform manifest only"
curl -sS -I --max-time 20 -H "Authorization: Bearer $token" \
  -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
  "https://registry-1.docker.io/v2/$hub_repo/manifests/$hub_tag" | headers

# Other public registries: the first HEAD either answers or names the
# token realm in WWW-Authenticate.
for ref in ghcr.io/home-assistant/home-assistant:stable quay.io/prometheus/node-exporter:latest; do
  registry=${ref%%/*}
  rest=${ref#*/}
  repo=${rest%:*}
  tag=${rest##*:}
  echo
  echo "== $ref: HEAD without a token"
  first=$(curl -sS -I --max-time 20 -H "Accept: $accept" "https://$registry/v2/$repo/manifests/$tag")
  printf '%s\n' "$first" | headers
  challenge=$(printf '%s\n' "$first" | tr -d '\r' | grep -i '^www-authenticate: bearer' || true)
  [ -n "$challenge" ] || continue
  realm=$(printf '%s' "$challenge" | sed -n 's/.*realm="\([^"]*\)".*/\1/p')
  service=$(printf '%s' "$challenge" | sed -n 's/.*service="\([^"]*\)".*/\1/p')
  bearer=$(curl -sS --max-time 20 "$realm?service=$service&scope=repository:$repo:pull" |
    python3 -c 'import json,sys; d = json.load(sys.stdin); print(d.get("token") or d.get("access_token"))')
  echo "-- with the anonymous token from $realm"
  curl -sS -I --max-time 20 -H "Authorization: Bearer $bearer" -H "Accept: $accept" \
    "https://$registry/v2/$repo/manifests/$tag" | headers
done

if ! docker info >/dev/null 2>&1; then
  echo
  echo "== no Docker daemon; daemon and private checks skipped"
  exit 0
fi

api=$(docker version --format '{{.Server.APIVersion}}')
echo
echo "== Docker $(docker version --format '{{.Server.Version}}') (API $api), $(docker info --format '{{.DriverStatus}}')"
echo "-- DistributionInspect alpine:$hub_tag"
curl -sS --unix-socket /var/run/docker.sock "http://localhost/v$api/distribution/alpine:$hub_tag/json" |
  python3 -c 'import json,sys; d = json.load(sys.stdin); print(json.dumps(d["Descriptor"]), len(d.get("Platforms") or []), "platforms")'

docker pull -q "alpine:$hub_tag" >/dev/null
echo "-- local RepoDigests and Descriptor"
docker image inspect "alpine:$hub_tag" --format '{{json .RepoDigests}} {{json .Descriptor}}'
echo "-- local index children (GET /images/{name}/json?manifests=1)"
curl -sS --unix-socket /var/run/docker.sock "http://localhost/v$api/images/alpine:$hub_tag/json?manifests=1" |
  python3 -c '
import json, sys
for m in json.load(sys.stdin).get("Manifests", []):
    platform = (m.get("ImageData") or {}).get("Platform") or {}
    print(m["Descriptor"]["digest"], m["Kind"], "available" if m["Available"] else "absent", platform.get("architecture", "-"))'

[ "${1:-}" = --private ] || exit 0

# A throwaway registry on 127.0.0.1 with a throwaway account. The
# password stays in this shell and is never printed.
dir=$(mktemp -d)
user=klab
pass=$(python3 -c 'import secrets; print(secrets.token_hex(12))')
docker run --rm --entrypoint htpasswd httpd:2.4-alpine -Bbn "$user" "$pass" >"$dir/htpasswd"
docker rm -f s8-registry >/dev/null 2>&1 || true
docker run -d --name s8-registry -p 127.0.0.1:5000:5000 -v "$dir:/auth" \
  -e REGISTRY_AUTH=htpasswd -e REGISTRY_AUTH_HTPASSWD_REALM=s8 \
  -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd registry:3 >/dev/null
trap 'docker rm -f s8-registry >/dev/null 2>&1; docker logout localhost:5000 >/dev/null 2>&1; rm -rf "$dir"' EXIT
sleep 2
printf '%s\n' "$pass" | docker login -u "$user" --password-stdin localhost:5000 >/dev/null
docker tag "alpine:$hub_tag" "localhost:5000/alpine:$hub_tag"
echo
echo "== private registry: push from the containerd store"
docker push -q "localhost:5000/alpine:$hub_tag" | tail -1
echo "-- curl -sI without credentials"
curl -sS -I --noproxy '*' -H "Accept: $accept" "http://127.0.0.1:5000/v2/alpine/manifests/$hub_tag" | headers
echo "-- docker buildx imagetools inspect (credentials from the CLI's store)"
docker buildx imagetools inspect "localhost:5000/alpine:$hub_tag" --format '{{json .Manifest}}' |
  python3 -c 'import json,sys; d = json.load(sys.stdin); print(d["mediaType"], d["digest"])'
echo "-- docker manifest inspect, without and with --insecure"
docker manifest inspect "localhost:5000/alpine:$hub_tag" 2>&1 | head -1 || true
docker manifest inspect --insecure -v "localhost:5000/alpine:$hub_tag" |
  python3 -c 'import json,sys; d = json.load(sys.stdin); d = d if isinstance(d, dict) else d[0]; print(d["Descriptor"]["digest"])'
echo "-- DistributionInspect without X-Registry-Auth"
curl -sS --unix-socket /var/run/docker.sock "http://localhost/v$api/distribution/localhost:5000/alpine:$hub_tag/json"
echo
echo "-- local RepoDigests after the push"
docker image inspect "localhost:5000/alpine:$hub_tag" --format '{{json .RepoDigests}}'
docker logout localhost:5000 >/dev/null
echo "-- docker buildx imagetools inspect after logout"
docker buildx imagetools inspect "localhost:5000/alpine:$hub_tag" 2>&1 | tail -1 || true
