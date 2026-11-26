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
| `requires` | one of `when`, `from`, `match`, `requires` | `changed`: the names of the requirements that apply on Arch differ between the release in `current` and the new version. `unmet`: the `depends` of the AUR package do not meet a requirement of the new version. `imports`: the files of the new version import modules that `depends` and `optdepends` do not hold. Strategy `pypi` or `rubygems`, `python.pypi` or `python.pyproject`, see [Python packages](#python-packages) and [Gems](#gems) |
| `note` | yes, optional with `requires` | one line of text without tabs for the maintainer. Numbers, booleans and dates go in quotes, as in `note: '2024'` |
| `hold` | no | `true` holds the update. Default `false` |

Rules fire once at each crossing, when the new version meets their condition and `current` does not. `from` rules can stay in the file after their release, and `when: major` rules fire again at the next major. Versions are compared in `pkgver` form, as `current` holds them, with `vercmp` for `from` and by the first number for `when: major`, so `9 → 10` is a new major. Packages without `current` fire no rule in the check. The update itself applies the rules with `hold: true` to the step from `pkgver` of the AUR `.SRCINFO`, and such a rule that fires there fails the update with its note, so the package gets `update_failed` and no `held`. Downgrades and version jumps that the package does not allow are skipped first, see [Downgrades and version jumps](/features/downgrades/).

With `hold: true`, `check-all.sh` writes `held: <version>`, logs the first line below and pushes nothing, and the README shows `✋ 29+1 held`. The maintainer makes the edit, publishes the version by hand with the `.SRCINFO` of `makepkg --printsrcinfo` and sets `current` to it, and the rule no longer fires. Pushes whose `.SRCINFO` keeps the old version stop the next update, see [Downgrades and version jumps](/features/downgrades/). Without `hold`, the update goes on and the log gets the second line. Each rule that fires logs its own line, so held updates show the notes of the other rules too.

```text
! myjdk-ea: update 28+25 → 29+1 held: Raise makedepends java-environment to 28
! myjdk-ea-bin: update 28+25 → 29+1 notice: Create the package for the old major
```

Held updates get the issue `✋ <package>: update held` with the notes of every rule that fired, since rules without `hold` no longer fire after the hand publish. The run closes it once the version is in the AUR. Published updates with notes get the issue `🔔 <package>: <version> notice`, and the maintainer closes it after the edit, see [Issues](/features/issues/). Held updates do not count as failures on the [statistics](/features/statistics/) card.

## Python packages

Packages whose `.SRCINFO` on the AUR has a pkgname with `python` or `python-*` in `depends` run the three `requires` rules in every check, listed or not. Entries of `alerts` set `hold` and `note` of their rule, and the rules that `alerts` does not list fire as notices. The check reads the `.SRCINFO` of HEAD from a shallow clone of the AUR repository, once per run, and packages that the AUR lacks run no rule. `validate-pkg.sh` reads the same at the version of `current` when a package is added or changed, so a package that the rules cannot read fails before its first new version, see [Add a package](/add-a-package/#3-validate-the-yaml). In the workflow, the rules download and parse releases in the job `rules`, one job for each package that needs them, without a token, and `publish` holds or notes the update by their lines, see [The jobs](/internals/workflow/#the-jobs). The requirements come from the release that the package names:

| Package | Key | Source |
|---|---|---|
| strategy `pypi` | none | `upstream.registry` at the new version |
| other strategies, project on PyPI | `python: {pypi: KubeDiagrams}` | that project at the new version |
| `-git` package of a project on PyPI | `python: {pypi: KubeDiagrams, release: newest}` | the newest release on PyPI, also for `imports` |
| no release on PyPI | `python: {pyproject: pyproject.toml}` | the `[project]` table of that file in the first https archive among the sources of the `.SRCINFO`, at the new version |
| Python in `depends`, no project | `python: none` | no rule, for strategy `pypi` too |

`python.pyproject` reads `name`, `requires-python` and `dependencies` of the `[project]` table, and `imports` reads the files of the same archive. It parses the whole file as TOML, so the table can also take the form of dotted keys such as `project.dependencies` or of an inline table, and CRLF line ends read as LF. Values with an escape, `dependencies` that hold anything but strings and text outside TOML fail the check with the reason, and so does a path other than a relative path to a `.toml` file without `..`, which `validate-pkg.sh` refuses too. It fails the check with `packages/<name>.yml: python.pyproject reads no static dependencies from <file>` when `dynamic` names `dependencies`, when the table has no `dependencies`, and when the sources hold no https archive, as with a git source. Packages with Python in `depends` and none of these keys fail their check with `packages/<name>.yml: its depends hold Python packages, so set python.pypi, python.pyproject or python: none`. `changed` runs where it can compare the release of `current` with the new version: not with `python.release`, `python.pyproject`, `pkgver_format` or `pkgver_dash`.

## The requires rules

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

`requires: unmet` reads the requirements of the new version as `changed` does, and the `.SRCINFO` of HEAD of the AUR repository of the package, and checks each pkgname whose `depends` hold `python` or `python-*`. Each requirement that applies on Arch needs an entry of `depends` that meets it. Entries meet a requirement when their package holds the distribution of that name, a `.dist-info` or `.egg-info` one, in the files database of pacman, or when the package, its name or a name of its `provides` is `python-<name>`, `<name>` or `python-<name as written>`, or when `python.map` maps the name to it:

```yaml
python:
  map:
    svg-path: python-svg.path
```

The rule resolves names of `provides` with `pacman -Sddp` for the repositories and with the AUR RPC for the AUR. Versions come from the distribution in the files database, which the `rules` job downloads with `pacman -Fy`, and otherwise from `pkgver`, which the note marks with `(pkgver)` or `(AUR pkgver)`. AUR versions other than `epoch:pkgver-pkgrel`, with a `pkgver` of the characters `A-Za-z0-9._+`, fail the check. Packages of the same repository whose `upstream.pin_from` names the project count with the pin of the new version, since the run publishes them beside it. Extras of a requirement, as in `httpx[http2]`, need the requirements that the extra adds to that dependency, read from its metadata at its version in Arch. `Requires-Python` has to hold for the version that `pacman -Si python` prints.

```text
! ydiskarc: update 1.0.1 → 1.1.0 held: rich: not in depends
```

Missing entries, lower bounds, exact pins and `Requires-Python` hold the update under `hold: true`: `rich: not in depends`, `botocore<1.45.0,>=1.44.10: python-botocore has 1.43.108`, `httpx[http2]: h2 not in depends`, `Requires-Python <3.14: python has 3.14.10`. Upper caps that Arch exceeds give notices also under `hold: true`, since Arch ships such pairs: sympy 1.14.0 requires `mpmath<1.4,>=1.1.0`, and Arch has python-mpmath 1.4.1. Requirements on a URL, versions outside PEP 440, such as `r675.70e1dda` of a `-git` package, and extras whose metadata PyPI does not give for the version in Arch give notices too. The rule joins its notes with `; `, and in packages with more than one pkgname each note starts with its pkgname. Packages that the AUR lacks fire nothing. `unmet` reads no `current`, so it also runs for packages without `current`, and `--prepare` and `--publish` take its notes from the check run.

`requires: imports` reads the files of the new version: a wheel, picked in the order of the metadata that the [pypi strategy](/strategies/#pypi) reads, otherwise the sdist without its `tests`, `test`, `docs`, `doc` and `examples` directories and without the build and test files `setup.py`, `conftest.py`, `noxfile.py`, `tasks.py` and `fabfile.py` at its top. `python.skip` lists more paths that the rule leaves out, relative to the top of the wheel or the sdist:

```yaml
python:
  skip:
    - tools
```

Archives within `upstream.max_answer_mb` have to match their sha256, and releases with more than 20 MB of Python files and scripts are not read. `scripts/lib/py_imports.py` parses every `.py` file and every script whose first line names `python` with the `ast` module of Python, which the `rules` job installs. Imports at module level are required when they run from a top-level package or module, from a `console_scripts` or `gui_scripts` entry of `entry_points.txt` or from a script, through the imports between the modules of the release. Imports inside functions, in `try` blocks that catch `ImportError`, under `suppress(ImportError)` and at module level of the other modules are optional, and imports under `if TYPE_CHECKING:` do not count, also when the test names it through a module, as `t.TYPE_CHECKING` after `import typing as t`. Tests on `sys.version_info`, `sys.platform`, `os.name` and `platform.system()` take the values of the Python of Arch on Linux, and imports in the branches they rule out do not count. Both branches of any other test, such as `if has_simplejson:`, are optional. Each module belongs to `python` for the standard library or to the package that holds it in `site-packages`, by the files database of pacman, else to an entry of `depends` or `optdepends` named `python-<module>`, else to the package that `python.map` names.

```text
! demo: update 1.0 → 1.1 notice: import tqdm: python-tqdm not in depends
```

Required imports whose package is not in `depends` note `import tqdm: python-tqdm not in depends`, optional ones whose package is in neither `depends` nor `optdepends` note `import numba (optional): python-numba in neither depends nor optdepends`, and required imports of a module that no package holds note `import foo: no package owns it`. Files that do not parse note `imports: <file> does not parse: <message>`. The rule gives notices alone, and `validate-pkg.sh` refuses `hold: true` on it. Without a files database, which local runs lack until `pacman -Fy`, and without `python3`, the rule notes that it read nothing. Errors of `pacman -Fx`, which looks up the owners of the modules, fail the check, for the gems of a package as well.

Releases of `current` that PyPI lacks fire the rule with `PyPI has no release <version> of <registry> to compare with`, and releases of `current` without metadata that lists their requirements fire it with `<registry> <version>: PyPI holds no metadata that lists the requirements without running code`, since only a publish moves `current`. New versions without such metadata fail the check. Other failed requests fail the check of the package with their URL, as failed strategies do. `--prepare` and `--publish` take the notes of these rules from the check run. `--prepare` asks PyPI again only for `changed` rules with `hold: true`, which it fires from the `pkgver` of the AUR, and `--publish` asks PyPI nothing.

## Gems

Packages whose `.SRCINFO` on the AUR has a pkgname with `ruby` or `ruby-*` in `depends` run the three `requires` rules on a gem in every check, listed or not, and the rules that `alerts` does not list fire as notices, as for Python. The rules read the runtime requirements and `ruby_version` of `https://rubygems.org/api/v2/rubygems/{gem}/versions/{version}.json?platform=ruby` for the gem that the package names:

| Package | Key | Source |
|---|---|---|
| strategy `rubygems` | none | `upstream.registry` at the new version |
| other strategies, gem on rubygems.org | `ruby: {gem: simplecov-cobertura}` | that gem at the new version |
| `-git` package, or no gem | `ruby: none` | no rule, for strategy `rubygems` too |

Packages with Ruby in `depends` and none of these keys fail their check with `packages/<name>.yml: its depends hold Ruby packages, so set ruby.gem or ruby: none`. `-git` packages take `ruby: none`, since rubygems.org has no release of their versions and gemspecs are Ruby code that the check does not run. `ruby.gem` does not apply to strategy `rubygems`, which reads `upstream.registry`. `changed` compares the names of the requirements of the release in `current` and of the new version, and fires with `rubygems.org has no release <version> of <gem> to compare with` for a release of `current` that rubygems.org lacks. It runs without `pkgver_format` and `pkgver_dash` alone, since their `current` is no release of the gem. `unmet` matches each requirement to an entry of `depends` as it does for Python: the package holds the gem in the files database of pacman, by its gemspec under `usr/lib/ruby/gems/` with the default gems of `ruby`, or the package, its name or a name it provides is `ruby-<gem>` or `<gem>`, or `ruby.map` names it. Under `hold: true` it holds the update for missing entries, for each clause that the version fails, since RubyGems checks every clause when a program loads the gem, and for a `ruby_version` that the `ruby` of Arch fails:

```text
! bashcov: update 3.3.0 → 4.0.3 held: simplecov ~> 1.1: ruby-simplecov has 0.22.0
```

`imports` reads the `.gem` of the new version from its `gem_uri`, within `upstream.max_answer_mb` and after its sha256 matches, and takes `bindir`, `executables` and `require_paths` from its `metadata.gz`. `scripts/lib/rb_requires.rb` parses the `.rb` files of the require paths and the executables with Prism, which the `rules` job installs with `ruby`, and prints each `require`, `require_relative` and `load` of a string. Requires at file level and in class and module bodies are required when they run from `lib/<gem>.rb` or an executable through the files of the gem; requires inside methods and blocks of `define_method`, in `begin` blocks that rescue `LoadError`, `ScriptError` or `Exception`, and at file level of the other files are optional. Bare `rescue` catches `StandardError` alone, and `LoadError` descends from `ScriptError`, so requires under it stay required. Tests of `RUBY_ENGINE` and `RUBY_PLATFORM` with `==`, `!=`, `=~`, `!~`, `match?`, `include?`, `start_with?` and `end_with?`, and `Gem.win_platform?`, take the values of Ruby on Arch, `ruby` and `x86_64-linux`, and requires in the branches they rule out, as for JRuby or Windows, do not count. Requires name a feature with or without `.rb`, `.so` or `.jar`, and the extensions that the gem builds at install, by the `create_makefile` of each `ext/<dir>/extconf.rb` of its `extensions` or else by `<dir>`, count as files of the gem. Each require path belongs to `ruby` or a package that `ruby` depends on, such as `rubygems`, to the package that holds it in `lib/` of an installed gem by the files database of pacman, to an entry of `depends` or `optdepends` named `ruby-<first part of the path>`, or to the package that `ruby.map` names, and features built into the interpreter, such as `enumerator`, need none. Notes follow those of Python, as `require simplecov: ruby-simplecov not in depends`.

`ruby.skip` lists gems that the rules leave out, such as gems for Windows. `imports` leaves out the require paths of such a gem: those whose first part is its name, and those whose parts joined by dashes start with it, as `win32/process` for `win32-process`. `ruby.relax: true` marks a PKGBUILD that turns `~>` into `>=`, and upper bounds of `~>` that Arch exceeds then give notices. Versions outside the grammar of RubyGems give notices as well.

```yaml
ruby:
  map:
    simplecov: ruby-simplecov
  skip: [win32ole]
  relax: true
```

`validate-pkg.sh` refuses entries that break the table: other keys, not exactly one of `when`, `from`, `match` and `requires`, or values of the wrong kind. It also refuses `when: major` together with `pkgver_format`, because the fixed text of formats such as `4.%s` holds the first number of every version. Packages take one `requires` rule of each value, and `requires` rules need strategy `pypi` or `rubygems`, `python.pypi`, `python.pyproject` or `ruby.gem`. `changed` does not apply with `python.release` or `python.pyproject`, and `hold: true` does not apply to `imports`. Rules that the check cannot evaluate fail the check of the package, so broken rules never let a held update through. The rules of one package run under the time limit of its check, 120 seconds by default, and rules that take longer fail the check as well.
