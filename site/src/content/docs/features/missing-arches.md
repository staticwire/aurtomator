---
title: Versions without some arches
---

A package that downloads one archive per arch cannot update when upstream releases a version without one of them: the [source check](/internals/update-process/#step-by-step) gets 404 and stops the update of every arch. Temurin released `jdk-28+23-ea-beta` without its aarch64 archive, and `jdk-temurin-ea-bin` stayed at 28+22 on all four arches.

aurtomator waits 24 hours for the missing archive, publishes the version without that arch, and puts the arch back once its archive appears. To leave an arch out, the update changes one more line, `arch=(...)`: makepkg writes no checksums and no `.SRCINFO` lines for an arch outside `arch=()`, and its `source_<arch>` array can stay.

A version without the archive of `x86_64`, or without those of every arch, fails as any update does, with `update_failed` and an issue.

`allow_missing_arch: false` in the package YAML turns the feature off. It is off with `pkgver_dash: ''` too: such a PKGBUILD can put the dash back anywhere in the version, and the check cannot build the URLs.

## The PKGBUILD

The check reads `arch=()` of the PKGBUILD in the AUR. The PKGBUILD needs one `arch=(...)` line at the start of a line, with plain arch names, quoted or not, and no comment after it. No other line may set `arch=` or `arch+=`, inside a function either. With any other form, no arch leaves.

## The wait

Each check sends a `HEAD` request to the `https` URLs of `source_<arch>` at the new version. A status of 400 or more, or an HTML page, means the archive is missing.

| Archives of the version | Status | Then |
|---|---|---|
| all there | `new_version` | a normal update |
| `x86_64` missing, or those of every arch | `new_version` | the update fails |
| another arch missing for less than 24 hours | `pending` | no push |
| another arch missing for 24 hours | `new_version` | the update leaves the arch out |
| an arch left out is back, at a new version | `new_version` | the update puts the arch back |
| an arch left out is back, at `current` | `arch_back` | the update puts the arch back at `current` |

The wait starts in the first run that finds the archive missing, and a newer version starts a new wait. A `pending` package opens no issue. The log names the missing archive:

```text
! jdk-temurin-ea-bin 28+23: no archive for aarch64 at https://github.com/adoptium/temurin28-binaries/releases/download/jdk-28+23-ea-beta/OpenJDK-jdk_aarch64_linux_hotspot_28_23-ea.tar.gz
! jdk-temurin-ea-bin 28+23: no archive for aarch64, pending for 24 h from 2026-11-06T11:17:00Z
```

## State in the package YAML

```yaml
arch_wait:
  version: 28+23
  since: "2026-11-06T11:17:00Z"
arch_out:
  aarch64: 3a5f6f12a7c9176a4c87bb402f1a3e938ec04011
```

`arch_wait` holds the waiting version and the start of its wait, and the push removes it. `arch_out` maps each arch left out to the last AUR commit that built it. Later checks build the URLs of the arch from that commit, and verify and publish compare the arch with it when it comes back. An arch leaves `arch_out` with the first push whose `arch=()` lists it, also when the maintainer put it back by hand. An arch that the maintainer removes from `arch=()` never enters `arch_out`.

## Statuses and README

| Moment | Status | README |
|---|---|---|
| the wait | `pending: 28+23` | `⏳ 28+23 pending` |
| the push without an arch | `updated: 28+23` | `📦 updated to 28+23 without aarch64` |
| the runs after it, while the arch is out | `up_to_date` | `⚠️ 28+23 without aarch64` |
| the check finds the arch back | `arch_back: 28+23 aarch64` | `✨ aarch64 for 28+23 available` |
| the push that puts it back | `arch_added: 28+23 aarch64` | `📦 aarch64 added to 28+23` |
| an arch back with a new version | `updated: 28+24` | `📦 updated to 28+24` |

A push that only puts arches back commits to the AUR as `Add <arches> to <version>`, keeps `pkgrel` and `last_updated`, and skips the [cooldown](/features/cooldown/). While an arch is out, the package has one open issue `⚠️ <package>: <version> without <arches>`, see [Issues](/features/issues/).

## Local updates

`check-all.sh --update` and `update-pkg.sh` without `--prepare` do not check the arches, and a missing archive stops them, see [Local testing](/develop/local-testing/).
