---
title: Values from release asset names
---

Some upstreams name a release asset with more than the version and rebuild a published release under a new name. `savonet/liquidsoap` publishes `liquidsoap_2.4.6-debian-forky-ocaml5.4.0-3_amd64.deb`: `debian-forky-ocaml5.4.0` names the build and `3` the Debian revision, which upstream raises when it rebuilds the same version. A PKGBUILD keeps such a value on a line of its own, unquoted, and `upstream.asset_var` in the package YAML names its variable, `_deb` here:

```bash
pkgver=2.4.6
_deb=2.4.6-debian-forky-ocaml5.4.0-3
pkgrel=1
...
source_x86_64=("${_release}/liquidsoap_${_deb}_amd64.deb")
```

`upstream.asset_regex` says where the value comes from. It is an ERE with exactly one capture group, and `github-tag` and `github-release` take it:

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

`check-asset.sh <package-name> <pkgver>` finds the value. It reads the tags of `upstream.project` as `github-tag` does, and keeps the one tag that gives the version through `tag_version_regex`, `tag_version_replace`, `pkgver_dash` and `pkgver_format`. It reads the release of that tag from `/repos/{owner}/{repo}/releases/tags/{tag}`, with the tag percent-encoded, and matches `asset_regex` against the names of its assets. Exactly one name has to match, and its capture group is the value. The regex above names the OCaml 5 build, because v2.4.6 also has `liquidsoap_2.4.6-debian-forky-ocaml4.14.2-3_amd64.deb`, and `ocaml[0-9.]+` would match both. No tag or more than one tag for the version, more than one matching asset, and a value outside the characters below fail the check.

A tag appears before its release. liquidsoap uploads the assets of a release to a draft and publishes the draft afterwards, 40 minutes after the tag for `v2.5.0-rc1`, and the API lists a draft only to users who can push. A release without a matching asset is therefore pending for 24 hours after its `published_at`, and a tag without a release for 24 hours after the date of its commit. After that the check fails, and for a release it names the assets. git takes any committer date, so a date more than 24 hours ahead of the run fails the check at once.

`check-all.sh` runs `check-asset.sh` within the budget of a check, after the downgrade, jump and alert checks, so a skipped or held update needs no value. A failure gets the second pass of a failed check. The value goes to `.status/_assets` as the package and the value, split by a tab, and `--prepare` and `--publish` take it from there, as they take the version from the status of the check run. A package that is up to date gets the value of `current` as well, and a value other than `current_asset` is a rebuild of that version. A YAML without `current_asset` gets one in its first run: when the AUR already has the value, publish only writes `current_asset`.

| Status | README | Meaning |
| --- | --- | --- |
| `pending: 2.5.0rc1` | `⏳ 2.5.0rc1 pending` | The release or its asset is not out yet. Nothing is prepared, and no issue opens |
| `new_build: 2.4.6` | `🔨 2.4.6 rebuild available` | A new value of the version the AUR has, not pushed yet |
| `rebuilt: 2.4.6` | `🔨 2.4.6 rebuilt` | The rebuild was pushed to the AUR |

None of the three counts among the failing packages of the statistics card, see [Statistics](/aurtomator/features/statistics/).

`update-pkg.sh`, `verify-pkg.sh` and `publish-pkg.sh` take the value with `--asset <value>`, and `check-all.sh` passes it. A package with `upstream.asset_var` needs it, and any other package refuses it. The value starts with a letter or a digit and holds only `A-Za-z0-9 . _ + ~ -`, because bash expands a tilde at the start of an assignment: `_deb=~root` gives the home directory of `root`. `update-pkg.sh` writes the value to the line of `upstream.asset_var`. `verify-pkg.sh` and `publish-pkg.sh` refuse a prepared line with another value than their `--asset`, as they refuse a `pkgver` other than `<version>`.

The AUR `PKGBUILD` must hold exactly one line of `upstream.asset_var`, and its value is the old value. `pkgrel` follows from the version and the value:

| `pkgver` against the AUR | Value against the AUR | `pkgrel` |
| --- | --- | --- |
| another version | any | `1` |
| the same version | another value, a rebuild | the AUR `pkgrel` plus one, for an integer AUR `pkgrel` only |
| the same version | the same value | as in the AUR, so publish finds nothing to push |

In `.SRCINFO`, each old value in a line stands for the new one, and the parts of the line between the values follow the rules of the version in step 5 of [Prepare and publish](/aurtomator/internals/update-process/#prepare-and-publish). A new value has to change a source URL or a checksum.

The check finds the value by its text. Only the PKGBUILD shows which occurrence of that text is the value, and verify and publish never run it. The text of the value therefore has to occur in a line only where the PKGBUILD writes the value. When it is also the version or other text of the line, as a lone revision `3` would be, the line splits in the wrong places and publish refuses correct updates. The capture group takes enough of the asset name to rule that out. Release v4.0.1 of `kyutai-labs/pocket-tts` names its Linux binary `pocket-tts-3.3.0-x86_64-unknown-linux-gnu.tar.gz`, by the version of its Rust crate. A value of `3.3.0` alone would be the same text as `pkgver` in a release where the two versions are equal, so the group takes the name of the binary with it:

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

The saved name holds `pkgver` because v4.0.0 and v4.0.1 publish different files under this asset name. It starts with `${pkgname}`, since `pocket-tts-${pkgver}` would write the text of the value in a release where both versions are `4.1.0`.

A rebuild commits to the AUR as `<version>-<pkgrel> release from <strategy>`, as in `2.4.6-2 release from github-tag`. `current_asset` in the package YAML gets the value together with `current`, also when the AUR already has it.

A download saved under a name without the value, as in `${pkgname}-${pkgver}-amd64.deb::<url>`, keeps that name through a rebuild. makepkg takes a file of that name from the build directory or from `SRCDEST` and fails on its checksum. The file name therefore holds the value, as the upstream name `liquidsoap_${_deb}_amd64.deb` does.
