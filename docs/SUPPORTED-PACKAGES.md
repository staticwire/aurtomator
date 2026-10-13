# Supported Package Types

What aurtomator can automate, what it cannot, and how to avoid breaking things.

## How aurtomator updates packages

Understanding the update mechanism is essential to knowing which packages
are safe to automate. For every update, aurtomator does exactly this:

1. Clone the existing AUR git repo
2. **Audit PKGBUILD** for unsupported features (blocks or warns)
3. `sed` replaces `pkgver=` with the new version
4. Reset `pkgrel=1`
5. **Validate source URLs** (HEAD request, Content-Type check)
6. Run `updpkgsums` (or skip for VCS checksums)
7. Run `makepkg --verifysource` to verify checksums
8. **Lint with `namcap`** (fatal on errors, warns on warnings)
9. Run `makepkg --printsrcinfo` to regenerate `.SRCINFO`
10. Commit and push to AUR

aurtomator does not build packages. It does not check runtime
dependencies — that requires `ldd`/`readelf` on built binaries, which
is outside the scope of this tool. Dependency correctness is the
maintainer's responsibility when creating the PKGBUILD.

## Supported

These package types work reliably with aurtomator:

### Simple binary packages (-bin)

Packages that download pre-built binaries and install them.
The source URL contains `${pkgver}` and the binary format doesn't change
between versions.

```bash
source=("https://github.com/user/app/releases/download/v${pkgver}/app-${pkgver}-linux-x86_64.tar.gz")
```

**Why it works:** Only `pkgver` changes. The URL pattern, binary format,
and installation steps remain the same. `updpkgsums` downloads the new
binary and updates checksums.

**Examples:** any `-bin` package with a stable download URL pattern.

### Packages with arch-specific sources

Packages with different source URLs per architecture:

```bash
source_x86_64=("https://example.com/app-${pkgver}-x86_64.tar.gz")
source_aarch64=("https://example.com/app-${pkgver}-aarch64.tar.gz")
```

**Why it works:** `updpkgsums` handles arch-specific checksum arrays.
As long as the URL pattern is stable, the bump works.

### VCS packages (-git) via git-latest strategy

Packages that track the latest commit of an upstream repository:

```yaml
strategy: git-latest
upstream:
  type: gitlab
  host: gitlab.example.com
  project: group/project
```

**Why it works:** The `git-latest` strategy performs a bare clone and
computes `r{count}.{hash}` (e.g., `r435.abc1234`). This matches the
standard AUR convention for `-git` package versions. aurtomator replaces
`pkgver=` with this computed value, skips checksums (SKIP), and pushes.

