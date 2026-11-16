---
title: Package YAML
---

Each package lives in `packages/<name>.yml`. `name` equals the file name and AUR `pkgbase`: runs find the file by `name`, and `validate-pkg.sh` refuses `name` values other than the file name. Names hold the characters `A-Z`, `a-z`, `0-9`, `@`, `.`, `_`, `+` and `-` and start with neither `.` nor `-`. `validate-pkg.sh --all` refuses every entry of `packages/` but `example.yml.sample`, `.gitkeep` and regular files `<name>.yml`, links and directories of that name included, since no run reads them. `check-all.sh` fails the check of a YAML that is a link, since the write-back of `current` takes regular files alone. `pkgbase` names the AUR git repository. It equals the package name, except for split packages such as `pkgbase=liblinear` with `pkgname=(liblinear python-liblinear)`.

| Field | Required | Description |
|---|---|---|
| `name` | yes | AUR `pkgbase`, file name without `.yml` |
| `strategy` | yes | version detection strategy, a script of `strategies/` without `.sh`, see [Strategies](/strategies/) |
| `upstream` | by strategy | strategy settings. `archpkg`, `repology` and `kde-tarball` need none |
| `current` | no | AUR version, written after every push. Without it, an update compares the new version with `pkgver` of the AUR `.SRCINFO` for the rules of downgrades, version jumps and alerts with `hold: true`, and fails where one of them would hold the version |
| `last_updated` | no | date of the last push, `YYYY-MM-DD`, written after every push, see [Cooldown](/features/cooldown/) |
| `current_asset` | no | value from release asset names that the AUR has, written after every push, see [Values from release asset names](/features/asset-values/) |
| `allow_downgrade` | no | `true` publishes versions below `current`. Default `false`, see [Downgrades and version jumps](/features/downgrades/) |
| `allow_version_jump` | no | `true` publishes versions whose first number has at least two digits more than that of `current`. Default `false`, see [Downgrades and version jumps](/features/downgrades/) |
| `allow_missing_arch` | no | `false` fails versions whose release lacks archives of some arches. Default `true`, see [Versions without some arches](/features/missing-arches/) |
| `arch_wait`, `arch_out` | no | written by runs while releases lack archives of some arches, see [Versions without some arches](/features/missing-arches/) |
| `cooldown_days` | no | days each push waits after the last one, 0 to 365. Default 7 for `git-latest` and 0 for other strategies, see [Cooldown](/features/cooldown/) |
| `pkgver_dash` | no | `_`, `.` or `''`: what stands for each `-` of upstream versions, see [pkgver_dash](#pkgver_dash) |
| `pkgver_format` | no | upstream version with fixed text around it, `%s` in its place, as `4.%s`, see [pkgver_format](#pkgver_format) |
| `alerts` | no | upstream steps that need hand edits, see [Update alerts](/features/update-alerts/) |

```yaml
name: my-package
strategy: github-release
upstream:
  project: owner/repo
current: "2.1.0"
```

`validate-pkg.sh` refuses keys that are not in the table and `upstream` keys that the strategy does not read, so misspelled keys cannot go unread: `allow_downgrades` gives `packages/<name>.yml: unknown key: allow_downgrades`, and `upstream.projet` gives `upstream.projet is not a field of any strategy`. It also refuses values with control characters other than tabs, and `current` values without digits or with characters outside `A-Za-z0-9._+`. Keys and values hold printable ASCII and tabs alone, since diffs do not show zero-width or bidi characters. `alerts[].note` is the one exception: it takes any letter but no format characters, no spaces other than U+0020, no letters, symbols or variation selectors that show nothing, such as the Hangul fillers and U+2800, and no combining mark at its start or after a space. `upstream.url` names its host after `https://` in ASCII letters, digits, dots and dashes, with an optional port. Regexes hold at most 256 characters and repeat each part at most 64 times, as in `{1,64}` or `{,64}`. Every regex except `upstream.version_pattern`, which is Perl, also holds at most 128 parts with its repeats written out, where each character, bracket expression, group and `|` is one part: `v([0-9a-f]{7,40})` holds 42. Such regexes put `*`, `+` and `{n,}` only after characters, bracket expressions and escapes, and their only anchors are `^` as the first character and `$` as the last. They hold no back reference such as `\1`, since glibc tries every split of the text among the groups for one, and a single tag then takes seconds. These limits keep each compile short, and bash compiles patterns again for every line it reads. `validate-pkg.sh` also refuses files that hold a key twice in one mapping, since `yq` reads the last of the two, and files with carriage returns inside lines, NEL, U+2028 or U+2029: `yq` ends lines at each of them and diffs do not, so reviewers could take keys for parts of comments.

`upstream.max_answer_mb` takes whole numbers from 1 to 500 and sets the largest answer in megabytes that requests of one package read. It defaults to 50, and to 5 for `webpage-scrape` pages. Larger answers fail the check. `git-tag` and `git-latest` read with git and take no `max_answer_mb`.

## pkgver_dash

`pkgver` cannot hold dashes, so `check-update.sh` refuses versions such as `1.9.0-1` from npm or `1.0.0-beta.24` from crates.io. With `pkgver_dash`, it first replaces every `-` of the version. PKGBUILDs turn the character back into a dash where source URLs need one, as `${pkgver//_/-}` does for `_`. `.` suits PKGBUILDs that already write the dash as a dot, such as pijul with `_pkgver=${pkgver/.beta/-beta}`. Versions given to `update-pkg.sh` by hand are taken as they are.

Pre-releases mapped to `_` or `.` sort above their final release: `vercmp 1.0.0.beta.24 1.0.0` and `vercmp 0.60.0_RC1 0.60.0` are both `1`. Final releases then count as downgrades, see [Downgrades and version jumps](/features/downgrades/), and AUR packages need `epoch`, which aurtomator does not write.

`pkgver_dash: ''` drops the dash and joins the pre-release to the number: `2.5.0-rc1` becomes `2.5.0rc1`, which `vercmp` sorts below `2.5.0`, so final releases update the package without `epoch`. PKGBUILDs put the dash back where URLs need it, as `${pkgver/rc/-rc}` does. Pre-releases that start with a digit stay above their release: `1.9.0-1` becomes `1.9.01`, above `1.9.0`. Packages that move to `''` from `_` or `.` get a lower pkgver, `2.5.0rc2` below `2.5.0_rc1`, and need `epoch` once.

## pkgver_format

With `pkgver_format`, `pkgver` is the upstream version with fixed text around it: `'4.%s'` turns build `4215` into `4.4215`, and `current` holds the formatted version. PKGBUILDs cut the text off where source URLs need the upstream version, as `${pkgver#4.}` does. `validate-pkg.sh` refuses formats without exactly one `%s` or with characters outside `A-Za-z0-9._+` around it, and `current` values that do not fit the format.

```yaml
name: my-package
strategy: webpage-scrape
upstream:
  url: https://example.com/updates.json
  pattern: '"latest_version": ([0-9]+)'
pkgver_format: '4.%s'
current: "4.4215"
```
