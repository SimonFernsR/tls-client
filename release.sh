#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly VERSION="${1:-}"
readonly REMOTE="${RELEASE_REMOTE:-origin}"
readonly XGO_VERSION="${XGO_VERSION:-v1.9.0}"
readonly GO_VERSION="${GO_VERSION:-go-1.24.1}"
readonly DIST_DIR="$SCRIPT_DIR/cffi_dist/dist"

usage() {
  echo "Usage: ./release.sh <version>" >&2
  echo "Example: ./release.sh 1.1.0" >&2
}

fail() {
  echo "error: $*" >&2
  exit 1
}

if [[ -z "$VERSION" || "$VERSION" == -* || $# -ne 1 ]]; then
  usage
  exit 2
fi

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]; then
  fail "version must look like 1.1.0 (do not include the leading v)"
fi

readonly TAG="v$VERSION"

for command_name in git go docker; do
  command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is required"
done

cd "$SCRIPT_DIR"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "run this script from a Git checkout"

if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
  fail "the Git worktree must be clean before creating a release"
fi

git remote get-url "$REMOTE" >/dev/null 2>&1 || fail "Git remote '$REMOTE' does not exist"
docker info >/dev/null 2>&1 || fail "Docker is not running"

temp_root="$(mktemp -d "${TMPDIR:-/tmp}/tls-client-release.XXXXXX")"
cleanup() {
  if [[ -n "${temp_root:-}" && -d "$temp_root" && "$(basename "$temp_root")" == tls-client-release.* ]]; then
    rm -rf -- "$temp_root"
  fi
}
trap cleanup EXIT

stage_dir="$temp_root/source"
tools_dir="$temp_root/bin"
stage_dist="$stage_dir/cffi_dist/dist"
mkdir -p "$stage_dir" "$tools_dir" "$stage_dist" "$DIST_DIR"

echo "==> Staging committed source at $(git rev-parse --short HEAD)"
git archive --format=tar HEAD | tar -xf - -C "$stage_dir"

# cffi_dist is normally its own module. For a release it is built as a package
# of the staged root module so every binary contains this exact checkout.
rm -f -- "$stage_dir/cffi_dist/go.mod" "$stage_dir/cffi_dist/go.sum"

if command -v xgo >/dev/null 2>&1; then
  xgo_bin="$(command -v xgo)"
else
  echo "==> Installing xgo $XGO_VERSION into the temporary tool directory"
  GOBIN="$tools_dir" go install "src.techknowlogick.com/xgo@$XGO_VERSION"
  xgo_bin="$tools_dir/xgo"
fi

xgo_assets=(
  "tls-client-xgo-$VERSION-darwin-amd64.dylib"
  "tls-client-xgo-$VERSION-darwin-arm64.dylib"
  "tls-client-xgo-$VERSION-linux-386.so"
  "tls-client-xgo-$VERSION-linux-amd64.so"
  "tls-client-xgo-$VERSION-linux-arm-5.so"
  "tls-client-xgo-$VERSION-linux-arm-6.so"
  "tls-client-xgo-$VERSION-linux-arm-7.so"
  "tls-client-xgo-$VERSION-linux-arm64.so"
  "tls-client-xgo-$VERSION-linux-ppc64le.so"
  "tls-client-xgo-$VERSION-linux-riscv64.so"
  "tls-client-xgo-$VERSION-linux-s390x.so"
  "tls-client-xgo-$VERSION-windows-386.dll"
  "tls-client-xgo-$VERSION-windows-amd64.dll"
)

native_assets=(
  "tls-client-darwin-amd64-$VERSION.dylib"
  "tls-client-darwin-arm64-$VERSION.dylib"
  "tls-client-linux-alpine-amd64-$VERSION.so"
  "tls-client-linux-arm64-$VERSION.so"
  "tls-client-linux-armv7-$VERSION.so"
  "tls-client-linux-ubuntu-amd64-$VERSION.so"
  "tls-client-windows-32-$VERSION.dll"
  "tls-client-windows-64-$VERSION.dll"
)

release_assets=("${native_assets[@]}" "${xgo_assets[@]}")

for asset in "${release_assets[@]}"; do
  rm -f -- "$DIST_DIR/$asset"
done

echo "==> Building the 13-target xgo matrix"
echo "==> Ensuring the amd64 xgo image is available (required for linux/386)"
docker pull --platform linux/amd64 "ghcr.io/techknowlogick/xgo:$GO_VERSION"
(
  cd "$stage_dir"
  "$xgo_bin" \
    -go "$GO_VERSION" \
    -dockerargs=--platform=linux/amd64 \
    -buildmode=c-shared \
    -buildvcs=false \
    -pkg ./cffi_dist \
    -targets=darwin/amd64,darwin/arm64,linux/386,linux/amd64,linux/arm-5,linux/arm-6,linux/arm-7,linux/arm64,linux/ppc64le,linux/riscv64,linux/s390x,windows/386,windows/amd64 \
    -out "cffi_dist/dist/tls-client-xgo-$VERSION" \
    .
)

echo "==> Building Linux amd64 glibc and musl variants"
docker run --rm --platform linux/amd64 \
  -v "$stage_dir:/source" \
  -w /source \
  golang:1.24.1-bookworm \
  sh -c "CGO_ENABLED=1 GOOS=linux GOARCH=amd64 go build -buildmode=c-shared -buildvcs=false -o cffi_dist/dist/tls-client-linux-ubuntu-amd64-$VERSION.so ./cffi_dist"

docker run --rm --platform linux/amd64 \
  -v "$stage_dir:/source" \
  -w /source \
  golang:1.24.1-alpine \
  sh -c "apk add --no-cache gcc musl-dev >/dev/null && CGO_ENABLED=1 GOOS=linux GOARCH=amd64 go build -buildmode=c-shared -buildvcs=false -o cffi_dist/dist/tls-client-linux-alpine-amd64-$VERSION.so ./cffi_dist"

echo "==> Creating the upstream-compatible native filenames"
cp "$stage_dist/tls-client-xgo-$VERSION-darwin-amd64.dylib" "$stage_dist/tls-client-darwin-amd64-$VERSION.dylib"
cp "$stage_dist/tls-client-xgo-$VERSION-darwin-arm64.dylib" "$stage_dist/tls-client-darwin-arm64-$VERSION.dylib"
cp "$stage_dist/tls-client-xgo-$VERSION-linux-arm64.so" "$stage_dist/tls-client-linux-arm64-$VERSION.so"
cp "$stage_dist/tls-client-xgo-$VERSION-linux-arm-7.so" "$stage_dist/tls-client-linux-armv7-$VERSION.so"
cp "$stage_dist/tls-client-xgo-$VERSION-windows-386.dll" "$stage_dist/tls-client-windows-32-$VERSION.dll"
cp "$stage_dist/tls-client-xgo-$VERSION-windows-amd64.dll" "$stage_dist/tls-client-windows-64-$VERSION.dll"

echo "==> Verifying and collecting 21 release assets"
for asset in "${release_assets[@]}"; do
  [[ -s "$stage_dist/$asset" ]] || fail "missing or empty build artifact: $asset"
  cp "$stage_dist/$asset" "$DIST_DIR/$asset"
done

actual_count=0
for asset in "${release_assets[@]}"; do
  [[ -s "$DIST_DIR/$asset" ]] || fail "failed to collect artifact: $asset"
  actual_count=$((actual_count + 1))
done
[[ "$actual_count" -eq 21 ]] || fail "expected 21 artifacts, found $actual_count"

if command -v shasum >/dev/null 2>&1; then
  (cd "$DIST_DIR" && shasum -a 256 "${release_assets[@]}")
elif command -v sha256sum >/dev/null 2>&1; then
  (cd "$DIST_DIR" && sha256sum "${release_assets[@]}")
fi

if [[ "${RELEASE_BUILD_ONLY:-0}" == "1" ]]; then
  echo "==> Build complete: $DIST_DIR"
  exit 0
fi

command -v gh >/dev/null 2>&1 || fail "gh is required to publish the release"
gh auth status -h github.com >/dev/null 2>&1 || fail "GitHub CLI is not authenticated; run: gh auth login -h github.com"

release_repo="${RELEASE_REPO:-}"
if [[ -z "$release_repo" ]]; then
  release_repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
fi

branch="$(git symbolic-ref --quiet --short HEAD)" || fail "releases cannot be created from a detached HEAD"

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  [[ "$(git rev-list -n 1 "$TAG")" == "$(git rev-parse HEAD)" ]] || fail "$TAG already exists at another commit"
else
  git tag -a "$TAG" -m "$TAG"
fi

echo "==> Pushing $branch and $TAG to $REMOTE"
git push "$REMOTE" "HEAD:$branch"
git push "$REMOTE" "refs/tags/$TAG"

asset_paths=()
for asset in "${release_assets[@]}"; do
  asset_paths+=("$DIST_DIR/$asset")
done

echo "==> Publishing $TAG to $release_repo"
if gh release view "$TAG" --repo "$release_repo" >/dev/null 2>&1; then
  gh release upload "$TAG" "${asset_paths[@]}" --repo "$release_repo" --clobber
  gh release edit "$TAG" --repo "$release_repo" --title "$TAG"
else
  gh release create "$TAG" "${asset_paths[@]}" \
    --repo "$release_repo" \
    --verify-tag \
    --title "$TAG" \
    --generate-notes
fi

echo "==> Release published: $(gh release view "$TAG" --repo "$release_repo" --json url --jq .url)"
