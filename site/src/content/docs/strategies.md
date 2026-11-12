---
title: Strategies
---

aurtomator includes 16 version detection strategies. Pick the one that reads the source the PKGBUILD downloads, because two sources of one project can disagree. The streamrip PKGBUILD builds the git tag `v2.2.0` from GitHub, while PyPI still holds `2.1.0`, so `pypi` reports a downgrade on every run. A vendor page can sit behind a bot check that its download host does not have, see [Upstreams behind a bot check](#upstreams-behind-a-bot-check).

By where the upstream publishes releases:

| Strategy | Source | Best for | Pre-release filter |
|---|---|---|---|
| `github-release` | GitHub Releases API | Most GitHub projects | Auto (excludes pre-releases) |
| `github-tag` | `git ls-remote` | Projects without formal releases | Auto (`v1.2.3` tags only) |
| `github-nightly` | GitHub Releases API | Nightly/dev builds (4 patterns) | Nightly-specific |
| `github-asset` | GitHub Releases API | Assets re-uploaded on a fixed tag (model zoos) | N/A (fixed tag) |
| `gitlab-tag` | GitLab Tags API | GitLab.com, invent.kde.org, self-hosted | Auto (`v1.2.3` tags only) |
| `gitea-tag` | Gitea/Forgejo Tags API | Codeberg, self-hosted Gitea | Auto (`v1.2.3` tags only) |
| `gitea-release` | Gitea/Forgejo Releases API | Releases on Codeberg or a self-hosted Gitea | Auto (excludes drafts and pre-releases) |
| `git-tag` | `git ls-remote` | Any HTTPS git host: sourcehut, kernel.org, Savannah | Auto (`v1.2.3` tags only) |
| `git-latest` | Bare git clone | `-git` packages (commit tracking) | N/A |
| `pypi` | PyPI JSON API | Python packages | Auto (stable only) |
| `npm` | npm registry | Node.js packages | Auto (`latest` tag) |
| `crates` | crates.io API | Rust packages | Auto (stable only, or `prerelease: true`) |
| `repology` | Repology API | Fallback across distro repositories, AUR left out | Varies |
| `archpkg` | Arch package search | Track official repo versions | N/A |
| `webpage-scrape` | Any HTTPS page + regex | No API available | None (depends on regex) |
| `kde-tarball` | download.kde.org | KDE projects, in one directory or in a directory per version | None |

## Strategy limitations

- **GitHub rate limit:** the GitHub strategies send `GITHUB_TOKEN` when it is set in the environment. The `check-updates` workflow sets it to the workflow token, which allows 1,000 requests per hour per repository. Without a token, the limit is 60 requests per hour. `github-tag` reads the tags with `git ls-remote`, outside this limit.
- **Retries:** a request that a strategy sends with curl tries a timeout, a refused connection and an HTTP 408, 429, 500, 502, 503, 504, 522 or 524 answer twice more, 5 seconds apart. The git calls of `git-latest`, `github-tag` and `git-tag` make one attempt. A check that still fails within its time budget runs once more after the other packages and a pause of 60 seconds. A failure on both tries fails the package for that run.
- **Answer size:** a request that a strategy sends with curl reads at most 50 MB of one answer, and `webpage-scrape` at most 5 MB of its page. `upstream.max_answer_mb`, a whole number from 1 to 500, sets another limit for one package. A larger answer fails the check.
- **Tag strategies take only `v1.2.3` and `1.2.3` by default:** without `tag_version_regex`, `github-tag`, `gitlab-tag`, `gitea-tag` and `git-tag` leave out every other tag, `latest`, `1.0.0-rc1` and `1.0.0rc1` included. `tag_version_regex` replaces that filter. They pick the newest version by `vercmp`, the order of pacman, which places `1.0.0rc1` below `1.0.0`. The comparison drops a dash before a letter, so `1.0.0-rc1` is below `1.0.0` as well, and a regex that lets pre-release tags through picks the release once it is out. A plain number is of that form too, so a repository that tags its releases `13` and `14` and its builds `2026102100` gives the build; `check-all.sh` holds such a step as a version jump, see [Downgrades and version jumps](/features/downgrades/), and `tag_version_regex: '^([0-9]{1,3})$'` keeps the releases.
- **`gitlab-tag` and `gitea-tag` fetch at most 100 and 50 tags:** there is no pagination. `git-tag` with the `.git` URL of the project reads every tag, and `gitea-release` reads the releases, up to 500 with `tag_version_regex`.
- **`gitlab-tag` has no authentication:** private GitLab projects cannot be queried.

## Upstreams behind a bot check

Some sites answer a client without a browser with a check page in place of the data. A failed check names which kind it met.

- **Cloudflare challenge:** the answer is HTTP 403 with the header `cf-mitigated: challenge`. Only a browser passes it, whatever the User-Agent, so `upstream.user_agent` does not help. The check fails with `<url>: The requested URL returned error: 403, a Cloudflare challenge, which only a browser passes`. The host the PKGBUILD downloads from, or a package repository of the vendor, often answers without the challenge. For anydesk-bin, the page `https://anydesk.com/en/downloads/linux` is behind it, while `download.anydesk.com` and the apt repository are not:

  ```yaml
  name: anydesk-bin
  strategy: webpage-scrape
  upstream:
    url: https://deb.anydesk.com/dists/all/main/binary-amd64/Packages
    pattern: 'Version: ([0-9.]+)'
  ```

- **A check of the site itself:** forge.soutade.fr redirects every request without its cookie to a page that asks "Are you Human?", the API, git and the archives alike. `gitea-tag` and `gitlab-tag` fail with the URL of that page, and the source check refuses the archives as HTML, see [Source URL returns HTML](/supported-packages/#source-url-returns-html-blocked). aurtomator sends no cookie, so a package whose upstream sits behind such a check, as libgourou, is not supported.

## Upstream sources not covered

The Go module proxy (proxy.golang.org) needs `webpage-scrape` or a custom strategy. Private registries (GitLab, npm, PyPI) and FTP servers need a custom strategy: `webpage-scrape` reads public HTTPS pages only and sends no credentials.

## Strategy reference

A strategy is a bash script in `strategies/`. It takes the package name, reads its settings from the package YAML, queries the upstream, and prints one version string on stdout. On failure it prints an error to stderr and exits non-zero. The HTTP-based strategies use `curl` with a 30-second timeout, and the tag-based ones strip a leading `v`.

### github-release

**Upstream:** GitHub Releases API: `/repos/{owner}/{repo}/releases/latest`, or the release list with `tag_version_regex`.

**When to use:** GitHub projects that publish releases.

**YAML fields:**

| Field                        | Required | Description                         |
|------------------------------|----------|-------------------------------------|
| `upstream.project`           | yes      | `owner/repo` format                 |
| `upstream.tag_version_regex` | no       | ERE whose first capture group is the version, see below |
| `upstream.tag_version_replace` | no     | The version built from the groups of `tag_version_regex` (default: `\1`), see below |
| `upstream.asset_regex`       | no       | ERE whose one capture group is a value from an asset name of the release, see [Values from release asset names](/features/asset-values/) |
| `upstream.asset_var`         | with `asset_regex` | The PKGBUILD variable that holds that value, see [Values from release asset names](/features/asset-values/) |

**Version:** reads `.tag_name` of the latest release and strips a leading `v`. The endpoint skips drafts and pre-releases. When it answers 404, the strategy reads the release list to say why: a list of pre-releases only gets a message that names `github-nightly` with `nightly_tag_regex`, an empty list one that names `github-tag`.

With `tag_version_regex`, the strategy reads the release list instead, 100 releases a page, until the list ends, at most 10 pages. The API lists releases by the date of the tagged commit, so the newest version can stand on any of them. It takes the highest version among the matches by `vercmp`, as [github-tag](#github-tag) does, and leaves out drafts and pre-releases, so a fix release of an older line published after the newest one is no downgrade. A repository that releases several products then gives the release of the product the regex names, whatever `/releases/latest` returns. tutao/tutanota publishes its web, desktop and mobile apps as separate releases:

```yaml
name: tutanota-desktop-bin
strategy: github-release
upstream:
  project: tutao/tutanota
  tag_version_regex: '^tutanota-desktop-release-(.*)$'
```

**Authentication:** when `GITHUB_TOKEN` is set in the environment, it is sent as a Bearer token. curl reads the header from stdin, so the token does not appear on a command line. The `check-updates` workflow sets it to the workflow token, which allows 1,000 requests per hour per repository. Without it, for example in a local run, the limit is 60 requests per hour.

**Example YAML:**

```yaml
name: my-package
strategy: github-release
upstream:
  project: owner/repo
```

**Custom tag format:** for tags like `MeshLab-2025.07` or `0.1.8-stable`, set `tag_version_regex`. The text of its first capture group becomes the version. bash `[[ =~ ]]` takes the group, so the regex may hold `|`. Without `tag_version_replace`, a group of alternatives has to come after the version, as in `^v?([0-9.]+)(-stable|)$`, because bash knows no group that does not capture: `^(mesa-)?([0-9.]+)$` gives `mesa-`.

```yaml
name: meshlab-bin
strategy: github-release
upstream:
  project: cnr-isti-vclab/meshlab
  tag_version_regex: 'MeshLab-(.*)'
```

`tag_version_replace` builds the version from more than one group. `\1` to `\9` stand for the groups of `tag_version_regex`, and every other character is copied. The tag `2026-09-10` gives `2026.09.10` here:

```yaml
name: whitesur-icon-theme
strategy: github-release
upstream:
  project: vinceliuice/WhiteSur-icon-theme
  tag_version_regex: '^([0-9]{4})-([0-9]{2})-([0-9]{2})$'
  tag_version_replace: '\1.\2.\3'
```

`validate-pkg.sh` refuses `tag_version_replace` without `tag_version_regex`, with a character other than `A-Za-z0-9._+` outside `\1` to `\9`, or with a group the regex does not have. Both fields also work with `github-tag`, `github-nightly`, `gitlab-tag`, `gitea-tag`, `gitea-release` and `git-tag`. `validate-pkg.sh` refuses `tag_version_regex` with any other strategy.

### github-tag

**Upstream:** the tags of the repository, read with `git ls-remote --tags --refs https://github.com/{owner}/{repo}.git`.

**When to use:** GitHub projects with tags and no releases.

**YAML fields:**

| Field                        | Required | Description                              |
|------------------------------|----------|------------------------------------------|
| `upstream.project`           | yes      | `owner/repo` format                      |
| `upstream.tag_version_regex` | no       | ERE whose first capture group is the version, replaces the default filter |
| `upstream.tag_version_replace` | no     | The version built from the groups of `tag_version_regex`, see [github-release](#github-release) |
| `upstream.asset_regex`       | no       | ERE whose one capture group is a value from an asset name of the release of the tag, see [Values from release asset names](/features/asset-values/) |
| `upstream.asset_var`         | with `asset_regex` | The PKGBUILD variable that holds that value, see [Values from release asset names](/features/asset-values/) |

**Version:** reads every tag in one request, outside the API rate limit. Without `tag_version_regex`, it keeps the tags of the form `v1.2.3` or `1.2.3`, so `latest`, `1.0.0-rc1` and `1.0.0rc1` are left out, and a project without such a tag fails the check with a message that names the field. `tag_version_regex` keeps the tags it matches instead. The strategy strips a leading `v`, or applies `tag_version_regex` and `tag_version_replace`, and returns the newest version by `vercmp`, the order of pacman: `1.0.0rc1` is below `1.0.0`. The comparison drops a dash before a letter, as `pkgver_dash: ''` does, so `1.0.0-rc1` is below `1.0.0` too, and takes any other dash for a dot, so `2025-04-03` compares as `2025.04.03`. With `pkgver_dash` `_` or `.`, pacman puts `1.0.0_rc1` above `1.0.0`, so `1.0.0` then shows as a skipped downgrade, see [Package YAML](/package-yaml/).

**Authentication:** when `GITHUB_TOKEN` is set in the environment, git sends it to `github.com` as `Authorization: Basic` with the user `x-access-token`, which a private repository needs. The header reaches git through `GIT_CONFIG_*` variables, so the token does not appear on a command line. git allows only `https` and asks for no password on the terminal.

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

**Upstream:** GitHub releases of nightly or prerelease builds, in 4 patterns. The fields select the pattern:

- **Pattern A, fixed tag** (default): `nightly_tag` names one tag that moves, as in neovim, ghostty or yazi.
- **Pattern B, dated tags**: `nightly_tag` is a prefix with a dash, such as `nightly-`. Of the first 20 releases the API lists, the first whose tag contains it wins (ruffle). With `nightly_tag_regex` in place of `nightly_tag`, the strategy reads up to 3 pages of 100 releases and takes the release published last among those whose tag matches the ERE (servo).
- **Pattern C, separate nightly repo**: `nightly_tag: latest` reads `/releases/latest` of a dedicated build repo (yt-dlp).
- **Pattern D, channel filter**: of the first 20 releases the API lists, the first whose name contains `channel` wins (brave).

Patterns B and C depend on how a repository files its releases. `/releases/latest` skips pre-releases, and ruffle-rs/ruffle files its nightlies as pre-releases, so pattern C gives its stable `v0.7.1`. `/releases/latest` also sorts by `created_at`, which GitHub sets to the date of the tagged commit, not of the release. Every release of servo/servo-nightly-builds carries `2024-02-14` there, and its release list starts with 12 `v0.x` rc releases, so `nightly_tag: '-'` picks `v0.7.0-rc1`. `nightly_tag_regex` ranks the matches by `published_at` and depends on neither order. A page with fewer than 100 releases, an empty one included, is the last page it reads.

Pattern A:

```yaml
name: myapp-nightly-bin
strategy: github-nightly
upstream:
  project: owner/repo
  nightly_tag: nightly
  version_source: release_body
  version_pattern: 'APP v\K\S+'
```

Pattern B:

```yaml
name: myapp-nightly-bin
strategy: github-nightly
upstream:
  project: owner/repo
  nightly_tag: "nightly-"
  version_source: tag_date
```

Pattern C:

```yaml
name: myapp-nightly-bin
strategy: github-nightly
upstream:
  project: owner/nightly-builds
  nightly_tag: latest
  version_source: tag
```

Pattern D:

```yaml
name: myapp-nightly-bin
strategy: github-nightly
upstream:
  project: owner/repo
  channel: Nightly
  version_source: tag
```

**YAML fields:**

| Field | Required | Description |
|-------|----------|-------------|
| `upstream.project` | yes | `owner/repo` |
| `upstream.nightly_tag` | no | Tag name or prefix (default: `"nightly"`, `"latest"` for pattern C) |
| `upstream.nightly_tag_regex` | no | ERE for the tag in pattern B, in place of `nightly_tag` and `channel` |
| `upstream.version_source` | no | `"tag"` (default), `"release_body"`, `"tag_date"`, `"published_date"` |
| `upstream.version_pattern` | for `release_body` | Perl regex for the version in the release body. Dashes in the match become `+`. |
| `upstream.tag_version_regex` | no | ERE whose first capture group is the version, for `version_source: tag` |
| `upstream.tag_version_replace` | no | The version built from the groups of `tag_version_regex`, see [github-release](#github-release) |
| `upstream.date_format` | no | Format of `date` for `tag_date` and `published_date` (default: `%Y.%m.%d`) |
| `upstream.channel` | for pattern D | Text that the release name must contain |

`tag_date` takes the `YYYY-MM-DD` date in the tag and `published_date` the UTC date of `published_at`. `date -u` renders both with `date_format`, `YYYY.MM.DD` by default. The two dates can differ: the servo release `2026-10-21` was published at `2026-10-22T00:25:00Z`.

A package whose `pkgver` has the form `20251213` needs `date_format: '%Y%m%d'`, because `vercmp` ranks `20251213` above `2026.10.21` and the default form never counts as newer:

```yaml
name: servo-nightly-bin
strategy: github-nightly
upstream:
  project: servo/servo-nightly-builds
  nightly_tag_regex: '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
  version_source: tag_date
  date_format: '%Y%m%d'
```

`validate-pkg.sh` refuses `date_format` with another `version_source` and a format whose output is not a valid version, such as `%Y-%m-%d`. It refuses `nightly_tag_regex` next to `nightly_tag` or `channel`, and one that bash cannot compile. It refuses `tag_version_regex` and `tag_version_replace` with a `version_source` other than `tag`. It refuses a `version_source` other than `tag`, `release_body`, `tag_date` or `published_date`, `release_body` without `version_pattern`, a `version_pattern` that `grep -P` cannot compile, and `version_pattern` with another `version_source`. It refuses `tag_date` with the fixed tag of pattern A: such a tag has no dash and so no `YYYY-MM-DD` date. It refuses `nightly_tag` next to `channel`: `nightly_tag: latest` leaves `channel` unread, and `channel` leaves any other `nightly_tag` unread.

**Authentication:** same as `github-release`.

### github-asset

**Upstream:** one GitHub release by tag (`/repos/{owner}/{repo}/releases/tags/{tag}`) and the `updated_at` of the assets listed in the package YAML.

**When to use:** releases whose tag never moves while the assets behind it are replaced, such as a model zoo or a rolling download tag. A PKGBUILD for such a release points at fixed URLs, so an update changes `pkgver`, `pkgrel` and the checksums and nothing else. Nightly binaries fit as well, such as the `nightly` tag of `wezterm/wezterm`. The PKGBUILD has no `pkgver()`, because the audit blocks one with this strategy, and `pkgver` holds the date, see [pkgver() with the wrong strategy](/supported-packages/#pkgver-with-the-wrong-strategy-blocked).

**YAML fields:**

| Field              | Required | Description                                  |
|--------------------|----------|----------------------------------------------|
| `upstream.project` | yes      | `owner/repo` format                          |
| `upstream.tag`     | yes      | Release tag that carries the assets          |
| `upstream.assets`  | yes      | List of exact asset file names, at least one |

**Version:** every listed asset must be present in the release, otherwise the strategy fails and names the missing one. The newest `updated_at` among them becomes the version, rendered as `YYYYMMDD` (for example `20251202`). A re-upload of any listed asset moves the date forward. The release object lists only assets in state `uploaded`, so one request covers every downloadable asset.

**Authentication:** same as `github-release`.

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

**Upstream:** GitLab Tags API (`/api/v4/projects/{id}/repository/tags`).

**When to use:** any GitLab instance: gitlab.com, invent.kde.org, self-hosted.

**YAML fields:**

| Field                  | Required | Description                                           |
|------------------------|----------|-------------------------------------------------------|
| `upstream.host`        | yes      | GitLab hostname (e.g. `invent.kde.org`, `gitlab.com`) |
| `upstream.project`     | yes      | Project path (e.g. `network/my-kde-app`)              |
| `upstream.tag_version_regex` | no | ERE whose first capture group is the version, replaces the default filter, see [github-release](#github-release) |
| `upstream.tag_version_replace` | no | The version built from the groups of `tag_version_regex`, see [github-release](#github-release) |

**Version:** URL-encodes the project path (`/` becomes `%2F`) and fetches the first 100 tags; [git-tag](#git-tag) with the `.git` URL of the project reads every tag. An answer that is not JSON, such as the page of a bot check, fails the check with the URL of that page, see [Upstreams behind a bot check](#upstreams-behind-a-bot-check). Without `tag_version_regex`, it keeps the tags of the form `v1.2.3` or `1.2.3`, and a project without such a tag fails the check with a message that names the field. It strips a leading `v`, or applies `tag_version_regex` and `tag_version_replace`, and returns the newest version by `vercmp`, as [github-tag](#github-tag) does. There is no authentication, so private projects cannot be queried.

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

**Upstream:** Gitea/Forgejo Tags API (`/api/v1/repos/{owner}/{repo}/tags`).

**When to use:** Codeberg and self-hosted Gitea or Forgejo instances.

**YAML fields:**

| Field                  | Required | Description                              |
|------------------------|----------|------------------------------------------|
| `upstream.host`        | yes      | Instance hostname (e.g. `codeberg.org`)  |
| `upstream.project`     | yes      | `owner/repo` format                      |
| `upstream.tag_version_regex` | no | ERE whose first capture group is the version, replaces the default filter, see [github-release](#github-release) |
| `upstream.tag_version_replace` | no | The version built from the groups of `tag_version_regex`, see [github-release](#github-release) |

**Version:** fetches up to 50 tags without pagination; [git-tag](#git-tag) with the `.git` URL of the project reads every tag. An answer that is not JSON, such as the page of a bot check, fails the check with the URL of that page, see [Upstreams behind a bot check](#upstreams-behind-a-bot-check). Without `tag_version_regex`, it keeps the tags of the form `v1.2.3` or `1.2.3`, and a project without such a tag fails the check with a message that names the field. It strips a leading `v`, or applies `tag_version_regex` and `tag_version_replace`, and returns the newest version by `vercmp`, as [github-tag](#github-tag) does.

**Example YAML:**

```yaml
name: my-package
strategy: gitea-tag
upstream:
  host: codeberg.org
  project: owner/repo
```

### git-latest

**Upstream:** any git repository with an HTTPS URL, through a bare clone.

**When to use:** `-git` AUR packages that track the latest commit.

**YAML fields:**

| Field              | Required | Description                                  |
|--------------------|----------|----------------------------------------------|
| `upstream.type`    | yes      | One of: `github`, `gitlab`, `git`            |
| `upstream.host`    | depends  | Required for the `gitlab` type               |
| `upstream.project` | depends  | Required for the `github` and `gitlab` types |
| `upstream.url`     | depends  | Required for the `git` type: full clone URL, `https://` only |
| `upstream.branch`  | no       | The branch of a source pinned to `#branch=`. Default: the default branch of the repository |
| `upstream.describe` | no      | `tags` or `annotated`: print the form of `git describe` instead of `r<count>.<hash>` |
| `upstream.tag_prefix` | no    | Text cut from the start of the tag with `upstream.describe`, such as `v` |

Each type reads only its own of `host`, `project` and `url`, and `validate-pkg.sh` refuses the others: `host` with `github` or `git`, `project` with `git`, and `url` with `github` or `gitlab`.

**Version:** makes a bare clone into a temporary directory, counts the commits on `HEAD` (`git rev-list --count HEAD`), takes the hash of `HEAD` and prints the usual `-git` format `r<count>.<hash>`, for example `r431.66db9ce`. The clone takes `--filter=tree:0` and holds commits and tags only, because the strategy reads no files: a full bare clone of `googleapis/mcp-toolbox`, 1.4 GB by the GitHub API, timed out after the 120 s of a check. A server without partial clone ignores the filter with a warning and sends the whole repository. With `upstream.branch`, the clone takes `--branch`, and `HEAD` is that branch, as makepkg checks it out for `#branch=`: sharkdp/fd gives `r2061.9e90463` on `master` and `r1925.cf8a48a` with `branch: abort-on-panic`. A branch the repository does not have fails the clone. `validate-pkg.sh` refuses a name that `git check-ref-format --branch` refuses, such as one that starts with `-`. The hash has as many characters as the hash in `current`, and 7 when `current` is empty. `git rev-parse --short` in a `pkgver()` gives more characters as the repository grows: fabric-git is `r2173.ef2e985d` on the AUR, and `vercmp` reads `r2173.ef2e985` of the same commit as newer, so a hash of 7 characters would publish that commit again.

With `upstream.describe`, the strategy prints what the `git describe` recipes of the [Arch package guidelines for VCS packages](https://manual.archlinux.page/package-guidelines/vcs/) print: `git describe --long --abbrev=<n>`, with `--tags` for `describe: tags` and without it for `describe: annotated`, which takes annotated tags only. `upstream.tag_prefix` is cut from the start of the tag first, as `sed 's/^v//'` does, and then `sed 's/\([^-]*-g\)/r\1/;s/-/./g'` turns `v1.2.0-rc1-47-g0bbf5ad` into `1.2.0.rc1.r47.g0bbf5ad`. On a tagged commit, `--long` still gives `r0` and the hash. The hash takes at least as many characters as the hash after `.g` in `current`, and at least 7 when `current` is empty: `git describe` adds characters when the shorter hash is not unique. A repository without a tag reachable from `HEAD` fails with `git describe finds no tag reachable from HEAD of <url>`. `validate-pkg.sh` refuses a `describe` other than `tags` or `annotated`, a `tag_prefix` without `describe`, and a `tag_prefix` with a character outside `A-Za-z0-9._+/-`.

`current` must be empty or of the form the strategy prints: `r<count>.<hash>`, or `<tag>.r<count>.g<hash>` with `upstream.describe`. `validate-pkg.sh` refuses any other. `vercmp` reads `1.4.0.r47.g0bbf5ad` as newer than every `r<count>.<hash>`. Without `upstream.describe`, a `current` of the `git describe` form would make each check a downgrade, and the package would never update. With `upstream.describe`, a `current` of the form `r<count>.<hash>` would make the next check an update, even on the same commit.

Every new commit upstream is a new version. A push of a `git-latest` package waits 7 days after the last one, unless `cooldown_days` sets other days, see [Cooldown](/features/cooldown/).

The clone runs with `GIT_ALLOW_PROTOCOL=https`. A URL in a package YAML that comes with a pull request therefore cannot read a local repository or connect to an ssh host with the SSH key of the machine that runs the check, and a redirect cannot move the clone to http.

**Example YAML (GitHub):**

```yaml
name: my-package-git
strategy: git-latest
upstream:
  type: github
  project: owner/repo
```

**Example YAML (GitLab):**

```yaml
name: my-package-git
strategy: git-latest
upstream:
  type: gitlab
  host: invent.kde.org
  project: network/my-kde-app
```

**Example YAML (the form of `git describe`):** lightdm-git counts with `git describe --long --tags | sed 's/\([^-]*-g\)/r\1/;s/-/./g'`, and git gives its hash 8 characters. The AUR version as `current` keeps that length:

```yaml
name: lightdm-git
strategy: git-latest
upstream:
  type: github
  project: CanonicalLtd/lightdm
  describe: tags
current: '1.30.0.r9.g03f21898'
```

**Example YAML (any HTTPS git URL):**

```yaml
name: my-package-git
strategy: git-latest
upstream:
  type: git
  url: "https://git.sr.ht/~user/repo"
```

### pypi

**Upstream:** PyPI JSON API (`https://pypi.org/pypi/{package}/json`).

**When to use:** Python packages published on PyPI.

**YAML fields:**

| Field               | Required | Description                                  |
|---------------------|----------|----------------------------------------------|
| `upstream.registry` | yes      | PyPI package name (e.g. `requests`, `flask`) |

**Version:** reads `.info.version`, the latest stable release on PyPI.

**Example YAML:**

```yaml
name: python-requests
strategy: pypi
upstream:
  registry: requests
```

### npm

**Upstream:** npm registry (`https://registry.npmjs.org/{package}/latest`).

**When to use:** Node.js packages published on npm.

**YAML fields:**

| Field               | Required | Description                                  |
|---------------------|----------|----------------------------------------------|
| `upstream.registry` | yes      | npm package name (e.g. `express`, `webpack`) |

**Version:** reads `.version` of the `latest` tag.

**Example YAML:**

```yaml
name: nodejs-express
strategy: npm
upstream:
  registry: express
```

### crates

**Upstream:** crates.io API (`https://crates.io/api/v1/crates/{crate}`).

**When to use:** Rust crates published on crates.io.

**YAML fields:**

| Field               | Required | Description                        |
|---------------------|----------|------------------------------------|
| `upstream.registry` | yes      | Crate name (e.g. `serde`, `tokio`) |
| `upstream.prerelease` | no     | `true` reads `max_version`, pre-releases included. Needs `pkgver_dash`. Default `false`. |

**Version:** reads `.crate.max_stable_version`, which excludes pre-releases, or `.crate.max_version` with `prerelease: true`. The request sends `User-Agent: aurtomator/1.0`, as the crates.io API policy requires.

**Example YAML:**

```yaml
name: rust-serde
strategy: crates
upstream:
  registry: serde
```

A semver pre-release such as `1.0.0-beta.24` holds a dash, so `validate-pkg.sh` refuses `prerelease: true` without `pkgver_dash`, see [Package YAML](/package-yaml/). pijul gives `1.0.0.beta.24` with:

```yaml
name: pijul
strategy: crates
upstream:
  registry: pijul
  prerelease: true
pkgver_dash: .
```

`1.0.0` sorts below `1.0.0.beta.24`, so when pijul 1.0.0 comes out, the check skips it as a downgrade, see the note on pre-releases in [Package YAML](/package-yaml/). With `pkgver_dash: ''`, pijul gives `1.0.0beta.24`, which `vercmp` puts below `1.0.0`.

### repology

**Upstream:** Repology API (`https://repology.org/api/v1/project/{name}`).

**When to use:** as a fallback when no other strategy fits. Repology tracks versions across many distribution repositories.

**YAML fields:**

| Field               | Required | Description                                                  |
|---------------------|----------|--------------------------------------------------------------|
| `upstream.repology` | no       | Repology project name. Defaults to the package `name`.       |

**Version:** returns the version of the first entry with `status == "newest"` outside the AUR. The AUR entries are left out, because for a package of ours they hold our own version. When only the AUR is newest, the strategy returns the newest `outdated` version outside the AUR by `vercmp`, and a `current` above it reads as a downgrade, see [Downgrades and version jumps](/features/downgrades/). The version is the normalized `version` field of Repology: the OpenBSD entry of qodem gives `1.0.1`, and its `origversion` is `1.0.1p1`. The request sends `User-Agent: aurtomator/1.0`, as Repology asks.

The version lags behind upstream until a distribution other than the AUR packages the new release. A project that Repology does not know, such as `wingide` in place of `wing-ide`, fails the check with `Project <name> not found on Repology`. A project with no `newest` or `outdated` entry outside the AUR fails with `No version found on Repology for <name> outside the AUR`.

Repology names a library of Python, Ruby, Perl or Haskell `<language>:<name>`, as `python:requests`, `ruby:rmagick`, `perl:mojolicious` and `haskell:haxml`. The AUR package name, such as `ruby-rmagick`, is then no Repology project, and the default fails with `Project ruby-rmagick not found on Repology`. The name without the prefix can be another project: `rmagick` holds one stale entry, `1.15.4`, which reads as a downgrade. The search at `https://repology.org/projects/?search=rmagick` lists `ruby:rmagick`:

```yaml
name: ruby-rmagick
strategy: repology
upstream:
  repology: ruby:rmagick
```

**Example YAML:**

```yaml
name: my-package
strategy: repology
upstream:
  repology: my-package
```

Without `upstream.repology`, the package name is used:

```yaml
name: my-package
strategy: repology
```

### archpkg

**Upstream:** Arch Linux package search API (`https://archlinux.org/packages/search/json/?name={name}`).

**When to use:** AUR packages that follow the `pkgver` of an official Arch package, for example an addon released together with it.

**YAML fields:**

| Field              | Required | Description                                                    |
|--------------------|----------|----------------------------------------------------------------|
| `upstream.archpkg` | no       | Package name in the official repos. Defaults to the package `name`. |
| `upstream.testing` | no       | `true` also reads `core-testing`, `extra-testing` and `multilib-testing`. Default `false`. |

**Version:** reads the entries of `core`, `extra` and `multilib` and takes the newest by `vercmp`, the epoch included. It prints its `pkgver`, the version without `epoch` and `pkgrel`: ffmpeg `2:9.0.2-2` gives `9.0.2`. When the official package raises its epoch, as `1:2.0` to `2:1.0`, the strategy gives `1.0` after `2.0`, and the check skips it as a downgrade, see [Downgrades and version jumps](/features/downgrades/). aurtomator does not write an `epoch`: the maintainer raises it in the AUR package, publishes `1.0` by hand and sets `current` to it. A package without an entry in these repositories fails with `Package not found in core, extra, multilib: <name>`. A rebuild in the official repos raises only `pkgrel`, so it gives no new version, and an update of this strategy never raises `pkgrel` alone, see [Packages needing a pkgrel bump](/supported-packages/#packages-needing-a-pkgrel-bump).

With `testing: true` the strategy also reads `core-testing`, `extra-testing` and `multilib-testing`. It takes the build in testing while that build is newer than the stable one, and the stable build otherwise. A build that moves from testing to the stable repository keeps its version and gives no new update. `gnome-unstable` and `kde-unstable` stay out. `validate-pkg.sh` refuses a `testing` that is not `true` or `false`, and `testing` with another strategy.

**Example YAML:**

```yaml
name: my-qt6-addon
strategy: archpkg
upstream:
  archpkg: qt6-base
```

### webpage-scrape

**Upstream:** any HTTPS page, with a regex that matches the version.

**When to use:** upstreams without a structured API: download pages, directory listings, changelogs.

**YAML fields:**

| Field              | Required | Description                                          |
|--------------------|----------|------------------------------------------------------|
| `upstream.url`     | yes      | HTTPS URL of the page                                |
| `upstream.pattern` | yes      | ERE whose first capture group is the version         |
| `upstream.user_agent` | no    | User-Agent in place of `aurtomator/1.0`, printable ASCII |

**Version:**

1. Fetches the page: HTTPS only, at most 5 redirects and 5 MB or `upstream.max_answer_mb`, with the User-Agent `aurtomator/1.0` or `upstream.user_agent`. SourceForge answers a bare `Mozilla/5.0` with HTTP 403. `validate-pkg.sh` refuses a `user_agent` with a character outside printable ASCII, because curl sends the text after a line break as a header of its own.
2. Finds every match with `grep -oE`.
3. Takes the first capture group of each match with bash `[[ =~ ]]`, so the pattern may hold any character, `/` included.
4. Returns the newest version by `vercmp`, as [github-tag](#github-tag) does.

`validate-pkg.sh` compiles the pattern with bash, which refuses some patterns that `grep -E` takes, `(?:...)` among them. It also refuses a pattern without a capture group.

**Example YAML:**

```yaml
name: my-scrape-pkg
strategy: webpage-scrape
upstream:
  url: "https://www.example.com/~maintainer/my-scrape-pkg/"
  pattern: "my-scrape-pkg-([0-9.]+)\\.tar\\.gz"
```

A version file that a project publishes as a release asset is read through its download URL, which redirects to the file. `jpenilla/ghostty-nightly-bin` publishes the version of each Ghostty nightly build as `ghostty-nightly-version.txt`:

```yaml
name: ghostty-nightly-bin
strategy: webpage-scrape
upstream:
  url: https://github.com/jpenilla/ghostty-nightly-bin/releases/download/nightly/ghostty-nightly-version.txt
  pattern: '^([0-9]{8}\.r[0-9]+\.g[0-9a-f]+)$'
```

**Common patterns:**

```text
# Standard tarball naming
"mypackage-([0-9]+\\.[0-9]+\\.[0-9]+)\\.tar\\.gz"

# With optional patch version
"mypackage-([0-9]+\\.[0-9]+(\\.[0-9]+)?)\\.tar\\.xz"

# Version in URL path
"/download/v([0-9.]+)/"
```

### kde-tarball

**Upstream:** the KDE download server listing (`https://download.kde.org/{path}/`), and the newest version directory in it.

**When to use:** KDE projects that publish release tarballs on download.kde.org, in one directory, such as `stable/kio-s3/kio-s3-1.0.2.tar.xz`, or in a directory per version or per series: Plasma under `stable/plasma/6.8.1/`, Frameworks under `stable/frameworks/6.31/`, KDE Gear under `stable/release-service/26.08.2/src/`, krita under `stable/krita/6.0.4.1/`.

**YAML fields:**

| Field              | Required | Description                                                  |
|--------------------|----------|--------------------------------------------------------------|
| `upstream.project` | no       | Tarball name. Defaults to the package `name`.                |
| `upstream.path`    | no       | Directory on download.kde.org. Defaults to `stable/{project}`. |

**Version:** matches `{project}-{version}.tar.xz` links on the listing, where the version is digits and dots (`[0-9]+\.[0-9]+(\.[0-9]+)*`). When the listing also holds directories named by digits and dots, it reads the newest of them by `sort -V`, and the `src/` in it when there is one, as for KDE Gear. The highest version of both listings wins by `sort -Vu`, so older tarballs beside the directories do not hide a newer release. A newest directory without a tarball of the project stops the strategy with that directory in the message, so a project dropped from Plasma is not followed into an older directory. A dot or a plus in `project` matches itself. `validate-pkg.sh` refuses a `project` that does not start with a letter or a digit or that holds a character outside `A-Za-z0-9@._+-`, and a `path` with an empty segment, a segment that starts with a dot, or a character outside `A-Za-z0-9._+-`.

**Example YAML:**

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

The pre-releases of alkimia, `8.2.70` at the time of writing, live in `unstable/alkimia/`:

```yaml
name: alkimia-unstable
strategy: kde-tarball
upstream:
  project: alkimia
  path: unstable/alkimia
```

### git-tag

**Upstream:** the tags of any git repository, read with `git ls-remote --tags --refs {url}`.

**When to use:** hosts without a tags API, such as sourcehut, kernel.org and Savannah, and a GitLab or Gitea project with more tags than `gitlab-tag` or `gitea-tag` read.

**YAML fields:**

| Field                        | Required | Description                              |
|------------------------------|----------|------------------------------------------|
| `upstream.url`               | yes      | HTTPS URL of the repository              |
| `upstream.tag_version_regex` | no       | ERE whose first capture group is the version, replaces the default filter |
| `upstream.tag_version_replace` | no     | The version built from the groups of `tag_version_regex`, see [github-release](#github-release) |

**Version:** reads every tag in one request, as `github-tag` does, and picks the version the same way: without `tag_version_regex`, the tags of the form `v1.2.3` or `1.2.3`, without a leading `v`, the newest by `vercmp`. git allows only `https`, asks for no password on the terminal and sends no `GITHUB_TOKEN`, so only a public repository works. `validate-pkg.sh` refuses a `url` that does not start with `https://`. A repository behind the bot check of its site fails with the message of git, which names the page of the redirect.

**Example YAML:**

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

**Upstream:** Gitea/Forgejo Releases API (`/api/v1/repos/{owner}/{repo}/releases/latest`, and `/releases` with `tag_version_regex`).

**When to use:** a project on Codeberg or another Gitea or Forgejo host that publishes releases and also pushes tags that are no release, which [gitea-tag](#gitea-tag) reads as well.

**YAML fields:**

| Field                  | Required | Description                              |
|------------------------|----------|------------------------------------------|
| `upstream.host`        | yes      | Instance hostname (e.g. `codeberg.org`)  |
| `upstream.project`     | yes      | `owner/repo` format                      |
| `upstream.tag_version_regex` | no | ERE whose first capture group is the version; the release list replaces `/releases/latest`, see [github-release](#github-release) |
| `upstream.tag_version_replace` | no | The version built from the groups of `tag_version_regex`, see [github-release](#github-release) |

**Version:** without `tag_version_regex`, it takes the tag of `/releases/latest`, the newest release by date that is neither a draft nor a pre-release, and strips a leading `v`. Gitea answers 404 when there is no such release, and the check then reads the release list to say whether the project has no release at all or pre-releases only. With `tag_version_regex`, it reads the release list, up to 10 pages of 50 releases and up to the first empty page, leaves out drafts and pre-releases, and returns the newest version by `vercmp` among the tags that the regex matches, as [gitea-tag](#gitea-tag) does. This fits a repository that publishes the releases of several products. An answer that is not JSON, such as the page of a bot check, fails the check with the URL of that page, see [Upstreams behind a bot check](#upstreams-behind-a-bot-check).

**Example YAML:**

```yaml
name: my-package
strategy: gitea-release
upstream:
  host: codeberg.org
  project: owner/repo
```
