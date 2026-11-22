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

`ztd-riscv64-linux` is built and checksummed like every other target.

## From source

Requires Go 1.27.4. No runtime dependencies; release binaries are built with
`CGO_ENABLED=0`.

```bash
go build -o ztd ./cmd/ztd
install -m 0755 ztd ~/.local/bin/ztd
```

## Packages, npm and the man page

Every release also ships `ztd.1.gz`, the gzipped `ztd(1)` man page
(source: [docs/ztd.1.scd](ztd.1.scd)), and publishes:

- `.deb` (amd64, arm64, armhf, i386), `.rpm` (x86_64, aarch64) and `.apk`
  (x86_64, aarch64) packages built with nfpm 2.45.1 from
  [packaging/nfpm.yaml](../packaging/nfpm.yaml): binary, man page and
  license. They are covered by `sha256sums.txt` like every other asset.
- The npm package `@vmvarela/ztd`, which picks the right platform binary
  behind a Node wrapper. The first publish is manual; afterwards the
  release workflow publishes when the `NPM_TRUSTED_PUBLISHING` repository
  variable is `true` (npm Trusted Publishing via OIDC, with `NPM_TOKEN` as
  the fallback).
- A Homebrew formula in `vmvarela/homebrew-tap` (macOS/Linux binaries plus
  the man page), Scoop, WinGet, AUR, Nix, and the APT/RPM/APK channel
  repositories.

Nothing goes public before `publish-release` verifies every draft asset
against `sha256sums.txt`; channel jobs whose secret is missing are skipped
and the binary release still succeeds. Secrets, repository paths and the
full job graph are documented in
[packaging/README.md](../packaging/README.md).

## First run

```bash
ztd --db ~/.ztd/ztd.db init
```

`init` creates the database (default `ZTD_DB` or `~/.ztd/ztd.db`; pass
`--db` to choose another file) and, on a terminal, asks for the actor and
scopes and shows a summary before it writes. In scripts pass `--actor` and
`--scope id=…,kind=…` explicitly.

## OpenCode integration

After installing the binary, publish the embedded assets:

```bash
ztd install opencode     # → ~/.config/opencode/{skills,commands}
ztd install templates    # → <store root>/templates/ (the directory of --db)
```

Both preflight the complete bundle before writing and refuse to overwrite a
file you edited, so an edited skill or template is a conflict and nothing is
written. `install templates` requires an existing store root (`ztd init`);
`--dry-run` reports the counts without writing. See the
[OpenCode adapter](../integrations/opencode/README.md) for the details.
