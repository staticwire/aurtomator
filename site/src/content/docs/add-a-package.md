---
title: Add a package
---

## 1. Draft the YAML

```bash
./aurtomator.sh draft my-package
```

It reads the `.SRCINFO` of the package in the AUR, writes `packages/my-package.yml` with a strategy, its `upstream` fields and `current`, and runs steps 3 and 4 below on the file, see [Draft a package](#draft-a-package). When no rule matches the url or a source of the package, it writes nothing, and you write the file from the sample:

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

`name` is the `pkgbase` on the AUR, the name of its git repository. It is the package name, except for a split package: liblinear with `pkgname=(liblinear python-liblinear)` has the `name` `liblinear`, and `python-liblinear` gets no YAML of its own. [Strategy reference](/strategies/#strategy-reference) has YAML examples for all 16 strategies.

## 3. Validate the YAML

```bash
./aurtomator.sh validate-pkg my-package
```

It checks the YAML syntax, the required fields and the fields of the strategy.

## 4. Test the version check

```bash
./aurtomator.sh check-update my-package
```

It runs the strategy and prints the latest upstream version.

## 5. Test the update

```bash
./aurtomator.sh update-pkg my-package 1.2.3 --dry-run
```

It clones the AUR repository, sets `pkgver`, regenerates the checksums and `.SRCINFO`, runs `namcap` when it is installed, and shows the diff of the PKGBUILD without a push. It changes no file of your repository.

The dry run runs the PKGBUILD of the AUR on your machine: the audit, the check of the source URLs, `namcap`, `makepkg --printsrcinfo`, `updpkgsums` and `makepkg --verifysource` source it, with your SSH key in reach of its code. When someone else can push to the AUR package, read its PKGBUILD first.

## 6. Push

Commit the package YAML and push it to your repository. A push to `main` runs `Validate packages`. `Check AUR Package Updates` runs on the schedule `17 * * * *` of `.github/workflows/check-updates.yml`, and GitHub starts only part of those runs: in October 2026 a repository with this schedule got about five a day. Actions > Check AUR Package Updates > Run workflow starts a run at once. A run started by hand on a branch other than the default one reads the package YAMLs of that branch, pushes their updates to the AUR and commits its results to that branch. The schedule runs on the default branch alone.

## Draft a package

```bash
./aurtomator.sh draft my-package
```

[![./aurtomator.sh draft hello-bin writes packages/hello-bin.yml with the github-release strategy, validates it and finds the update from 1.4.2 to 2.0.0](/demo/draft.gif)](/demo/draft.gif)

The command clones the AUR repository of the package and reads its `.SRCINFO` as data: `pkgver`, `epoch`, `url` and every `source` and `source_<arch>` of the pkgbase section. It never reads or runs the PKGBUILD. An unknown name stops it with `No AUR package my-package`, and an existing `packages/my-package.yml` stops it and stays as it is.

The first source that a rule matches decides. A rule reads the URL after a `<file>::` prefix, without its query and fragment, and a local file or a signature (`.sig`, `.asc`, `.sign`) matches none:

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

A `-git` package is one whose name ends in `-git`, as the Arch guidelines name them, since `.SRCINFO` does not show a `pkgver()`. A `git-latest` draft takes `branch` from the `#branch=` of its source. The `path` of a KDE tarball is its directory without a last `src/` and without a last directory of the version or the series: `stable/plasma/6.9.5/oxygen-6.9.5.tar.xz` gives `stable/plasma`, as [kde-tarball](/strategies/#kde-tarball) reads it.

When no source matches, the `url` of the package decides: a `https://github.com/<owner>/<repo>` gives `github-tag`, `https://gitlab.com/<group>/<project>` gives `gitlab-tag`, and `https://codeberg.org/<owner>/<repo>` gives `gitea-tag`. When that fails too, the command prints the `url`, every source it read and the command that writes the file from the sample, and exits with status 1.

The file holds `name`, `strategy`, the fields of `upstream`, and `current` from `pkgver`. Each value is written as a string, so quotes or `$(...)` from a `.SRCINFO` stay text. A `pkgver` that `current` cannot hold, a control character other than a tab in the `.SRCINFO`, or a `.SRCINFO` larger than 1 MiB stops the command before it writes the file. With an `epoch` other than 0, it prints the warning of the PKGBUILD audit. Then it runs `validate-pkg.sh` and `check-update.sh` on the file, which shows a strategy that reads another version than `current`. When either fails, the file stays for an edit, and the command exits with status 1. A `-git` package whose `pkgver` has the form of `git describe` fails `validate-pkg` until `upstream.describe` is set, see [git-latest](/strategies/#git-latest).
