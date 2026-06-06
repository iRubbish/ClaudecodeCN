#!/bin/bash

set -e

usage() {
    echo "Usage: $0 [stable|latest|VERSION|update]" >&2
    exit 1
}

TARGET="${1:-}"
UPDATE_MODE=false

[ "$#" -le 1 ] || usage
if [ "$TARGET" = "update" ]; then
    UPDATE_MODE=true
    TARGET="latest"
fi

[[ -z "$TARGET" || "$TARGET" =~ ^(stable|latest|[0-9]+\.[0-9]+\.[0-9]+(-[^[:space:]]+)?)$ ]] || usage

# ============================================================
# GitHub Mirror Configuration
# ============================================================
GITHUB_REPO="iRubbish/ClaudecodeCN"
RAW_BASE="https://raw.githubusercontent.com/${GITHUB_REPO}/main"
RELEASE_BASE="https://github.com/${GITHUB_REPO}/releases/download"

DEFAULT_MIRROR_PREFIXES=(
    "https://ghfast.top/"
    "https://gh-proxy.com/"
    ""
)
MIRROR_PREFIXES=()

normalize_mirror_prefix() {
    local prefix="${1:-}"
    case "$prefix" in
        ""|direct|github|none) echo "" ;;
        *) echo "${prefix%/}/" ;;
    esac
}

add_mirror_prefix() {
    local prefix existing
    prefix="$(normalize_mirror_prefix "$1")"
    for existing in "${MIRROR_PREFIXES[@]}"; do
        [ "$existing" = "$prefix" ] && return 0
    done
    MIRROR_PREFIXES+=("$prefix")
}

# Optional preferred mirror. Example:
#   CC_MIRROR=https://gh-proxy.com  ... | bash
#   CC_MIRROR=direct                ... | bash
if [ -n "${CC_MIRROR:-}" ]; then
    add_mirror_prefix "$CC_MIRROR"
fi
for prefix in "${DEFAULT_MIRROR_PREFIXES[@]}"; do
    add_mirror_prefix "$prefix"
done

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
            curl -fSL --http1.1 --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 10 --progress-bar -o "$output" "$url"
        else
            curl -fsSL --http1.1 --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 10 "$url"
        fi
    else
        if [ -n "$output" ]; then
            wget --connect-timeout=10 --read-timeout=30 --tries=3 --waitretry=2 --retry-connrefused --show-progress -O "$output" "$url" 2>&1
        else
            wget -q --connect-timeout=10 --read-timeout=30 --tries=3 --waitretry=2 --retry-connrefused -O - "$url"
        fi
    fi
}

mirror_label() {
    local prefix="$1"
    if [ -n "$prefix" ]; then
        echo "${prefix%%/}"
    else
        echo "direct GitHub"
    fi
}

get_raw_url()     { echo "${1}${RAW_BASE}/$2"; }
get_release_url() { echo "${1}${RELEASE_BASE}/$2"; }

