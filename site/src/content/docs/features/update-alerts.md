---
title: Update alerts
---

Some packages need a hand edit of the PKGBUILD at a known point of the upstream version line, and a bump of `pkgver` alone misses it: a new major of a JDK needs a newer boot JDK in `makedepends`, a release changes the license, or the old major needs a package of its own. `alerts` names such points. Each rule fires on the step from `current` to the new version, and either pauses the update or lets it through with a note for the maintainer.

```yaml
alerts:
  - when: major
    note: Create the package for the old major
  - from: '0.4.0'
    hold: true
    note: License changes to Apache-2.0
  - match: '^29\+'
    hold: true
    note: Raise makedepends java-environment to 28
```

| Field   | Required | Description |
|---------|----------|-------------|
| `when`  | one of `when`, `from`, `match` | `major`: the first number of the new version is greater than the first number of `current`, as in `28+25 → 29+1` |
| `from`  | one of `when`, `from`, `match` | A version: the new version is at or above it, and `current` is below it |
| `match` | one of `when`, `from`, `match` | An ERE: the new version matches it, and `current` does not |
| `note`  | yes      | One line of text for the maintainer. A number, a boolean or a date goes in quotes, as in `note: '2024'` |
| `hold`  | no       | `true` pauses the update. Default `false` |

A rule fires when the new version meets its condition and `current` does not, so it fires once at each crossing. A `from` rule can stay in the file after the release it names, and a `when: major` rule fires again at the next major. The versions are in `pkgver` form, as `current` holds them, after `pkgver_dash` and `pkgver_format`. `vercmp` compares a version with `from` and the first numbers for `when: major`, so `9 → 10` is a new major. A package without `current` fires no rule.

With `hold: true`, `check-all.sh` writes `held: <version>`, logs the first line below and pushes nothing. The maintainer makes the edit, publishes the version by hand and sets `current` in the package YAML to it. The rule then no longer fires, and the next run finds the package up to date. Without `hold`, the update goes on, and `check-all.sh` logs the second line. Every rule that fires logs its own line, so a held update shows the notes of the other rules too.

```text
! myjdk-ea: update 28+25 → 29+1 held: Raise makedepends java-environment to 28
! myjdk-ea-bin: update 28+25 → 29+1 notice: Create the package for the old major
```

A skipped downgrade or version jump comes first, see [Downgrades and version jumps](/features/downgrades/). `--prepare` and `--publish` apply the rules again to the version of the check run. A held update does not count among the failing packages of the statistics card, and `update-readme.sh` renders `held: 29+1` as `✋ 29+1 held`.

Every rule that fires writes its note to `.status/_alerts`. The run opens an issue from the notes for a held update and for a published one, see [Issues](/features/issues/). A held update gets the issue `✋ <package>: update held` with the notes of every rule that fired, because after the hand publish a rule without `hold` no longer fires. The run closes it once the version is in the AUR. A published update gets the issue `🔔 <package>: <version> notice` with its notes, and the maintainer closes it once the edit is done.

`validate-pkg.sh` refuses an entry with any other key, without exactly one of `when`, `from` and `match`, with `when` other than `major`, with a `from` that is not a version, a `match` that bash does not accept as an ERE, a `note` that is not one line of text, or a `hold` that is not a boolean. It refuses `when: major` together with `pkgver_format`, because the fixed text of a format such as `4.%s` holds the first number of every version. `check-all.sh` reads the rules on every run. A rule it cannot evaluate, or a `note` that is not one line of text, fails the check of the package and never lets a held update through.
