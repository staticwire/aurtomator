# Supported Package Types

What aurtomator can automate, what it cannot, and how to avoid breaking things.

## How aurtomator updates packages

For every update, aurtomator does exactly this:

1. Clone the existing AUR git repo
2. **Audit the PKGBUILD** for unsupported features (blocks or warns)
3. `sed` replaces `pkgver=` with the new version
4. Reset `pkgrel=1`
5. **Validate source URLs** (HEAD request, HTTP status and `Content-Type` check)
6. Run `updpkgsums`, or skip it for VCS checksums
7. Run `makepkg --verifysource` to verify checksums
8. **Lint with `namcap`** when it is installed (errors are fatal, warnings are not)
9. Run `makepkg --printsrcinfo` to regenerate `.SRCINFO`
10. Commit and push to the AUR

aurtomator does not build packages and does not check runtime dependencies. That needs `ldd` or `readelf` on built binaries and is out of scope. Dependency correctness is the maintainer's responsibility.

## Supported

### Simple binary packages (-bin)

Packages that download prebuilt binaries and install them. The source URL contains `${pkgver}`, and the binary format stays the same between versions.

```bash
source=("https://github.com/user/app/releases/download/v${pkgver}/app-${pkgver}-linux-x86_64.tar.gz")
```

**Why it works:** only `pkgver` changes. The URL pattern, binary format and installation steps stay the same, and `updpkgsums` downloads the new binary and updates the checksums.

### Packages with arch-specific sources

Packages with a different source URL per architecture:

```bash
source_x86_64=("https://example.com/app-${pkgver}-x86_64.tar.gz")
source_aarch64=("https://example.com/app-${pkgver}-aarch64.tar.gz")
```

**Why it works:** `updpkgsums` handles arch-specific checksum arrays, and source URL validation covers every `source_<arch>` array. A stable URL pattern is enough.

### VCS packages (-git) with the git-latest strategy

Packages that track the latest commit of an upstream repository:

```yaml
strategy: git-latest
upstream:
  type: gitlab
  host: gitlab.example.com
  project: group/project
```

**Why it works:** `git-latest` makes a bare clone and computes `r{count}.{hash}`, for example `r435.abc1234`, the usual AUR format for `-git` versions. aurtomator writes this value to `pkgver=`, skips `SKIP` checksums and pushes.

A `pkgver()` function in the PKGBUILD is fine: it produces the same `r{count}.{hash}` format. A user who builds the package later gets a newer value when upstream has moved on, as with every `-git` package on the AUR.

### Packages with VCS checksums (SKIP)

Packages whose checksum array starts with `SKIP`:

```bash
sha256sums=('SKIP')
```

**Why it works:** aurtomator matches `md5sums=('SKIP'`, `sha*sums=('SKIP'` and `b2sums=('SKIP'` and then skips `updpkgsums`, which would otherwise replace `SKIP` with a real hash.

Arch-specific arrays such as `b2sums_x86_64=('SKIP')` are not matched, so `updpkgsums` runs on them.

`updpkgsums` is all-or-nothing: it recalculates every checksum or none. A real hash next to `SKIP` for a remote source is blocked by the PKGBUILD audit. See "Mixed SKIP and real checksums" below.

### Non-standard tag formats (tag_version_regex)

`github-release`, `github-tag` and `github-nightly` accept `tag_version_regex` for unusual tag names:

```yaml
upstream:
  project: user/app
  tag_version_regex: '^release-v?([0-9.]+)-stable$'
```

**Why it works:** the ERE capture group extracts the version from any tag format, for example `0.1.8-stable`, `release-v2.3.0` or `app/v1.5.0`.

### Nightly and prerelease packages

`github-nightly` tracks nightly builds in 4 patterns:

- **Fixed tag**, for example the neovim `nightly` tag, moved daily
- **Dated tags**, for example `nightly-2026-03-26`
- **Separate nightly repo**, for example yt-dlp-nightly-builds
- **Channel filter**, for example the brave-browser Nightly channel

