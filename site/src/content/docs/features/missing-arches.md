---
title: Versions without some arches
---

Packages that download one archive per arch cannot update when upstream releases a version without one of them: the [source check](/internals/update-process/#step-by-step) gets 404 and stops the update of every arch. Temurin released `jdk-28+23-ea-beta` without its aarch64 archive, and `jdk-temurin-ea-bin` stayed at 28+22 on all four arches.

aurtomator waits 24 hours for the missing archive, publishes the version without that arch, and puts the arch back once its archive appears. To leave an arch out, the update changes one more line, `arch=(...)`: makepkg writes no checksums and no `.SRCINFO` lines for arches outside `arch=()`, and their `source_<arch>` arrays can stay.

Versions without the `x86_64` archive, or with no archive at all, fail as other updates do, with `update_failed` and an issue.

`allow_missing_arch: false` in the package YAML turns the feature off. It is off with `pkgver_dash: ''` too: such PKGBUILDs can put the dash back anywhere in the version, and the check cannot build the URLs.

## The PKGBUILD

The check reads `arch=()` of AUR PKGBUILD. The PKGBUILD needs one `arch=(...)` that starts its line, with plain arch names, quoted or not, and no comment after it. No other line may set `arch=` or `arch+=`, inside functions either. With any other form, no arch leaves.

## The wait

Each check sends `HEAD` requests to the `https` URLs of `source_<arch>` at the new version. Statuses 404 and 410, and HTML pages, mean the archive is missing. Other statuses of 400 or more, such as 429 or 503, tell nothing about the archive, so the check fails with `<url> answered with status <code>`. Packages with archives in S3 buckets without public listing get no wait, since S3 answers 403 for missing files there: the check fails in every run until the archive appears, and its error names S3.

| Archives of the version | Status | Then |
|---|---|---|
| all there | `new_version` | normal update |
| `x86_64` missing, or all missing | `new_version` | update fails |
| other arch missing for less than 24 hours | `pending` | no push |
| other arch missing for 24 hours | `new_version` | update leaves the arch out |
| arch left out is back, at a new version | `new_version` | update puts the arch back |
| arch left out is back, at `current` | `arch_back` | update puts the arch back at `current` |

The wait starts in the first run that finds the archive missing, and newer versions start a new wait. `pending` packages open no issue. The log names the missing archive:

```text
! jdk-temurin-ea-bin 28+23: no archive for aarch64 at https://github.com/adoptium/temurin28-binaries/releases/download/jdk-28+23-ea-beta/OpenJDK-jdk_aarch64_linux_hotspot_28_23-ea.tar.gz
! jdk-temurin-ea-bin 28+23: no archive for aarch64, pending for 24 h from 2026-11-06T11:17:00Z
```

## State in the package YAML

```yaml
arch_wait:
  version: 28+23
  since: "2026-11-06T11:17:00Z"
  commit: 3a5f6f12a7c9176a4c87bb402f1a3e938ec04011
  arches: aarch64
arch_out:
  aarch64: 3a5f6f12a7c9176a4c87bb402f1a3e938ec04011
```

`arch_wait` holds the waiting version, the start of its wait, the arches it waits for and the AUR commit that built them when the wait started, and the push removes it. Later runs of the same wait add the arches they find missing and keep that commit. `arch_out` maps each arch left out to the last AUR commit that built it. Later checks build the arch URLs from that commit, and verify and publish compare the arch with it when it comes back. Arches leave `arch_out` with the first push whose `arch=()` lists them, also when the maintainer put them back by hand. Arches that the maintainer removes from `arch=()` never enter `arch_out`, and neither do arches that the commit's `.SRCINFO` does not list. Arches of `arch_out` whose `source_<arch>` AUR `PKGBUILD` no longer assigns were dropped by the maintainer: they stay out with no request for their archive, and the next push or version sync takes them out of `arch_out`. When the YAML commit after the push is lost, the next run finds the version on the AUR and writes to `arch_out` the arches of `arch_wait` that the AUR lacks, with the commit of `arch_wait`. The AUR log plays no part there, since anyone who can push to the package writes it.

## Statuses and README

| Moment | Status | README |
|---|---|---|
| wait | `pending: 28+23` | `⏳ 28+23 pending` |
| push without an arch | `updated: 28+23` | `📦 updated to 28+23 without aarch64` |
| runs after it, while the arch is out | `up_to_date` | `⚠️ 28+23 without aarch64` |
| check finds the arch back | `arch_back: 28+23 aarch64` | `✨ aarch64 for 28+23 available` |
| push that puts it back | `arch_added: 28+23 aarch64` | `📦 aarch64 added to 28+23` |
| arch back with a new version | `updated: 28+24` | `📦 updated to 28+24` |

Pushes that only put arches back commit to the AUR as `Add <arches> to <version>`, keep `pkgrel` and `last_updated`, and skip [cooldown](/features/cooldown/). While arches are out, the package has one open issue `⚠️ <package>: <version> without <arches>`, see [Issues](/features/issues/).

## Local updates

`check-all.sh --update` and `update-pkg.sh` without `--prepare` do not check arches, and missing archives stop them, see [Local testing](/develop/local-testing/).