get_checksum_from_manifest() {
    local json="$1"
    local platform="$2"
    json=$(echo "$json" | tr -d '\n\r\t' | sed 's/ \+/ /g')
    if [[ "$json" =~ \"$platform\"[^}]*\"checksum\"[[:space:]]*:[[:space:]]*\"([a-f0-9]{64})\" ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

extract_checksum() {
    local json="$1"
    local platform="$2"
    local value=""
    if [ "$HAS_JQ" = true ]; then
        if value=$(printf '%s' "$json" | jq -er ".platforms[\"$platform\"].checksum // empty" 2>/dev/null) &&
            [[ "$value" =~ ^[a-f0-9]{64}$ ]]; then
            echo "$value"
            return 0
        fi
    elif value=$(get_checksum_from_manifest "$json" "$platform") &&
        [[ "$value" =~ ^[a-f0-9]{64}$ ]]; then
        echo "$value"
        return 0
    fi
    return 1
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# ============================================================
# Download helpers: try every mirror in order, fail only if all fail
# ============================================================
download_latest_version_with_fallback() {
    local prefix url content candidate
    for prefix in "${MIRROR_PREFIXES[@]}"; do
        url="$(get_raw_url "$prefix" latest_version)"
        echo "Fetching latest_version from $(mirror_label "$prefix")..." >&2
        if content="$(download_file "$url" "")"; then
            candidate="$(printf '%s' "$content" | tr -d '[:space:]')"
            if [[ "$candidate" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[^[:space:]]+)?$ ]]; then
                printf '%s\n' "$candidate"
                return 0
            fi
            echo "  Invalid latest_version from $(mirror_label "$prefix")" >&2
        else
            echo "  Failed to fetch latest_version from $(mirror_label "$prefix")" >&2
        fi
    done
    return 1
}

download_manifest_with_fallback() {
    local release_path="$1"
    local prefix url content value
    checksum=""
    for prefix in "${MIRROR_PREFIXES[@]}"; do
        url="$(get_release_url "$prefix" "$release_path")"
        echo "Fetching manifest from $(mirror_label "$prefix")..." >&2
        if content="$(download_file "$url" "")"; then
            if value="$(extract_checksum "$content" "$platform")"; then
                checksum="$value"
                echo "Using manifest from $(mirror_label "$prefix")"
                return 0
            fi
            echo "  Manifest from $(mirror_label "$prefix") has no valid checksum for $platform" >&2
        else
            echo "  Failed to fetch manifest from $(mirror_label "$prefix")" >&2
        fi
    done
    return 1
}

download_binary_with_fallback() {
    local release_path="$1"
    local output="$2"
    local expected="$3"
    local tmp_path="${output}.part"
    local prefix url actual
    rm -f "$output" "$tmp_path"
    for prefix in "${MIRROR_PREFIXES[@]}"; do
        url="$(get_release_url "$prefix" "$release_path")"
        echo "Downloading claude ($platform) from $(mirror_label "$prefix")..."
        rm -f "$tmp_path"
        if ! download_file "$url" "$tmp_path"; then
            echo "  Download failed from $(mirror_label "$prefix")" >&2
            rm -f "$tmp_path"
            continue
        fi
        actual="$(sha256_file "$tmp_path")"
        if [ "$actual" != "$expected" ]; then
            echo "  Checksum verification failed from $(mirror_label "$prefix")" >&2
            rm -f "$tmp_path"
            continue
        fi
        if mv "$tmp_path" "$output"; then
            return 0
        fi
        echo "  Failed to finalize download from $(mirror_label "$prefix")" >&2
        rm -f "$tmp_path" "$output"
    done
    rm -f "$tmp_path" "$output"
    return 1
}

# ============================================================
# Optional: inject third-party API config into ~/.claude/settings.json
# ============================================================
find_python() {
    if command -v python3 >/dev/null 2>&1; then
        command -v python3
    elif command -v python >/dev/null 2>&1; then
        command -v python
    else
        return 1
    fi
}

merge_api_settings() {
    local base_url="$1"
    local auth_token="$2"
    local settings_dir="$HOME/.claude"
    local settings_file="$settings_dir/settings.json"
    local tmp_dir values_file input_file output_file patch_file python_bin

    # Token is a secret; create every file in this function as 0600 from birth so
    # it can never land world-readable if a later chmod is suppressed. This is the
    # last step of the script, so the umask need not be restored.
    umask 077

    mkdir -p "$settings_dir" || return 1
    # Temp dir on the same filesystem as settings.json so mv is atomic.
    tmp_dir="$(mktemp -d "$settings_dir/.settings.tmp.XXXXXX")" || return 1
    chmod 700 "$tmp_dir" 2>/dev/null || true
    values_file="$tmp_dir/values"
    input_file="$tmp_dir/input.json"
    output_file="$tmp_dir/settings.json"
    patch_file="$tmp_dir/env.json"

    # Pass secrets via file (chmod 600), never via argv (visible in ps).
    { printf '%s\n' "$base_url"; printf '%s\n' "$auth_token"; } > "$values_file" || {
        rm -rf "$tmp_dir"; return 1
    }
    chmod 600 "$values_file" 2>/dev/null || true

    if [ -f "$settings_file" ]; then
        cp "$settings_file" "$input_file" || { rm -rf "$tmp_dir"; return 1; }
    else
        printf '{}\n' > "$input_file" || { rm -rf "$tmp_dir"; return 1; }
    fi

    if [ "$HAS_JQ" = true ]; then
        if jq -Rn '[inputs] as $v | {"ANTHROPIC_BASE_URL": ($v[0] // ""), "ANTHROPIC_AUTH_TOKEN": ($v[1] // "")}' < "$values_file" > "$patch_file" 2>/dev/null &&
            jq -S --slurpfile envpatch "$patch_file" '
                if type != "object" then
                    error("settings root must be an object")
                elif (.env? != null and (.env | type) != "object") then
                    error("settings env must be an object")
                else
                    .env = ((.env // {}) + $envpatch[0])
                end
            ' "$input_file" > "$output_file" 2>/dev/null; then
            chmod 600 "$output_file" 2>/dev/null || true
            if mv "$output_file" "$settings_file"; then
                rm -rf "$tmp_dir"
                return 0
            fi
        fi
    fi

    python_bin="$(find_python || true)"
    if [ -n "$python_bin" ]; then
        if "$python_bin" - "$input_file" "$output_file" "$values_file" >/dev/null 2>&1 <<'PY'
import json
import sys

input_path, output_path, values_path = sys.argv[1:4]
with open(values_path, "r", encoding="utf-8") as f:
    values = f.read().splitlines()
if len(values) < 2:
    raise SystemExit("missing API settings values")

base_url, auth_token = values[0], values[1]
with open(input_path, "r", encoding="utf-8") as f:
    data = json.load(f)

if not isinstance(data, dict):
    raise SystemExit("settings root must be an object")

env = data.get("env", {})
if env is None:
    env = {}
if not isinstance(env, dict):
    raise SystemExit("settings env must be an object")

env.update({
    "ANTHROPIC_BASE_URL": base_url,
    "ANTHROPIC_AUTH_TOKEN": auth_token,
})
data["env"] = env

with open(output_path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2, sort_keys=True)
    f.write("\n")
PY
        then
            chmod 600 "$output_file" 2>/dev/null || true
            if mv "$output_file" "$settings_file"; then
                rm -rf "$tmp_dir"
                return 0
            fi
        fi
    fi

    rm -rf "$tmp_dir"
    return 1
}

prompt_api_settings() {
    local base_url auth_token

    [ "$UPDATE_MODE" = false ] || return 0

    # curl | bash consumes stdin for the script body, so read from the controlling
    # terminal. Open it via fd 3: this fails cleanly when there is no controlling
    # terminal (CI / detached), unlike a -r/-w test on the 0666 /dev/tty node.
    if ! exec 3<>/dev/tty; then
        echo "API config skipped: no interactive terminal."
        return 0
    fi

    printf '\n' >&3
    echo "Optional: configure third-party API in ~/.claude/settings.json" >&3
    printf "ANTHROPIC_BASE_URL (leave empty to skip): " >&3
    if ! IFS= read -r base_url <&3 || [ -z "$base_url" ]; then
        exec 3<&-
        echo "API config skipped."
        return 0
    fi

    printf "ANTHROPIC_AUTH_TOKEN: " >&3
    if ! IFS= read -r -s auth_token <&3; then
        printf '\n' >&3
        exec 3<&-
        echo "API config skipped."
        return 0
    fi
    printf '\n' >&3
    exec 3<&-

    if [ -z "$auth_token" ]; then
        echo "API config skipped: empty auth token."
        return 0
    fi

    if merge_api_settings "$base_url" "$auth_token"; then
        echo "API config written to ~/.claude/settings.json"
    else
        echo "WARNING: install succeeded, but settings.json could not be safely merged." >&2
    fi
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

echo "Mirror order:"
for prefix in "${MIRROR_PREFIXES[@]}"; do
    echo "  - $(mirror_label "$prefix")"
done

# ============================================================
# Resolve version
# ============================================================
if [ -n "$TARGET" ] && [ "$TARGET" != "latest" ] && [ "$TARGET" != "stable" ]; then
    version="$TARGET"
    echo "Requested version: $version"
else
    if ! version="$(download_latest_version_with_fallback)"; then
        echo "Failed to fetch latest version from all mirrors" >&2
        exit 1
    fi
    echo "Latest version: $version"
fi

# ============================================================
# Download manifest and resolve checksum
# ============================================================
if ! download_manifest_with_fallback "v${version}/manifest.json"; then
    echo "Failed to fetch a valid manifest for $platform from all mirrors" >&2
    exit 1
fi

# ============================================================
# Download binary from GitHub Release (per-mirror checksum verification)
# ============================================================
binary_path="$DOWNLOAD_DIR/claude-$version-$platform"
if ! download_binary_with_fallback "v${version}/claude-${platform}" "$binary_path" "$checksum"; then
    echo "Download failed from all mirrors" >&2
    exit 1
fi

chmod +x "$binary_path"

echo "Setting up Claude Code..."
INSTALL_DIR="$HOME/.local/share/claude/versions"
BIN_DIR="$HOME/.local/bin"
mkdir -p "$INSTALL_DIR" "$BIN_DIR"

cp "$binary_path" "$INSTALL_DIR/$version"
chmod +x "$INSTALL_DIR/$version"
ln -sf "$INSTALL_DIR/$version" "$BIN_DIR/claude"

# ============================================================
# Add to PATH if not already present
# ============================================================
user_shell="$(basename "${SHELL:-/bin/sh}")"
SHELL_RC=""

case "$user_shell" in
    zsh)  SHELL_RC="$HOME/.zshrc" ;;
    bash)
        if [ "$os" = "darwin" ]; then
            SHELL_RC="$HOME/.bash_profile"
        else
            SHELL_RC="$HOME/.bashrc"
        fi
        ;;
    fish) SHELL_RC="$HOME/.config/fish/config.fish" ;;
esac

# Only write to rc file if .local/bin is not already configured there
PATH_WRITTEN=false
if [ -n "$SHELL_RC" ] && ! grep -qF '.local/bin' "$SHELL_RC" 2>/dev/null; then
    if [ "$user_shell" = "fish" ]; then
        mkdir -p "$(dirname "$SHELL_RC")"
        echo 'fish_add_path $HOME/.local/bin' >> "$SHELL_RC"
    else
        echo 'export PATH=$HOME/.local/bin:$PATH' >> "$SHELL_RC"
    fi
    PATH_WRITTEN=true
fi

# Make claude available in the current process immediately
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) export PATH="$BIN_DIR:$PATH" ;;
esac

rm -f "$binary_path"

echo ""
if [ "$UPDATE_MODE" = true ]; then
    echo "Update complete!"
else
    echo "Installation complete!"
fi
echo "  Version:  $version"
echo "  Location: $BIN_DIR/claude"
if [ "$PATH_WRITTEN" = true ]; then
    echo "  PATH:     added to $SHELL_RC"
fi
if claude --version >/dev/null 2>&1; then
    echo "  Verify:   $(claude --version)"
fi
echo ""

# API config is an optional best-effort step; never let it abort a successful install.
prompt_api_settings || true

if [ -n "$SHELL_RC" ]; then
    printf "\033[1;33m%s\033[0m\n" ">>> Run this command to activate claude / 运行以下命令以激活 claude <<<"
    echo ""
    printf "  \033[1;32msource %s && claude\033[0m\n" "$SHELL_RC"
    echo ""
fi
