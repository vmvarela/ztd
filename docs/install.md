# Install

## One-line installers

```bash
curl -fsSL https://raw.githubusercontent.com/vmvarela/ztd/master/install.sh | sh
```

```powershell
irm https://raw.githubusercontent.com/vmvarela/ztd/master/install.ps1 | iex
```

Both download the release asset for the current platform, verify it against
`sha256sums.txt`, and install to `~/.local/bin` (POSIX) or
`%LOCALAPPDATA%\ztd\bin` (Windows). Set `ZTD_INSTALL_DIR` to override.

## Assets

| Platform | Asset |
| --- | --- |
| Linux x86_64 | `ztd-x86_64-linux` |
| Linux aarch64 | `ztd-aarch64-linux` |
| Linux armv7 | `ztd-armv7-linux` |
| Linux riscv64 | `ztd-riscv64-linux` |
| Linux x86 | `ztd-x86-linux` |
| macOS x86_64 | `ztd-x86_64-macos` |
| macOS aarch64 | `ztd-aarch64-macos` |
| Windows x86_64 | `ztd-x86_64-windows.exe` |
| Windows aarch64 | `ztd-aarch64-windows.exe` |
| Windows x86 | `ztd-x86-windows.exe` |
| FreeBSD x86_64 | `ztd-x86_64-freebsd` |
| FreeBSD aarch64 | `ztd-aarch64-freebsd` |

## Homebrew

```bash
brew install vmvarela/tap/ztd
```

## WinGet

```powershell
winget install vmvarela.ztd
```

## Scoop

```powershell
scoop bucket add vmvarela https://github.com/vmvarela/scoop-bucket
scoop install ztd
```

## npm

```bash
npm install -g @vmvarela/ztd
```

The npm package selects the right binary for Linux, macOS or Windows.

## Debian / Ubuntu

```bash
sudo add-apt-repository ppa:vmvarela/ztd
sudo apt install ztd
```

## Fedora / RHEL

```bash
sudo dnf install ztd
```

## Alpine

```bash
sudo apk add ztd
```

## Arch

```bash
yay -S ztd
```

## Nix

```bash
nix profile install github:vmvarela/nix-packages#ztd
```

## From source

```bash
zig build -Doptimize=ReleaseSafe -Dversion=0.1.0
install -m 0755 zig-out/bin/ztd ~/.local/bin/ztd
```

Requirements: Zig 0.17.0. No runtime dependencies.
