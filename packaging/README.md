# Packaging

The release workflow in `.github/workflows/release.yml` builds 12 native
binaries plus the `ztd.1.gz` man page, stages them as a draft, builds the
three package formats with nfpm, and publishes only after `sha256sums.txt`
verifies every asset. `.github/workflows/build-all.yml` cross-compiles the
same targets on every push and pull request (plus a best-effort NetBSD
smoke build).

## Secrets and variables

| Name | Used by | Scope |
| --- | --- | --- |
| `PACKAGE_DISTRIBUTION_TOKEN` | Homebrew, Scoop, WinGet, APT, RPM, APK, Nix | fine-grained PAT with `contents:write` on `homebrew-tap`, `scoop-bucket`, `nix-packages`, `apt-packages`, `rpm-packages`, `apk-packages`, and `public_repo` for WinGet |
| `PACKAGE_SSH_KEY` | AUR | private key authorized on aur.archlinux.org |
| `NPM_TRUSTED_PUBLISHING` (repository variable) | npm | the enable switch: set to `true` after the first manual publish of `@vmvarela/ztd` and after configuring npm Trusted Publishing for this repo + `release.yml` |
| `NPM_TOKEN` (optional secret) | npm | classic automation token used only when the OIDC publish fails |

Jobs whose secret is absent are skipped. The binary release still succeeds.

The first publish of `@vmvarela/ztd` is done manually once; from then on
`publish-npm` publishes each release (OIDC with provenance, token
fallback) while `NPM_TRUSTED_PUBLISHING` is `true`.

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

- `packaging/nfpm.yaml` — deb, rpm and apk layout: binary in `/usr/bin`,
  man page in `/usr/share/man/man1/`, license per packaging convention.
  The output names match the package-distribution catalog patterns
  (`ztd_{version}_{arch}.deb`, `ztd-{version}-1.{arch}.rpm`,
  `ztd_{version}_{arch}.apk`).
- `packaging/npm/` — npm wrapper and platform binary map for
  `@vmvarela/ztd`; the release workflow stages the six platform binaries
  it needs.
- `docs/ztd.1.scd` — man page source; `build-man` compiles it with
  `scdoc` and `gzip -9`.

## Release checklist

1. `bash scripts/check.sh` (gofmt, vet, tests, race, integration, build).
2. Tag `vX.Y.Z`.
3. CI stages the draft (binaries + man page), builds the deb/rpm/apk
   packages, requires the full asset set in `sha256sums.txt`, and
   publishes the release only after `sha256sum --check` and a file-set
   comparison pass.
4. CI then updates npm (once `NPM_TRUSTED_PUBLISHING` is `true`),
   Homebrew, AUR, WinGet, Scoop and the Nix/APT/RPM/APK channels; jobs
   whose secret is missing are skipped.
5. Check the one-line installers on a clean machine.