The version comes from the tag name, the release body, the tag date or the publish date. `strategies/github-nightly.sh` lists the fields.

## Not supported (blocked or detected)

aurtomator detects these cases and blocks the update or warns.

### Split packages (BLOCKED)

Packages with `pkgname=(foo foo-libs foo-doc)` and several `package_*()` functions.

**Detection:** `audit_pkgbuild()` checks for `pkgname=(` and blocks.

**Why:** aurtomator can update `pkgver`, but it cannot tell when subpackages need different `depends` or when the `pkgname` array itself changes upstream.

### pkgver() with the wrong strategy (BLOCKED)

A PKGBUILD with a `pkgver()` function and a strategy other than `git-latest` or `github-nightly`, for example `github-release`.

**Detection:** `audit_pkgbuild()` checks for a `pkgver()` function and the strategy. Release and tag strategies report release versions, which do not match what `pkgver()` computes at build time.

**Correct approach:** use `strategy: git-latest` for packages with `pkgver()`.

### Mixed SKIP and real checksums (BLOCKED)

A checksum array that starts with `SKIP` and also holds a real hash for a remote source:

```bash
source=("git+https://example.com/app.git" "https://example.com/data.tar.gz")
sha256sums=('SKIP'
            'abc123def456...')
```

**Detection:** `audit_pkgbuild()` sources the PKGBUILD and pairs each entry of `md5sums`, `sha1sums`, `sha256sums`, `sha512sums` and `b2sums` with the matching `source` entry. A real hash for a URL with `://` blocks the update. A real hash for a local file is allowed, because that file lives in the AUR repo and does not change between versions.

**Why:** when aurtomator sees `SKIP`, it skips `updpkgsums`, so the real hash of the remote source would be stale after the version bump.

### Source URL returns HTML (BLOCKED)

Upstream moves or renames a release, and the old URL now redirects to an HTML error or download page.

**Detection:** `validate_source_urls()` sends a HEAD request to every URL in `source` and in each `source_<arch>` array. HTTP status 400 or above, or `Content-Type: text/html`, blocks the update.

**Why:** without this check, `updpkgsums` would hash the HTML page. The checksums would match and the package would fail to install.

### Packages with patches (WARNING)

Packages with `.patch` or `.diff` files in `source=()`.

**Detection:** `audit_pkgbuild()` warns and does not block. Patches often survive a minor version bump and can break on a major one. The maintainer accepts that risk.

## Not supported (not detected)

aurtomator cannot detect these cases. The maintainer has to watch for them.

### Packages needing a pkgrel bump

When `pkgver` stays the same and the PKGBUILD changes (dependency fix, build flag, patch update), `pkgrel` has to be incremented. aurtomator always sets `pkgrel=1`. A pkgrel-only bump needs a human decision.

### Packages with changing source URLs

When upstream changes the download URL format:

- GitHub to GitLab migration
- `.tar.gz` to `.tar.zst`
- Binary renamed: `app-linux-x86_64` to `app-linux-amd64`
- Major version path change: `v1/app.tar.gz` to `v2/app.tar.gz`

aurtomator does not modify `source=()`. After such a change, source URL validation or `updpkgsums` fails and aurtomator refuses to push. That failure is safe.

### Packages with changing dependencies

aurtomator does not modify `depends`, `makedepends` or `optdepends`. When a new version needs a library that was not listed before, users can hit runtime errors.

### Packages requiring epoch

When upstream changes its versioning scheme, for example from CalVer to SemVer, and the new version compares lower than the old one, `epoch` is needed. aurtomator does not detect or set `epoch`. Setting it cannot be undone and needs maintainer judgment.

### Packages with version-dependent install scripts

aurtomator does not touch `.install` files. When a new version needs migration steps in `post_upgrade()`, the maintainer updates them by hand.

## Version detection strategies

