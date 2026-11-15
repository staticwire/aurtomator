---
title: Update alerts
---

Some packages need hand edits of the PKGBUILD at known points of the upstream version line, which `pkgver` bumps miss: new JDK majors need a newer boot JDK in `makedepends`, releases change the license, or the old major needs a package of its own. `alerts` names such points. Each rule fires on the step from `current` to the new version, and either holds the update or lets it through with a note for the maintainer.

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
| `from` | one of `when`, `from`, `match` | version: the new version is at or above it, and `current` is below it |
| `match` | one of `when`, `from`, `match` | ERE: the new version matches it, and `current` does not |
| `note` | yes | one line of text for the maintainer. Numbers, booleans and dates go in quotes, as in `note: '2024'` |
| `hold` | no | `true` holds the update. Default `false` |

Rules fire once at each crossing, when the new version meets their condition and `current` does not. `from` rules can stay in the file after their release, and `when: major` rules fire again at the next major. Versions are compared in `pkgver` form, as `current` holds them, with `vercmp` for `from` and by the first number for `when: major`, so `9 → 10` is a new major. Packages without `current` fire no rule. Downgrades and version jumps that the package does not allow are skipped first, see [Downgrades and version jumps](/features/downgrades/).

With `hold: true`, `check-all.sh` writes `held: <version>`, logs the first line below and pushes nothing, and the README shows `✋ 29+1 held`. The maintainer makes the edit, publishes the version by hand and sets `current` to it, and the rule no longer fires. Without `hold`, the update goes on and the log gets the second line. Each rule that fires logs its own line, so held updates show the notes of the other rules too.

```text
! myjdk-ea: update 28+25 → 29+1 held: Raise makedepends java-environment to 28
! myjdk-ea-bin: update 28+25 → 29+1 notice: Create the package for the old major
```

Held updates get the issue `✋ <package>: update held` with the notes of every rule that fired, since rules without `hold` no longer fire after the hand publish. The run closes it once the version is in the AUR. Published updates with notes get the issue `🔔 <package>: <version> notice`, and the maintainer closes it after the edit, see [Issues](/features/issues/). Held updates do not count as failures on the [statistics](/features/statistics/) card.

`validate-pkg.sh` refuses entries that break the table: other keys, not exactly one of `when`, `from` and `match`, or values of the wrong kind. It also refuses `when: major` together with `pkgver_format`, because the fixed text of formats such as `4.%s` holds the first number of every version. Rules that the check cannot evaluate fail the check of the package, so broken rules never let a held update through.
