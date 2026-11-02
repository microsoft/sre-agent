#!/usr/bin/env bash
set -euo pipefail

SPLUNK_PASSWORD=""
PACKAGE_URL=""
REGISTRY_SERVER="${registryServer:-}"
REGISTRY_USERNAME="${registryUsername:-}"
REGISTRY_PASSWORD=""
ENABLE_LAB_HTTP="${enableLabHttp:-false}"

cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n "${REGISTRY_SERVER:-}" ]]; then
    docker logout "$REGISTRY_SERVER" >/dev/null 2>&1 || true
    rm -f /root/.docker/config.json
  fi
  rm -f /tmp/splunk-mcp-server.tgz
  exit "$status"
}
trap cleanup EXIT

if [[ -n "${splunkPasswordBase64:-}" ]]; then
  SPLUNK_PASSWORD="$(printf '%s' "$splunkPasswordBase64" | base64 -d)"
fi
if [[ -n "${packageUrlBase64:-}" ]]; then
  PACKAGE_URL="$(printf '%s' "$packageUrlBase64" | base64 -d)"
fi
if [[ -n "${registryPasswordBase64:-}" ]]; then
  REGISTRY_PASSWORD="$(printf '%s' "$registryPasswordBase64" | base64 -d)"
fi

for argument in "$@"; do
  case "$argument" in
    splunkPasswordBase64=*) SPLUNK_PASSWORD="$(printf '%s' "${argument#*=}" | base64 -d)" ;;
    packageUrlBase64=*) PACKAGE_URL="$(printf '%s' "${argument#*=}" | base64 -d)" ;;
    registryServer=*) REGISTRY_SERVER="${argument#*=}" ;;
    registryUsername=*) REGISTRY_USERNAME="${argument#*=}" ;;
    registryPasswordBase64=*) REGISTRY_PASSWORD="$(printf '%s' "${argument#*=}" | base64 -d)" ;;
    enableLabHttp=*) ENABLE_LAB_HTTP="${argument#*=}" ;;
  esac
done

: "${SPLUNK_PASSWORD:?splunkPasswordBase64 is required}"
: "${PACKAGE_URL:?packageUrlBase64 is required}"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y docker.io curl
systemctl enable --now docker

if [[ -n "${REGISTRY_SERVER:-}" ]]; then
  : "${REGISTRY_USERNAME:?registryUsername is required when registryServer is set}"
  : "${REGISTRY_PASSWORD:?registryPassword is required when registryServer is set}"
  printf '%s' "$REGISTRY_PASSWORD" | docker login "$REGISTRY_SERVER" --username "$REGISTRY_USERNAME" --password-stdin
  SPLUNK_IMAGE="${REGISTRY_SERVER}/splunk/splunk:latest"
else
  SPLUNK_IMAGE="splunk/splunk:latest"
fi

docker pull nginx:alpine
if docker inspect private-test >/dev/null 2>&1; then
  docker start private-test >/dev/null
else
  docker run -d --name private-test --restart unless-stopped -p 8080:80 nginx:alpine
fi

docker pull "$SPLUNK_IMAGE"
if docker inspect splunk >/dev/null 2>&1; then
  CURRENT_LAB_HTTP="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' splunk | grep -c '^SPLUNKD_SSL_ENABLE=false$' || true)"
  REQUESTED_LAB_HTTP="0"
  [[ "${ENABLE_LAB_HTTP:-false}" == "true" ]] && REQUESTED_LAB_HTTP="1"
  if [[ "$CURRENT_LAB_HTTP" != "$REQUESTED_LAB_HTTP" ]]; then
    echo "The existing Splunk container TLS mode differs from the requested mode." >&2
    echo "Delete the disposable container and rerun this script; the named Splunk volumes can be retained." >&2
    exit 1
  fi
  docker start splunk >/dev/null
else
  DOCKER_ARGS=(
    -d
    --name splunk
    --restart unless-stopped
    -p 8000:8000
    -p 8089:8089
    -v splunk-etc:/opt/splunk/etc
    -v splunk-var:/opt/splunk/var
    -e SPLUNK_START_ARGS=--accept-license
    -e SPLUNK_GENERAL_TERMS=--accept-sgt-current-at-splunk-com
    -e "SPLUNK_PASSWORD=$SPLUNK_PASSWORD"
  )
  if [[ "${ENABLE_LAB_HTTP:-false}" == "true" ]]; then
    echo "WARNING: enabling plaintext HTTP on Splunk port 8089 for this isolated private lab."
    DOCKER_ARGS+=(-e SPLUNKD_SSL_ENABLE=false -e SPLUNK_CERT_PREFIX=http)
  fi
  docker run "${DOCKER_ARGS[@]}" "$SPLUNK_IMAGE"
fi

for _ in {1..90}; do
  if [[ "$(docker inspect --format '{{.State.Health.Status}}' splunk 2>/dev/null || true)" == "healthy" ]]; then
    break
  fi
  sleep 10
done

[[ "$(docker inspect --format '{{.State.Health.Status}}' splunk)" == "healthy" ]] || {
  docker logs --tail 100 splunk
  echo "Splunk did not become healthy." >&2
  exit 1
}

curl -fsSL "$PACKAGE_URL" -o /tmp/splunk-mcp-server.tgz
docker cp /tmp/splunk-mcp-server.tgz splunk:/tmp/splunk-mcp-server.tgz
docker exec -u splunk -e INSTALL_PASSWORD="$SPLUNK_PASSWORD" splunk sh -c \
  '/opt/splunk/bin/splunk install app /tmp/splunk-mcp-server.tgz -auth "admin:$INSTALL_PASSWORD" -update 1'
docker restart splunk >/dev/null

for _ in {1..90}; do
  if [[ "$(docker inspect --format '{{.State.Health.Status}}' splunk 2>/dev/null || true)" == "healthy" ]]; then
    exit 0
  fi
  sleep 10
done

docker logs --tail 100 splunk
echo "Splunk did not become healthy after MCP app installation." >&2
exit 1
