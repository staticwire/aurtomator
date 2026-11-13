---
title: Strategies
---

aurtomator has 16 version detection strategies. Pick the one that reads the source the PKGBUILD downloads, because two sources of one project can disagree: the streamrip PKGBUILD builds the git tag `v2.2.0` from GitHub while PyPI still holds `2.1.0`, so `pypi` would report a downgrade in every run. A vendor page can also sit behind a bot check that its download host does not have, see [Upstreams behind a bot check](#upstreams-behind-a-bot-check).

| Strategy | Source | Best for | Pre-releases |
|---|---|---|---|
| `github-release` | GitHub Releases API | most GitHub projects | left out |
| `github-tag` | `git ls-remote` | projects without releases | only `v1.2.3` tags by default |
| `github-nightly` | GitHub Releases API | nightly and dev builds, in 4 patterns | by pattern |
| `github-asset` | GitHub Releases API | assets replaced on a fixed tag, such as model zoos | fixed tag |
| `gitlab-tag` | GitLab Tags API | gitlab.com, invent.kde.org, self-hosted | only `v1.2.3` tags by default |
| `gitea-tag` | Gitea and Forgejo Tags API | Codeberg, self-hosted Gitea | only `v1.2.3` tags by default |
| `gitea-release` | Gitea and Forgejo Releases API | releases on Codeberg or a self-hosted Gitea | drafts and pre-releases left out |
| `git-tag` | `git ls-remote` | any HTTPS git host: sourcehut, kernel.org, Savannah | only `v1.2.3` tags by default |
| `git-latest` | bare git clone | `-git` packages, which follow commits | none |
| `pypi` | PyPI JSON API | Python packages | stable only |
| `npm` | npm registry | Node.js packages | the `latest` tag |
| `crates` | crates.io API | Rust packages | stable only, or `prerelease: true` |
| `repology` | Repology API | a fallback across distribution repositories, the AUR left out | by repository |
| `archpkg` | Arch package search | the version of an official package | none |
| `webpage-scrape` | any HTTPS page and a regex | upstreams without an API | as the regex reads |
| `kde-tarball` | download.kde.org | KDE projects | none |

## Strategy limitations

- The GitHub strategies send `GITHUB_TOKEN` when it is set. The workflow sets it to the workflow token, which allows 1,000 requests per hour per repository, and a local run without a token gets 60. `github-tag` reads tags with `git ls-remote`, outside this limit.
- A request with curl tries a timeout, a refused connection and an HTTP 408, 429, 500, 502, 503, 504, 522 or 524 answer twice more, 5 seconds apart. The git calls of `git-latest`, `github-tag` and `git-tag` make one attempt. A check that fails within its time limit runs once more after the other packages and a pause of 60 seconds.
- An answer can hold at most 50 MB, and the page of `webpage-scrape` 5 MB, unless `upstream.max_answer_mb` sets another limit, see [Package YAML](/package-yaml/).
- Without `tag_version_regex`, the tag strategies keep only tags of the form `v1.2.3` or `1.2.3`, so `latest`, `1.0.0-rc1` and `1.0.0rc1` are left out. They pick the newest version by `vercmp`, the order of pacman, which puts `1.0.0rc1` and `1.0.0-rc1` below `1.0.0`, so a regex that lets pre-release tags through picks the release once it is out. A repository that tags releases `13` and `14` and builds `2026102100` gives the build, which `check-all.sh` holds as a version jump, see [Downgrades and version jumps](/features/downgrades/); `tag_version_regex: '^([0-9]{1,3})$'` keeps the releases.
- `gitlab-tag` reads at most 100 tags and `gitea-tag` 50. `git-tag` with the `.git` URL of the project reads every tag, and `gitea-release` reads up to 500 releases.
- `gitlab-tag` sends no credentials, so it cannot read a private GitLab project.

## Upstreams behind a bot check

Some sites answer a client without a browser with a check page in place of the data, and a failed check names the kind of page it met.

A Cloudflare challenge answers HTTP 403 with the header `cf-mitigated: challenge`. Only a browser passes it, whatever the User-Agent, and the check fails with `<url>: The requested URL returned error: 403, a Cloudflare challenge, which only a browser passes`. The host the PKGBUILD downloads from, or a package repository of the vendor, often answers without it. The page `https://anydesk.com/en/downloads/linux` of anydesk-bin is behind the challenge, and its apt repository is not:

```yaml
name: anydesk-bin
strategy: webpage-scrape
upstream:
  url: https://deb.anydesk.com/dists/all/main/binary-amd64/Packages
  pattern: 'Version: ([0-9.]+)'
```

A site can also run a check of its own. forge.soutade.fr redirects every request without its cookie to a page that asks "Are you Human?", the API, git and the archives alike. `gitea-tag` and `gitlab-tag` fail with the URL of that page, and the source check refuses the archives as HTML, see [Source URL returns HTML](/supported-packages/#source-url-returns-html-blocked). aurtomator sends no cookie, so a package behind such a check, as libgourou is, cannot be supported.

## Upstream sources not covered

The Go module proxy, proxy.golang.org, needs `webpage-scrape` or a custom strategy. Private registries of GitLab, npm or PyPI and FTP servers need a custom strategy, since `webpage-scrape` reads public HTTPS pages only and sends no credentials.

## Strategy reference

A strategy is a bash script in `strategies/`. It takes the package name, reads its settings from the package YAML and prints one version on stdout, or an error on stderr with a non-zero exit code. The tag strategies strip a leading `v`.

### github-release

**Upstream:** the GitHub Releases API, `/repos/{owner}/{repo}/releases/latest`, or the release list with `tag_version_regex`.

**YAML fields:**

| Field | Required | Description |
|---|---|---|
| `upstream.project` | yes | `owner/repo` |
| `upstream.tag_version_regex` | no | an ERE whose first capture group is the version, see below |
| `upstream.tag_version_replace` | no | the version built from the groups of `tag_version_regex`, `\1` by default, see below |
| `upstream.asset_regex` | no | an ERE whose one capture group is a value from an asset name of the release, see [Values from release asset names](/features/asset-values/) |
| `upstream.asset_var` | with `asset_regex` | the PKGBUILD variable that holds that value |

**Version:** `.tag_name` of the latest release, without a leading `v`. The endpoint skips drafts and pre-releases. When it answers 404, the strategy reads the release list to say why: a list of pre-releases only gets a message that names `github-nightly` with `nightly_tag_regex`, and an empty list one that names `github-tag`.

With `tag_version_regex`, the strategy reads up to 10 pages of 100 releases, leaves out drafts and pre-releases, and takes the highest version among the matching tags by `vercmp`, as [github-tag](#github-tag) does. A fix release of an older line is then no downgrade, and a repository that releases several products gives the release of the product the regex names. tutao/tutanota publishes its web, desktop and mobile apps as separate releases:

```yaml
name: tutanota-desktop-bin
strategy: github-release
upstream:
  project: tutao/tutanota
  tag_version_regex: '^tutanota-desktop-release-(.*)$'
```

**Authentication:** with `GITHUB_TOKEN` set, the strategy sends it as a Bearer token, which curl reads from stdin, so the token never appears on a command line.

**Example YAML:**

```yaml
name: my-package
strategy: github-release
upstream:
  project: owner/repo
```

**Custom tag format:** for tags such as `MeshLab-2025.07` or `0.1.8-stable`, the text of the first capture group of `tag_version_regex` becomes the version. bash `[[ =~ ]]` takes the group, so the regex may hold `|`. bash has no group that does not capture, so without `tag_version_replace` a group of alternatives comes after the version, as in `^v?([0-9.]+)(-stable|)$`: `^(mesa-)?([0-9.]+)$` gives `mesa-`.

```yaml
name: meshlab-bin
strategy: github-release
upstream:
  project: cnr-isti-vclab/meshlab
  tag_version_regex: 'MeshLab-(.*)'
```

`tag_version_replace` builds the version from several groups: `\1` to `\9` stand for the groups, and every other character is copied. The tag `2026-09-10` gives `2026.09.10` here:

```yaml
name: whitesur-icon-theme
strategy: github-release
upstream:
  project: vinceliuice/WhiteSur-icon-theme
  tag_version_regex: '^([0-9]{4})-([0-9]{2})-([0-9]{2})$'
  tag_version_replace: '\1.\2.\3'
```

`validate-pkg.sh` refuses `tag_version_replace` without `tag_version_regex`, with a character other than `A-Za-z0-9._+` outside `\1` to `\9`, or with a group the regex does not have. Both fields work with `github-tag`, `github-nightly`, `gitlab-tag`, `gitea-tag`, `gitea-release` and `git-tag` too, and with no other strategy.

### github-tag

**Upstream:** the tags of the repository, from `git ls-remote --tags --refs https://github.com/{owner}/{repo}.git`.

**YAML fields:**

| Field | Required | Description |
|---|---|---|
| `upstream.project` | yes | `owner/repo` |
| `upstream.tag_version_regex` | no | an ERE whose first capture group is the version, in place of the default filter |
| `upstream.tag_version_replace` | no | the version built from the groups of `tag_version_regex`, see [github-release](#github-release) |
| `upstream.asset_regex` | no | an ERE whose one capture group is a value from an asset name of the release of the tag, see [Values from release asset names](/features/asset-values/) |
| `upstream.asset_var` | with `asset_regex` | the PKGBUILD variable that holds that value |

**Version:** the newest version among the tags by `vercmp`, read in one request outside the API rate limit. Without `tag_version_regex` it keeps the tags `v1.2.3` and `1.2.3`, and a project without such a tag fails with a message that names the field. The comparison drops a dash before a letter, so `1.0.0-rc1` sorts below `1.0.0`, and reads any other dash as a dot, so `2025-04-03` compares as `2025.04.03`. With `pkgver_dash` `_` or `.`, pacman puts `1.0.0_rc1` above `1.0.0`, which then shows as a skipped downgrade, see [Package YAML](/package-yaml/).

**Authentication:** with `GITHUB_TOKEN` set, git sends it to `github.com`, which a private repository needs, through `GIT_CONFIG_*` variables and never on a command line. git takes `https` alone and asks for no password.

**Example YAML:**

```yaml
name: my-package
strategy: github-tag
upstream:
  project: owner/repo
```

A package that follows one release line pins it with the regex. kubernetes gives `1.36.5` here, and `1.37.1` without the field:

```yaml
name: my-kubectl-1.36
strategy: github-tag
upstream:
  project: kubernetes/kubernetes
  tag_version_regex: '^v(1\.36\.[0-9]+)$'
```

### github-nightly

**Upstream:** the GitHub releases of nightly builds, in 4 patterns that the fields select:

- A, a fixed tag, the default: `nightly_tag` names one tag that moves, as in neovim, ghostty and yazi.
- B, dated tags: `nightly_tag` is a prefix with a dash, such as `nightly-`, and of the first 20 releases the first whose tag contains it wins, as for ruffle. With `nightly_tag_regex` in place of `nightly_tag`, the release published last among up to 300 whose tag matches the ERE wins, as for servo.
- C, a separate nightly repository: `nightly_tag: latest` reads `/releases/latest` of the build repository, as for yt-dlp.
- D, a channel: of the first 20 releases the first whose name contains `channel` wins, as for brave.

Patterns B and C depend on how a repository files its releases. `/releases/latest` skips pre-releases, so for ruffle-rs/ruffle, which files its nightlies as pre-releases, pattern C gives the stable `v0.7.1`. The release list is in the order of the dates of the tagged commits, and every release of servo/servo-nightly-builds carries `2024-02-14` there, so `nightly_tag: '-'` picks `v0.7.0-rc1`. `nightly_tag_regex` ranks by `published_at` and depends on neither order.

```yaml
# Pattern A
name: myapp-nightly-bin
strategy: github-nightly
upstream:
  project: owner/repo
  nightly_tag: nightly
  version_source: release_body
  version_pattern: 'APP v\K\S+'
```

```yaml
# Pattern B
name: myapp-nightly-bin
strategy: github-nightly
upstream:
  project: owner/repo
  nightly_tag: "nightly-"
  version_source: tag_date
```

```yaml
# Pattern C
name: myapp-nightly-bin
strategy: github-nightly
upstream:
  project: owner/nightly-builds
  nightly_tag: latest
  version_source: tag
```

```yaml
# Pattern D
name: myapp-nightly-bin
strategy: github-nightly
upstream:
  project: owner/repo
  channel: Nightly
  version_source: tag
```

**YAML fields:**

| Field | Required | Description |
|---|---|---|
| `upstream.project` | yes | `owner/repo` |
| `upstream.nightly_tag` | no | the tag or its prefix, `nightly` by default, `latest` for pattern C |
| `upstream.nightly_tag_regex` | no | an ERE for the tag of pattern B, in place of `nightly_tag` and `channel` |
| `upstream.version_source` | no | `tag` (default), `release_body`, `tag_date` or `published_date` |
| `upstream.version_pattern` | for `release_body` | a Perl regex for the version in the release body. A dash in the match becomes `+` |
| `upstream.tag_version_regex` | no | an ERE whose first capture group is the version, for `version_source: tag` |
| `upstream.tag_version_replace` | no | the version built from the groups of `tag_version_regex`, see [github-release](#github-release) |
| `upstream.date_format` | no | the format of `date` for `tag_date` and `published_date`, `%Y.%m.%d` by default |
| `upstream.channel` | for pattern D | text that the name of the release contains |

`tag_date` takes the `YYYY-MM-DD` date in the tag and `published_date` the UTC date of `published_at`, and the two can differ: the servo release `2026-10-21` was published at `2026-10-22T00:25:00Z`. A package whose `pkgver` has the form `20251213` needs `date_format: '%Y%m%d'`, because `vercmp` ranks `20251213` above `2026.10.21`:

```yaml
name: servo-nightly-bin
strategy: github-nightly
upstream:
  project: servo/servo-nightly-builds
  nightly_tag_regex: '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
  version_source: tag_date
  date_format: '%Y%m%d'
```

`validate-pkg.sh` refuses a field that the chosen pattern and `version_source` do not read: `date_format` without a date source, `version_pattern` without `release_body`, `tag_version_regex` and `tag_version_replace` without `tag`, `nightly_tag_regex` beside `nightly_tag` or `channel`, and `nightly_tag` beside `channel`. It also refuses `release_body` without `version_pattern`, `tag_date` with the fixed tag of pattern A, which holds no date, a `date_format` whose output is no valid version, such as `%Y-%m-%d`, and a regex that does not compile.

**Authentication:** as `github-release`.

### github-asset

**Upstream:** one GitHub release by tag, `/repos/{owner}/{repo}/releases/tags/{tag}`, and the `updated_at` of the assets listed in the package YAML.

Use it for a release whose tag never moves while its assets are replaced, such as a model zoo, a rolling download tag or the `nightly` tag of `wezterm/wezterm`. The PKGBUILD points at fixed URLs, so an update changes `pkgver`, `pkgrel` and the checksums alone. `pkgver` holds the date, and the audit blocks a `pkgver()` with this strategy, see [pkgver() with the wrong strategy](/supported-packages/#pkgver-with-the-wrong-strategy-blocked).

**YAML fields:**

| Field | Required | Description |
|---|---|---|
| `upstream.project` | yes | `owner/repo` |
| `upstream.tag` | yes | the release tag that carries the assets |
| `upstream.assets` | yes | the exact file names of the assets, at least one |

**Version:** the newest `updated_at` among the listed assets, as `YYYYMMDD`, such as `20251202`, so a new upload of any of them moves the version forward. A listed asset missing from the release fails the check and is named.

**Authentication:** as `github-release`.

**Example YAML:**

```yaml
name: sherpa-onnx-piper-voices-ru
strategy: github-asset
upstream:
  project: k2-fsa/sherpa-onnx
  tag: tts-models
  assets:
    - vits-piper-ru_RU-denis-medium.tar.bz2
    - vits-piper-ru_RU-dmitri-medium.tar.bz2
```

### gitlab-tag

**Upstream:** the GitLab Tags API, `/api/v4/projects/{id}/repository/tags`, on gitlab.com, invent.kde.org or a self-hosted instance.

**YAML fields:**

| Field | Required | Description |
|---|---|---|
| `upstream.host` | yes | the GitLab host, such as `invent.kde.org` or `gitlab.com` |
| `upstream.project` | yes | the project path, such as `network/my-kde-app` |
| `upstream.tag_version_regex` | no | an ERE whose first capture group is the version, in place of the default filter, see [github-release](#github-release) |
| `upstream.tag_version_replace` | no | the version built from the groups of `tag_version_regex`, see [github-release](#github-release) |

**Version:** the newest version among the first 100 tags, picked as [github-tag](#github-tag) picks it. An answer that is no JSON, such as the page of a bot check, fails the check with the URL of that page, see [Upstreams behind a bot check](#upstreams-behind-a-bot-check).

**Example YAML:**

```yaml
name: my-kde-app
strategy: gitlab-tag
upstream:
  host: invent.kde.org
  project: network/my-kde-app
```

Mesa names its releases `mesa-26.2.5`:

```yaml
name: my-mesa
strategy: gitlab-tag
upstream:
  host: gitlab.freedesktop.org
  project: mesa/mesa
  tag_version_regex: '^mesa-([0-9.]+)$'
```

### gitea-tag

**Upstream:** the Gitea and Forgejo Tags API, `/api/v1/repos/{owner}/{repo}/tags`, on Codeberg or a self-hosted instance.

**YAML fields:**

| Field | Required | Description |
|---|---|---|
| `upstream.host` | yes | the host, such as `codeberg.org` |
| `upstream.project` | yes | `owner/repo` |
| `upstream.tag_version_regex` | no | an ERE whose first capture group is the version, in place of the default filter, see [github-release](#github-release) |
| `upstream.tag_version_replace` | no | the version built from the groups of `tag_version_regex`, see [github-release](#github-release) |

**Version:** the newest version among the first 50 tags, picked as [github-tag](#github-tag) picks it. An answer that is no JSON fails the check with the URL of that page, see [Upstreams behind a bot check](#upstreams-behind-a-bot-check).

**Example YAML:**

```yaml
name: my-package
strategy: gitea-tag
upstream:
  host: codeberg.org
  project: owner/repo
```

### git-latest

**Upstream:** any git repository with an HTTPS URL, through a bare clone. Use it for a `-git` package that follows the latest commit.

**YAML fields:**

| Field | Required | Description |
|---|---|---|
| `upstream.type` | yes | `github`, `gitlab` or `git` |
| `upstream.host` | for `gitlab` | the GitLab host |
| `upstream.project` | for `github` and `gitlab` | the project path |
| `upstream.url` | for `git` | the full clone URL, `https://` only |
| `upstream.branch` | no | the branch of a source pinned to `#branch=`, the default branch of the repository by default |
| `upstream.describe` | no | `tags` or `annotated`: the form of `git describe` in place of `r<count>.<hash>` |
| `upstream.tag_prefix` | no | text cut from the start of the tag with `upstream.describe`, such as `v` |

Each type reads only its own of `host`, `project` and `url`, and `validate-pkg.sh` refuses the others.

**Version:** `r<count>.<hash>`, the usual form of a `-git` package, such as `r431.66db9ce`: the number of commits on `HEAD` and its hash. The clone holds commits and tags alone, `--filter=tree:0`, since the strategy reads no files. With `upstream.branch`, `HEAD` is that branch, as makepkg checks it out for `#branch=`, and a branch the repository does not have fails the clone. The hash takes as many characters as the hash in `current`, and 7 without `current`: `git rev-parse --short` in a `pkgver()` gives more characters as a repository grows, and `vercmp` reads `r2173.ef2e985` as newer than `r2173.ef2e985d` of the same commit.

With `upstream.describe`, the strategy prints what the `git describe` recipes of the [Arch package guidelines for VCS packages](https://manual.archlinux.page/package-guidelines/vcs/) print: `git describe --long`, with `--tags` for `describe: tags` and annotated tags alone for `describe: annotated`. `upstream.tag_prefix` is cut from the tag first, as `sed 's/^v//'` does, then `v1.2.0-rc1-47-g0bbf5ad` becomes `1.2.0.rc1.r47.g0bbf5ad`. The hash keeps at least the length of the hash after `.g` in `current`. A repository without a tag reachable from `HEAD` fails with `git describe finds no tag reachable from HEAD of <url>`.

`current` must be empty or of the form the strategy prints, and `validate-pkg.sh` refuses any other: `vercmp` reads `1.4.0.r47.g0bbf5ad` as newer than every `r<count>.<hash>`, so a mixed `current` would make every check a downgrade, or an update on the same commit.

A new commit is a new version, and a push of a `git-latest` package waits 7 days after the last one unless `cooldown_days` says otherwise, see [Cooldown](/features/cooldown/).

The clone runs with `GIT_ALLOW_PROTOCOL=https`, so a URL from a pull request cannot read a local repository, use the SSH key of the machine, or redirect the clone to http.

**Example YAML:**

```yaml
name: my-package-git
strategy: git-latest
upstream:
  type: github
  project: owner/repo
```

```yaml
name: my-package-git
strategy: git-latest
upstream:
  type: gitlab
  host: invent.kde.org
  project: network/my-kde-app
```

```yaml
name: my-package-git
strategy: git-latest
upstream:
  type: git
  url: "https://git.sr.ht/~user/repo"
```

lightdm-git counts with `git describe --long --tags | sed 's/\([^-]*-g\)/r\1/;s/-/./g'`, and git gives its hash 8 characters, which the AUR version as `current` keeps:

```yaml
name: lightdm-git
strategy: git-latest
upstream:
  type: github
  project: CanonicalLtd/lightdm
  describe: tags
current: '1.30.0.r9.g03f21898'
```

### pypi

**Upstream:** the PyPI JSON API, `https://pypi.org/pypi/{package}/json`. **Version:** `.info.version`, the latest stable release.

| Field | Required | Description |
|---|---|---|
| `upstream.registry` | yes | the PyPI name, such as `requests` |

```yaml
name: python-requests
strategy: pypi
upstream:
  registry: requests
```

### npm

**Upstream:** the npm registry, `https://registry.npmjs.org/{package}/latest`. **Version:** `.version` of the `latest` tag.

| Field | Required | Description |
|---|---|---|
| `upstream.registry` | yes | the npm name, such as `express` |

```yaml
name: nodejs-express
strategy: npm
upstream:
  registry: express
```

### crates

**Upstream:** the crates.io API, `https://crates.io/api/v1/crates/{crate}`. **Version:** `.crate.max_stable_version`, or `.crate.max_version` with `prerelease: true`. The request sends `User-Agent: aurtomator/1.0`, as the crates.io API policy requires.

| Field | Required | Description |
|---|---|---|
| `upstream.registry` | yes | the crate name, such as `serde` |
| `upstream.prerelease` | no | `true` reads pre-releases too and needs `pkgver_dash`. Default `false` |

```yaml
name: rust-serde
strategy: crates
upstream:
  registry: serde
```

A semver pre-release such as `1.0.0-beta.24` holds a dash, so `prerelease: true` needs `pkgver_dash`, see [Package YAML](/package-yaml/). pijul gives `1.0.0.beta.24` here, and its release `1.0.0` then reads as a skipped downgrade. With `pkgver_dash: ''` it gives `1.0.0beta.24`, which `vercmp` puts below `1.0.0`.

```yaml
name: pijul
strategy: crates
upstream:
  registry: pijul
  prerelease: true
pkgver_dash: .
```

### repology

**Upstream:** the Repology API, `https://repology.org/api/v1/project/{name}`, a fallback when no other strategy fits.

| Field | Required | Description |
|---|---|---|
| `upstream.repology` | no | the Repology project, the package `name` by default |

**Version:** the version of the first `newest` entry outside the AUR, since the AUR entries hold the version of this package. When only the AUR is newest, the newest `outdated` version outside the AUR, and a `current` above it reads as a downgrade. The version is the normalized `version` of Repology: the OpenBSD entry of qodem gives `1.0.1` for its `1.0.1p1`. It lags until a distribution other than the AUR packages the release. The request sends `User-Agent: aurtomator/1.0`, as Repology asks.

An unknown project fails with `Project <name> not found on Repology`, and a project without a `newest` or `outdated` entry outside the AUR with `No version found on Repology for <name> outside the AUR`. Repology names a library of Python, Ruby, Perl or Haskell `<language>:<name>`, such as `ruby:rmagick`, and the search at `https://repology.org/projects/?search=rmagick` lists it:

```yaml
name: ruby-rmagick
strategy: repology
upstream:
  repology: ruby:rmagick
```

### archpkg

**Upstream:** the Arch Linux package search, `https://archlinux.org/packages/search/json/?name={name}`. Use it for an AUR package that follows the `pkgver` of an official package, such as an addon released with it.

| Field | Required | Description |
|---|---|---|
| `upstream.archpkg` | no | the official package, the package `name` by default |
| `upstream.testing` | no | `true` reads `core-testing`, `extra-testing` and `multilib-testing` too. Default `false` |

**Version:** the `pkgver` of the newest entry of `core`, `extra` and `multilib` by `vercmp`, the epoch included: ffmpeg `2:9.0.2-2` gives `9.0.2`. With `testing: true`, a build in testing wins while it is newer than the stable one. A raised epoch, as `1:2.0` to `2:1.0`, gives `1.0` after `2.0`, a skipped downgrade: the maintainer raises the epoch in the AUR package, publishes `1.0` by hand and sets `current`. A rebuild in the official repositories raises only `pkgrel` and gives no update, see [Packages needing a pkgrel bump](/supported-packages/#packages-needing-a-pkgrel-bump). A package found in none of the repositories fails with `Package not found in core, extra, multilib: <name>`.

```yaml
name: my-qt6-addon
strategy: archpkg
upstream:
  archpkg: qt6-base
```

### webpage-scrape

**Upstream:** any HTTPS page and a regex that matches the version, for an upstream without an API.

| Field | Required | Description |
|---|---|---|
| `upstream.url` | yes | the HTTPS URL of the page |
| `upstream.pattern` | yes | an ERE whose first capture group is the version |
| `upstream.user_agent` | no | a User-Agent in printable ASCII in place of `aurtomator/1.0`. SourceForge answers a bare `Mozilla/5.0` with 403 |

**Version:** the newest version by `vercmp` among the first capture groups of every match on the page. The page comes over HTTPS with at most 5 redirects. bash takes the groups, so the pattern may hold any character, `/` included, and `validate-pkg.sh` refuses a pattern that bash cannot compile, such as one with `(?:...)`, or one without a group.

```yaml
name: my-scrape-pkg
strategy: webpage-scrape
upstream:
  url: "https://www.example.com/~maintainer/my-scrape-pkg/"
  pattern: "my-scrape-pkg-([0-9.]+)\\.tar\\.gz"
```

A version file published as a release asset is read through its download URL. `jpenilla/ghostty-nightly-bin` publishes the version of each Ghostty nightly build as `ghostty-nightly-version.txt`:

```yaml
name: ghostty-nightly-bin
strategy: webpage-scrape
upstream:
  url: https://github.com/jpenilla/ghostty-nightly-bin/releases/download/nightly/ghostty-nightly-version.txt
  pattern: '^([0-9]{8}\.r[0-9]+\.g[0-9a-f]+)$'
```

### kde-tarball

**Upstream:** the listing of `https://download.kde.org/{path}/`. Use it for a KDE project with release tarballs there, in one directory, such as `stable/kio-s3/kio-s3-1.0.2.tar.xz`, or in a directory per version or series: Plasma under `stable/plasma/6.8.1/`, Frameworks under `stable/frameworks/6.31/`, KDE Gear under `stable/release-service/26.08.2/src/`.

| Field | Required | Description |
|---|---|---|
| `upstream.project` | no | the tarball name, the package `name` by default |
| `upstream.path` | no | the directory on download.kde.org, `stable/{project}` by default |

**Version:** the highest version of the links `{project}-{version}.tar.xz`, with a version of digits and dots, in the listing and in its newest version directory, with the `src/` in it when there is one. A newest directory without a tarball of the project fails the check and is named, so a project dropped from Plasma is not followed into an older directory.

```yaml
name: my-kde-app
strategy: kde-tarball
```

The Oxygen theme comes with Plasma, so its tarball sits in the directory of each Plasma release:

```yaml
name: xcursor-oxygen
strategy: kde-tarball
upstream:
  project: oxygen
  path: stable/plasma
```

### git-tag

**Upstream:** the tags of any git repository, from `git ls-remote --tags --refs {url}`. Use it for a host without a tags API, such as sourcehut, kernel.org and Savannah, and for a GitLab or Gitea project with more tags than `gitlab-tag` or `gitea-tag` read.

| Field | Required | Description |
|---|---|---|
| `upstream.url` | yes | the HTTPS URL of the repository |
| `upstream.tag_version_regex` | no | an ERE whose first capture group is the version, in place of the default filter |
| `upstream.tag_version_replace` | no | the version built from the groups of `tag_version_regex`, see [github-release](#github-release) |

**Version:** as [github-tag](#github-tag). git takes `https` alone, asks for no password and sends no `GITHUB_TOKEN`, so only a public repository works. A repository behind the bot check of its site fails with the message of git, which names the page of the redirect.

```yaml
name: my-package
strategy: git-tag
upstream:
  url: https://git.sr.ht/~owner/repo
```

The `.git` URL of a GitLab or Gitea project works the same way:

```yaml
name: my-package
strategy: git-tag
upstream:
  url: https://gitlab.gnome.org/GNOME/gtk.git
```

### gitea-release

**Upstream:** the Gitea and Forgejo Releases API, `/api/v1/repos/{owner}/{repo}/releases/latest`, and `/releases` with `tag_version_regex`. Use it for a project on Codeberg or another Gitea or Forgejo host that also pushes tags that are no release, which [gitea-tag](#gitea-tag) would read.

| Field | Required | Description |
|---|---|---|
| `upstream.host` | yes | the host, such as `codeberg.org` |
| `upstream.project` | yes | `owner/repo` |
| `upstream.tag_version_regex` | no | an ERE whose first capture group is the version, read from the release list, see [github-release](#github-release) |
| `upstream.tag_version_replace` | no | the version built from the groups of `tag_version_regex`, see [github-release](#github-release) |

**Version:** the tag of `/releases/latest`, the newest release by date that is neither a draft nor a pre-release, without a leading `v`. A 404 there makes the check read the release list to say whether the project has no release or pre-releases only. With `tag_version_regex`, the newest version by `vercmp` among the matching tags of up to 10 pages of 50 releases, drafts and pre-releases left out, which suits a repository that releases several products. An answer that is no JSON fails the check with the URL of that page, see [Upstreams behind a bot check](#upstreams-behind-a-bot-check).

```yaml
name: my-package
strategy: gitea-release
upstream:
  host: codeberg.org
  project: owner/repo
```
