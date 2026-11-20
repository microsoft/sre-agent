#!/usr/bin/env sh
# Install a verified `az sre` extension wheel.
#
# Supported sources (see devx/sdks/python/azure-cli-sre/docs/release.md):
#   --wheel-url URL --expected-sha256 HEX   exact HTTPS wheel + trusted digest
#   --wheel-path FILE [--expected-sha256 HEX]  local copy of an official wheel
#   (no arguments)                          the pinned DEFAULT_* release below
# Private GitHub run/release selectors are intentionally not supported.
set -eu

EXTENSION_NAME="sre"

# Pinned release used when no wheel source is given (curl ... | bash).
# Each public release PR updates both values together.
DEFAULT_WHEEL_URL="https://github.com/microsoft/sre-agent/releases/download/cli-v1.0.0b2/sre-1.0.0b2-py3-none-any.whl"
DEFAULT_EXPECTED_SHA256="e1a05b99d9006e76a1e2949ce8a6bb70143f573e11169f7b28c773328c06fa08"

WHEEL_URL="${SRE_INSTALL_WHEEL_URL:-}"
WHEEL_PATH="${SRE_INSTALL_WHEEL_PATH:-}"
EXPECTED_SHA256="${SRE_INSTALL_EXPECTED_SHA256:-}"
UNINSTALL=0

usage() {
  printf '%s\n' \
'Usage: install-az-sre.sh [options]' \
'' \
'Install a verified az sre extension wheel.' \
'With no wheel source, installs the pinned default release.' \
'' \
'Options:' \
'  --wheel-url URL             Exact HTTPS URL ending in sre-<version>-py3-none-any.whl' \
'  --wheel-path FILE           Local sre-<version>-py3-none-any.whl' \
'  --expected-sha256 HEX       Trusted SHA-256 (required with --wheel-url)' \
'  --uninstall, -u             Remove sre if installed' \
'  --help, -h                  Show this help' \
'' \
'Matching environment variables use the SRE_INSTALL_* prefix' \
'(SRE_INSTALL_WHEEL_URL, SRE_INSTALL_WHEEL_PATH, SRE_INSTALL_EXPECTED_SHA256).'
}

require_value() {
  if [ "$#" -lt 2 ] || [ -z "$2" ]; then
    echo "ERROR: $1 requires a value." >&2
    exit 2
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --wheel-url)
      require_value "$@"
      WHEEL_URL="$2"
      shift 2
      ;;
    --wheel-path)
      require_value "$@"
      WHEEL_PATH="$2"
      shift 2
      ;;
    --expected-sha256)
      require_value "$@"
      EXPECTED_SHA256="$2"
      shift 2
      ;;
    --uninstall|-u)
      UNINSTALL=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! command -v az >/dev/null 2>&1; then
  echo "ERROR: Azure CLI ('az') not found." >&2
  echo "Install it first: https://learn.microsoft.com/cli/azure/install-azure-cli" >&2
  exit 1
fi

if [ "$UNINSTALL" -eq 1 ]; then
  INSTALLED_NAME="$(az extension list --query "[?name=='$EXTENSION_NAME'].name" --output tsv)"
  if [ "$INSTALLED_NAME" = "$EXTENSION_NAME" ]; then
    az extension remove --name "$EXTENSION_NAME"
    echo "Uninstalled '$EXTENSION_NAME'."
  elif [ -z "$INSTALLED_NAME" ]; then
    echo "'$EXTENSION_NAME' is not installed; nothing to do."
  else
    echo "ERROR: Unexpected extension list response; refusing to uninstall." >&2
    exit 1
  fi
  exit 0
fi

if [ -n "$WHEEL_URL" ] && [ -n "$WHEEL_PATH" ]; then
  echo "ERROR: Use either --wheel-url or --wheel-path, not both." >&2
  exit 2
fi
if [ -z "$WHEEL_URL" ] && [ -z "$WHEEL_PATH" ]; then
  if [ -z "$DEFAULT_WHEEL_URL" ] || [ -z "$DEFAULT_EXPECTED_SHA256" ]; then
    echo "ERROR: No default release is pinned yet. Provide --wheel-url (with --expected-sha256) or --wheel-path." >&2
    usage >&2
    exit 2
  fi
  WHEEL_URL="$DEFAULT_WHEEL_URL"
  EXPECTED_SHA256="$DEFAULT_EXPECTED_SHA256"
fi

check_wheel_name() {
  case "$1" in
    sre-*-py3-none-any.whl) ;;
    *)
      echo "ERROR: '$1' is not an exact sre-<version>-py3-none-any.whl filename." >&2
      exit 2
      ;;
  esac
}

