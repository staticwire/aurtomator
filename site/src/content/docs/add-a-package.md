---
title: Add a package
---

## 1. Draft the YAML

```bash
./aurtomator.sh draft my-package
```

It reads the `.SRCINFO` of the package in the AUR, writes `packages/my-package.yml` with a strategy, its `upstream` fields and `current`, and runs steps 3 and 4 below on that file, see [Draft a package](#draft-a-package). When no rule matches the url or a source of the package, it writes nothing. Then write the file from the example:

```bash
./aurtomator.sh sample > packages/my-package.yml
```

## 2. Edit the YAML

```yaml
name: my-package
strategy: github-release
upstream:
  project: owner/repo
```

`name` is the `pkgbase` on the AUR, the name of its git repository. It is the package name, except for a split package: liblinear with `pkgname=(liblinear python-liblinear)` has the `name` `liblinear`, and `python-liblinear` has no YAML of its own.

[Strategy reference](/strategies/#strategy-reference) has YAML examples for all 16 strategies.

## 3. Validate the config

```bash
./aurtomator.sh validate-pkg my-package
```

It checks the YAML syntax, the required fields and the fields each strategy needs.

## 4. Test the version check

```bash
./aurtomator.sh check-update my-package
```

It runs the strategy and prints the latest upstream version. Without a `current` field in the YAML, it also reports that no current version is set.

## 5. Test the update (dry run)

```bash
./aurtomator.sh update-pkg my-package 1.2.3 --dry-run
```

It clones the AUR repo, sets `pkgver`, regenerates checksums and `.SRCINFO`, runs `namcap` when it is installed, and shows the PKGBUILD diff **without pushing**. It changes no file of your repository: when the AUR already has the version, it says so and stops.

The dry run runs the PKGBUILD of the AUR on your machine before it stops: the audit, the check of the source URLs, `namcap` and `makepkg --printsrcinfo` source it, as `updpkgsums` and `makepkg --verifysource` do for a package with checksums, and your SSH key is in reach of that code. When someone else can push to the AUR package, read its PKGBUILD first.

## 6. Push and let CI take over

Commit the package YAML and push to your repository. The push to `main` runs `Validate packages`. `Check AUR Package Updates` runs on the schedule `17 * * * *` of `.github/workflows/check-updates.yml`, and GitHub starts only part of those runs: in October 2026 a repository with this schedule got about five a day, one every five hours. Actions > Check AUR Package Updates > Run workflow starts a run at once, through `workflow_dispatch`. A run started by hand from a branch other than the default one reads the package YAMLs of that branch, pushes their updates to the AUR, and commits its results to that branch. The schedule runs on the default branch only.

## Draft a package

```bash
./aurtomator.sh draft my-package
```

![./aurtomator.sh draft hello-bin writes packages/hello-bin.yml with the github-release strategy, validates it and finds the update from 1.4.2 to 2.0.0](/demo/draft.gif)

The command writes a first `packages/my-package.yml` from the AUR. The argument must have the form of a package name, and an existing `packages/my-package.yml` stops the command and stays as it is. It clones the AUR repository of the package with `--depth 1` and without a checkout, so no attribute or filter of that repository applies, and reads its `.SRCINFO` from the commit as data: `pkgver`, `epoch`, `url` and every `source` and `source_<arch>` of the pkgbase section, in their order. It never reads or runs the PKGBUILD. The AUR serves an empty repository for an unknown name, so a clone without `.SRCINFO` stops the command with `No AUR package my-package`, and a `.SRCINFO` that is a link stops it as well. A `pkgver` with a character outside `A-Za-z0-9._+` or without a digit stops it before it writes the file.

The first source that a rule matches decides. The rules read the URL after a `<file>::` prefix, without its query and its fragment, and a local file and a signature (`.sig`, `.asc`, `.sign`) match none:

| Source | Strategy | Fields |
|---|---|---|
| `https://github.com/<owner>/<repo>/releases/download/...` | `github-release` | `project` |
| `https://github.com/<owner>/<repo>/archive/...` | `github-tag` | `project` |
| `git+https://github.com/<owner>/<repo>` | `git-latest` with `type: github` for a `-git` package, else `github-tag` | `project` |
| `https://<host>/<group>/<project>/-/archive/...`, GitLab on any host | `gitlab-tag` | `host`, `project` |
| `git+https://gitlab.com/<group>/<project>` | `git-latest` with `type: gitlab` for a `-git` package, else `gitlab-tag` | `host`, `project` |
| `https://codeberg.org/<owner>/<repo>/releases/download/...` | `gitea-release` | `host`, `project` |
| `https://codeberg.org/<owner>/<repo>/archive/...` | `gitea-tag` | `host`, `project` |
| any other `git+https://...` | `git-latest` with `type: git` for a `-git` package, else `git-tag` | `url` |
| `https://files.pythonhosted.org/packages/source/<letter>/<name>/...`, or the same path on `pypi.io` | `pypi` | `registry` |
| `https://registry.npmjs.org/<name>/-/...`, with `@<scope>/<name>` too | `npm` | `registry` |
| `https://static.crates.io/crates/<name>/...`, `https://crates.io/api/v1/crates/<name>/...` | `crates` | `registry` |
| `https://download.kde.org/<path>/.../<project>-<pkgver>.tar.xz` | `kde-tarball` | `project` and `path` where they differ from the defaults |

A `git-latest` draft also takes `branch` from the `#branch=` of its source. A `-git` package is one whose name ends in `-git`, as the Arch guidelines name them, because `.SRCINFO` does not show whether the PKGBUILD has a `pkgver()`. The `path` of a KDE tarball is its directory without a last `src/` and without a last directory of digits and dots, the version or the series: `stable/plasma/6.9.5/oxygen-6.9.5.tar.xz` and `stable/frameworks/6.9/kio-6.9.0.tar.xz` give `stable/plasma` and `stable/frameworks`, as [kde-tarball](/strategies/#kde-tarball) reads them.

When no source matches, the `url` of the package decides: `https://github.com/<owner>/<repo>` gives `github-tag`, `https://gitlab.com/<group>/<project>` gives `gitlab-tag`, and `https://codeberg.org/<owner>/<repo>` gives `gitea-tag`. When that fails too, the command writes no file, prints the `url` and every source it read and the command that writes the file from the sample, and exits with status 1.

The file holds `name`, `strategy`, the fields of `upstream` and `current` from `pkgver`. `yq` writes each value as a string, so quotes or `$(...)` from a `.SRCINFO` stay text in the YAML. With an `epoch` other than 0, the command prints the warning of the PKGBUILD audit, see [Step-by-step](/internals/update-process/#step-by-step). It prints the strategy, the source or the url it came from, and the file. The epoch, the url and the sources it prints show each control byte as `?`, because the AUR package sets them and a terminal acts on such a byte. Then it runs `validate-pkg.sh` and, when that passes, `check-update.sh` on the file, see [Check a single package](/develop/local-testing/#check-a-single-package), which shows a strategy that reads another version than `current`. When either fails, the file stays for an edit, and the command says to fix or delete it and exits with status 1. A `-git` package whose `pkgver` has the form of `git describe` fails `validate-pkg` until `upstream.describe` is set, see [git-latest](/strategies/#git-latest).
