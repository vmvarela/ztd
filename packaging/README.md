# Packaging

> **Legacy / follow-up:** the adapters documented here describe the Zig
> release. The Go release workflow (`.github/workflows/release.yml`)
> publishes only the native binaries and `sha256sums.txt`; re-enabling
> Homebrew, npm, APT, RPM, APK, Scoop, WinGet, AUR and Nix publishing is a
> follow-up, not part of the Go rewrite.

The release workflow in `.github/workflows/release.yml` builds 12 native
binaries, three package formats, and publishes to the external repositories
below.

## Secrets and variables

| Name | Used by | Scope |
| --- | --- | --- |
| `PACKAGE_DISTRIBUTION_TOKEN` | Homebrew, Scoop, WinGet, APT, RPM, APK, Nix | fine-grained PAT with `contents:write` on `homebrew-tap`, `scoop-bucket`, `nix-packages`, `apt-packages`, `rpm-packages`, `apk-packages`, and `public_repo` for WinGet |
| `PACKAGE_SSH_KEY` | AUR | private key authorized on aur.archlinux.org |
| `NPM_TRUSTED_PUBLISHING` (repository variable) | npm | set to `true` after configuring npm Trusted Publishing for `@vmvarela/ztd` |

Jobs whose secret is absent are skipped. The binary release still succeeds.

## External repositories

| Repository | Expected path |
| --- | --- |
| `vmvarela/homebrew-tap` | `Formula/ztd.rb` |
| `vmvarela/scoop-bucket` | `bucket/ztd.json` |
| `vmvarela/nix-packages` | `pkgs/ztd/{package.nix,versions.json}` |
| `vmvarela/apt-packages` | event `update-ztd` |
| `vmvarela/rpm-packages` | event `update-ztd` |
| `vmvarela/apk-packages` | event `update-ztd` |
| `microsoft/winget-pkgs` | initial `vmvarela.ztd` manifest submitted manually |
| AUR | `ztd` package, initial PKGBUILD submitted manually |

## Package files

- `packaging/nfpm.yaml` — deb, rpm and apk layout (binary + license); the
  man-page entry was dropped because the Go CLI has no man page yet.
- `packaging/npm/` — npm wrapper and platform binary map.

## Release checklist

1. `bash scripts/check.sh` (gofmt, vet, tests, race, integration, build).
2. Tag `vX.Y.Z`.
3. Wait for the draft release; verify `sha256sums.txt` covers every asset.
4. Publish the release.
5. Check the one-line installers on a clean machine.
