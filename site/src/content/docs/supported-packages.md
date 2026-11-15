---
title: Supported packages
---

## Supported

### Simple binary packages (-bin)

Packages that download a prebuilt binary whose URL holds `${pkgver}` and whose format stays the same between versions:

```bash
source=("https://github.com/user/app/releases/download/v${pkgver}/app-${pkgver}-linux-x86_64.tar.gz")
```

Only `pkgver` changes, and `updpkgsums` downloads the new binary and writes its checksum.

### Packages with arch-specific sources

Packages with one source URL per architecture:

```bash
source_x86_64=("https://example.com/app-${pkgver}-x86_64.tar.gz")
source_aarch64=("https://example.com/app-${pkgver}-aarch64.tar.gz")
```

The source check covers every `source_<arch>` array. `updpkgsums` writes all checksum arrays in one block at the place of the first one, so `sha256sums_<arch>` arrays beside their `source_<arch>` move into that block at the first update. Packages with `SKIP` in every checksum get no `updpkgsums`: their arrays stay where they stand, the arrays of arches that go out are dropped, and arches that come back take those of the AUR commit that last built them. Releases without the archive of one arch go out without that arch after 24 hours, see [Versions without some arches](/features/missing-arches/).

### VCS packages (-git) with the git-latest strategy

