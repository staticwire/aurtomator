---
title: Values from release asset names
---

Some upstreams put more than the version into release asset names and rebuild published releases under new names. `savonet/liquidsoap` publishes `liquidsoap_2.4.6-debian-forky-ocaml5.4.0-3_amd64.deb`: `debian-forky-ocaml5.4.0` names the build, and `3` is the Debian revision, which upstream raises when it rebuilds the same version. PKGBUILDs keep such values unquoted on lines of their own, and `upstream.asset_var` in the package YAML names the variable, `_deb` here:

```bash
pkgver=2.4.6
_deb=2.4.6-debian-forky-ocaml5.4.0-3
pkgrel=1
...
source_x86_64=("${_release}/liquidsoap_${_deb}_amd64.deb")
```

`upstream.asset_regex` is an ERE with exactly one capture group, matched against release asset names. `github-tag` and `github-release` take it:

```yaml
name: liquidsoap-bin
strategy: github-tag
upstream:
  project: savonet/liquidsoap
  tag_version_regex: '^v([0-9.]+(-rc[0-9]+)?)$'
  asset_regex: '^liquidsoap_([0-9.]+-debian-forky-ocaml5\.[0-9.]+-[0-9]+)_amd64\.deb$'
  asset_var: _deb
pkgver_dash: ''
```

The check takes the one tag that gives the version, as `github-tag` reads tags, and the release of that tag. Exactly one asset name must match `asset_regex`, and its capture group is the value. The regex above names the OCaml 5 build, because v2.4.6 also has an `ocaml4.14.2` asset and `ocaml[0-9.]+` would match both. Versions with no tag or two tags, two matching assets, and values with characters outside those below fail the check.

Upstream can push a tag before it publishes the release: liquidsoap uploads the assets to a draft, which the API shows only to users who can push, and published `v2.5.0-rc1` 40 minutes after its tag. Releases without matching assets wait 24 hours from their `published_at`, and tags without releases 24 hours from the tagger date of an annotated tag or the commit date of a lightweight one, with status `pending`. After that the check fails and names the release assets. Tag and commit dates more than 24 hours after the run fail the check at once.

For packages at `current`, values other than `current_asset` are rebuilds of that version. YAML files without `current_asset` get it in their first run, with no push when the AUR already has the value.

| Status | README | Meaning |
|---|---|---|
| `pending: 2.5.0rc1` | `⏳ 2.5.0rc1 pending` | release or its asset is not out yet, and no issue opens |
| `new_build: 2.4.6` | `🔨 2.4.6 rebuild available` | new value for the AUR version, pushed next |
| `rebuilt: 2.4.6` | `🔨 2.4.6 rebuilt` | rebuild pushed |

None of the three counts as a failure on the [statistics](/features/statistics/) card. Rebuilds commit to the AUR as `<version>-<pkgrel> release from <strategy>`, as in `2.4.6-2 release from github-tag`.

## The PKGBUILD

Values start with a letter or a digit and hold only `A-Za-z0-9 . _ + ~ -`. Tildes never start them, because bash expands a tilde at the start of an assignment: `_deb=~root` gives the home directory of `root`. AUR PKGBUILD holds exactly one line of `upstream.asset_var`, with the old value. Updates write the new value to that line and set `pkgrel`:

| `pkgver` against the AUR | Value against the AUR | `pkgrel` |
|---|---|---|
| other version | any | `1` |
| same version | other value, rebuild | AUR `pkgrel` plus one, which must be an integer |
| same version | same value | as in the AUR, nothing pushed |

In `.SRCINFO`, each old value in a line stands for the new one, and the rest of the line follows the version rules of step 5 in [Prepare and publish](/internals/update-process/#prepare-and-publish). New values have to change source URLs or checksums.

Verify and publish never run the PKGBUILD, so they find the value by its text. The value text must therefore occur in a line only where the PKGBUILD writes the value. Values that equal the version, or other text of the line, split lines in the wrong places, and publish refuses correct updates. The capture group takes enough of the asset name to rule that out. Release v4.0.1 of `kyutai-labs/pocket-tts` names its Linux binary by its Rust crate version, `pocket-tts-3.3.0-x86_64-unknown-linux-gnu.tar.gz`, and `3.3.0` alone would equal `pkgver` in releases where both versions are the same. The group takes the binary name with it:

```yaml
name: pocket-tts-bin
strategy: github-release
upstream:
  project: kyutai-labs/pocket-tts
  asset_regex: '^(pocket-tts-[0-9.]+)-x86_64-unknown-linux-gnu\.tar\.gz$'
  asset_var: _bin
```

```bash
pkgver=4.0.1
_bin=pocket-tts-3.3.0
...
_release="${url}/releases/download/v${pkgver}"
source_x86_64=("${pkgname}-${pkgver}-${_bin}-x86_64.tar.gz::${_release}/${_bin}-x86_64-unknown-linux-gnu.tar.gz")
```

The saved name starts with `${pkgname}`, since `pocket-tts-${pkgver}` would write the value text when both versions are `4.1.0`. It holds `pkgver`, since v4.0.0 and v4.0.1 publish different files under one asset name.

Downloads saved under names without the value, as in `${pkgname}-${pkgver}-amd64.deb::<url>`, keep that name through rebuilds. makepkg then takes the old file from the build directory or from `SRCDEST` and fails on its checksum. Saved names hold the value, as `liquidsoap_${_deb}_amd64.deb` does.

Run by hand, `update-pkg.sh` needs `--asset <value>` for packages with `upstream.asset_var` and refuses it for other packages.
