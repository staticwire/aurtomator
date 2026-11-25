---
title: Add a package
---

## 1. Draft the YAML

```bash
./aurtomator.sh draft my-package
```

It reads the AUR `.SRCINFO` of the package, writes `packages/my-package.yml` with a strategy, its `upstream` fields and `current`, and runs steps 3 and 4 below on the file, see [Draft a package](#draft-a-package). When no rule matches the package url or its sources, it writes nothing, and you write the file from the sample:

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

`name` is AUR `pkgbase`, the name of its git repository. It equals the package name, except for split packages: liblinear with `pkgname=(liblinear python-liblinear)` has `name: liblinear`, and `python-liblinear` gets no YAML of its own. [Strategy reference](/strategies/#strategy-reference) has YAML examples for all 17 strategies.

## 3. Validate the YAML

```bash
./aurtomator.sh validate-pkg my-package
```

It checks YAML syntax, required fields and strategy fields. Online, it also reads what the requires rules of each new version need, as the check reads them: the `.SRCINFO` of the package on the AUR, the `python` or `ruby` key of a package with Python or Ruby in `depends`, and the requirements of the release of `current` on PyPI or rubygems.org, see [Update alerts](/features/update-alerts/). It fails when a rule could not read them, and when the network fails.

## 4. Test the version check

```bash
./aurtomator.sh check-update my-package
```

It runs the strategy and prints the latest upstream version.

## 5. Test the update

```bash
./aurtomator.sh update-pkg my-package 1.2.3 --dry-run
```

It clones the AUR repository, sets `pkgver`, regenerates checksums and `.SRCINFO`, runs `namcap` when it is installed, and shows the PKGBUILD diff without a push. It changes no file of your repository.

The dry run runs AUR PKGBUILD on your machine: the audit, the source URL check, `namcap`, `makepkg --printsrcinfo`, `updpkgsums` and `makepkg --verifysource` source it, with your SSH key in reach of its code. When others can push to the AUR package, read its PKGBUILD first.

## 6. Push

Commit the package YAML and push it to your repository. Pushes to `main` run `Validate packages`. `Check AUR Package Updates` runs on the schedule `17 * * * *` of `.github/workflows/check-updates.yml`, and GitHub starts only part of those runs: in October 2026 a repository with this schedule got about five a day. Actions > Check AUR Package Updates > Run workflow starts a run at once. Runs started by hand on a branch other than the default one read the package YAMLs of that branch, push their updates to the AUR and commit their results to that branch. The schedule runs on the default branch alone.

## Draft a package

```bash
./aurtomator.sh draft my-package
```

[![./aurtomator.sh draft hello-bin writes packages/hello-bin.yml with the github-release strategy, validates it and finds the update from 1.4.2 to 2.0.0](/demo/draft.gif)](/demo/draft.gif)

The command clones the AUR repository of the package and reads its `.SRCINFO` as data: `pkgver`, `epoch`, `url` and every `source` and `source_<arch>` of the pkgbase section. It never reads or runs the PKGBUILD. Unknown names stop it with `No AUR package my-package`, and existing `packages/my-package.yml` files stop it and stay as they are.

The first source that a rule matches decides. Rules read the URL after the `<file>::` prefix, without its query and fragment, and local files and signatures (`.sig`, `.asc`, `.sign`) match none:

| Source | Strategy | Fields |
|---|---|---|
| `https://github.com/<owner>/<repo>/releases/download/...` | `github-release` | `project` |
| `https://github.com/<owner>/<repo>/archive/...` | `github-tag` | `project` |
| `git+https://github.com/<owner>/<repo>` | `git-latest` with `type: github` for `-git` packages, else `github-tag` | `project` |
| `https://<host>/<group>/<project>/-/archive/...`, GitLab on any host | `gitlab-tag` | `host`, `project` |
| `git+https://gitlab.com/<group>/<project>` | `git-latest` with `type: gitlab` for `-git` packages, else `gitlab-tag` | `host`, `project` |
| `https://codeberg.org/<owner>/<repo>/releases/download/...` | `gitea-release` | `host`, `project` |
| `https://codeberg.org/<owner>/<repo>/archive/...` | `gitea-tag` | `host`, `project` |
| any other `git+https://...` | `git-latest` with `type: git` for `-git` packages, else `git-tag` | `url` |
| `https://files.pythonhosted.org/packages/source/<letter>/<name>/...`, or the same path on `pypi.io` | `pypi` | `registry` |
| `https://registry.npmjs.org/<name>/-/...`, with `@<scope>/<name>` too | `npm` | `registry` |
| `https://static.crates.io/crates/<name>/...`, `https://crates.io/api/v1/crates/<name>/...` | `crates` | `registry` |
| `https://rubygems.org/downloads/<name>-<version>.gem`, the same under `https://rubygems.org/gems/` | `rubygems` | `registry` |
| `https://download.kde.org/<path>/.../<project>-<pkgver>.tar.xz` | `kde-tarball` | `project` and `path` where they differ from the defaults |

`-git` packages are those whose name ends in `-git`, as the Arch guidelines name them, since `.SRCINFO` does not show `pkgver()`. `git-latest` drafts take `branch` from the `#branch=` of their source. For KDE tarballs, `path` is their directory without a trailing `src/` and without a trailing version or series directory: `stable/plasma/6.9.5/oxygen-6.9.5.tar.xz` gives `stable/plasma`, as [kde-tarball](/strategies/#kde-tarball) reads it.

When no source matches, the package `url` decides: `https://github.com/<owner>/<repo>` gives `github-tag`, `https://gitlab.com/<group>/<project>` gives `gitlab-tag`, `https://codeberg.org/<owner>/<repo>` gives `gitea-tag`, and `https://rubygems.org/gems/<name>` gives `rubygems`. When that fails too, the command prints the `url`, every source it read and the command that writes the file from the sample, and exits with status 1.

The file holds `name`, `strategy`, the `upstream` fields, and `current` from `pkgver`. Each value is written as a string, so quotes or `$(...)` from `.SRCINFO` stay text. `pkgver` values that `current` cannot hold, control characters other than tabs in `.SRCINFO`, and `.SRCINFO` files larger than 1 MiB stop the command before it writes the file. With `epoch` other than 0, it prints the PKGBUILD audit warning. Then it runs `validate-pkg.sh` and `check-update.sh` on the file, which shows strategies that read another version than `current`. When either fails, the file stays for an edit, and the command exits with status 1. `-git` packages whose `pkgver` has the form of `git describe` fail `validate-pkg` until `upstream.describe` is set, see [git-latest](/strategies/#git-latest).