Packages that follow the latest commit of their upstream, with `strategy: git-latest`, see [git-latest](/strategies/#git-latest). aurtomator writes `r<count>.<hash>` to `pkgver=`, keeps the `SKIP` checksums and pushes, by default 7 days after the last push, see [Cooldown](/features/cooldown/). Sources pinned to `#branch=` need `upstream.branch` with the same branch.

`pkgver()` functions in the PKGBUILD have to produce the same form. Those that follow the `git describe` recipe of the Arch package guidelines, such as `1.4.0.r47.g0bbf5ad`, need `upstream.describe`. Those that count commits in another way, as hyprland-git does with `git rev-list --count --cherry-pick`, give a count the strategy does not reproduce. Users who build the package later get a newer value when upstream has moved on, as with every `-git` package on the AUR.

### Packages with VCS checksums (SKIP)

Packages with `SKIP` in a checksum array, with or without an arch suffix:

```bash
sha256sums=('SKIP')
b2sums_aarch64=('SKIP')
```

`SKIP` at any position makes aurtomator skip `updpkgsums`, which would replace the `SKIP` of a download with a real hash and clone every VCS source. The `SKIP` of a signature does not count, see [Sources with a signature](#sources-with-a-signature), and neither does the `SKIP` that makepkg gives a VCS source itself, see [Mixed SKIP and real checksums](#mixed-skip-and-real-checksums-blocked). Source URLs are checked either way, see [Source URL returns HTML](#source-url-returns-html-blocked).

### Sources with a signature

Packages that download a file and its detached signature, as `lib32-gettext` does:

```bash
source=("https://example.com/app-${pkgver}.tar.gz"{,.sig})
sha256sums=('abc123def456...'
            'SKIP')
```

makepkg gives `SKIP` to every source whose file name ends in `.sig`, `.sign` or `.asc`, and for sources with a name before `::` it reads that name. When every `SKIP` of the PKGBUILD belongs to such sources, the other sources get new checksums as in packages without `SKIP`. aurtomator does not check the signature: `makepkg --verifysource` runs with `--skippgpcheck`, and verify skips every `SKIP`.

### Other tag formats, dashes and fixed text

`tag_version_regex` reads the version from tags such as `0.1.8-stable`, `release-v2.3.0` or `app/v1.5.0`, see [github-release](/strategies/#github-release). `pkgver_dash` stands for the dash of versions such as `1.9.0-1`, and `pkgver_format` for fixed text around the upstream version, such as `4.4215` for build `4215`, see [Package YAML](/package-yaml/). The PKGBUILD turns the form back where source URLs need it, as `${pkgver//_/-}` or `${pkgver#4.}` do.

### Release asset names with more than the version (asset_regex)

`savonet/liquidsoap` publishes `liquidsoap_2.4.6-debian-forky-ocaml5.4.0-3_amd64.deb`, whose Debian revision `3` grows when upstream rebuilds a published release in place. `pkgver` bumps cannot build that name, and rebuilds keep the version. With `upstream.asset_regex` and `upstream.asset_var`, the check reads the value from the asset name, and new values of the same version go out as a rebuild, see [Values from release asset names](/features/asset-values/).

### Nightly and prerelease packages

`github-nightly` follows nightly builds in 4 patterns: a fixed tag, dated tags, a separate nightly repository and a channel, see [github-nightly](/strategies/#github-nightly). Releases that keep their tag and their date while their assets are replaced, such as the `nightly` release of `wezterm/wezterm`, are followed by the asset date with `github-asset`, see [pkgver() with the wrong strategy](#pkgver-with-the-wrong-strategy-blocked).

Fixed tags keep their download URL, so PKGBUILDs can save the download under a name with the date, as `neovim-nightly-bin` does with `_date="$(date -u +%Y%m%d)"` and `"$_pkgname-$_date.tar.gz::<url>"`. The checksum of that source must be `SKIP`, and only the digits of the name may change between updates.

### Split packages

Packages with `pkgbase`, a `pkgname` array and a `package_*()` function for each package, as liblinear:

```bash
pkgbase=liblinear
pkgname=(liblinear python-liblinear)
pkgver=2.50
source=("https://www.csie.ntu.edu.tw/~cjlin/$pkgbase/$pkgbase-$pkgver.tar.gz")
```

`pkgver`, `pkgrel`, sources and checksums belong to `pkgbase`, so the update is that of a single package, and `name` in the package YAML is the `pkgbase`. Lines of one package in `.SRCINFO` follow the rule of every line: `depends = foo=1.2.3` from `depends=("foo=$pkgver")` takes the new version. New or dropped packages in the `pkgname` array go unnoticed, as new dependencies do, see [Packages with changing dependencies](#packages-with-changing-dependencies).

## Not supported (blocked or detected)

aurtomator detects these cases and blocks the update or warns.

### pkgver() with the wrong strategy (BLOCKED)

PKGBUILDs with a `pkgver()` function and a strategy other than `git-latest` or `github-nightly`, such as `github-release`.

**Detection:** release and tag strategies report release versions, which do not match what `pkgver()` computes at build time. `pkgver()` functions that only print `pkgver` pass: `cd` lines and one `printf` or `echo` of `$pkgver`, `${pkgver}`, or `pkgver` with its dash replaced, as streamrip has `cd streamrip` and `printf "${pkgver//-/.}"`.

**Correct approach:** packages built from a git checkout use `git-latest`. Binaries from a release tag that never moves drop `pkgver()`, set `pkgver` to a date and use `github-asset`, which reads the date of the newest listed asset. The URLs name the tag as text:

```bash
pkgver=20261023
source=("wezterm-nightly.Ubuntu24.04.tar.xz::https://github.com/wezterm/wezterm/releases/download/nightly/wezterm-nightly.Ubuntu24.04.tar.xz")
sha256sums=('SKIP')
```

```yaml
name: wezterm-nightly-bin
strategy: github-asset
upstream:
  project: wezterm/wezterm
  tag: nightly
  assets:
    - wezterm-nightly.Ubuntu24.04.tar.xz
```

Versions that a project publishes as a text asset are read with [webpage-scrape](/strategies/#webpage-scrape).

### Mixed SKIP and real checksums (BLOCKED)

PKGBUILDs with `SKIP` and a real hash for a remote source, in any order and in any checksum array:

```bash
source=("git+https://example.com/app.git#commit=1a2b3c4" "https://example.com/data.tar.gz")
sha256sums=('SKIP'
            'abc123def456...')
```

`SKIP` entries that makepkg writes itself do not count, since `updpkgsums` keeps them: those of signatures, of svn sources, and of git, hg or bzr sources without the pin makepkg hashes, `#commit=` or `#tag=` for git, `#tag=` or `#revision=` for hg and `#revision=` for bzr. makepkg hashes fossil sources as downloads, so their `SKIP` counts.

**Detection:** the audit pairs every checksum, with and without an arch suffix, with its source. Real hashes for a URL with `://` beside any other `SKIP` block the update, since `updpkgsums` would turn that `SKIP` into a hash and the prepared file check refuses `SKIP` entries that change. Real hashes for local files of the AUR repository pass.

**Correct approach:** run `updpkgsums` once and push the hashes it writes, as for sources pinned to a tag or a commit. Downloads whose file changes under the same URL keep their `SKIP` and need a manual update.

### Sources that do not follow pkgver (BLOCKED)

PKGBUILDs whose sources take the version from another variable, as `_pkgver=2025-04-03` with `pkgver="${_pkgver//-/.}"`; download URLs without the version whose file has not changed; or VCS sources pinned to a commit the version does not set, as `git+https://example.org/player.git#commit=$_commit`. `sed` sets only `pkgver`, so the new version would hold the old files.

**Detection:** the `.SRCINFO` check refuses new `pkgver` values when no source URL and no checksum changed while some download has a real checksum or some VCS source is pinned. It checks each architecture, and the common sources count for all of them until the sources of one architecture change: from then on, architectures with downloads of their own need a change in those, since their build takes its files from them. Downloads saved under the new version from the URL and the checksum of the old one are refused even when another source changes. VCS pins that stay pass beside other sources that change.

**Correct approach:** make `pkgver` the literal and derive the other variable from it:

```bash
pkgver=2025.04.03
_pkgver=${pkgver//./-}
source=("${pkgname}-${_pkgver}.tar.gz::${url}/archive/refs/tags/${_pkgver}.tar.gz")
```

`pkgver_dash: .` turns the dashes of tags such as `2026-09-10` into dots, as for the date tags of `vinceliuice/WhiteSur-gtk-theme`:

```yaml
name: whitesur-gtk-theme
strategy: github-tag
upstream:
  project: vinceliuice/WhiteSur-gtk-theme
  tag_version_regex: '^([0-9]{4}-[0-9]{2}-[0-9]{2})$'
pkgver_dash: .
```

Derived variables pass when their text is one of the version forms in step 5 of publish in [Prepare and publish](/internals/update-process/#prepare-and-publish). Sources that need data the version does not hold, such as commit hashes or build numbers, need a manual update.

### Lines the check cannot read from the PKGBUILD (BLOCKED)

Lines of `.SRCINFO` other than `pkgver`, `pkgrel`, `source` and the checksums that hold the version, where the PKGBUILD writes the value with an escaped character, `{a,b}` or `$'...'`, takes it from a variable that does not follow `pkgver`, or derives it from `pkgver` and also writes its text elsewhere outside a comment line. Comments after code count as text.

**Detection:** verify and publish never run the PKGBUILD, so the check reads its text. Lines whose value that text holds must stay as they are, and other lines must take the new version. In these forms the text leads the check to expect another line than makepkg writes, and correct updates stop with a message that names the expected line.

**Correct approach:** write values that stay as plain text, and derive values that follow the version from `pkgver`:

```bash
license=('Apache-2.0')
provides=("demo=${pkgver}")
```

### Source URL returns HTML (BLOCKED)

Upstream moves or renames a release, and the old URL redirects to an HTML error or download page.

**Detection:** `HEAD` requests to every `http` and `https` URL of `source` and `source_<arch>`, whatever its checksum, with up to 5 redirects. Statuses of 400 or more, no status, and `Content-Type: text/html` block the update. The check reads the PKGBUILD with `CARCH` set, so URLs built from `$CARCH` are the ones makepkg downloads. It skips VCS sources and local files. Without it, `updpkgsums` would hash the HTML page, and the package would fail to install with matching checksums.

### Checksums verify cannot compute (BLOCKED)

Real checksums for downloads over `http` or `ftp`, for git sources over a protocol other than `https`, for `hg` or `bzr` sources at a pin makepkg hashes, or for `fossil` sources.

**Detection:** verify computes every checksum other than `SKIP` again from its source, and downloads and clones over `https` only, so any other checksum stops the update. See step 5 of verify in [Prepare and publish](/internals/update-process/#prepare-and-publish).

**Correct approach:** use the `https` URL where the host serves one. Packages that need one of the other sources need a manual update.

### Packages with patches (WARNING)

Packages with `.patch` or `.diff` files in `source=()`. The audit warns: patches often survive a minor bump and can break on a major one.

### Packages with an epoch (WARNING)

PKGBUILDs with `epoch` other than 0. The audit warns. Updates keep `epoch`, and `current` holds the version without it. pacman compares the epoch first, so downgrades that `allow_downgrade: true` publishes do not install over the newer version until the maintainer raises `epoch`.

## Not supported (not detected)

aurtomator cannot detect these cases, and the maintainer watches for them. When the version that needs a hand edit is known in advance, such as new JDK majors that need a newer boot JDK in `makedepends`, alerts hold the update at that version or report it, see [Update alerts](/features/update-alerts/).

### Packages needing a pkgrel bump

PKGBUILD changes at the same `pkgver`, such as dependency fixes, build flags or new patches, need a higher `pkgrel`. aurtomator sets `pkgrel=1` for new versions and raises `pkgrel` alone only for new values from release asset names, see [Values from release asset names](/features/asset-values/).

### Packages with changing source URLs

aurtomator does not change `source=()`, so new URL schemes upstream, such as a move from GitHub to GitLab, `.tar.gz` to `.tar.zst`, a renamed binary or `v1/` to `v2/` in the path, fail the source check or `updpkgsums`, and nothing is pushed. Packages whose remote sources are all `SKIP` download none of them: changed URLs that answer 404 or HTML stop the update, and those that serve another file are pushed unnoticed.

### Packages with changing dependencies

aurtomator does not change `depends`, `makedepends` or `optdepends`. New versions that need a library the PKGBUILD does not list fail at run time for their users.

### Packages requiring epoch

When upstream changes its version scheme, as from CalVer to SemVer, the new version can sort lower than the old one and needs `epoch`. aurtomator cannot tell such versions from downgrades: it skips the version unless the package YAML sets `allow_downgrade: true`, see [Downgrades and version jumps](/features/downgrades/), and never sets `epoch`, which cannot be undone.

### Packages with version-dependent install scripts

aurtomator does not touch `.install` files. Versions that need migration steps in `post_upgrade()` need them by hand.

## Rules for safe automation

1. Automate only packages you maintain, since a failure needs your hand.
2. Automate only packages where `pkgver` is the one thing that changes, never those whose upstream often changes dependencies, source URLs or the build system.
3. Watch the issues of your repository: packages that start failing get one, and so do failed runs.
4. Build and install each new package by hand once before you add it.
5. Automate packages with patches only when the patches apply across versions.
6. Build your packages with `makepkg -si` now and then after automated pushes.
