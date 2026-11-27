#!/bin/bash
# Install a pinned, checksummed cosign release binary into /usr/local/bin.
#
# Downloaded from the release page and checked against a pinned SHA-256 rather
# than installed through sigstore's own action: a job that signs images is the
# last place to run code from a moving tag. cosign is the one tool not pinned
# in a Dockerfile of tool images (../install-tools/Dockerfile), because it is
# what checks those images' signatures, so nothing there can vouch for it.
# That also makes it the one pin Dependabot doesn't update: to upgrade, change
# all three defaults below, taking the hashes for cosign-linux-amd64 and
# cosign-linux-arm64 from the release's cosign_checksums.txt asset.
#
# A script rather than only the action's steps, so install-tools can run it
# from beside itself ($GITHUB_ACTION_PATH/../install-cosign), which works the
# same whether the actions are local or another repository's. RUNNER_ARCH
# (X64 or ARM64) picks the build; outside Actions, uname -m does.
set -euo pipefail

COSIGN_VERSION=${COSIGN_VERSION:-v3.1.6}
COSIGN_SHA256_AMD64=${COSIGN_SHA256_AMD64:-318a99ade4156a0c4113aa983b46c0a0830fa7896a096c63121ee47b610a94c6}
COSIGN_SHA256_ARM64=${COSIGN_SHA256_ARM64:-bbb2ebc765f483cf9fac42da8763dddc2b55b350ee12ea0c44a520a6d6d52334}

case ${RUNNER_ARCH:-$(uname -m)} in
	X64 | x86_64 | amd64)   arch=amd64; sha=$COSIGN_SHA256_AMD64 ;;
	ARM64 | aarch64 | arm64) arch=arm64; sha=$COSIGN_SHA256_ARM64 ;;
	*) echo "install-cosign: no pinned cosign for ${RUNNER_ARCH:-$(uname -m)}" >&2; exit 1 ;;
esac

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
curl -fsSL -o "$tmp" \
	"https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-${arch}"
echo "${sha}  $tmp" | sha256sum -c -
sudo install -m 755 "$tmp" /usr/local/bin/cosign
cosign version
