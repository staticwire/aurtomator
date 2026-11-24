---
title: Update alerts
---

Some packages need hand edits of the PKGBUILD at known points of the upstream version line, which `pkgver` bumps miss: new JDK majors need a newer boot JDK in `makedepends`, releases change the license, or the old major needs a package of its own. Python packages list the requirements of the PyPI release in `depends`, so releases that add or drop one need an edit too. `alerts` names such points. Each rule fires on the step from `current` to the new version, and either holds the update or lets it through with a note for the maintainer.

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
| `when` | one of `when`, `from`, `match`, `requires` | `major`: the first number of the new version is greater than that of `current`, as in `28+25 → 29+1` |
| `from` | one of `when`, `from`, `match`, `requires` | version: the new version is at or above it, and `current` is below it |
| `match` | one of `when`, `from`, `match`, `requires` | ERE: the new version matches it, and `current` does not |
| `requires` | one of `when`, `from`, `match`, `requires` | `changed`: the names of the requirements that apply on Arch differ between the release in `current` and the new version. `unmet`: the `depends` of the AUR package do not meet a requirement of the new version. `pypi` only |
| `note` | yes, optional with `requires` | one line of text without tabs for the maintainer. Numbers, booleans and dates go in quotes, as in `note: '2024'` |
| `hold` | no | `true` holds the update. Default `false` |

Rules fire once at each crossing, when the new version meets their condition and `current` does not. `from` rules can stay in the file after their release, and `when: major` rules fire again at the next major. Versions are compared in `pkgver` form, as `current` holds them, with `vercmp` for `from` and by the first number for `when: major`, so `9 → 10` is a new major. Packages without `current` fire no rule in the check. The update itself applies the rules with `hold: true` to the step from `pkgver` of the AUR `.SRCINFO`, and such a rule that fires there fails the update with its note, so the package gets `update_failed` and no `held`. Downgrades and version jumps that the package does not allow are skipped first, see [Downgrades and version jumps](/features/downgrades/).

With `hold: true`, `check-all.sh` writes `held: <version>`, logs the first line below and pushes nothing, and the README shows `✋ 29+1 held`. The maintainer makes the edit, publishes the version by hand with the `.SRCINFO` of `makepkg --printsrcinfo` and sets `current` to it, and the rule no longer fires. Pushes whose `.SRCINFO` keeps the old version stop the next update, see [Downgrades and version jumps](/features/downgrades/). Without `hold`, the update goes on and the log gets the second line. Each rule that fires logs its own line, so held updates show the notes of the other rules too.

```text
! myjdk-ea: update 28+25 → 29+1 held: Raise makedepends java-environment to 28
! myjdk-ea-bin: update 28+25 → 29+1 notice: Create the package for the old major
```

Held updates get the issue `✋ <package>: update held` with the notes of every rule that fired, since rules without `hold` no longer fire after the hand publish. The run closes it once the version is in the AUR. Published updates with notes get the issue `🔔 <package>: <version> notice`, and the maintainer closes it after the edit, see [Issues](/features/issues/). Held updates do not count as failures on the [statistics](/features/statistics/) card.

`requires: changed` reads the requirements of both releases from their metadata on PyPI and compares their names in PEP 503 form. Requirements whose environment markers are false on Arch do not count, as the [pypi strategy](/strategies/#pypi) describes along with the metadata it reads, and neither do version clauses: black 26.1.0 to 26.10.1 turns `pytokens>=0.3.0` into `pytokens~=0.4.0` and adds `winloop` for Windows, and fires nothing. The rule notes the change as `adds <names>; drops <names>`, after its own note and a colon when it has one:

```yaml
name: zensical-bin
strategy: pypi
upstream:
  registry: zensical
alerts:
  - requires: changed
    hold: true
```

```text
! zensical-bin: update 0.0.74 → 0.1.3 held: drops deepmerge
```

`requires: unmet` reads the requirements of the new version as `changed` does, and the `.SRCINFO` of HEAD of the AUR repository of the package, and checks each pkgname whose `depends` hold `python` or `python-*`. Each requirement that applies on Arch needs an entry of `depends` that meets it. Entries meet a requirement when their package holds the distribution of that name in the files database of pacman, or when the package, its name or a name of its `provides` is `python-<name>`, `<name>` or `python-<name as written>`, or when `python.map` maps the name to it:

```yaml
python:
  map:
    svg-path: python-svg.path
```

The rule resolves names of `provides` with `pacman -Sddp` for the repositories and with the AUR RPC for the AUR. Versions come from the distribution in the files database, which the `check` job downloads with `pacman -Fy`, and otherwise from `pkgver`, which the note marks with `(pkgver)` or `(AUR pkgver)`. Packages of the same repository whose `upstream.pin_from` names the project count with the pin of the new version, since the run publishes them beside it. Extras of a requirement, as in `httpx[http2]`, need the requirements that the extra adds to that dependency, read from its metadata at its version in Arch. `Requires-Python` has to hold for the version that `pacman -Si python` prints.

```text
! ydiskarc: update 1.0.1 → 1.1.0 held: rich: not in depends
```

Missing entries, lower bounds, exact pins and `Requires-Python` hold the update under `hold: true`: `rich: not in depends`, `botocore<1.45.0,>=1.44.10: python-botocore has 1.43.108`, `httpx[http2]: h2 not in depends`, `Requires-Python <3.14: python has 3.14.10`. Upper caps that Arch exceeds give notices also under `hold: true`, since Arch ships such pairs: sympy 1.14.0 requires `mpmath<1.4,>=1.1.0`, and Arch has python-mpmath 1.4.1. Requirements on a URL, versions outside PEP 440, such as `r675.70e1dda` of a `-git` package, and extras whose metadata PyPI does not give for the version in Arch give notices too. The rule joins its notes with `; `, and in packages with more than one pkgname each note starts with its pkgname. Packages that the AUR lacks fire nothing. `unmet` reads no `current`, so it also runs for packages without `current`, and `--prepare` and `--publish` take its notes from the check run.

Releases of `current` that PyPI lacks fire the rule with `PyPI has no release <version> of <registry> to compare with`, and releases of `current` without metadata that lists their requirements fire it with `<registry> <version>: PyPI holds no metadata that lists the requirements without running code`, since only a publish moves `current`. New versions without such metadata fail the check. Other failed requests fail the check of the package with their URL, as failed strategies do. `--prepare` and `--publish` take the notes of these rules from the check run. `--prepare` asks PyPI again only for rules with `hold: true`, which it fires from the `pkgver` of the AUR, and `--publish` asks PyPI nothing. `requires` reads `current` as a version of PyPI, so it does not apply with `pkgver_format` or `pkgver_dash`.

`validate-pkg.sh` refuses entries that break the table: other keys, not exactly one of `when`, `from`, `match` and `requires`, or values of the wrong kind. It also refuses `when: major` together with `pkgver_format`, because the fixed text of formats such as `4.%s` holds the first number of every version. Packages take one `requires` rule of each value. Rules that the check cannot evaluate fail the check of the package, so broken rules never let a held update through. The rules of one package run under the time limit of its check, 120 seconds by default, and rules that take longer fail the check as well.