aurtomator includes 14 version detection strategies. Choose by where your upstream publishes releases:

| Strategy | Source | Best for | Pre-release filter |
|---|---|---|---|
| `github-release` | GitHub Releases API | Most GitHub projects | Auto (excludes pre-releases) |
| `github-tag` | GitHub Tags API | Projects without formal releases | Manual (`tag_pattern`) |
| `github-nightly` | GitHub Releases API | Nightly/dev builds (4 patterns) | Nightly-specific |
| `github-asset` | GitHub Releases API | Assets re-uploaded on a fixed tag (model zoos) | N/A (fixed tag) |
| `gitlab-tag` | GitLab Tags API | GitLab.com, invent.kde.org, self-hosted | Manual (`tag_pattern`) |
| `gitea-tag` | Gitea/Forgejo Tags API | Codeberg, self-hosted Gitea | Manual (`tag_pattern`) |
| `git-latest` | Bare git clone | `-git` packages (commit tracking) | N/A |
| `pypi` | PyPI JSON API | Python packages | Auto (stable only) |
| `npm` | npm registry | Node.js packages | Auto (`latest` tag) |
| `crates` | crates.io API | Rust packages | Auto (stable only) |
| `repology` | Repology API | Fallback across distro repositories | Varies |
| `archpkg` | Arch package search | Track official repo versions | N/A |
| `webpage-scrape` | Any HTTPS page + regex | No API available | None (depends on regex) |
| `kde-tarball` | download.kde.org | KDE/Plasma packages | None |

### Strategy limitations

- **GitHub rate limit:** the GitHub strategies send `GITHUB_TOKEN` when it is set in the environment. The `check-updates` workflow sets it to the workflow token, which allows 1,000 requests per hour per repository. Without a token, the limit is 60 requests per hour.
- **No retry on API failure:** strategies make one attempt. A transient failure fails the package for that run.
- **Tag strategies include pre-releases:** `github-tag`, `gitlab-tag` and `gitea-tag` pick the highest tag with `sort -V`, which places `1.0.0-rc1` above `1.0.0`. Filter with `tag_pattern`.
- **`gitea-tag` fetches at most 50 tags:** there is no pagination.
- **`gitlab-tag` has no authentication:** private GitLab projects cannot be queried.

### Upstream sources not covered

These need `webpage-scrape` or a custom strategy:

- SourceHut (git.sr.ht)
- Go module proxy (proxy.golang.org)
- Private registries (GitLab, npm, PyPI)
- FTP servers

## Comparison with other tools

| Tool | Detection | Update | Push | Approach |
|---|---|---|---|---|
| **aurtomator** | 14 built-in strategies | pkgver sed + updpkgsums | Auto push to AUR | Fully automated, self-hosted |
| **nvchecker** | 40+ sources, TOML config | No | No | Detection only |
| **aurpublish** | No | No | git subtree push | Workflow tool for maintainers |
| **aur-auto-update** | nvchecker | pkgver bump | Auto push | Centralized bot (add as co-maintainer) |
| **aurupbot** | Git clone | Runs `makepkg` for pkgver() | Auto push | VCS packages only |
| **Renovate** | Regex manager | PR-based | Separate action | PR workflow with human review |

aurtomator combines detection, update and push in one tool that runs in your own GitHub Actions and needs no external service. nvchecker covers more sources but does not update or push.

## Rules for safe automation

1. **Only automate packages you actively maintain.** When something breaks, you fix it by hand.
2. **Only automate packages where pkgver is the only thing that changes.** Do not automate a package whose upstream often changes dependencies, source URLs or the build system.
3. **Watch your issues.** aurtomator opens a GitHub Issue for every failure.
4. **Test a new package by hand first.** Build and install it once before adding it to aurtomator.
5. **Do not automate packages with patches** unless the patches are known to apply across versions.
6. **Check your packages after automated pushes.** Build them now and then with `makepkg -si` to confirm they build and work.
