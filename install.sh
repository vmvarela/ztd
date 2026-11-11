#!/bin/sh
set -eu

REPO="vmvarela/ztd"
VERSION="${ZTD_VERSION:-latest}"
INSTALL_DIR="${ZTD_INSTALL_DIR:-$HOME/.local/bin}"

need() {
	command -v "$1" >/dev/null 2>&1 || {
		echo "ztd: missing $1" >&2
		exit 1
	}
}

need curl
need tar
need uname

if [ "$VERSION" = "latest" ]; then
	VERSION=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" |
		sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)
	[ -n "$VERSION" ] || {
		echo "ztd: could not resolve latest release" >&2
		exit 1
	}
fi

OS=$(uname -s)
ARCH=$(uname -m)

case "$OS" in
Linux)
	case "$ARCH" in
	x86_64 | amd64) ASSET="ztd-x86_64-linux" ;;
	aarch64 | arm64) ASSET="ztd-aarch64-linux" ;;
	armv7l | armv7) ASSET="ztd-armv7-linux" ;;
	riscv64) ASSET="ztd-riscv64-linux" ;;
	i386 | i686) ASSET="ztd-x86-linux" ;;
	*)
		echo "ztd: unsupported Linux architecture: $ARCH" >&2
		exit 1
		;;
	esac
	;;
Darwin)
	case "$ARCH" in
	x86_64 | amd64) ASSET="ztd-x86_64-macos" ;;
	aarch64 | arm64) ASSET="ztd-aarch64-macos" ;;
	*)
		echo "ztd: unsupported macOS architecture: $ARCH" >&2
		exit 1
		;;
	esac
	;;
FreeBSD)
	case "$ARCH" in
	x86_64 | amd64) ASSET="ztd-x86_64-freebsd" ;;
	aarch64 | arm64) ASSET="ztd-aarch64-freebsd" ;;
	*)
		echo "ztd: unsupported FreeBSD architecture: $ARCH" >&2
		exit 1
		;;
	esac
	;;
*)
	echo "ztd: unsupported operating system: $OS" >&2
	exit 1
	;;
esac

URL="https://github.com/$REPO/releases/download/$VERSION"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "ztd: downloading $ASSET $VERSION"
curl -fsSL "$URL/$ASSET" -o "$TMP/$ASSET"
curl -fsSL "$URL/sha256sums.txt" -o "$TMP/sha256sums.txt"

(
	cd "$TMP"
	if command -v sha256sum >/dev/null 2>&1; then
		grep " $ASSET\$" sha256sums.txt | sha256sum -c -
	else
		grep " $ASSET\$" sha256sums.txt | shasum -a 256 -c -
	fi
)

mkdir -p "$INSTALL_DIR"
install -m 0755 "$TMP/$ASSET" "$INSTALL_DIR/ztd"
echo "ztd: installed $INSTALL_DIR/ztd"
case ":$PATH:" in
*":$INSTALL_DIR:"*) ;;
*) echo "ztd: add $INSTALL_DIR to PATH" ;;
esac
