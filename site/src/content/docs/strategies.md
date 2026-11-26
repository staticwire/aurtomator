---
title: Strategies
---

aurtomator has 17 version detection strategies. Pick the one that reads the source the PKGBUILD downloads, because two sources of one project can disagree: the streamrip PKGBUILD builds the git tag `v2.2.0` from GitHub while PyPI still holds `2.1.0`, so `pypi` would report a downgrade in every run. Vendor pages can also sit behind a bot check that their download host does not have, see [Upstreams behind a bot check](#upstreams-behind-a-bot-check).

| Strategy | Source | Best for | Pre-releases |
|---|---|---|---|
| `github-release` | GitHub Releases API | GitHub projects with releases | left out |
| `github-tag` | `git ls-remote` | GitHub projects without releases | only `v1.2.3` tags by default |
| `github-nightly` | GitHub Releases API | GitHub nightly and dev builds, in 4 patterns | by pattern |
| `github-asset` | GitHub Releases API | GitHub release assets replaced on a fixed tag, such as model zoos | fixed tag |
| `gitlab-tag` | GitLab Tags API | GitLab projects on gitlab.com or a self-hosted instance | only `v1.2.3` tags by default |
| `gitea-tag` | Gitea and Forgejo Tags API | Codeberg, Gitea and Forgejo projects without releases | only `v1.2.3` tags by default |
| `gitea-release` | Gitea and Forgejo Releases API | Codeberg, Gitea and Forgejo projects with releases | drafts and pre-releases left out |
| `git-tag` | `git ls-remote` | projects on any HTTPS git host: sourcehut, kernel.org, Savannah | only `v1.2.3` tags by default |
| `git-latest` | bare git clone | `-git` packages, which follow commits | none |
| `pypi` | PyPI JSON API | Python packages | stable only |
| `npm` | npm registry | Node.js packages | `latest` tag |
| `crates` | crates.io API | Rust crates | stable only, or `prerelease: true` |
| `rubygems` | rubygems.org API | Ruby gems | stable only |
| `repology` | Repology API | fallback across distribution repositories, the AUR left out | by repository |
| `archpkg` | Arch package search | official Arch packages | none |
| `webpage-scrape` | any HTTPS page and a regex | upstreams without an API | as the regex reads |
| `kde-tarball` | download.kde.org | KDE projects | none |

## Strategy limitations

- The GitHub strategies send `GITHUB_TOKEN` when it is set. The workflow sets it to the workflow token, which allows 1,000 requests per hour per repository, and local runs without a token get 60. `github-tag` reads tags with `git ls-remote`, outside this limit. With a token, `check-all.sh` first reads the releases of the `github-release` packages over GraphQL, which has a budget of its own, 50 repositories in one request: `/releases/latest`, and the release list of each repository with at most 100 releases. The strategy then reads these answers in place of REST requests, and asks REST for what GraphQL did not answer, such as a renamed repository. These answers hold no assets, which `check-asset.sh` reads over REST. Repositories of `github-nightly` packages stay with REST, since that strategy can read the notes of releases in a list. Before every tenth check that asks REST, the check run reads `GET /rate_limit`, which counts against no limit, and gives such packages `unchecked:` once fewer than 400 requests of the hour are left, since `publish` commits and the issues job writes over the same limit.
- Check runs keep a pace between the requests to each host, as the host states it: one a second to `repology.org` and `crates.io`, ten a second to `rubygems.org`, about eight a second to `gitlab.com`, five a second to hosts that state none, and no pause for `pypi.org`, which asks for none, and `api.github.com`, which counts above. Repology counts more than 1000 requests a day as bulk, so a check run gives the `repology` packages 40 checks and the rest `unchecked:`, and the next run takes the 40 after them, so each package gets its check within a known number of runs. Runs by hand have no run number and take the next 40 each hour.
- Requests with curl retry timeouts, refused connections and HTTP 408, 429, 500, 502, 503, 504, 522 and 524 answers twice, 5 seconds apart or after the wait of a `Retry-After` header, and start no retry later than 75 seconds after the first attempt. The git calls of `git-latest`, `github-tag` and `git-tag` make one attempt and stop when they receive less than 100 KiB/s for 60 seconds. Checks that fail within their time limit run once more after the other packages and a pause of 60 seconds.
- Answers can hold at most 50 MB, and `webpage-scrape` pages 5 MB, unless `upstream.max_answer_mb` sets another limit, see [Package YAML](/package-yaml/).
- Without `tag_version_regex`, the tag strategies keep only tags of the form `v1.2.3` or `1.2.3`, so `latest`, `1.0.0-rc1` and `1.0.0rc1` are left out. They pick the newest version by `vercmp`, the order of pacman, which puts `1.0.0rc1` and `1.0.0-rc1` below `1.0.0`, so regexes that let pre-release tags through pick the release once it is out. Repositories that tag releases `13` and `14` and builds `2026102100` give the build, which `check-all.sh` holds as a version jump, see [Downgrades and version jumps](/features/downgrades/); `tag_version_regex: '^([0-9]{1,3})$'` keeps the releases.
- `gitlab-tag` reads at most 100 tags and `gitea-tag` 50. `git-tag` with the `.git` URL of the project reads every tag of a listing within the answer limit above, and `gitea-release` reads up to 500 releases.
- `gitlab-tag` sends no credentials, so it cannot read private GitLab projects.

## Upstreams behind a bot check

Some sites answer clients without a browser with a check page in place of the data, and failed checks name the kind of page they met.

Cloudflare challenges answer HTTP 403 with the header `cf-mitigated: challenge`. Only browsers pass them, whatever the User-Agent, and the check fails with `<url>: The requested URL returned error: 403, a Cloudflare challenge, which only a browser passes`. The host the PKGBUILD downloads from, or a package repository of the vendor, often answers without it. The page `https://anydesk.com/en/downloads/linux` of anydesk-bin is behind the challenge, and its apt repository is not:

```yaml
name: anydesk-bin
strategy: webpage-scrape
upstream:
  url: https://deb.anydesk.com/dists/all/main/binary-amd64/Packages
  pattern: 'Version: ([0-9.]+)'
```

Sites can also run checks of their own. forge.soutade.fr redirects every request without its cookie to a page that asks "Are you Human?", the API, git and the archives alike. `gitea-tag` and `gitlab-tag` fail with the URL of that page, and the source check refuses the archives as HTML, see [Source URL returns HTML](/supported-packages/#source-url-returns-html-blocked). aurtomator sends no cookie, so packages behind such a check, as libgourou is, cannot be supported.

## Upstream sources not covered

The Go module proxy, proxy.golang.org, needs `webpage-scrape` or a custom strategy. Private registries of GitLab, npm or PyPI and FTP servers need a custom strategy, since `webpage-scrape` reads public HTTPS pages only and sends no credentials.

## Strategy reference

Strategies are bash scripts in `strategies/`. Each takes the package name, reads its settings from the package YAML and prints one version on stdout, or an error on stderr with a non-zero exit code. The tag strategies strip the leading `v`.

### github-release

**Upstream:** the GitHub Releases API, `/repos/{owner}/{repo}/releases/latest`, or the release list with `tag_version_regex`.

**YAML fields:**

| Field | Required | Description |
|---|---|---|
| `upstream.project` | yes | `owner/repo` |
| `upstream.tag_version_regex` | no | ERE whose first capture group is the version, see below |
| `upstream.tag_version_replace` | no | version built from the groups of `tag_version_regex`, `\1` by default, see below |
| `upstream.asset_regex` | no | ERE whose one capture group is a value from a release asset name, see [Values from release asset names](/features/asset-values/) |
| `upstream.asset_var` | with `asset_regex` | PKGBUILD variable that holds that value |

**Version:** `.tag_name` of the latest release, without the leading `v`. The endpoint skips drafts and pre-releases. When it answers 404, the strategy reads the release list to say why: lists of pre-releases only get a message that names `github-nightly` with `nightly_tag_regex`, and empty lists one that names `github-tag`.

With `tag_version_regex`, the strategy reads up to 10 pages of 100 releases, leaves out drafts and pre-releases, and takes the highest version among the matching tags by `vercmp`, as [github-tag](#github-tag) does. Fix releases of an older line are then no downgrade, and repositories that release several products give the release of the product the regex names. tutao/tutanota publishes its web, desktop and mobile apps as separate releases:

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

**Custom tag format:** for tags such as `MeshLab-2025.07` or `0.1.8-stable`, the text of the first capture group of `tag_version_regex` becomes the version. bash `[[ =~ ]]` takes the group, so the regex may hold `|`. bash has no group that does not capture, so without `tag_version_replace` groups of alternatives come after the version, as in `^v?([0-9.]+)(-stable|)$`: `^(mesa-)?([0-9.]+)$` gives `mesa-`.

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

`validate-pkg.sh` refuses `tag_version_replace` without `tag_version_regex`, with characters other than `A-Za-z0-9._+` outside `\1` to `\9` and `\p`, with `\p` outside [github-nightly](#github-nightly), or with groups the regex does not have. Both fields work with `github-tag`, `github-nightly`, `gitlab-tag`, `gitea-tag`, `gitea-release` and `git-tag` too, and with no other strategy.

### github-tag

**Upstream:** the tags of the repository, from `git ls-remote --tags --refs https://github.com/{owner}/{repo}.git`.

**YAML fields:**

| Field | Required | Description |
|---|---|---|
| `upstream.project` | yes | `owner/repo` |
| `upstream.tag_version_regex` | no | ERE whose first capture group is the version, in place of the default filter |
| `upstream.tag_version_replace` | no | version built from the groups of `tag_version_regex`, see [github-release](#github-release) |
| `upstream.asset_regex` | no | ERE whose one capture group is a value from an asset name of the release of the tag, see [Values from release asset names](/features/asset-values/) |
| `upstream.asset_var` | with `asset_regex` | PKGBUILD variable that holds that value |

**Version:** the newest version among the tags by `vercmp`, read in one request outside the API rate limit. Without `tag_version_regex` it keeps the tags `v1.2.3` and `1.2.3`, and projects without such tags fail with a message that names the field. The comparison drops dashes before a letter, so `1.0.0-rc1` sorts below `1.0.0`, and reads other dashes as dots, so `2025-04-03` compares as `2025.04.03`. With `pkgver_dash` `_` or `.`, pacman puts `1.0.0_rc1` above `1.0.0`, which then shows as a skipped downgrade, see [Package YAML](/package-yaml/).

**Authentication:** with `GITHUB_TOKEN` set, git sends it to `github.com`, which private repositories need, through `GIT_CONFIG_*` variables and never on a command line. git takes `https` alone and asks for no password.

**Example YAML:**

```yaml
name: my-package
strategy: github-tag
upstream:
  project: owner/repo
```

Packages that follow one release line pin it with the regex. kubernetes gives `1.36.5` here, and `1.37.1` without the field:

```yaml
name: my-kubectl-1.36
strategy: github-tag
upstream:
  project: kubernetes/kubernetes
  tag_version_regex: '^v(1\.36\.[0-9]+)$'
```

### github-nightly

**Upstream:** the GitHub releases of nightly builds, in 4 patterns that the fields select:

- A, fixed tag, the default: `nightly_tag` names one tag that moves, as in neovim, ghostty and yazi.
- B, dated tags: `nightly_tag` is a prefix with a dash, such as `nightly-`, and of the first 20 releases the first whose tag contains it wins, as for ruffle. With `nightly_tag_regex` in place of `nightly_tag`, the release published last among up to 300 whose tag matches the ERE wins, as for servo.
- C, separate nightly repository: `nightly_tag: latest` reads `/releases/latest` of the build repository, as for yt-dlp.
- D, channel: of the first 20 releases the first whose name contains `channel` wins, as for brave.

Patterns B and C depend on how repositories file their releases. `/releases/latest` skips pre-releases, so for ruffle-rs/ruffle, which files its nightlies as pre-releases, pattern C gives the stable `v0.7.1`. The release list is in the order of tagged commit dates, and every release of servo/servo-nightly-builds carries `2024-02-14` there, so `nightly_tag: '-'` picks `v0.7.0-rc1`. `nightly_tag_regex` ranks by `published_at` and depends on neither order.

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
| `upstream.nightly_tag` | no | tag or its prefix, `nightly` by default, `latest` for pattern C |
| `upstream.nightly_tag_regex` | no | ERE for the tag of pattern B, in place of `nightly_tag` and `channel` |
| `upstream.version_source` | no | `tag` (default), `release_body`, `tag_date` or `published_date` |
| `upstream.version_pattern` | for `release_body` | Perl regex for the version in the release body. Dashes in the match become `+` |
| `upstream.tag_version_regex` | no | ERE whose first capture group is the version, for `version_source: tag` |
| `upstream.tag_version_replace` | no | version built from the groups of `tag_version_regex`, see [github-release](#github-release), and from `\p`, see below |
| `upstream.date_format` | no | `date` format for `tag_date`, `published_date` and `\p`, `%Y.%m.%d` by default; at most 32 characters, with no field width such as `%10d` |
| `upstream.channel` | for pattern D | text that the release name contains |

`tag_date` takes the `YYYY-MM-DD` date in the tag and `published_date` the UTC date of `published_at`, and the two can differ: the servo release `2026-10-21` was published at `2026-10-22T00:25:00Z`. Packages whose `pkgver` has the form `20251213` need `date_format: '%Y%m%d'`, because `vercmp` ranks `20251213` above `2026.10.21`:

```yaml
name: servo-nightly-bin
strategy: github-nightly
upstream:
  project: servo/servo-nightly-builds
  nightly_tag_regex: '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
  version_source: tag_date
  date_format: '%Y%m%d'
```

`\p` in `tag_version_replace` stands for the UTC time of `published_at` in `date_format`, the value that `published_date` gives. It is for projects that publish one pre-release per commit with the commit hash in the tag: the source URL needs the hash, and hashes do not sort by time. `vercmp` ranks the form `<version>dev<time>+<hash>` by the upstream version first and by the time second, and ranks the stable release `0.1.0` above every `0.1.0dev` build. With a dot before `dev`, the dev builds rank above the stable release. The default `date_format` holds the day alone, so builds of one day fall back to the order of their hashes. The tag `v0.1.0-dev.6600c5cfe9c9`, published at `2026-11-16T09:48:25Z`, gives `0.1.0dev20261116094825+6600c5cfe9c9` here:

```yaml
name: nvx-bin
strategy: github-nightly
upstream:
  project: microsoft/nvx
  nightly_tag_regex: '^v[0-9.]+-dev\.[0-9a-f]{12}$'
  tag_version_regex: '^v([0-9.]+)-dev\.([0-9a-f]{12})$'
  tag_version_replace: '\1dev\p+\2'
  date_format: '%Y%m%d%H%M%S'
cooldown_days: 7
```

The PKGBUILD takes the upstream version and the hash back out of `pkgver`:

```bash
source=("nvx-${pkgver}-linux-kvm.tar.gz::${url}/releases/download/v${pkgver%%dev*}-dev.${pkgver##*+}/nvx-${pkgver%%dev*}-linux-kvm.tar.gz")
```

With `cooldown_days: 7`, the AUR gets at most one of these builds in 7 days, see [Cooldown](/features/cooldown/).

`validate-pkg.sh` refuses fields that the chosen pattern and `version_source` do not read: `date_format` without a date source or `\p`, `version_pattern` without `release_body`, `tag_version_regex` and `tag_version_replace` without `tag`, `nightly_tag_regex` beside `nightly_tag` or `channel`, and `nightly_tag` beside `channel`. It also refuses `release_body` without `version_pattern`, `tag_date` with the fixed tag of pattern A, which holds no date, `date_format` values whose output is no valid version, such as `%Y-%m-%d`, and regexes that do not compile.

**Authentication:** as `github-release`.

### github-asset

**Upstream:** one GitHub release by tag, `/repos/{owner}/{repo}/releases/tags/{tag}`, and the `updated_at` of the assets listed in the package YAML.

Use it for releases whose tag never moves while their assets are replaced, such as model zoos, rolling download tags or the `nightly` tag of `wezterm/wezterm`. The PKGBUILD points at fixed URLs, so updates change `pkgver`, `pkgrel` and the checksums alone. `pkgver` holds the date, and the audit blocks `pkgver()` with this strategy, see [pkgver() with the wrong strategy](/supported-packages/#pkgver-with-the-wrong-strategy-blocked).

**YAML fields:**

| Field | Required | Description |
|---|---|---|
| `upstream.project` | yes | `owner/repo` |
| `upstream.tag` | yes | release tag that carries the assets |
| `upstream.assets` | yes | exact asset file names, at least one |

**Version:** the newest `updated_at` among the listed assets, as `YYYYMMDD`, such as `20251202`, so new uploads of any of them move the version forward. Listed assets missing from the release fail the check and are named.

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

**Upstream:** the GitLab Tags API, `/api/v4/projects/{id}/repository/tags`, on gitlab.com or a self-hosted instance.

**Authentication:** with the secret `GITLAB_TOKEN`, which the calling workflow passes by name as the [Setup](/setup/#the-calling-workflows) page shows, the check job asks gitlab.com for the tags of these packages as root before the checks, with the token as `PRIVATE-TOKEN`, and the strategy reads those answers as `builder`, which never gets the token. GitLab.com then counts the requests of that token apart from the traffic of the address that runners share. Self-hosted instances get no token, and the strategy asks again without the token for tags that root could not fetch or did not reach in the 300 s of its step. Local runs send `GITLAB_TOKEN` of the environment to gitlab.com alone, curl reads it from stdin, so it never appears on a command line, and `check-update.sh` takes it out of the environment of every other strategy. Without the secret, check runs keep the pace of gitlab.com for requests without a token.

**YAML fields:**

| Field | Required | Description |
|---|---|---|
| `upstream.host` | yes | GitLab host, such as `gitlab.com` or `gitlab.freedesktop.org` |
| `upstream.project` | yes | project path, such as `group/project` |
| `upstream.tag_version_regex` | no | ERE whose first capture group is the version, in place of the default filter, see [github-release](#github-release) |
| `upstream.tag_version_replace` | no | version built from the groups of `tag_version_regex`, see [github-release](#github-release) |

**Version:** the newest version among the first 100 tags, picked as [github-tag](#github-tag) picks it. Answers that are no JSON, such as bot check pages, fail the check with the URL of that page, see [Upstreams behind a bot check](#upstreams-behind-a-bot-check).

**Example YAML:**

```yaml
name: my-package
strategy: gitlab-tag
upstream:
  host: gitlab.com
  project: group/project
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
| `upstream.host` | yes | host, such as `codeberg.org` |
| `upstream.project` | yes | `owner/repo` |
| `upstream.tag_version_regex` | no | ERE whose first capture group is the version, in place of the default filter, see [github-release](#github-release) |
| `upstream.tag_version_replace` | no | version built from the groups of `tag_version_regex`, see [github-release](#github-release) |

**Version:** the newest version among the first 50 tags, picked as [github-tag](#github-tag) picks it. Answers that are no JSON fail the check with the URL of that page, see [Upstreams behind a bot check](#upstreams-behind-a-bot-check).

**Example YAML:**

```yaml
name: my-package
strategy: gitea-tag
upstream:
  host: codeberg.org
  project: owner/repo
```

### git-latest

**Upstream:** any git repository with an HTTPS URL, through a bare clone. Use it for `-git` packages that follow the latest commit.

**YAML fields:**

| Field | Required | Description |
|---|---|---|
| `upstream.type` | yes | `github`, `gitlab` or `git` |
| `upstream.host` | for `gitlab` | GitLab host |
| `upstream.project` | for `github` and `gitlab` | project path |
| `upstream.url` | for `git` | full clone URL, `https://` only |
| `upstream.branch` | no | branch of a source pinned to `#branch=`, the default branch of the repository by default |
| `upstream.describe` | no | `tags` or `annotated`: the form of `git describe` in place of `r<count>.<hash>` |
| `upstream.tag_prefix` | no | text cut from the start of the tag with `upstream.describe`, such as `v` |

Each type reads only its own of `host`, `project` and `url`, and `validate-pkg.sh` refuses the others.

**Version:** `r<count>.<hash>`, the usual form of `-git` packages, such as `r431.66db9ce`: the number of commits on `HEAD` and its hash. The clone holds commits and tags alone, `--filter=tree:0`, since the strategy reads no files. Servers can send more than the filter asks, so the clone stops at 1 GiB for the pack and for one object, as fetches in verify do. With `upstream.branch`, `HEAD` is that branch, as makepkg checks it out for `#branch=`, and branches the repository does not have fail the clone. The hash takes as many characters as the hash in `current`, and 7 without `current`: `git rev-parse --short` in `pkgver()` gives more characters as repositories grow, and `vercmp` reads `r2173.ef2e985` as newer than `r2173.ef2e985d` of the same commit.

With `upstream.describe`, the strategy prints what the `git describe` recipes of the [Arch package guidelines for VCS packages](https://manual.archlinux.page/package-guidelines/vcs/) print: `git describe --long`, with `--tags` for `describe: tags` and annotated tags alone for `describe: annotated`. `upstream.tag_prefix` is cut from the tag first, as `sed 's/^v//'` does, then `v1.2.0-rc1-47-g0bbf5ad` becomes `1.2.0.rc1.r47.g0bbf5ad`. The hash keeps at least the length of the hash after `.g` in `current`. Repositories without a tag reachable from `HEAD` fail with `git describe finds no tag reachable from HEAD of <url>`.

`current` must be empty or of the form the strategy prints, and `validate-pkg.sh` refuses any other: `vercmp` reads `1.4.0.r47.g0bbf5ad` as newer than every `r<count>.<hash>`, so mixed `current` values would make every check a downgrade, or an update on the same commit.

New commits are new versions, and pushes of `git-latest` packages wait 7 days after the last one unless `cooldown_days` says otherwise, see [Cooldown](/features/cooldown/).

URLs that do not start with `https://` fail the check with `Only HTTPS URLs supported: <url>` before any clone, also in a YAML that reached the branch without `validate-pkg.sh`. The clone runs with `GIT_ALLOW_PROTOCOL=https`, so URLs from pull requests cannot read local repositories, use the SSH key of the machine, or redirect the clone to http.

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
| `upstream.registry` | yes | PyPI name, such as `requests` |
| `upstream.pin_from` | no | PyPI name of a project whose newest release pins `upstream.registry` with `==`, such as `zensical` |

```yaml
name: python-requests
strategy: pypi
upstream:
  registry: requests
```

With `upstream.pin_from`, the version is the pin on `upstream.registry` in the requirements of the newest release of that project, the release that `.info.version` of `https://pypi.org/pypi/{pin_from}/json` names. The check reads the requirements from the `.metadata` of a wheel of that release, since it parses no release archive, and fails with `<pin_from> <version>: PyPI holds no wheel with metadata, which pin_from reads` for a release without one, as one with an sdist alone. zensical 0.1.3 requires `zensical-ui==0.0.43`, so python-zensical-ui gets `0.0.43`:

```yaml
name: python-zensical-ui
strategy: pypi
upstream:
  registry: zensical-ui
  pin_from: zensical
```

The requirements of a release come from its metadata on PyPI. The check reads `https://pypi.org/simple/{project}/` with `Accept: application/vnd.pypi.simple.v1+json` once per project, takes the release whose version equals the wanted one under PEP 440, so `2.50` finds `2.50.0`, and leaves yanked files out. Wheels give their metadata as `<wheel URL>.metadata`, which has to match the sha256 that the page lists for it: wheels for any platform (`-none-any.whl`) first, then wheels for Linux on x86_64, then any other wheel. Releases without such a wheel give the `PKG-INFO` of their sdist, read from the archive within `upstream.max_answer_mb` after its sha256 matches, from `Metadata-Version: 2.2` on and unless `Dynamic` names `Requires-Dist`. Releases with neither fail the check with `<project> <version>: PyPI holds no metadata that lists the requirements without running code`. Control characters other than tabs fail the check in `Metadata-Version`, `Name`, `Version`, `Requires-Dist`, `Requires-Python` and `Dynamic`, and read as spaces in the other headers, such as a `License` that holds a license text with form feeds.

Packages of this strategy with Python in their AUR `depends` run the requires rules `changed`, `unmet` and `imports` on `upstream.registry`, see [Python packages](/features/update-alerts/#python-packages).

Names compare in their PEP 503 form, so `Zensical_UI` and `zensical-ui` are one project. The check skips requirements on `upstream.registry` whose environment markers are false on Arch, and fails with `<pin_from> lists no requirement on <registry> that applies on Arch` when none is left. It fails with `<pin_from> requires '<requirement>', which pins no single version of <registry>` for an operator other than `==`, a wildcard such as `==0.0.*` or a second clause, and with `<pin_from> pins <registry> to more than one version: <versions>` for different pins. Requirement strings outside PEP 508 fail it with `<pin_from>: cannot read the requirement '<requirement>'`.

Packages with `upstream.pin_from` wait for the package of the project that pins them, since their version fits the newest release of that project. They wait whenever a package with strategy `pypi` whose `upstream.registry` is `pin_from` in PEP 503 form does not reach that release in the same run: when its update is held, waits in its cooldown or for an arch, is skipped as a downgrade or a version jump, or fails. The waiting package gets `held` with its new version, and the README shows `✋ 0.0.43 held`. The log gets one of the lines below. The issue of a held update of the project names the wait with `python-zensical-ui waits for this update`, while the waiting package gets no issue of its own. Packages with `pin_from` are checked after the other packages, and after the second check of a package of their project that failed in the first one. `--publish` pushes them after the packages of their project, and keeps their update for the next run when the push of such a package fails. The wait applies to updates that no rule of the package holds, and once the package of the project reaches the release, the next run lets the waiting package through.

```text
! python-zensical-ui: update 0.0.41 → 0.0.43 waits for the held update of zensical-bin
! python-zensical-ui: update 0.0.41 → 0.0.43 waits for the update of zensical-bin
```

In environment markers, `os_name` is `posix`, `sys_platform` is `linux`, `platform_system` is `Linux`, `platform_python_implementation` is `CPython` and `implementation_name` is `cpython`. `python_version`, `python_full_version` and `implementation_version` come from the version of the `python` package that `pacman -Si python` prints, and compare as PEP 440 does: `python_version == "3.14.0"` holds for Python 3.14. `in` and `not in` test their text as a substring, as packaging does, so `python_version in "3.13, 3.14"` holds for Python 3.14. `~=` and `===` on a field of text, such as `sys_platform`, are unknown, since packaging refuses them. The check asks for no extras, so `extra == "test"` is false. Comparisons on other fields, such as `platform_machine`, and with text outside PEP 440 are unknown, and requirements count unless their marker is false.

### npm

**Upstream:** the npm registry, `https://registry.npmjs.org/{package}/latest`. **Version:** `.version` of the `latest` tag.

| Field | Required | Description |
|---|---|---|
| `upstream.registry` | yes | npm name, such as `express` |

```yaml
name: nodejs-express
strategy: npm
upstream:
  registry: express
```

### crates

**Upstream:** the sparse index of crates.io, `https://index.crates.io/{path}`, where the path is the lower-case crate name under its first letters: `1/a`, `2/ab`, `3/a/abc`, `se/rd/serde`. The index states no rate limit, and the API allows one request a second. **Version:** the newest version by SemVer 2.0 among those not yanked, outside pre-releases, or among all with `prerelease: true`; build metadata after `+` takes no part in the order. The request sends `User-Agent: aurtomator/1.0`.

| Field | Required | Description |
|---|---|---|
| `upstream.registry` | yes | crate name, such as `serde` |
| `upstream.prerelease` | no | `true` reads pre-releases too and needs `pkgver_dash`. Default `false` |

```yaml
name: rust-serde
strategy: crates
upstream:
  registry: serde
```

Semver pre-releases such as `1.0.0-beta.24` hold a dash, so `prerelease: true` needs `pkgver_dash`, see [Package YAML](/package-yaml/). pijul gives `1.0.0.beta.24` here, and its release `1.0.0` then reads as a skipped downgrade. With `pkgver_dash: ''` it gives `1.0.0beta.24`, which `vercmp` puts below `1.0.0`.

```yaml
name: pijul
strategy: crates
upstream:
  registry: pijul
  prerelease: true
pkgver_dash: .
```

### rubygems

**Upstream:** the rubygems.org API, `https://rubygems.org/api/v1/versions/{gem}.json`. **Version:** the highest `number` among the entries with `prerelease` false and `platform` `ruby`, in the order of RubyGems.

| Field | Required | Description |
|---|---|---|
| `upstream.registry` | yes | gem name of A-Za-z0-9._- that starts with a letter or digit, such as `bashcov` |

```yaml
name: bashcov
strategy: rubygems
upstream:
  registry: bashcov
```

Packages of this strategy with Ruby in their AUR `depends` run the requires rules `changed`, `unmet` and `imports` on `upstream.registry`, see [Gems](/features/update-alerts/#gems).

Gems list each release once per platform, so nokogiri 1.19.7 appears eleven times in the answer and the strategy reads the entry for `ruby`. RubyGems puts letters before numbers: `4.0.0.rc1` of simplecov-cobertura sorts below `4.0.0`, where `vercmp` puts it above, and rubygems.org marks it as a pre-release.

### repology

**Upstream:** the Repology API, `https://repology.org/api/v1/project/{name}`, a fallback when no other strategy fits. Repology allows one request per second and blocks clients that send more, so the strategy waits one second before its request and sends a User-Agent with a link to the aurtomator repository. Blocked requests fail with `repology.org answered 403, as it does to clients that send more than one request per second`.

| Field | Required | Description |
|---|---|---|
| `upstream.repology` | no | Repology project, the package `name` by default. It holds the characters `A-Z`, `a-z`, `0-9`, `@`, `.`, `_`, `+`, `:` and `-` and starts with none of `.`, `-` and `:`, since it goes into the path of the API URL |

**Version:** the version of the first `newest` entry outside the AUR, since the AUR entries hold the version of this package. When only the AUR is newest, the newest `outdated` version outside the AUR, and `current` values above it read as a downgrade. The version is the normalized `version` of Repology: the OpenBSD entry of qodem gives `1.0.1` for its `1.0.1p1`. It lags until a distribution other than the AUR packages the release. The request sends `User-Agent: aurtomator/1.0`, as Repology asks.

Unknown projects fail with `Project <name> not found on Repology`, and projects without a `newest` or `outdated` entry outside the AUR with `No version found on Repology for <name> outside the AUR`. Repology names libraries of Python, Ruby, Perl or Haskell `<language>:<name>`, such as `ruby:rmagick`, and the search at `https://repology.org/projects/?search=rmagick` lists them:

```yaml
name: ruby-rmagick
strategy: repology
upstream:
  repology: ruby:rmagick
```

### archpkg

**Upstream:** the Arch Linux package search, `https://archlinux.org/packages/search/json/?name={name}`. Use it for AUR packages that follow the `pkgver` of an official package, such as addons released with it.

| Field | Required | Description |
|---|---|---|
| `upstream.archpkg` | no | official package, the package `name` by default. It holds the characters of package names, `A-Z`, `a-z`, `0-9`, `@`, `.`, `_`, `+` and `-`, and starts with neither `.` nor `-`, since it goes into the query of the search URL |
| `upstream.testing` | no | `true` reads `core-testing`, `extra-testing` and `multilib-testing` too. Default `false` |

**Version:** the `pkgver` of the newest entry of `core`, `extra` and `multilib` by `vercmp`, the epoch included: ffmpeg `2:9.0.2-2` gives `9.0.2`. With `testing: true`, builds in testing win while they are newer than the stable one. Raised epochs, as `1:2.0` to `2:1.0`, give `1.0` after `2.0`, a skipped downgrade: the maintainer raises the epoch in the AUR package, publishes `1.0` by hand and sets `current`. Rebuilds in the official repositories raise only `pkgrel` and give no update, see [Packages needing a pkgrel bump](/supported-packages/#packages-needing-a-pkgrel-bump). Packages found in none of the repositories fail with `Package not found in core, extra, multilib: <name>`.

```yaml
name: my-qt6-addon
strategy: archpkg
upstream:
  archpkg: qt6-base
```

### webpage-scrape

**Upstream:** any HTTPS page and a regex that matches the version, for upstreams without an API.

| Field | Required | Description |
|---|---|---|
| `upstream.url` | yes | HTTPS URL of the page |
| `upstream.pattern` | yes | ERE whose first capture group is the version |
| `upstream.user_agent` | no | User-Agent in printable ASCII in place of `aurtomator/1.0`. SourceForge answers bare `Mozilla/5.0` with 403 |

**Version:** the newest version by `vercmp` among the first capture groups of every match on the page. The page comes over HTTPS with at most 5 redirects. bash takes the groups, so the pattern may hold any character, `/` included, and `validate-pkg.sh` refuses patterns that bash cannot compile, such as those with `(?:...)`, and patterns without a group. Patterns that take more than 30 seconds on the page fail the check. grep starts a match at each place that the first part of the pattern takes, so `([0-9.]+)\.tar\.gz` spends time that grows with the square of a long run of digits on the page, while patterns that start with fixed text, as `my-scrape-pkg-([0-9.]+)\.tar\.gz`, stay fast.

```yaml
name: my-scrape-pkg
strategy: webpage-scrape
upstream:
  url: "https://www.example.com/~maintainer/my-scrape-pkg/"
  pattern: "my-scrape-pkg-([0-9.]+)\\.tar\\.gz"
```

Version files published as release assets are read through their download URL. `jpenilla/ghostty-nightly-bin` publishes the version of each Ghostty nightly build as `ghostty-nightly-version.txt`:

```yaml
name: ghostty-nightly-bin
strategy: webpage-scrape
upstream:
  url: https://github.com/jpenilla/ghostty-nightly-bin/releases/download/nightly/ghostty-nightly-version.txt
  pattern: '^([0-9]{8}\.r[0-9]+\.g[0-9a-f]+)$'
```

### kde-tarball

**Upstream:** the listing of `https://download.kde.org/{path}/`. Use it for KDE projects with release tarballs there, in one directory, such as `stable/kio-s3/kio-s3-1.0.2.tar.xz`, or in a directory per version or series: Plasma under `stable/plasma/6.8.1/`, Frameworks under `stable/frameworks/6.31/`, KDE Gear under `stable/release-service/26.08.2/src/`.

| Field | Required | Description |
|---|---|---|
| `upstream.project` | no | tarball name, the package `name` by default |
| `upstream.path` | no | directory on download.kde.org, `stable/{project}` by default |

**Version:** the highest version of the links `{project}-{version}.tar.xz`, with a version of digits and dots, in the listing and in its newest version directory, with the `src/` in it when there is one. Newest directories without a tarball of the project fail the check and are named, so projects dropped from Plasma are not followed into an older directory.

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

**Upstream:** the tags of any git repository, from `git ls-remote --tags --refs {url}`. Use it for hosts without a tags API, such as sourcehut, kernel.org and Savannah, and for GitLab or Gitea projects with more tags than `gitlab-tag` or `gitea-tag` read.

| Field | Required | Description |
|---|---|---|
| `upstream.url` | yes | HTTPS URL of the repository |
| `upstream.tag_version_regex` | no | ERE whose first capture group is the version, in place of the default filter |
| `upstream.tag_version_replace` | no | version built from the groups of `tag_version_regex`, see [github-release](#github-release) |

**Version:** as [github-tag](#github-tag). git takes `https` alone, asks for no password and sends no `GITHUB_TOKEN`, so only public repositories work. Repositories behind the bot check of their site fail with the git message, which names the redirect page.

```yaml
name: my-package
strategy: git-tag
upstream:
  url: https://git.sr.ht/~owner/repo
```

`.git` URLs of GitLab or Gitea projects work the same way:

```yaml
name: my-package
strategy: git-tag
upstream:
  url: https://gitlab.gnome.org/GNOME/gtk.git
```

### gitea-release

**Upstream:** the Gitea and Forgejo Releases API, `/api/v1/repos/{owner}/{repo}/releases/latest`, and `/releases` with `tag_version_regex`. Use it for projects on Codeberg or another Gitea or Forgejo host that also push tags that are no release, which [gitea-tag](#gitea-tag) would read.

| Field | Required | Description |
|---|---|---|
| `upstream.host` | yes | host, such as `codeberg.org` |
| `upstream.project` | yes | `owner/repo` |
| `upstream.tag_version_regex` | no | ERE whose first capture group is the version, read from the release list, see [github-release](#github-release) |
| `upstream.tag_version_replace` | no | version built from the groups of `tag_version_regex`, see [github-release](#github-release) |

**Version:** the tag of `/releases/latest`, the newest release by date that is neither a draft nor a pre-release, without the leading `v`. 404 answers there make the check read the release list to say whether the project has no release or pre-releases only. With `tag_version_regex`, the newest version by `vercmp` among the matching tags of up to 10 pages of 50 releases, drafts and pre-releases left out, which suits repositories that release several products. Answers that are no JSON fail the check with the URL of that page, see [Upstreams behind a bot check](#upstreams-behind-a-bot-check).

```yaml
name: my-package
strategy: gitea-release
upstream:
  host: codeberg.org
  project: owner/repo
```
