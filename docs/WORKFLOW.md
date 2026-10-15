# Aurtomator Workflow Reference

## Table of Contents

1. [Overview](#1-overview)
2. [Package YAML Format](#2-package-yaml-format)
3. [Strategies](#3-strategies)
4. [Update Process](#4-update-process)
5. [CI Workflow: check-updates.yml](#5-ci-workflow-check-updatesyml)
6. [CI Quality Gate: ci.yml](#6-ci-quality-gate-ciyml)
7. [Local Testing](#7-local-testing)
8. [Writing Custom Strategies](#8-writing-custom-strategies)

## 1. Overview

aurtomator bumps the version of AUR packages you already maintain. It does **not** generate PKGBUILDs: it changes `pkgver` in the existing PKGBUILD on the AUR, regenerates checksums and `.SRCINFO`, and pushes the update.

### End-to-end flow

```mermaid
flowchart TD
    A[Schedule / manual trigger] --> P[prepare job: no secrets]
    P --> B[check-all.sh with the read-only token]
    B --> C{for each package}
    C --> D[check-update.sh]
    D --> E[run strategy script]
    E --> F{version changed?}
    F -->|same| G[write up_to_date]
    F -->|new version| G2[write new_version]
    C -->|all done| B2[check-all.sh --prepare without a token]
    B2 --> H[update-pkg.sh --prepare for each new_version]
    H --> H1[clone AUR repo over HTTPS]
    H1 --> H2[audit PKGBUILD]
    H2 --> H3[sed pkgver, reset pkgrel=1]
    H3 --> H4[validate URLs, updpkgsums, verify sources]
    H4 --> H5[namcap, makepkg --printsrcinfo]
    H5 --> H6[hand over PKGBUILD, .SRCINFO, AUR commit]
    H -->|failure| J[write error to .status/]
    D -->|failure| J
    B2 -->|all done| W{update prepared or status table changed?}
    W -->|no| O[done]
    W -->|yes| V[verify job: no secrets]
    V --> V1[check-all.sh --verify]
    V1 --> V2[verify-pkg.sh: download the sources, check the checksums]
    V2 -->|failure| V3[take the update out, write update_failed]
    V2 --> Q[publish job: SSH key, GPG key, write token]
    V3 --> Q
    Q --> R[check-all.sh --publish]
    R --> R1[run strategy again]
    R1 --> R2[publish-pkg.sh: check the prepared files against the AUR copy]
    R2 --> R3[git commit + push to AUR]
    R3 --> K[update-readme.sh]
    K --> L[commit via GitHub API]
    L --> M{failures in .status/?}
    M -->|yes| N[create GitHub Issue]
    M -->|no| O
```

### Key design decisions

- **One YAML per package.** Adding or removing a package is one file.
- **Strategy-based version detection.** Each type of upstream source has its own script. A new source is a new script plus its entry in `scripts/validate-pkg.sh`.
- **Patch, do not generate.** aurtomator trusts your PKGBUILD and changes only `pkgver`, `pkgrel`, checksums and `.SRCINFO`. Build steps, dependencies and install files stay untouched.
- **Three jobs, one with secrets.** A PKGBUILD is code that every step reading it executes. `prepare` checks all packages and runs those steps without secrets, and only its check step, which runs no PKGBUILD, gets the read-only workflow token. `verify` downloads the sources of each prepared update and checks its checksums, without secrets, so code from one PKGBUILD cannot forge the checksums of another package. `publish` holds the SSH key, the GPG key and the write token, never executes a PKGBUILD and never downloads a source, and checks what `verify` passes on before it pushes. See [4.4](#44-prepare-and-publish).
- **Failure isolation.** A broken package does not block the others. Each failure is logged for its package and opens a GitHub Issue.

## 2. Package YAML Format

Each package has a file at `packages/<name>.yml`. The file name, the `name` field and the AUR package name are the same.

| Field          | Required | Description                                                                 |
|----------------|----------|-----------------------------------------------------------------------------|
| `name`         | yes      | AUR package name, equal to the file name without `.yml`                     |
| `strategy`     | yes      | Version detection strategy: a script name in `strategies/` without `.sh`    |
| `upstream`     | depends  | Strategy-specific settings. `archpkg`, `repology` and `kde-tarball` need none. |
| `current`      | no       | Currently tracked version. Written after every push.                        |
| `last_updated` | no       | Date of the last push, `YYYY-MM-DD`. Written after every push.              |

Example:

```yaml
name: my-package
strategy: github-release
upstream:
  project: owner/repo
current: "2.1.0"
```

## 3. Strategies

aurtomator ships 14 strategies. A strategy is a bash script in `strategies/`. It takes the package name, reads its settings from the package YAML, queries the upstream, and prints one version string on stdout. On failure it prints an error to stderr and exits non-zero. The HTTP-based strategies use `curl` with a 30-second timeout, and the tag-based ones strip a leading `v`.

### 3.1 github-release

**What it checks:** GitHub Releases API (`/repos/{owner}/{repo}/releases/latest`).

**When to use:** GitHub projects that publish releases.

**YAML fields:**

| Field                        | Required | Description                         |
|------------------------------|----------|-------------------------------------|
| `upstream.project`           | yes      | `owner/repo` format                 |
| `upstream.tag_version_regex` | no       | ERE with one capture group, see below |

**How the version is extracted:** reads `.tag_name` of the latest release and strips a leading `v`. The endpoint skips drafts and pre-releases.

**Authentication:** when `GITHUB_TOKEN` is set in the environment, it is sent as a Bearer token. curl reads the header from stdin, so the token does not appear on a command line. The `check-updates` workflow sets it to the workflow token, which allows 1,000 requests per hour per repository. Without it, for example in a local run, the limit is 60 requests per hour.

**Example YAML:**

```yaml
name: my-package
strategy: github-release
upstream:
  project: owner/repo
```

**Custom tag format:** for tags like `MeshLab-2025.07` or `0.1.8-stable`, set `tag_version_regex`. The text of its capture group becomes the version. It also works with `github-tag` and `github-nightly`.

```yaml
name: meshlab-bin
strategy: github-release
upstream:
  project: cnr-isti-vclab/meshlab
  tag_version_regex: 'MeshLab-(.*)'
```

### 3.2 github-tag

**What it checks:** GitHub Tags API (`/repos/{owner}/{repo}/tags`).

**When to use:** GitHub projects with tags and no releases.

**YAML fields:**

| Field                        | Required | Description                              |
|------------------------------|----------|------------------------------------------|
| `upstream.project`           | yes      | `owner/repo` format                      |
| `upstream.tag_pattern`       | no       | Glob to filter tags (e.g. `v*`)          |
| `upstream.tag_version_regex` | no       | ERE with one capture group               |

**How the version is extracted:** fetches the first 100 tags and filters them by `tag_pattern`, where `*` matches anything and the match is anchored at the start. It strips a leading `v`, or applies `tag_version_regex`, and returns the highest tag by `sort -V`. `sort -V` places `1.0.0-rc1` above `1.0.0`, so filter pre-release tags with `tag_pattern`.

**Authentication:** same as `github-release`.

**Example YAML:**

```yaml
name: my-package
strategy: github-tag
upstream:
  project: owner/repo
  tag_pattern: "v*"
```

### 3.3 github-nightly

**What it checks:** GitHub releases of nightly or prerelease builds, in 4 patterns. The fields select the pattern:

- **Pattern A, fixed tag** (default): `nightly_tag` names one tag that moves, as in neovim, ghostty or yazi.
- **Pattern B, dated tags**: `nightly_tag` is a prefix with a dash, such as `nightly-`. The newest of the last 20 releases whose tag contains it wins (ruffle, servo).
- **Pattern C, separate nightly repo**: `nightly_tag: latest` reads `/releases/latest` of a dedicated build repo (yt-dlp).
- **Pattern D, channel filter**: `channel` picks the newest of the last 20 releases whose name contains it (brave).

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
| `upstream.version_source` | no | `"tag"` (default), `"release_body"`, `"tag_date"`, `"published_date"` |
| `upstream.version_pattern` | for `release_body` | Perl regex for the version in the release body. Dashes in the match become `+`. |
| `upstream.tag_version_regex` | no | ERE with one capture group, for `version_source: tag` |
| `upstream.channel` | for pattern D | Text that the release name must contain |

`tag_date` takes the `YYYY-MM-DD` date in the tag and `published_date` the release date, both rendered as `YYYY.MM.DD`.

**Authentication:** same as `github-release`.

### 3.4 github-asset

**What it checks:** one GitHub release by tag (`/repos/{owner}/{repo}/releases/tags/{tag}`) and the `updated_at` of the assets listed in the package YAML.

**When to use:** releases whose tag never moves while the assets behind it are replaced, such as a model zoo or a rolling download tag. A PKGBUILD for such a release points at fixed URLs, so an update changes `pkgver` and the checksums and nothing else.

**YAML fields:**

| Field              | Required | Description                                  |
|--------------------|----------|----------------------------------------------|
| `upstream.project` | yes      | `owner/repo` format                          |
| `upstream.tag`     | yes      | Release tag that carries the assets          |
| `upstream.assets`  | yes      | List of exact asset file names, at least one |

**How the version is extracted:** every listed asset must be present in the release, otherwise the strategy fails and names the missing one. The newest `updated_at` among them becomes the version, rendered as `YYYYMMDD` (for example `20251202`). A re-upload of any listed asset moves the date forward. The release object lists only assets in state `uploaded`, so one request covers every downloadable asset.

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

### 3.5 gitlab-tag

**What it checks:** GitLab Tags API (`/api/v4/projects/{id}/repository/tags`).

**When to use:** any GitLab instance: gitlab.com, invent.kde.org, self-hosted.

**YAML fields:**

| Field                  | Required | Description                                           |
|------------------------|----------|-------------------------------------------------------|
| `upstream.host`        | yes      | GitLab hostname (e.g. `invent.kde.org`, `gitlab.com`) |
| `upstream.project`     | yes      | Project path (e.g. `network/my-kde-app`)              |
| `upstream.tag_pattern` | no       | Glob to filter tags                                   |

**How the version is extracted:** URL-encodes the project path (`/` becomes `%2F`), fetches the first 100 tags, filters them by `tag_pattern`, strips a leading `v` and returns the highest by `sort -V`. There is no authentication, so private projects cannot be queried.

**Example YAML:**

```yaml
name: my-kde-app
strategy: gitlab-tag
upstream:
  host: invent.kde.org
  project: network/my-kde-app
```

### 3.6 gitea-tag

**What it checks:** Gitea/Forgejo Tags API (`/api/v1/repos/{owner}/{repo}/tags`).

**When to use:** Codeberg and self-hosted Gitea or Forgejo instances.

**YAML fields:**

| Field                  | Required | Description                              |
|------------------------|----------|------------------------------------------|
| `upstream.host`        | yes      | Instance hostname (e.g. `codeberg.org`)  |
| `upstream.project`     | yes      | `owner/repo` format                      |
| `upstream.tag_pattern` | no       | Glob to filter tags                      |

**How the version is extracted:** fetches up to 50 tags without pagination, filters them by `tag_pattern`, strips a leading `v` and returns the highest by `sort -V`.

**Example YAML:**

```yaml
name: my-package
strategy: gitea-tag
upstream:
  host: codeberg.org
  project: owner/repo
```

### 3.7 git-latest

**What it checks:** any git repository, through a bare clone.

**When to use:** `-git` AUR packages that track the latest commit.

**YAML fields:**

| Field              | Required | Description                                  |
|--------------------|----------|----------------------------------------------|
| `upstream.type`    | yes      | One of: `github`, `gitlab`, `git`            |
| `upstream.host`    | depends  | Required for the `gitlab` type               |
| `upstream.project` | depends  | Required for the `github` and `gitlab` types |
| `upstream.url`     | depends  | Required for the `git` type: full clone URL  |

**How the version is extracted:** makes a bare clone into a temporary directory, counts the commits on `HEAD` (`git rev-list --count HEAD`), takes the short hash (`git rev-parse --short=7 HEAD`) and prints the usual `-git` format `r<count>.<shorthash>`, for example `r431.66db9ce`.

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

**Example YAML (any git URL):**

```yaml
name: my-package-git
strategy: git-latest
upstream:
  type: git
  url: "https://git.sr.ht/~user/repo"
```

### 3.8 pypi

**What it checks:** PyPI JSON API (`https://pypi.org/pypi/{package}/json`).

**When to use:** Python packages published on PyPI.

**YAML fields:**

| Field               | Required | Description                                  |
|---------------------|----------|----------------------------------------------|
| `upstream.registry` | yes      | PyPI package name (e.g. `requests`, `flask`) |

**How the version is extracted:** reads `.info.version`, the latest stable release on PyPI.

**Example YAML:**

```yaml
name: python-requests
strategy: pypi
upstream:
  registry: requests
```

### 3.9 npm

**What it checks:** npm registry (`https://registry.npmjs.org/{package}/latest`).

**When to use:** Node.js packages published on npm.

**YAML fields:**

| Field               | Required | Description                                  |
|---------------------|----------|----------------------------------------------|
| `upstream.registry` | yes      | npm package name (e.g. `express`, `webpack`) |

**How the version is extracted:** reads `.version` of the `latest` tag.

**Example YAML:**

```yaml
name: nodejs-express
strategy: npm
upstream:
  registry: express
```

### 3.10 crates

**What it checks:** crates.io API (`https://crates.io/api/v1/crates/{crate}`).

**When to use:** Rust crates published on crates.io.

**YAML fields:**

| Field               | Required | Description                        |
|---------------------|----------|------------------------------------|
| `upstream.registry` | yes      | Crate name (e.g. `serde`, `tokio`) |

**How the version is extracted:** reads `.crate.max_stable_version`, which excludes pre-releases. The request sends `User-Agent: aurtomator/1.0`, as the crates.io API policy requires.

**Example YAML:**

```yaml
name: rust-serde
strategy: crates
upstream:
  registry: serde
```

### 3.11 repology

**What it checks:** Repology API (`https://repology.org/api/v1/project/{name}`).

**When to use:** as a fallback when no other strategy fits. Repology tracks versions across many distribution repositories.

**YAML fields:**

| Field               | Required | Description                                                  |
|---------------------|----------|--------------------------------------------------------------|
| `upstream.repology` | no       | Repology project name. Defaults to the package `name`.       |

**How the version is extracted:** returns the version of the first entry with `status == "newest"`. The request sends `User-Agent: aurtomator/1.0`, as Repology asks.

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

### 3.12 archpkg

**What it checks:** Arch Linux package search API (`https://archlinux.org/packages/search/json/?name={name}`).

**When to use:** AUR packages that follow an official Arch package, for example a package that needs a rebuild when a dependency in the official repos is updated.

**YAML fields:**

| Field              | Required | Description                                                    |
|--------------------|----------|----------------------------------------------------------------|
| `upstream.archpkg` | no       | Package name in the official repos. Defaults to the package `name`. |

**How the version is extracted:** reads `.results[0].pkgver`, the version without `pkgrel`.

**Example YAML:**

```yaml
name: my-qt6-addon
strategy: archpkg
upstream:
  archpkg: qt6-base
```

### 3.13 webpage-scrape

**What it checks:** any HTTPS page, with a regex that matches the version.

**When to use:** upstreams without a structured API: download pages, directory listings, changelogs.

**YAML fields:**

| Field              | Required | Description                                          |
|--------------------|----------|------------------------------------------------------|
| `upstream.url`     | yes      | HTTPS URL of the page                                |
| `upstream.pattern` | yes      | ERE whose first capture group is the version         |

**How the version is extracted:**

1. Fetches the page: HTTPS only, at most 5 redirects and 5 MB.
2. Finds every match with `grep -oE`.
3. Extracts the first capture group with `sed -E`.
4. Sorts with `sort -Vu` and returns the highest version.

**Example YAML:**

```yaml
name: my-scrape-pkg
strategy: webpage-scrape
upstream:
  url: "https://www.example.com/~maintainer/my-scrape-pkg/"
  pattern: "my-scrape-pkg-([0-9.]+)\\.tar\\.gz"
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

### 3.14 kde-tarball

**What it checks:** the KDE download server listing (`https://download.kde.org/stable/{name}/`).

**When to use:** KDE and Plasma packages that publish release tarballs on download.kde.org.

**YAML fields:** none. The package `name` is the directory on the server.

**How the version is extracted:** matches `{name}-{version}.tar.xz` links on the listing, where the version is digits and dots (`[0-9]+\.[0-9]+(\.[0-9]+)*`), and returns the highest by `sort -Vu`.

**Example YAML:**

```yaml
name: my-kde-app
strategy: kde-tarball
```

## 4. Update Process

`check-all.sh --update` calls `update-pkg.sh` for every package with a new version. `--prepare`, `--verify` and `--publish` split the same update into three runs, see [4.4](#44-prepare-and-publish).

### 4.1 Arguments

```text
update-pkg.sh <package-name> <new-version> [--dry-run] [--prepare <dir>]
verify-pkg.sh <package-name> <prepared-dir>
publish-pkg.sh <package-name> <version> <prepared-dir> [--dry-run]
check-all.sh [--update | --prepare <dir> | --verify <dir> | --publish <dir>] [--dry-run]
```

### 4.2 Step-by-step

1. Load `.aurtomator.conf` when it exists. In CI, `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL` and `GPG_KEY_ID` come from the workflow environment.
2. Clone `ssh://aur@aur.archlinux.org/<package-name>.git` into a temporary directory, with up to 3 attempts. A clone without a PKGBUILD stops the update.
3. When the clone lands on a detached `HEAD`, reset `master` to `origin/master`, so the push is a fast-forward.
4. Warn when the PKGBUILD has no `# Maintainer:` line.
5. Audit the PKGBUILD. Split packages, `pkgver()` with the wrong strategy and mixed checksums block the update. Patches only warn. See [SUPPORTED-PACKAGES.md](SUPPORTED-PACKAGES.md).
6. Set `pkgver` with `sed` and reset `pkgrel=1`. When the PKGBUILD does not change, the AUR already has this version: the script writes it to `current` and exits with code 2.
7. Unless a checksum array holds a `SKIP`, validate every source URL, run `updpkgsums`, and verify the result with `makepkg --verifysource --skippgpcheck`. Any failure stops the update.
8. Run `namcap` when it is installed. Errors stop the update. Warnings are printed.
9. Regenerate `.SRCINFO` with `makepkg --printsrcinfo`.
10. With `--dry-run`, print the PKGBUILD diff and stop.
11. Commit `PKGBUILD` and `.SRCINFO` as `<new-version> release from <strategy>`, authored by `GIT_AUTHOR_NAME` and `GIT_AUTHOR_EMAIL` (default `aurtomator`). With `GPG_KEY_ID` set, the commit is amended with a signature. When signing fails, the commit is pushed unsigned.
12. Push, with up to 3 attempts.
13. Write `current` and `last_updated` to the package YAML.

### 4.3 Downgrade behavior

aurtomator follows upstream when it publishes a version older than the tracked one, and does **not** block it. Upstream is the source of truth: a packager that refuses a re-published older release only drifts out of sync. A downgrade is logged and shown, and it does not count as a failure.

#### When does this happen?

- Upstream deletes and recreates a release tag. In the gap, `/releases/latest` returns the previous release, so a cycle like `v1.2.1 → v1.2.0 → v1.2.1` can take only minutes.
- Upstream rolls back a broken release and removes its tag.
- Upstream marks an older release line as latest again, for example when a 2.x release is pulled and 1.x becomes the newest release.

#### How to detect downgrades in logs

Every comparison that finds the current version newer than the latest one (`vercmp "$current" "$latest"` returns `1`) logs the literal token `DOWNGRADE`. In a CI run, `check-all.sh` logs:

```text
! myapp-bin: DOWNGRADE detected 1.2.1 → 1.2.0 (mirroring upstream)
```

`check-update.sh` run on its own logs:

```text
! myapp-bin: DOWNGRADE 1.2.1 → 1.2.0
```

`grep DOWNGRADE` on a downloaded run log finds both.

#### Status values and README icons

`check-all.sh` writes two status tokens for downgrades to `.status/<pkg>`:

| Token                         | Meaning                                           |
|-------------------------------|---------------------------------------------------|
| `downgrade: <version>`        | `--update` mode: the downgrade was pushed to the AUR |
| `available_downgrade: <ver>`  | Check-only mode: a downgrade is available and not applied |

`update-readme.sh` renders them as:

- `downgrade: 1.2.0` → `⬇️ downgraded to 1.2.0`
- `available_downgrade: 1.2.0` → `⬇️ 1.2.0 available (downgrade)`

Both count toward `pkg_ok`, so the packages badge stays `brightgreen`. Only `check_failed` and `update_failed` turn it red.

### 4.4 Prepare and publish

A PKGBUILD is a bash script, and every step that reads it executes it: the audit, `updpkgsums`, `makepkg --verifysource` and `makepkg --printsrcinfo`. Whoever can push to the AUR repo of a tracked package, a co-maintainer for example, runs code in those steps. Prepare and publish split the update so that this code never runs where the SSH key, the GPG key or a write token is. Code that runs in prepare can write the prepared files of every package, so verify checks their checksums against the sources in between.

**Prepare**, `update-pkg.sh --prepare <dir>`, needs no secrets:

1. Clone `https://aur.archlinux.org/<package-name>.git` anonymously.
2. Run steps 3 to 9 of [4.2](#42-step-by-step).
3. Copy `PKGBUILD`, `.SRCINFO` and the commit id of the clone's `HEAD` to `<dir>/<package-name>/` as `PKGBUILD`, `.SRCINFO` and `base`. Nothing is committed and the package YAML does not change. Exit code 2 still means the AUR already has the version.

**Verify**, `verify-pkg.sh <package-name> <dir>/<package-name>`, needs no secrets, never sources the PKGBUILD and never runs `makepkg`:

1. The prepared directory must pass step 1 of publish below.
2. Clone `https://aur.archlinux.org/<package-name>.git` anonymously. When `HEAD` is not `base`, the AUR repo moved after the update was prepared: exit code 3.
3. `PKGBUILD` and `.SRCINFO` in the clone must be regular files. The prepared files must hold no NUL byte and pass steps 4 and 5 of publish below, with the prepared `pkgver` as `<version>`. From here on, every source URL in the prepared `.SRCINFO` follows from the AUR copy.
4. Each checksum array of the prepared `PKGBUILD` must hold the same values as the same key in the prepared `.SRCINFO`.
5. Every checksum other than `SKIP` must match its source, computed as makepkg does with `<algorithm>sum`. The file is the one makepkg uses. A file in the AUR repo with the name of the source comes first and must be a regular file. Otherwise a remote source is downloaded with curl, retried as makepkg does and limited to `http`, `https` and `ftp`, redirects included. A checksum for any other protocol, a VCS source for example, cannot be checked and stops the verify.
6. Any mismatch stops the verify with exit code 1. Otherwise the exit code is 0.

**Publish**, `publish-pkg.sh <package-name> <version> <dir>/<package-name>`, never sources the PKGBUILD and never runs `makepkg`. It treats the prepared files as untrusted:

1. The prepared directory must not be a symlink, `PKGBUILD`, `.SRCINFO` and `base` must be regular files, and `base` a commit id.
2. When the prepared `pkgver` is not `<version>`, upstream moved after the update was prepared: exit code 3.
3. Clone over SSH. When `HEAD` is not `base`, the AUR repo moved after the update was prepared: exit code 3. `PKGBUILD` and `.SRCINFO` in the clone must be regular files, not symlinks.
4. The prepared `PKGBUILD` may differ from the AUR copy only in `pkgver=`, which must be `<version>`, in `pkgrel=`, which must be `1`, and in the values of the checksum arrays. The arrays keep their names and lengths, hold only quoted hex checksums or `SKIP`, and have a `SKIP` exactly where the AUR copy has one.
5. Each line of the prepared `.SRCINFO` must be the line of the AUR copy with the old version replaced by `<version>`. The same holds for three forms a PKGBUILD often derives from `pkgver`: dots turned into underscores (`1_86_0`), the part before the first `+` (`0.13.0` of `0.13.0+dev+1853+g6edb38ca98`), and the version without its last component (`6.19` of `6.19.0`, as in `frameworks/${pkgver%.*}/` of KDE Frameworks). The last form counts only while it keeps a dot. Each part of a line is replaced at most once, so `5.1` inside an already replaced `5.10.0` stays. A line built from any other form of the version, a lone major version for example, stops the publish, and the package needs a manual update. `pkgrel` and the checksums follow the rules of step 4.
6. Any other difference, and a NUL byte in either file, stops the publish with exit code 1. Otherwise steps 10 to 13 of [4.2](#42-step-by-step) follow. When the prepared files equal the AUR copy, only `current` is written to the YAML and the exit code is 2.

`check-all.sh --prepare <dir>` runs no strategy and needs no `GITHUB_TOKEN`. It takes the versions from the statuses that a check run, `check-all.sh` without a mode, wrote to `.status/` before it, and reads them before the first PKGBUILD runs. It prepares every package with `new_version` or `available_downgrade` into `<dir>/prepared/` and copies the statuses to `<dir>/status/`. A failed preparation becomes `update_failed`, and a package without a status from the check run becomes `check_failed`. The other statuses stay as the check run wrote them.

`check-all.sh --verify <dir>` runs `verify-pkg.sh` for every package in `packages/` that has a directory in `<dir>/prepared/`, and runs no strategy. An update that fails is removed from `<dir>/prepared/`, its status in `<dir>/status/` becomes `update_failed`, and `<dir>/status/_error_count` grows by one. An update with exit code 3 is removed and keeps its status, and the next run prepares it again.

`check-all.sh --publish <dir>` builds `.status/` anew from `<dir>/status/`. The prepare run executes PKGBUILDs, so only regular files named after a package in `packages/` are taken, in the forms that run writes, and any other content becomes `check_failed`. When the script stops before that, `.status/` stays empty and the steps after it read nothing from the prepare run. Then it takes every package in `packages/` that has a directory in `<dir>/prepared/`, runs its strategy once more and publishes with the version the strategy reports now. Exit code 3 leaves the status at `new_version` or `available_downgrade` without an error, and the next run prepares the package again.

## 5. CI Workflow: check-updates.yml

### 5.1 Trigger

The workflow runs every hour (`cron: "0 * * * *"`) and by hand through `workflow_dispatch`. The `check-updates` concurrency group serializes runs: a new run waits for the running one.

### 5.2 Permissions and container

The workflow has three jobs. All run in `archlinux:base-devel` on `ubuntu-latest` with a 30-minute timeout, and `vercmp` from pacman, which `check-all.sh` requires, is the reason `verify` and `publish` need Arch too. `makepkg` refuses to run as root, so the steps that touch packages in `prepare` and `publish` run as a `builder` user. `builder` has no `sudo` rights: the steps run as root and switch to `builder` with `sudo -u builder`. `verify` executes no PKGBUILD and runs as root.

| Job | Permissions | Secrets |
|-----|-------------|---------|
| `prepare` | `contents: read` | none |
| `verify` | `contents: read` | none |
| `publish` | `contents: write` for the status commit, `issues: write` for failure issues | `AUR_SSH_KEY`, `GPG_SIGNING_KEY`, `AUR_GIT_NAME`, `AUR_GIT_EMAIL` |

`verify` and `publish` run only when `prepare` hands over a prepared update or a change in the status table of `README.md`, and `publish` only after `verify` succeeds. In most hours nothing changes, and both are skipped.

### 5.3 Steps

Every job starts with **Checkout:** `actions/checkout`, pinned by commit SHA like every action in this repository, with `persist-credentials: false`, so the workflow token is not written to `.git/config`. The workflow never pushes to GitHub with git: the status commit goes through the API.

`prepare`:

1. **Install dependencies:** `sudo git openssh namcap jq go-yq pacman-contrib`, and the `builder` user.
2. **Check updates:** gives the workspace to `builder` and runs `check-all.sh` as `builder`, with `GITHUB_TOKEN` set to the read-only workflow token. `sudo --preserve-env` passes the token, so it does not appear on a command line. No PKGBUILD runs in this step.
3. **Prepare updates:** runs `check-all.sh --prepare handoff` as `builder`, without a token. Code from a PKGBUILD can read the environment of every running process of `builder` through `/proc/<pid>/environ`, so the token exists only in the step before.
4. **Hand over:** as `builder`, runs `update-readme.sh` to find out whether the status table changes. Code from a PKGBUILD has run in the workspace by now, `.git/config` included, so root does not run git there. A process started by a PKGBUILD can outlive its step, so the step then kills every process of `builder`. Only after that does root copy the regular files at `prepared/<package>/PKGBUILD`, `prepared/<package>/.SRCINFO`, `prepared/<package>/base` and `status/<package>` from `handoff/` to `upload/`. `find` does not follow symlinks and separates paths with NUL, because a name may hold a newline, so a link to a file outside the workspace does not reach the artifact. A package name never starts with a dot, so `.` and `..` match no path.
5. **Upload handoff:** uploads `upload/` as the `handoff` artifact with `include-hidden-files: true`, because `.SRCINFO` starts with a dot, and a retention of 1 day.

`verify`:

1. **Install dependencies:** `git jq go-yq`.
2. **Download handoff:** the `handoff` artifact to `handoff/`.
3. **Verify checksums:** runs `check-all.sh --verify handoff`, see [4.4](#44-prepare-and-publish).
4. **Upload verified handoff:** uploads `handoff/` as the `verified` artifact with `include-hidden-files: true` and a retention of 1 day.

`publish`:

1. **Install dependencies:** `sudo git github-cli openssh gnupg jq go-yq`, and the `builder` user.
2. **Download verified handoff:** the `verified` artifact to `handoff/`.
3. **Setup workspace:** git identity for `builder` from the `AUR_GIT_NAME` and `AUR_GIT_EMAIL` secrets, default `aurtomator`.
4. **Setup AUR SSH:** writes `AUR_SSH_KEY` to `/home/builder/.ssh/aur`, writes the Ed25519 host key that <https://aur.archlinux.org> publishes to `known_hosts`, and writes an SSH config with `StrictHostKeyChecking yes` and connection multiplexing. A host that answers with another key fails with `Host key verification failed`. When the AUR changes its host key, update the key in `check-updates.yml`.
5. **Setup GPG:** with `GPG_SIGNING_KEY` set, imports the key for `builder`, passes `GPG_KEY_ID` to the later steps and enables commit signing. Without it, the step is skipped.
6. **Publish updates:** runs `check-all.sh --publish handoff` as `builder`, with `GPG_KEY_ID`, `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL` and `GITHUB_TOKEN` set to the workflow token. It builds `.status/` from the checked statuses and checks the prepared files before it pushes, see [4.4](#44-prepare-and-publish).
7. **Update README status table:** runs `update-readme.sh` as `builder`.
8. **Commit changes via API (verified):** see [5.5](#55-verified-commit).
9. **Create issues for failed packages:** see [5.6](#56-failure-issues).

Steps 8 and 9 run as root with `GH_TOKEN` set to the workflow token, `github.token`.

### 5.4 README update

`update-readme.sh` rewrites two blocks of `README.md`:

1. **Badges** between `<!-- BADGES:START -->` and `<!-- BADGES:END -->`: CI, Codecov and static badges for the repository in `origin`. A public repository gets its own tokenless Codecov badge. A private one, or a failed API call, links the upstream aurtomator badge.
2. **Package table** between `<!-- PACKAGES:START -->` and `<!-- PACKAGES:END -->`, built from `.status/`.

#### .status/ directory format

`check-all.sh` writes one file per package:

| Filename               | Content                          | Meaning                                  |
|------------------------|----------------------------------|------------------------------------------|
| `.status/<name>`       | `up_to_date`                     | The package is at the latest version     |
| `.status/<name>`       | `updated: 2.0.0`                 | Pushed to the AUR                        |
| `.status/<name>`       | `new_version: 2.0.0`             | Update found, not pushed yet             |
| `.status/<name>`       | `downgrade: 1.2.0`               | Downgrade pushed to the AUR              |
| `.status/<name>`       | `available_downgrade: 1.2.0`     | Downgrade found, not pushed yet          |
| `.status/<name>`       | `check_failed: <error>`          | The strategy failed                      |
| `.status/<name>`       | `update_failed: <error>`         | The update failed                        |
| `.status/_error_count` | `0`                              | Total error count of the run             |

#### Packages badge

```text
https://img.shields.io/badge/packages-<ok>%2F<total>-<color>
```

The color is `brightgreen` with no failures and `red` otherwise.

#### Status table

```markdown
| Package | Version | Strategy | Updated | Status |
|---------|---------|----------|---------|--------|
| [my-package](https://aur.archlinux.org/packages/my-package) | 1.0.1 | kde-tarball | 2026-10-01 | ✅ up to date |
| [other-pkg](https://aur.archlinux.org/packages/other-pkg) | 2.0.0 | github-release | 2026-10-14 | 🔄 updated to 2.0.0 |
```

### 5.5 Verified commit

A `git push` from the workflow would show as unverified, so the step commits through the GitHub Git Data API:

1. Stop when `git diff --quiet` finds no change.
2. Read the branch head and its tree.
3. Create a blob for every changed file, a tree on the base tree, and a commit.
4. Move the branch ref with `force=false`.

The message is `chore: update package versions [skip ci]`. `[skip ci]` keeps the commit from starting `ci.yml`. GitHub marks the commit as verified because the Actions bot creates it through the API.

### 5.6 Failure issues

The step runs with `if: always()`. For every `.status/` entry with `check_failed:` or `update_failed:`, it:

1. Creates the `auto-update` label when it is missing.
2. Skips the package when an open `auto-update` issue already matches `<package> failed`.
3. Opens an issue titled `❌ <package>: update failed` with the package, the error and a link to the run.

The step belongs to `publish`, which runs when the status table changes. A package that keeps failing gets its issue in the run where it starts failing, and a closed issue comes back only after its status changes again.

## 6. CI Quality Gate: ci.yml

`ci.yml` runs on every push and pull request to `main`.

### 6.1 Lint job

`ubuntu-latest`, 5-minute timeout. It installs `shellcheck` from apt and `shfmt` with `go install`, then runs:

```bash
shellcheck -x -S warning scripts/*.sh strategies/*.sh
shfmt -d -i 2 -ci scripts/*.sh strategies/*.sh
```

`-x` follows `source` directives and `-S warning` sets the minimum severity. `-d` fails on any formatting diff, `-i 2` sets two-space indentation, and `-ci` indents `case` branches.

### 6.2 Test job

`archlinux:base-devel` container, 15-minute timeout. It installs `bash bats git go-yq curl openssh ruby ruby-erb` and the `bashcov` and `simplecov-cobertura` gems, then runs:

```bash
./scripts/validate-pkg.sh --all
bats tests/ --recursive
bashcov -- bats tests/ --recursive
```

The coverage run uploads `coverage/coverage.xml` to Codecov and never fails the job.

## 7. Local Testing

### 7.1 Prerequisites

```bash
sudo pacman -S --needed git curl go-yq pacman-contrib namcap
# For tests and linting:
sudo pacman -S --needed bats shellcheck shfmt
```

### 7.2 Check a single package

```bash
./scripts/check-update.sh my-package
```

The log goes to stderr. When an update is available, the new version is printed on stdout:

```text
→ Checking my-package (strategy: github-release, current: 1.0.0)
! my-package: update available 1.0.0 → 2.0.0
2.0.0
```

When the package is up to date, stdout stays empty:

```text
→ Checking my-package (strategy: github-release, current: 2.0.0)
✓ my-package is up to date (2.0.0)
```

### 7.3 Dry-run an update

```bash
./scripts/update-pkg.sh my-package 2.0.0 --dry-run
```

It runs the steps of [4.2](#42-step-by-step) up to `.SRCINFO`, prints the PKGBUILD diff and does not push.

### 7.4 Push an update

```bash
./scripts/update-pkg.sh my-package 2.0.0
```

It runs the full cycle, including `git push` to the AUR with your SSH key.

### 7.5 Check all packages

```bash
# Check only
./scripts/check-all.sh

# Check and push updates
./scripts/check-all.sh --update

# Check and dry-run updates
./scripts/check-all.sh --update --dry-run
```

The last line is a summary:

```text
→ Checked: 4, Updated: 2, Errors: 0
```

### 7.6 Running BATS tests

```bash
# Run all tests
bats tests/ --recursive --timing

# Run one file
bats tests/scripts.bats
bats tests/strategies.bats
bats tests/setup.bats
```

`tests/helpers/setup.sh` gives every test a temporary project directory with symlinked scripts and strategies. It copies `tests/helpers/mock-curl.sh` there as `curl`, puts it first in `PATH`, and removes the directory afterwards. Tests that need `git`, `ssh` or `gh` put their own mocks in the same place. The suite makes no network requests and never touches real AUR repos.

### 7.7 Linting locally

```bash
# shellcheck
shellcheck -x -S warning scripts/*.sh strategies/*.sh

# shfmt (check mode)
shfmt -d -i 2 -ci scripts/*.sh strategies/*.sh

# shfmt (auto-fix)
shfmt -w -i 2 -ci scripts/*.sh strategies/*.sh
```

## 8. Writing Custom Strategies

A strategy is a bash script in `strategies/` that finds the latest upstream version of a package.

### 8.1 Interface contract

- **Input:** one positional argument, the package name.
- **Success:** the version on stdout as one line, exit code 0.
- **Failure:** an error on stderr, a non-zero exit code.
- **Version format:** `check-update.sh` rejects a version with any character outside `A-Za-z0-9._+`.

The script can rely on `yq` and `curl`. `scripts/lib.sh` provides YAML helpers and logging and sets `AURTOMATOR_DIR` to the project root.

### 8.2 Template

```bash
#!/usr/bin/env bash
#
# my-strategy - Detect latest version from <source>
#
# Input: package name (reads upstream config from package YAML)
# Output: latest version string

set -euo pipefail

readonly NAME="${1:?Usage: my-strategy.sh <package-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly TIMEOUT=30

# shellcheck source=../scripts/lib.sh
source "${SCRIPT_DIR}/../scripts/lib.sh"

pkg_file=$(pkg_file "$NAME")
my_field=$(pkg_get "$pkg_file" .upstream.my_field)

version=$(curl -sfL --max-time "$TIMEOUT" \
  "https://example.com/api/${my_field}" |
  yq -r '.version') || {
  echo "Failed to fetch version for ${my_field}" >&2
  exit 1
}

if [[ -z "$version" || "$version" == "null" ]]; then
  echo "No version found for ${my_field}" >&2
  exit 1
fi

echo "$version"
```

### 8.3 Checklist

1. **Location:** `strategies/<name>.sh`, executable (`chmod +x`). `<name>` is the value of the YAML `strategy` field.
2. **Header:** `set -euo pipefail`, then source `lib.sh` for `pkg_file`, `pkg_get` and logging.
3. **HTTP:** `curl -sfL --max-time "$TIMEOUT"`. `-f` fails on HTTP errors, `-L` follows redirects, and `--max-time` prevents hangs.
4. **Result:** check for an empty string and for `null` from `yq`.
5. **Prefix:** strip a leading `v` with `${version#v}` when upstream tags look like `v1.0.0`.
6. **Validation:** add the name and its required fields to `scripts/validate-pkg.sh`.
7. **Tests:** add the API fixture to `tests/helpers/mock-curl.sh` and tests to `tests/strategies.bats`.
8. **Linters:**

   ```bash
   shellcheck -x -S warning strategies/my-strategy.sh
   shfmt -d -i 2 -ci strategies/my-strategy.sh
   ```

9. **Docs:** the strategies table in `README.md`, a section in this file, and an example in `packages/example.yml.sample`.

### 8.4 Available lib.sh functions

| Function                        | Description                                         |
|---------------------------------|-----------------------------------------------------|
| `pkg_file <name>`               | Resolves `packages/<name>.yml`, returns 1 if missing |
| `pkg_get <file> <yq-query>`     | Reads a field from a YAML file with yq              |
| `pkg_set <file> <query> <val>`  | Writes a field to a YAML file with yq               |
| `require_cmd <cmd>`             | Exits 1 if the command is not in `PATH`             |
| `load_config`                   | Sources `.aurtomator.conf` if present               |
| `log_ok <msg>`                  | Prints a green check mark and the message to stderr |
| `log_warn <msg>`                | Prints a yellow `!` and the message to stderr       |
| `log_err <msg>`                 | Prints a red cross and the message to stderr        |
| `log_info <msg>`                | Prints a bold arrow and the message to stderr       |

The logging functions omit ANSI colors when stdout is not a terminal.

### 8.5 YAML conventions for custom strategies

Put the strategy's settings under `upstream`, with descriptive names, and list them in the header of the strategy script. Other strategies ignore fields they do not read.

```yaml
name: my-package
strategy: my-strategy
upstream:
  my_field: some-value
  another_field: another-value
```
