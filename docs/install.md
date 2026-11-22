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

On macOS arm64, the POSIX installer re-signs the copied binary ad hoc
(`codesign --force --sign -`). Without that step macOS kills the copied
binary with exit code 137.

## Assets

Every release ships `sha256sums.txt` covering all binaries below.

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

`ztd-riscv64-linux` is built best-effort: if that cross-build fails, the
asset is omitted from the release and `sha256sums.txt` covers only what was
published.

## From source

Requires Go 1.27.4. No runtime dependencies; release binaries are built with
`CGO_ENABLED=0`.

```bash
go build -o ztd ./cmd/ztd
install -m 0755 ztd ~/.local/bin/ztd
```

## Package managers

Homebrew, WinGet, Scoop, npm, Debian, RPM, APK, AUR and Nix packaging still
describe the legacy Zig release and are a follow-up; see
[packaging/README.md](../packaging/README.md). The current Go release
workflow publishes only the binaries above and `sha256sums.txt`.

## First run

```bash
ztd --db ~/.ztd/ztd.db init
```

`init` creates the database (default `ZTD_DB` or `~/.ztd/ztd.db`; pass
`--db` to choose another file) and, on a terminal, asks for the actor and
scopes and shows a summary before it writes. In scripts pass `--actor` and
`--scope id=…,kind=…` explicitly.

## OpenCode integration

The Go binary does not implement `ztd install opencode` yet. Copy
`integrations/opencode/` (skills and commands) into your OpenCode
configuration manually until that command is ported. `ztd install templates`
is not implemented either; method templates live in `method/`.
