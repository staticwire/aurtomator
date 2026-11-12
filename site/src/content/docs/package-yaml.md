---
title: Package YAML
---

Each package has a file at `packages/<name>.yml`. The file name, the `name` field and the `pkgbase` on the AUR are the same. A run finds the file of a package by its `name`, so `validate-pkg.sh` refuses a `name` other than the file name. The `pkgbase` names the AUR git repository, and it is the package name, except for a split package such as `pkgbase=liblinear` with `pkgname=(liblinear python-liblinear)`.

| Field          | Required | Description                                                                 |
|----------------|----------|-----------------------------------------------------------------------------|
| `name`         | yes      | `pkgbase` on the AUR, equal to the file name without `.yml`                 |
| `strategy`     | yes      | Version detection strategy: a script name in `strategies/` without `.sh`    |
| `upstream`     | depends  | Strategy-specific settings. `archpkg`, `repology` and `kde-tarball` need none. |
| `current`      | no       | Currently tracked version. Written after every push.                        |
| `last_updated` | no       | Date of the last push, `YYYY-MM-DD`. Written after every push. The cooldown counts from it, see [Cooldown](/aurtomator/features/cooldown/). |
| `current_asset` | no      | The value from a release asset name that the AUR has, for a package with `upstream.asset_var`. Written after every push, see [Values from release asset names](/aurtomator/features/asset-values/) |
| `allow_downgrade` | no    | `true` publishes an upstream version lower than `current`. Default `false`, see [Downgrades and version jumps](/aurtomator/features/downgrades/). |
| `allow_version_jump` | no | `true` publishes a version whose first number has at least two digits more than the first number of `current`. Default `false`, see [Downgrades and version jumps](/aurtomator/features/downgrades/). |
| `allow_missing_arch` | no | `false` fails the update of a version whose release lacks the archive of an arch, as for any missing source. Default `true`: the version goes out without that arch after 24 hours, see [Versions without some arches](/aurtomator/features/missing-arches/). |
| `arch_wait` | no | The version that waits for the archive of an arch and the time a run first saw it without one. Written by the runs, see [Versions without some arches](/aurtomator/features/missing-arches/). |
| `arch_out` | no | Each arch an update left out of `arch=()`, with the AUR commit the update started from. Written by the runs, see [Versions without some arches](/aurtomator/features/missing-arches/). |
| `cooldown_days` | no      | The days a push waits after the last one, from 0 to 365. Default 7 for `git-latest` and 0 for the other strategies, and `0` turns the wait off, see [Cooldown](/aurtomator/features/cooldown/). |
| `pkgver_dash`  | no       | `_`, `.` or `''`: the character that stands for each `-` of the upstream version, or none, see below |
| `pkgver_format` | no      | The upstream version with a fixed text around it, `%s` in its place, as `4.%s`, see below |
| `alerts`       | no       | Rules for steps of upstream that need a hand edit: each pauses the update or reports a note, see [Update alerts](/aurtomator/features/update-alerts/) |

`validate-pkg.sh` refuses a key that is not in this table, and an `upstream` key that the strategy does not read, so a misspelled key does not go unread. A misspelled `allow_downgrade` gives `packages/<name>.yml: unknown key: allow_downgrades`. The `upstream` keys of each strategy are its line of `UPSTREAM_KEYS` in `scripts/validate-pkg.sh`, and the error names the strategies that read the key, as in `upstream.branch applies to the git-latest strategy only`. A key that no strategy reads gives `upstream.projet is not a field of any strategy`. A file that is not a map of fields is refused before these checks, and an `upstream` that is not a map before the check of its keys. It also refuses a `current` with a character outside `A-Za-z0-9._+` or without a digit, the form of a version in every script.

A request that a strategy or `check-asset.sh` sends with curl reads at most 50 MB of one answer, and `webpage-scrape` reads at most 5 MB of its page. `upstream.max_answer_mb`, a whole number from 1 to 500, sets another limit for the requests of one package, `webpage-scrape` included, and a larger answer fails the check. `check-update.sh` hands the value to the strategy as `MAX_ANSWER_MB`. `git-tag` and `git-latest` read with git and take no `max_answer_mb`.

Example:

```yaml
name: my-package
strategy: github-release
upstream:
  project: owner/repo
current: "2.1.0"
```

`pkgver` cannot hold a dash, so `check-update.sh` refuses a version such as `1.9.0-1` from npm or `1.0.0-beta.24` from crates.io. With `pkgver_dash`, it replaces every `-` in the output of the strategy before that check. The PKGBUILD turns the character back where a source URL needs the dash, as `${pkgver//_/-}` does for `_`, and the `.SRCINFO` check of verify and publish counts such a form as the version, see step 5 of publish in [Prepare and publish](/aurtomator/internals/update-process/#prepare-and-publish). `vercmp` reads `_` and `.` the same. `.` fits a PKGBUILD that already writes the dash as a dot, such as pijul with `_pkgver=${pkgver/.beta/-beta}`. A version given to `update-pkg.sh` by hand is taken as it is.

A pre-release mapped to `_` or `.` sorts above its final release: `vercmp 1.0.0.beta.24 1.0.0` and `vercmp 0.60.0_RC1 0.60.0` are both `1`, while a pre-release glued to the number, `1.0.0beta.24`, sorts below `1.0.0`. When the final release comes out, the check skips it as a downgrade, see [Downgrades and version jumps](/aurtomator/features/downgrades/), and the AUR package needs an `epoch`, which aurtomator does not write.

`pkgver_dash: ''` drops the dash and so glues the pre-release to the number: `2.5.0-rc1` becomes `2.5.0rc1`, which `vercmp` puts below `2.5.0` and above `2.4.6`, and the final release updates the package without an epoch. The PKGBUILD puts the dash back where a URL needs it, as `${pkgver/rc/-rc}` does, and the `.SRCINFO` check counts a form of the version with a dash between two of its characters as the version. A pre-release that starts with a digit stays above its release: `1.9.0-1` becomes `1.9.01`, and `vercmp 1.9.01 1.9.0` is `1`. A package that moves to `''` from `_` or `.` gets a lower pkgver for `vercmp`, `2.5.0rc2` below `2.5.0_rc1`, so the move needs an epoch once.

With `pkgver_format`, `pkgver` is the upstream version with a fixed text around it: `'4.%s'` turns build `4215` into `4.4215`. `check-update.sh` puts the output of the strategy in place of `%s`, after `pkgver_dash`, so `current` holds the formatted version. The PKGBUILD cuts the text off where a source URL needs the upstream version, as `${pkgver#4.}` does, and the `.SRCINFO` check of verify and publish counts that form as the version, see step 5 of publish in [Prepare and publish](/aurtomator/internals/update-process/#prepare-and-publish). `validate-pkg.sh` refuses a format without exactly one `%s` or with a character outside `A-Za-z0-9._+` around it, and a `current` that does not fit the format.

```yaml
name: my-package
strategy: webpage-scrape
upstream:
  url: https://example.com/updates.json
  pattern: '"latest_version": ([0-9]+)'
pkgver_format: '4.%s'
current: "4.4215"
```
