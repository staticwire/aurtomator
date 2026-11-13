---
title: Versions without some arches
---

A package that builds each arch from an archive of its own cannot take a release that lacks the archive of one arch: the source check of step 7 of [Step-by-step](/internals/update-process/#step-by-step) gets 404 for that archive, and the update of every arch stops. Release `jdk-28+23-ea-beta` of Temurin came out without its aarch64 archive, so `jdk-temurin-ea-bin` stayed at 28+22 for all four arches. aurtomator publishes such a version without the arches whose archives are missing, after a wait of 24 hours, and puts each arch back once its archive is out. makepkg handles an arch outside `arch=()` the way this needs: `makepkg -g` writes no checksums for it, `makepkg --printsrcinfo` lists none of its lines, and its `source_<arch>` array may stay in the PKGBUILD. The update therefore needs one change more, the `arch=(...)` line.

`allow_missing_arch: false` in the package YAML turns this off, and the update then fails on the missing archive as on any other. It is off as well for a package with `pkgver_dash: ''`, because the check cannot build the URLs of a version whose dash can stand anywhere. A release without the archive of `x86_64`, or without the archives of every arch in `arch=()`, fails the update as before, with `update_failed` and an issue: the feature leaves out an arch such as aarch64, riscv64 or powerpc64le, never `x86_64`.

## State in the package YAML

The runs write two keys, as they write `current`:

```yaml
arch_wait:
  version: 28+23
  since: "2026-11-06T11:17:00Z"
arch_out:
  aarch64: 3a5f6f12a7c9176a4c87bb402f1a3e938ec04011
```

`arch_wait` holds the version that waits for an archive and the UTC time a run first saw it without one. `arch_out` names each arch an update left out, with the `base` of that update: the last AUR commit whose `.SRCINFO` holds every line of the arch, its `depends_<arch>` and its checksums included. The check builds the URLs of any later version from that commit, and verify and publish check a put-back against it. An arch that the maintainer leaves out of `arch=()` is not in `arch_out`, and no run asks for its archive or puts it back.

`validate-pkg.sh` refuses an `allow_missing_arch` other than `true` or `false`, an `arch_out` that is not a map, an arch name with a character outside `a-z0-9_`, a commit id that is not 40 hex digits, an `arch_wait` without `version` and `since` or with another key, a `version` that `validate_pkgver` refuses, and a `since` that is not a UTC time `YYYY-MM-DDTHH:MM:SSZ` or lies in the future.

## Check

For a package with the feature on, `check-all.sh` runs `check-arch.sh <package-name> <version> [--asset <value>]` within the budget of a check. For a new version it runs after the downgrade, jump, alert and cooldown checks and after the asset value of [Values from release asset names](/features/asset-values/). A package with `arch_out` and no new version gets the check in every run, at `current`. The script prints the arches that stay out after the update on its first line and the start of the wait on its second, and exits with code 3 while the version waits.

1. It clones `https://aur.archlinux.org/<package-name>.git` anonymously with `--no-checkout`, and reads `PKGBUILD` and `.SRCINFO` of `HEAD` and of each commit of `arch_out`. A failed clone keeps the arches of `arch_out` out, and the package goes on as before in that run. A commit of `arch_out` that the AUR repo lacks, or whose `.SRCINFO` does not build its arch, fails the check.
2. It reads `arch=()` of the PKGBUILD at `HEAD`. That has to be one line `arch=(...)` at the start of a line, of arch names of `a-z0-9_` in single quotes, double quotes or none, with nothing but spaces after the closing parenthesis. No other line may set `arch=` or `arch+=`, inside a function either. Otherwise no arch leaves in that version, and the arches of `arch_out` stay out.
3. It takes the `source_<arch>` lines of each arch, of `HEAD` for an arch in `arch=()` and of its commit for an arch of `arch_out`, and replaces the version of that file in each URL by the new one, in the forms that step 5 of publish in [Prepare and publish](/internals/update-process/#prepare-and-publish) counts as the version, the asset value included. At the `pkgver` and asset value of the AUR, only the arches of `arch_out` are asked.
4. It sends each `https` URL the `HEAD` request of the source check, see [Source URL returns HTML](/supported-packages/#source-url-returns-html-blocked). A status of 400 or more, or an HTML page, means the archive is missing. A URL that gives no status fails the check, so the next run asks again. A URL of another scheme is not asked.

An arch of `arch_out` that `arch=()` names again was put back by hand: it is not asked, and the next publish takes it out of `arch_out`. The common `source` array is not asked, and prepare checks it as before.

| Archives of the version | Status | Then |
|---|---|---|
| all there | `new_version` | an update as before |
| `x86_64` missing, or those of every arch in `arch=()` | `new_version` | the update fails as before |
| another arch missing for less than 24 hours | `pending` | no prepare job |
| another arch missing for 24 hours | `new_version` | the update leaves the arch out |
| an arch of `arch_out` there again, at a new version | `new_version` | the update puts the arch back |
| an arch of `arch_out` there again, at `current` | `arch_back` | the update puts the arch back at that version |

The wait counts from `arch_wait.since` when `arch_wait.version` is the version, and from the run otherwise, so a newer version starts a new wait. A `since` after the time of the run counts from the run too, and `check-all.sh` takes no such start from the record of the check run. Only an arch that leaves `arch=()` starts a wait, so an arch that is out already starts none at a later version. A wait can last one run interval longer than the wait of [Values from release asset names](/features/asset-values/), which counts from `published_at`, because not every strategy has a date of upstream, `webpage-scrape` among them. `pending: <version>` shows as `⏳ <version> pending`, opens no issue and is no failure. The log names the missing archive and the wait:

```text
! jdk-temurin-ea-bin 28+23: no archive for aarch64 at https://github.com/adoptium/temurin28-binaries/releases/download/jdk-28+23-ea-beta/OpenJDK-jdk_aarch64_linux_hotspot_28_23-ea.tar.gz
! jdk-temurin-ea-bin 28+23: no archive for aarch64, pending for 24 h from 2026-11-06T11:17:00Z
```

`check-all.sh` writes a line to `.status/_arches` for the package: `<package><TAB><version><TAB><arches out after the update><TAB><start of the wait>`, either of the last two fields possibly empty. It writes the line when it names arches or a start, and when the YAML holds `arch_out`, because a line without arches tells prepare to put every arch of `arch_out` back. With the feature off it writes none, so nothing is put back unchecked. `--prepare`, `--verify` and `--publish` take the line of the package for the version they handle. A line of another form or for another version gives `check_failed: invalid arch record from the check run`, or `update_failed` with the same text in `--verify`.

## Prepare

`check-all.sh --prepare` passes the arches of the line to `update-pkg.sh` as `--arch-out <arches>`, an empty list included. The option needs `--prepare`.

1. The arches of the list leave `arch=()`. Each arch of `arch_out` that the list does not name and `arch=()` lacks comes back, after the last arch that stands before it in the `arch` lines of its commit, or first. A changed line takes the quoting of the first word of the old one, with one space between the words.
2. An arch of the list that `arch=()` names stays when every `http` and `https` URL of its `source_<arch>` answers, as makepkg builds the URL with `CARCH` set to that arch: the check asked other URLs.
3. The source check of step 7 of [Step-by-step](/internals/update-process/#step-by-step) skips the `source_<arch>` arrays of the arches that leave, and `updpkgsums` and `makepkg --printsrcinfo` cover the arches in `arch=()` alone.
4. When the AUR has the `pkgver` and `pkgrel` of the update and only the arch line changes, the update goes on with both as they are. Exit code 2 means that the arch line stays as well.

`update-pkg.sh` stops with exit code 1 when the PKGBUILD has no arch line of the form of step 2 of the check, when a commit of `arch_out` is not in the AUR repo, and when the list would leave `arch=()` empty.

## Verify and publish

`--verify` and `--publish` pass the arches of the line to `verify-pkg.sh` and `publish-pkg.sh` as `--arch-out <arches>`. Each works out the arch line that the update must have the way prepare does, from the AUR copy, the list and `arch_out`. An arch of the list that the prepared line still names counts as kept by step 2 of prepare, and verify checks its sources as those of any arch. Without `--arch-out`, the arch line must stay as the AUR copy has it.

- The `arch=(...)` line of the prepared PKGBUILD must be the line worked out. The checksum arrays of an arch taken out are gone, and those of an arch that comes back have the names, lengths and `SKIP` entries of its arrays in the PKGBUILD of its commit. The other arrays follow step 4 of publish in [Prepare and publish](/internals/update-process/#prepare-and-publish).
- The lines of an arch taken out leave the `.SRCINFO` of the AUR copy: its `arch` line and every key that ends in `_<arch>`, in every section. The lines of an arch that comes back leave the prepared `.SRCINFO` once each matches its line in the `.SRCINFO` of its commit, in the same section: a value that the PKGBUILD of the commit holds as text stays, a `source` takes the version of the update in place of that of the commit, and a checksum keeps its key and stays a hash or `SKIP`. Step 5 of publish checks the rest, the number of lines included.
- At the version of the AUR, an update that puts an arch back goes through the checks as any update, with the `pkgrel` of the AUR, and prepared files equal to those of the AUR stop it.
- verify downloads the sources of an arch that comes back and checks their checksums, as it does for every source.

A commit of `arch_out` that the AUR repo lacks stops both with exit code 1.

## After the push

After the push, each arch taken out goes to `arch_out` with `base`. After the push, and when the AUR has the update already and publish exits with code 2, each arch that `arch=()` names leaves `arch_out`, an empty `arch_out` is removed, and so is `arch_wait`, with `--arch-out` or without. An arch that stays out keeps its commit. An update that puts arches back and keeps the `pkgver` and `pkgrel` of the AUR commits as `Add <arches> to <version>`, as in `Add aarch64 to 28+23`, with `-<pkgrel>` after the version when `pkgrel` is not 1. It keeps `last_updated` and does not wait for the cooldown of [Cooldown](/features/cooldown/). A version that leaves an arch out commits as any update does, as `28+23 release from webpage-scrape`.

`check-all.sh --publish` writes `arch_wait` from the line of `.status/_arches` when the line names a start: for a `pending` package, and before the push of a version whose wait is over, so a failed push keeps the start for the next run. It leaves the YAML alone when `arch_wait` holds that version and start already. At the end of the run it writes `.status/_without`, a line `<package><TAB><current><TAB><arches>` for each package YAML with `arch_out`, and leaves the file empty when there is none.

## Statuses, README and issues

| Moment | Status | README |
|---|---|---|
| the wait of 24 hours | `pending: 28+23` | `⏳ 28+23 pending` |
| the push without an arch | `updated: 28+23` | `📦 updated to 28+23 without aarch64` |
| the runs after it, while the arch is out | `up_to_date` | `⚠️ 28+23 without aarch64` |
| the check finds the arch back | `arch_back: 28+23 aarch64` | `✨ aarch64 for 28+23 available` |
| the push that puts it back | `arch_added: 28+23 aarch64` | `📦 aarch64 added to 28+23` |
| an arch back with a new version | `updated: 28+24` | `📦 updated to 28+24` |

`update-readme.sh` passes the arches of `arch_out` and `current` of each package to `status_label`, which changes the labels of `up_to_date` and `updated` alone: a failure, a new version and a wait keep theirs. Several arches stand in the order of `arch_out`, separated by spaces. The run summary of [Issues](/features/issues/) shows each status with its label alone.

A package with a line in `.status/_without` gets an issue titled `⚠️ <package>: <version> without <arches>` with the label `arch-missing`, see [Issues](/features/issues/). The journal of [Statistics](/features/statistics/) writes the push that puts arches back as `arch_added`, a push like the others on the card, and writes no row for `arch_back`.

`check-all.sh --update` and `update-pkg.sh` without `--prepare`, the local updates of [Push an update](/develop/local-testing/#push-an-update) and [Check all packages](/develop/local-testing/#check-all-packages), run no `check-arch.sh` and write no `arch_out`: a missing archive stops them as before.
