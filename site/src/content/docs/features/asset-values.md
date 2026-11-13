---
title: Values from release asset names
---

Some upstreams name a release asset with more than the version and rebuild a published release under a new name. `savonet/liquidsoap` publishes `liquidsoap_2.4.6-debian-forky-ocaml5.4.0-3_amd64.deb`: `debian-forky-ocaml5.4.0` names the build, and `3` is the Debian revision, which upstream raises when it rebuilds the same version. The PKGBUILD keeps such a value unquoted on a line of its own, and `upstream.asset_var` in the package YAML names the variable, `_deb` here:

```bash
pkgver=2.4.6
_deb=2.4.6-debian-forky-ocaml5.4.0-3
pkgrel=1
...
source_x86_64=("${_release}/liquidsoap_${_deb}_amd64.deb")
```

`upstream.asset_regex` is an ERE with exactly one capture group, matched against the asset names of the release. `github-tag` and `github-release` take it:

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

The check takes the one tag that gives the version, as `github-tag` reads the tags, and the release of that tag. Exactly one asset name must match `asset_regex`, and its capture group is the value. The regex above names the OCaml 5 build, because v2.4.6 also has an `ocaml4.14.2` asset and `ocaml[0-9.]+` would match both. No tag or two tags for the version, two matching assets, or a value with characters outside those below fail the check.

Upstream can push a tag before it publishes the release: liquidsoap uploads the assets to a draft, which the API shows only to users who can push, and published `v2.5.0-rc1` 40 minutes after its tag. A release without a matching asset waits 24 hours from its `published_at`, and a tag without a release 24 hours from the date of its commit, with the status `pending`. After that the check fails and names the assets of the release. A commit date more than 24 hours after the run fails the check at once.

For a package at `current`, a value other than `current_asset` is a rebuild of that version. A package YAML without `current_asset` gets it in its first run, with no push when the AUR has the value already.

| Status | README | Meaning |
|---|---|---|
| `pending: 2.5.0rc1` | `⏳ 2.5.0rc1 pending` | the release or its asset is not out yet, and no issue opens |
| `new_build: 2.4.6` | `🔨 2.4.6 rebuild available` | a new value of the version the AUR has, the push comes next |
| `rebuilt: 2.4.6` | `🔨 2.4.6 rebuilt` | the rebuild is pushed |

None of the three is a failure on the [statistics](/features/statistics/) card. A rebuild commits to the AUR as `<version>-<pkgrel> release from <strategy>`, as in `2.4.6-2 release from github-tag`.

## The PKGBUILD

The value starts with a letter or a digit and holds only `A-Za-z0-9 . _ + ~ -`. A tilde never starts it, because bash expands a tilde at the start of an assignment: `_deb=~root` gives the home directory of `root`. The AUR PKGBUILD holds exactly one line of `upstream.asset_var`, with the old value. The update writes the new value to that line and sets `pkgrel`:

| `pkgver` against the AUR | Value against the AUR | `pkgrel` |
|---|---|---|
| another version | any | `1` |
| the same version | another value, a rebuild | the AUR `pkgrel` plus one, which must be an integer |
| the same version | the same value | as in the AUR, and nothing is pushed |

In `.SRCINFO`, each old value in a line stands for the new one, and the rest of the line follows the rules of the version in step 5 of [Prepare and publish](/internals/update-process/#prepare-and-publish). A new value has to change a source URL or a checksum.

Verify and publish never run the PKGBUILD, so they find the value by its text. The text of the value must therefore occur in a line only where the PKGBUILD writes the value. A value that is also the version, or other text of the line, splits the line in the wrong places, and publish refuses correct updates. The capture group takes enough of the asset name to rule that out. Release v4.0.1 of `kyutai-labs/pocket-tts` names its Linux binary by the version of its Rust crate, `pocket-tts-3.3.0-x86_64-unknown-linux-gnu.tar.gz`, and a value of `3.3.0` alone would equal `pkgver` in a release where both versions are the same. The group takes the name of the binary with it:

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

The saved name starts with `${pkgname}`, since `pocket-tts-${pkgver}` would write the text of the value when both versions are `4.1.0`. It holds `pkgver`, since v4.0.0 and v4.0.1 publish different files under one asset name.

A download saved under a name without the value, as in `${pkgname}-${pkgver}-amd64.deb::<url>`, keeps that name through a rebuild. makepkg then takes the old file from the build directory or from `SRCDEST` and fails on its checksum. The saved name holds the value, as `liquidsoap_${_deb}_amd64.deb` does.

Run by hand, `update-pkg.sh` needs `--asset <value>` for a package with `upstream.asset_var` and refuses it for any other package.
