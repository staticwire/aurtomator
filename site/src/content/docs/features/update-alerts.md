---
title: Update alerts
---

Some packages need a hand edit of the PKGBUILD at a known point of the upstream version line, which a bump of `pkgver` misses: a new major of a JDK needs a newer boot JDK in `makedepends`, a release changes the license, or the old major needs a package of its own. `alerts` names such points. Each rule fires on the step from `current` to the new version, and either holds the update or lets it through with a note for the maintainer.

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

| Field | Required | Description |
|---|---|---|
| `when` | one of `when`, `from`, `match` | `major`: the first number of the new version is greater than that of `current`, as in `28+25 → 29+1` |
| `from` | one of `when`, `from`, `match` | a version: the new version is at or above it, and `current` is below it |
| `match` | one of `when`, `from`, `match` | an ERE: the new version matches it, and `current` does not |
| `note` | yes | one line of text for the maintainer. A number, a boolean or a date goes in quotes, as in `note: '2024'` |
| `hold` | no | `true` holds the update. Default `false` |

A rule fires once at each crossing, when the new version meets its condition and `current` does not. A `from` rule can stay in the file after its release, and a `when: major` rule fires again at the next major. The versions are compared in `pkgver` form, as `current` holds them, with `vercmp` for `from` and by the first number for `when: major`, so `9 → 10` is a new major. A package without `current` fires no rule. A downgrade or a version jump that the package does not allow is skipped first, see [Downgrades and version jumps](/features/downgrades/).

With `hold: true`, `check-all.sh` writes `held: <version>`, logs the first line below and pushes nothing, and the README shows `✋ 29+1 held`. The maintainer makes the edit, publishes the version by hand and sets `current` to it, and the rule no longer fires. Without `hold`, the update goes on and the log gets the second line. Each rule that fires logs its own line, so a held update shows the notes of the other rules too.

```text
! myjdk-ea: update 28+25 → 29+1 held: Raise makedepends java-environment to 28
! myjdk-ea-bin: update 28+25 → 29+1 notice: Create the package for the old major
```

A held update gets the issue `✋ <package>: update held` with the notes of every rule that fired, since a rule without `hold` no longer fires after the hand publish. The run closes it once the version is in the AUR. A published update with a note gets the issue `🔔 <package>: <version> notice`, and the maintainer closes it after the edit, see [Issues](/features/issues/). A held update is no failure on the [statistics](/features/statistics/) card.

`validate-pkg.sh` refuses an entry that breaks the table: another key, not exactly one of `when`, `from` and `match`, or a value of the wrong kind. It also refuses `when: major` together with `pkgver_format`, because the fixed text of a format such as `4.%s` holds the first number of every version. A rule that the check cannot evaluate fails the check of the package, so a broken rule never lets a held update through.