verify_sha256() {
  asset_name="$1"
  asset_file="$2"
  expected_digest="$3"
  case "$expected_digest" in
    *[!0-9A-Fa-f]*)
      echo "ERROR: Invalid expected SHA-256 digest for '$asset_name'." >&2
      return 1
      ;;
  esac
  if [ "${#expected_digest}" -ne 64 ]; then
    echo "ERROR: Invalid expected SHA-256 digest for '$asset_name'." >&2
    return 1
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    actual_digest="$(sha256sum "$asset_file")"
  elif command -v shasum >/dev/null 2>&1; then
    actual_digest="$(shasum -a 256 "$asset_file")"
  else
    echo "ERROR: sha256sum or shasum is required for verification." >&2
    return 1
  fi
  actual_digest="${actual_digest%% *}"
  expected_digest="$(printf '%s' "$expected_digest" | tr 'A-F' 'a-f')"
  actual_digest="$(printf '%s' "$actual_digest" | tr 'A-F' 'a-f')"
  if [ "$actual_digest" != "$expected_digest" ]; then
    echo "ERROR: SHA-256 verification failed for '$asset_name'." >&2
    return 1
  fi
}

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sre-install.XXXXXX")"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup 0
trap 'cleanup; exit 130' 1 2 15

if [ -n "$WHEEL_URL" ]; then
  if [ -z "$EXPECTED_SHA256" ]; then
    echo "ERROR: --wheel-url requires --expected-sha256." >&2
    exit 2
  fi
  case "$WHEEL_URL" in
    https://*) ;;
    *)
      echo "ERROR: --wheel-url must be an HTTPS URL." >&2
      exit 2
      ;;
  esac
  case "$WHEEL_URL" in
    *\?*|*\#*|https://*@*)
      echo "ERROR: --wheel-url must not contain a query, fragment, or credentials." >&2
      exit 2
      ;;
  esac
  if ! command -v curl >/dev/null 2>&1; then
    echo "ERROR: curl is required for downloads." >&2
    exit 1
  fi
  WHEEL_NAME="${WHEEL_URL##*/}"
  check_wheel_name "$WHEEL_NAME"
  WHEEL_FILE="$TMP_DIR/$WHEEL_NAME"
  EFFECTIVE_URL="$(curl --fail --location --show-error --proto '=https' --tlsv1.2 \
    --output "$WHEEL_FILE" --write-out '%{url_effective}' "$WHEEL_URL")"
  case "$EFFECTIVE_URL" in
    https://*) ;;
    *)
      echo "ERROR: Wheel download did not finish at an HTTPS URL." >&2
      exit 1
      ;;
  esac
  if grep -EIqi '<html|<!doctype' "$WHEEL_FILE"; then
    echo "ERROR: Download looks like an HTML page (sign-in?), not a wheel." >&2
    exit 1
  fi
  verify_sha256 "$WHEEL_NAME" "$WHEEL_FILE" "$EXPECTED_SHA256"
  SOURCE_DESCRIPTION="URL:    $WHEEL_URL"
else
  if [ ! -f "$WHEEL_PATH" ]; then
    echo "ERROR: Wheel file not found: $WHEEL_PATH" >&2
    exit 1
  fi
  WHEEL_NAME="${WHEEL_PATH##*/}"
  check_wheel_name "$WHEEL_NAME"
  WHEEL_FILE="$TMP_DIR/$WHEEL_NAME"
  cp "$WHEEL_PATH" "$WHEEL_FILE"
  if [ -n "$EXPECTED_SHA256" ]; then
    verify_sha256 "$WHEEL_NAME" "$WHEEL_FILE" "$EXPECTED_SHA256"
  else
    echo "WARNING: No --expected-sha256 given; local wheel digest not verified." >&2
  fi
  SOURCE_DESCRIPTION="File:   $WHEEL_PATH"
fi

EXPECTED_VERSION="${WHEEL_NAME#sre-}"
EXPECTED_VERSION="${EXPECTED_VERSION%-py3-none-any.whl}"
case "$EXPECTED_VERSION" in
  ""|*[!A-Za-z0-9.+_]*)
    echo "ERROR: Unsafe extension version in wheel filename '$WHEEL_NAME'." >&2
    exit 1
    ;;
esac

az extension add \
  --upgrade \
  --yes \
  --source "$WHEEL_FILE" \
  --output none

az_value() {
  query="$1"
  stderr_file="$TMP_DIR/az-version.stderr"
  if value="$(az sre version --query "$query" --output tsv 2>"$stderr_file")"; then
    rm -f "$stderr_file"
    printf '%s\n' "$value"
    return 0
  else
    status=$?
  fi
  cat "$stderr_file" >&2
  rm -f "$stderr_file"
  return "$status"
}

ACTUAL_NAME="$(az_value extensionName)"
ACTUAL_VERSION="$(az_value extensionVersion)"
if [ "$ACTUAL_NAME" != "$EXTENSION_NAME" ]; then
  echo "ERROR: Installed extension name '$ACTUAL_NAME' is not '$EXTENSION_NAME'." >&2
  exit 1
fi
if [ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]; then
  echo "ERROR: Installed version '$ACTUAL_VERSION' does not match wheel '$EXPECTED_VERSION'." >&2
  exit 1
fi

echo "Installed '$EXTENSION_NAME' $ACTUAL_VERSION successfully."
echo "  $SOURCE_DESCRIPTION"
echo "  Wheel:  $WHEEL_NAME"
echo "Verify with: az sre version"