If the PKGBUILD contains a `pkgver()` function, that's fine — it will
use the same `r{count}.{hash}` format. When users build the package,
`makepkg` runs `pkgver()` and may get a slightly newer version (if
upstream advanced since aurtomator's check). This is normal for all
`-git` packages on AUR.

**Examples:** any `-git` package using the `r{count}.{hash}` version format.

### Packages with VCS checksums (SKIP)

Packages where **all** checksums in an array are `SKIP`:

```bash
sha256sums=('SKIP')
```

Or with arch-specific arrays:

```bash
b2sums_x86_64=('SKIP')
b2sums_aarch64=('SKIP')
```

**Why it works:** aurtomator detects `*sums=('SKIP'` and skips
`updpkgsums` entirely. This prevents updpkgsums from replacing SKIP
with a real hash, which would break nightly/VCS rebuilds.

**Important:** `updpkgsums` is all-or-nothing — it either recalculates
all checksums or none. Packages where a single checksum array mixes
SKIP and real hashes (e.g., `sha256sums=('SKIP' 'realhash')`) are
**not supported** and will be blocked by the PKGBUILD audit. See
"Mixed SKIP and real checksums" below.

### Non-standard tag formats (via tag_version_regex)

Upstream projects that use unusual tag names:

```yaml
upstream:
  project: user/app
  tag_version_regex: '^release-v?([0-9.]+)-stable$'
```

**Why it works:** `tag_version_regex` applies an ERE capture group to
extract the version from any tag format (e.g., `0.1.8-stable`,
`release-v2.3.0`, `app/v1.5.0`).

### Nightly/prerelease packages

Packages tracking nightly builds with 4 supported patterns:

- **Fixed tag** (e.g., neovim `nightly` tag, force-pushed daily)
- **Dated tags** (e.g., `nightly-2026-03-26`)
- **Separate nightly repo** (e.g., yt-dlp-nightly-builds)
- **Channel filter** (e.g., brave-browser Nightly channel)

Version can be extracted from tag name, release body, tag date, or
publish date. See `strategies/github-nightly.sh` for details.

## Not supported (blocked or detected)

aurtomator actively detects these cases and either blocks the update
or warns the maintainer.

### Split packages (BLOCKED)

Packages with `pkgname=(foo foo-libs foo-doc)` and multiple
`package_*()` functions.

**Detection:** `audit_pkgbuild()` checks for `pkgname=(` and blocks.

**Why:** aurtomator updates `pkgver` correctly, but cannot detect when
subpackages need different `depends`, or when the `pkgname` array itself
needs to change (subpackage added or removed upstream).

### pkgver() with wrong strategy (BLOCKED)

VCS packages with a `pkgver()` function paired with a non-`git-latest`
strategy (e.g., `github-release`).

**Detection:** `audit_pkgbuild()` checks for `pkgver()` function and
verifies the strategy is `git-latest`. Other strategies detect versions
from releases/tags, not commits — the version format won't match what
`pkgver()` produces at build time.

**Correct approach:** Use `strategy: git-latest` for packages with
`pkgver()`.

### Mixed SKIP and real checksums (BLOCKED)

Packages where a single checksum array contains both SKIP and real
hash values:

```bash
sha256sums=('SKIP'
            'abc123def456...')
```

**Detection:** `audit_pkgbuild()` sources the PKGBUILD, iterates each
checksum array, and blocks if any array has both SKIP and non-SKIP
entries.

**Why:** `updpkgsums` is all-or-nothing. If aurtomator sees SKIP, it
skips `updpkgsums` entirely — meaning the real hash in the same array
becomes stale on version bump. This would push a broken package.

### Source URL returns HTML (BLOCKED)

When upstream moves or renames a release and the old URL redirects to
an HTML error or download page.

**Detection:** `validate_source_urls()` sends a HEAD request to each
source URL and checks the Content-Type header. `text/html` indicates
an error page, not a binary/archive.

**Why:** Without this check, `updpkgsums` would hash the HTML page
content. The checksums would "pass" but the package would fail to
install.

### Packages with patches (WARNING)

Packages that include `.patch` or `.diff` files in `source=()`.

**Detection:** `audit_pkgbuild()` warns but does not block. Patches
often apply cleanly across minor version bumps, but can break on major
changes. The maintainer accepts this risk.

## Not supported (not detected, requires maintainer awareness)

These scenarios cannot be automatically detected and require the
maintainer to monitor their packages.

### Packages needing pkgrel bump

When `pkgver` stays the same but the PKGBUILD changes (dependency fix,
build flag change, patch update), `pkgrel` should be incremented, not
reset to 1. aurtomator always sets `pkgrel=1`. pkgrel-only bumps
require human judgment.

### Packages with changing source URLs

When upstream changes the download URL format:

- GitHub to GitLab migration
- `.tar.gz` to `.tar.zst` format change
- Binary renamed: `app-linux-x86_64` to `app-linux-amd64`
- Major version path change: `v1/app.tar.gz` to `v2/app.tar.gz`

aurtomator doesn't modify `source=()`. If the URL pattern changed,
the source URL validation or `updpkgsums` will fail and aurtomator
refuses to push. This is a safe failure.

### Packages with changing dependencies

aurtomator doesn't modify `depends`, `makedepends`, or `optdepends`.
If a new version requires a library that wasn't previously listed,
users may encounter runtime errors. Dependency correctness is the
maintainer's responsibility.

### Packages requiring epoch

When upstream changes versioning scheme (CalVer to SemVer) and the new
version is numerically "lower" than the old one, `epoch` is needed.
aurtomator doesn't detect or set epoch. Setting epoch is irreversible
and requires maintainer judgment.

### Packages with version-dependent install scripts

aurtomator doesn't touch `.install` files. If a new version requires
migration steps in `post_upgrade()`, the maintainer must update these
manually.

## Version detection strategies

aurtomator includes 14 version detection strategies. Choose based on where your upstream publishes releases:

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
| `npm` | npm registry | Node.js packages | Auto (latest tag) |
| `crates` | crates.io API | Rust packages | Auto (stable only) |
| `repology` | Repology API | Fallback (120+ repos) | Varies |
| `archpkg` | Arch package search | Track official repo versions | Auto |
| `webpage-scrape` | Any HTTPS page + regex | No API available | None (depends on regex) |
| `kde-tarball` | download.kde.org | KDE/Plasma packages | None |

### Strategy limitations

- **GitHub rate limit:** GitHub Actions provides `GITHUB_TOKEN`
  automatically (5000 requests/hour). If running outside CI, set the
  token manually for repos with >10 GitHub packages.
- **No retry on API failure:** Strategies make one attempt. Transient
  failures become permanent for that run.
- **`github-tag` includes pre-releases:** Tags like `v1.0-rc1` will be
  picked up if they sort higher than stable. Use `tag_pattern` to filter.
- **`gitea-tag` fetches max 50 tags:** No pagination. Projects with 50+
  tags may miss older versions (not a problem since we want the latest).
- **`gitlab-tag` has no auth:** Private GitLab projects cannot be queried.
  No authentication support yet.
- **`sort -V` edge cases:** Calendar versioning (`2024.12` vs `2024.2`)
  may sort incorrectly. Use `tag_version_regex` to normalize.

### Upstream sources not covered

These require `webpage-scrape` or a custom strategy:

- SourceHut (git.sr.ht) — no dedicated API strategy
- Docker Hub — no image tag detection (not relevant for AUR packages)
- Go module proxy (proxy.golang.org)
- Private registries (GitLab, npm, PyPI)
- FTP servers

## Comparison with other tools

| Tool | Detection | Update | Push | Approach |
|---|---|---|---|---|
| **aurtomator** | 14 built-in strategies | pkgver sed + updpkgsums | Auto push to AUR | Fully automated, self-hosted |
| **nvchecker** | 40+ sources, TOML config | No | No | Detection only (standard tool) |
| **aurpublish** | No | No | git subtree push | Workflow tool for maintainers |
| **aur-auto-update** | nvchecker | pkgver bump | Auto push | Centralized bot (add as co-maintainer) |
| **aurupbot** | Git clone | Runs `makepkg` for pkgver() | Auto push | VCS packages only |
| **Renovate** | Regex manager | PR-based | Separate action | PR workflow with human review |

**Key difference:** aurtomator bundles detection + update + push in one
tool, runs self-hosted via GitHub Actions, and requires no external
services. nvchecker is the industry standard for detection but doesn't
update or push.

## Rules for safe automation

1. **Only automate packages you actively maintain.** If something breaks,
   you need to fix it manually.

2. **Only automate packages where pkgver is the only thing that changes.**
   If upstream frequently changes dependencies, source URLs, or build
   system — don't automate.

3. **Monitor your pipeline.** aurtomator creates GitHub Issues on failure.
   Don't ignore them.

4. **Test new packages manually first.** Before adding a package to
   aurtomator, build and install it once to verify the PKGBUILD works.

5. **Don't automate packages with patches** unless you're certain the
   patches will apply cleanly across versions (rare).

6. **Review the AUR after automated pushes.** Periodically install your
   packages with `makepkg -si` to verify they actually build and work.
