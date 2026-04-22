#!/bin/bash

set -e

TARGET="$1"

if [[ -n "$TARGET" ]] && [[ ! "$TARGET" =~ ^(stable|latest|[0-9]+\.[0-9]+\.[0-9]+(-[^[:space:]]+)?)$ ]]; then
    echo "Usage: $0 [stable|latest|VERSION]" >&2
    exit 1
fi

# ============================================================
# GitHub Mirror Configuration
# ============================================================
GITHUB_REPO="iRubbish/ClaudecodeCN"
RAW_BASE="https://raw.githubusercontent.com/${GITHUB_REPO}/main"
RELEASE_BASE="https://github.com/${GITHUB_REPO}/releases/download"

MIRROR_PREFIXES=(
    "https://ghfast.top/"
    "https://gh-proxy.com/"
    ""
)

DOWNLOAD_DIR="$HOME/.claude/downloads"

DOWNLOADER=""
if command -v curl >/dev/null 2>&1; then
    DOWNLOADER="curl"
elif command -v wget >/dev/null 2>&1; then
    DOWNLOADER="wget"
else
    echo "Either curl or wget is required but neither is installed" >&2
    exit 1
fi

HAS_JQ=false
if command -v jq >/dev/null 2>&1; then
    HAS_JQ=true
fi

download_file() {
    local url="$1"
    local output="$2"
    if [ "$DOWNLOADER" = "curl" ]; then
        if [ -n "$output" ]; then
            curl -fsSL --connect-timeout 10 -o "$output" "$url"
        else
            curl -fsSL --connect-timeout 10 "$url"
        fi
    else
        if [ -n "$output" ]; then
            wget -q --timeout=10 -O "$output" "$url"
        else
            wget -q --timeout=10 -O - "$url"
        fi
    fi
}

# ============================================================
# Mirror probe: find the fastest working prefix
# ============================================================
MIRROR_PREFIX=""
probe_url_raw="${RAW_BASE}/latest_version"

echo "Detecting fastest mirror..."
for prefix in "${MIRROR_PREFIXES[@]}"; do
    if download_file "${prefix}${probe_url_raw}" /dev/null 2>/dev/null; then
        MIRROR_PREFIX="$prefix"
        if [ -n "$prefix" ]; then
            echo "Using mirror: ${prefix%%/}"
        else
            echo "Using direct GitHub access"
        fi
        break
    fi
done

get_raw_url()    { echo "${MIRROR_PREFIX}${RAW_BASE}/$1"; }
get_release_url() { echo "${MIRROR_PREFIX}${RELEASE_BASE}/$1"; }

get_checksum_from_manifest() {
    local json="$1"
    local platform="$2"
    json=$(echo "$json" | tr -d '\n\r\t' | sed 's/ \+/ /g')
    if [[ $json =~ \"$platform\"[^}]*\"checksum\"[[:space:]]*:[[:space:]]*\"([a-f0-9]{64})\" ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

# ============================================================
# Detect platform
# ============================================================
case "$(uname -s)" in
    Darwin) os="darwin" ;;
    Linux) os="linux" ;;
    MINGW*|MSYS*|CYGWIN*) echo "Windows is not supported. See https://code.claude.com/docs" >&2; exit 1 ;;
    *) echo "Unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac

case "$(uname -m)" in
    x86_64|amd64) arch="x64" ;;
    arm64|aarch64) arch="arm64" ;;
    *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

if [ "$os" = "darwin" ] && [ "$arch" = "x64" ]; then
    if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" = "1" ]; then
        arch="arm64"
    fi
fi

if [ "$os" = "linux" ]; then
    if [ -f /lib/libc.musl-x86_64.so.1 ] || [ -f /lib/libc.musl-aarch64.so.1 ] || ldd /bin/ls 2>&1 | grep -q musl; then
        platform="linux-${arch}-musl"
    else
        platform="linux-${arch}"
    fi
else
    platform="${os}-${arch}"
fi

mkdir -p "$DOWNLOAD_DIR"

# ============================================================
# Resolve version
# ============================================================
version=$(download_file "$(get_raw_url latest_version)")
version=$(echo "$version" | tr -d '[:space:]')

if [ -z "$version" ]; then
    echo "Failed to fetch latest version" >&2
    exit 1
fi
echo "Latest version: $version"

# ============================================================
# Download manifest and verify checksum
# ============================================================
manifest_json=$(download_file "$(get_release_url "v${version}/manifest.json")")

if [ "$HAS_JQ" = true ]; then
    checksum=$(echo "$manifest_json" | jq -r ".platforms[\"$platform\"].checksum // empty")
else
    checksum=$(get_checksum_from_manifest "$manifest_json" "$platform")
fi

if [ -z "$checksum" ] || [[ ! "$checksum" =~ ^[a-f0-9]{64}$ ]]; then
    echo "Platform $platform not found in manifest" >&2
    exit 1
fi

# ============================================================
# Download binary from GitHub Release
# ============================================================
binary_path="$DOWNLOAD_DIR/claude-$version-$platform"
echo "Downloading claude ($platform)..."
if ! download_file "$(get_release_url "v${version}/claude-${platform}")" "$binary_path"; then
    echo "Download failed" >&2
    rm -f "$binary_path"
    exit 1
fi

if [ "$os" = "darwin" ]; then
    actual=$(shasum -a 256 "$binary_path" | cut -d' ' -f1)
else
    actual=$(sha256sum "$binary_path" | cut -d' ' -f1)
fi

if [ "$actual" != "$checksum" ]; then
    echo "Checksum verification failed" >&2
    rm -f "$binary_path"
    exit 1
fi

chmod +x "$binary_path"

echo "Setting up Claude Code..."
"$binary_path" install ${TARGET:+"$TARGET"}

rm -f "$binary_path"

echo ""
echo "Installation complete!"
echo ""
