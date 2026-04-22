#!/bin/bash

set -euo pipefail

UPSTREAM="https://downloads.claude.ai/claude-code-releases"
GITHUB_REPO="iRubbish/ClaudecodeCN"
PLATFORMS=("darwin-arm64" "darwin-x64" "linux-x64" "linux-arm64" "linux-x64-musl" "linux-arm64-musl")
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMP_DIR=""

cleanup() { [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT

die() { echo "ERROR: $*" >&2; exit 1; }

for cmd in curl gh jq sha256sum; do
    if [ "$cmd" = "sha256sum" ] && command -v shasum >/dev/null 2>&1; then continue; fi
    command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required"
done

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# PLACEHOLDER_SYNC_LOGIC

echo "==> Fetching latest version from upstream..."
remote_version=$(curl -fsSL "$UPSTREAM/latest" | tr -d '[:space:]')
[ -z "$remote_version" ] && die "Failed to fetch upstream version"
echo "    Upstream version: $remote_version"

tag="v${remote_version}"
if gh release view "$tag" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
    echo "==> Release $tag already exists, nothing to do."
    exit 0
fi

echo "==> New version detected: $remote_version"
TMP_DIR=$(mktemp -d)

echo "==> Downloading manifest.json..."
curl -fsSL -o "$TMP_DIR/manifest.json" "$UPSTREAM/$remote_version/manifest.json"

echo "==> Downloading binaries for all platforms..."
fail=0
for p in "${PLATFORMS[@]}"; do
    echo "    Downloading $p..."
    if ! curl -fsSL -o "$TMP_DIR/claude-${p}" "$UPSTREAM/$remote_version/$p/claude"; then
        echo "    WARN: Failed to download $p, skipping"
        rm -f "$TMP_DIR/claude-${p}"
        fail=$((fail + 1))
        continue
    fi

    expected=$(jq -r ".platforms[\"$p\"].checksum // empty" "$TMP_DIR/manifest.json")
    if [ -z "$expected" ]; then
        echo "    WARN: No checksum for $p in manifest, skipping"
        rm -f "$TMP_DIR/claude-${p}"
        fail=$((fail + 1))
        continue
    fi

    actual=$(sha256 "$TMP_DIR/claude-${p}")
    if [ "$actual" != "$expected" ]; then
        echo "    WARN: Checksum mismatch for $p (expected=$expected actual=$actual)"
        rm -f "$TMP_DIR/claude-${p}"
        fail=$((fail + 1))
        continue
    fi
    echo "    $p OK (sha256 verified)"
done

assets=("$TMP_DIR/manifest.json")
for p in "${PLATFORMS[@]}"; do
    [ -f "$TMP_DIR/claude-${p}" ] && assets+=("$TMP_DIR/claude-${p}")
done

if [ ${#assets[@]} -le 1 ]; then
    die "No binaries downloaded successfully, aborting release"
fi

echo "==> Creating GitHub Release $tag..."
gh release create "$tag" \
    --repo "$GITHUB_REPO" \
    --title "Claude Code $remote_version" \
    --notes "Synced from upstream. Platforms: ${PLATFORMS[*]}" \
    "${assets[@]}"

echo "==> Updating latest_version..."
echo "$remote_version" > "$SCRIPT_DIR/latest_version"

if [ -d "$SCRIPT_DIR/.git" ]; then
    cd "$SCRIPT_DIR"
    git add latest_version
    if ! git diff --cached --quiet; then
        git commit -m "chore: update latest_version to $remote_version"
        git push
    fi
fi

echo "==> Done! Released $tag with $((${#assets[@]} - 1)) platform binaries."
if [ "$fail" -gt 0 ]; then
    echo "    WARNING: $fail platform(s) failed to sync."
fi
