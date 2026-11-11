# Packaging

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

- `packaging/nfpm.yaml` — deb, rpm and apk layout (binary + license).
- `packaging/npm/` — npm wrapper and platform binary map.
- `docs/ztd.1.scd` — manual page source; generate with `scdoc < docs/ztd.1.scd > ztd.1`.

## Release checklist

1. `zig build test` and `bash test/integration.sh`.
2. Tag `vX.Y.Z`.
3. Wait for the draft release; verify `sha256sums.txt` covers every asset.
4. Publish the release.
5. Check `brew`, `scoop`, `winget`, `npm`, `apt`, `dnf`, `apk`, `yay` and
   `nix profile install` on a clean machine.
