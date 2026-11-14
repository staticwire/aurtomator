---
title: Package YAML
---

Each package has a file `packages/<name>.yml`. The file name, `name` and the `pkgbase` on the AUR are the same: a run finds the file by `name`, and `validate-pkg.sh` refuses a `name` other than the file name. The `pkgbase` names the AUR git repository. It is the package name, except for a split package such as `pkgbase=liblinear` with `pkgname=(liblinear python-liblinear)`.

| Field | Required | Description |
|---|---|---|
| `name` | yes | the `pkgbase` on the AUR, the file name without `.yml` |
| `strategy` | yes | the version detection strategy, a script of `strategies/` without `.sh`, see [Strategies](/strategies/) |
| `upstream` | by strategy | the settings of the strategy. `archpkg`, `repology` and `kde-tarball` need none |
| `current` | no | the version in the AUR, written after every push |
| `last_updated` | no | the date of the last push, `YYYY-MM-DD`, written after every push, see [Cooldown](/features/cooldown/) |
| `current_asset` | no | the value from a release asset name that the AUR has, written after every push, see [Values from release asset names](/features/asset-values/) |
| `allow_downgrade` | no | `true` publishes a version below `current`. Default `false`, see [Downgrades and version jumps](/features/downgrades/) |
| `allow_version_jump` | no | `true` publishes a version whose first number has at least two digits more than that of `current`. Default `false`, see [Downgrades and version jumps](/features/downgrades/) |
| `allow_missing_arch` | no | `false` fails a version whose release lacks the archive of an arch. Default `true`, see [Versions without some arches](/features/missing-arches/) |
| `arch_wait`, `arch_out` | no | written by the runs while a version lacks the archive of an arch, see [Versions without some arches](/features/missing-arches/) |
| `cooldown_days` | no | the days a push waits after the last one, 0 to 365. Default 7 for `git-latest` and 0 for the others, see [Cooldown](/features/cooldown/) |
| `pkgver_dash` | no | `_`, `.` or `''`: what stands for each `-` of the upstream version, see [pkgver_dash](#pkgver_dash) |
| `pkgver_format` | no | the upstream version with a fixed text around it, `%s` in its place, as `4.%s`, see [pkgver_format](#pkgver_format) |
| `alerts` | no | the steps of upstream that need a hand edit, see [Update alerts](/features/update-alerts/) |

```yaml
name: my-package
strategy: github-release
upstream:
  project: owner/repo
current: "2.1.0"
```

`validate-pkg.sh` refuses a key that is not in the table and an `upstream` key that the strategy does not read, so a misspelled key cannot go unread: `allow_downgrades` gives `packages/<name>.yml: unknown key: allow_downgrades`, and `upstream.projet` gives `upstream.projet is not a field of any strategy`. It also refuses a value with a control character other than a tab, and a `current` without a digit or with a character outside `A-Za-z0-9._+`. It refuses a file that holds a key twice in one mapping, since `yq` reads the last of the two, and a file with a carriage return inside a line, a NEL, a U+2028 or a U+2029: `yq` ends a line at each of them and a diff does not, so a review could read a key as part of a comment.

`upstream.max_answer_mb`, a whole number from 1 to 500, sets the largest answer in megabytes that the requests of one package read. The default is 50, and 5 for the page of `webpage-scrape`. A larger answer fails the check. `git-tag` and `git-latest` read with git and take no `max_answer_mb`.

## pkgver_dash

`pkgver` cannot hold a dash, so `check-update.sh` refuses a version such as `1.9.0-1` from npm or `1.0.0-beta.24` from crates.io. With `pkgver_dash`, it replaces every `-` of the version first. The PKGBUILD turns the character back into a dash where a source URL needs one, as `${pkgver//_/-}` does for `_`. `.` suits a PKGBUILD that writes the dash as a dot already, such as pijul with `_pkgver=${pkgver/.beta/-beta}`. A version given to `update-pkg.sh` by hand is taken as it is.

A pre-release mapped to `_` or `.` sorts above its final release: `vercmp 1.0.0.beta.24 1.0.0` and `vercmp 0.60.0_RC1 0.60.0` are both `1`. The final release is then a downgrade, see [Downgrades and version jumps](/features/downgrades/), and the AUR package needs an `epoch`, which aurtomator does not write.

`pkgver_dash: ''` drops the dash and joins the pre-release to the number: `2.5.0-rc1` becomes `2.5.0rc1`, which `vercmp` sorts below `2.5.0`, so the final release updates the package without an epoch. The PKGBUILD puts the dash back where a URL needs it, as `${pkgver/rc/-rc}` does. A pre-release that starts with a digit stays above its release: `1.9.0-1` becomes `1.9.01`, above `1.9.0`. A package that moves to `''` from `_` or `.` gets a lower pkgver, `2.5.0rc2` below `2.5.0_rc1`, and needs an epoch once.

## pkgver_format

With `pkgver_format`, `pkgver` is the upstream version with a fixed text around it: `'4.%s'` turns build `4215` into `4.4215`, and `current` holds the formatted version. The PKGBUILD cuts the text off where a source URL needs the upstream version, as `${pkgver#4.}` does. `validate-pkg.sh` refuses a format without exactly one `%s` or with a character outside `A-Za-z0-9._+` around it, and a `current` that does not fit the format.

```yaml
name: my-package
strategy: webpage-scrape
upstream:
  url: https://example.com/updates.json
  pattern: '"latest_version": ([0-9]+)'
pkgver_format: '4.%s'
current: "4.4215"
```
