---
title: Supported packages
---

## Supported

### Simple binary packages (-bin)

A package that downloads a prebuilt binary whose URL holds `${pkgver}` and whose format stays the same between versions:

```bash
source=("https://github.com/user/app/releases/download/v${pkgver}/app-${pkgver}-linux-x86_64.tar.gz")
```

Only `pkgver` changes, and `updpkgsums` downloads the new binary and writes its checksum.

### Packages with arch-specific sources

A package with a source URL per architecture:

```bash
source_x86_64=("https://example.com/app-${pkgver}-x86_64.tar.gz")
source_aarch64=("https://example.com/app-${pkgver}-aarch64.tar.gz")
```

The source check covers every `source_<arch>` array. `updpkgsums` writes all checksum arrays in one block at the place of the first one, so a `sha256sums_<arch>` array beside its `source_<arch>` moves into that block at the first update. A release without the archive of one arch goes out without that arch after 24 hours, see [Versions without some arches](/features/missing-arches/).

### VCS packages (-git) with the git-latest strategy

A package that follows the latest commit of its upstream, with `strategy: git-latest`, see [git-latest](/strategies/#git-latest). aurtomator writes `r<count>.<hash>` to `pkgver=`, keeps the `SKIP` checksums and pushes, by default 7 days after the last push, see [Cooldown](/features/cooldown/). A source pinned to `#branch=` needs `upstream.branch` with the same branch.

A `pkgver()` in the PKGBUILD has to produce the same form. One that follows the `git describe` recipe of the Arch package guidelines, such as `1.4.0.r47.g0bbf5ad`, needs `upstream.describe`. One that counts commits in another way, as hyprland-git does with `git rev-list --count --cherry-pick`, gives a count the strategy does not reproduce. A user who builds the package later gets a newer value when upstream has moved on, as with every `-git` package on the AUR.

### Packages with VCS checksums (SKIP)

A package with `SKIP` in a checksum array, with or without an arch suffix:

```bash
sha256sums=('SKIP')
b2sums_aarch64=('SKIP')
```

A `SKIP` at any position makes aurtomator skip `updpkgsums`, which would replace the `SKIP` of a download with a real hash and clone every VCS source. The `SKIP` of a signature does not count, see [Sources with a signature](#sources-with-a-signature), and neither does a `SKIP` that makepkg gives a VCS source itself, see [Mixed SKIP and real checksums](#mixed-skip-and-real-checksums-blocked). The source URLs are checked either way, see [Source URL returns HTML](#source-url-returns-html-blocked).

### Sources with a signature

A package that downloads a file and its detached signature, as `lib32-gettext` does:

```bash
source=("https://example.com/app-${pkgver}.tar.gz"{,.sig})
sha256sums=('abc123def456...'
            'SKIP')
```

makepkg gives `SKIP` to every source whose file name ends in `.sig`, `.sign` or `.asc`, and for a source with a name before `::` it reads that name. When every `SKIP` of the PKGBUILD belongs to such a source, the other sources get new checksums as in a package without `SKIP`. aurtomator does not check the signature: `makepkg --verifysource` runs with `--skippgpcheck`, and verify skips every `SKIP`.

### Other tag formats, dashes and fixed text

`tag_version_regex` reads the version from a tag such as `0.1.8-stable`, `release-v2.3.0` or `app/v1.5.0`, see [github-release](/strategies/#github-release). `pkgver_dash` stands for the dash of a version such as `1.9.0-1`, and `pkgver_format` for a fixed text around the upstream version, such as `4.4215` for build `4215`, see [Package YAML](/package-yaml/). The PKGBUILD turns the form back where a source URL needs it, as `${pkgver//_/-}` or `${pkgver#4.}` do.

### Release asset names with more than the version (asset_regex)

`savonet/liquidsoap` publishes `liquidsoap_2.4.6-debian-forky-ocaml5.4.0-3_amd64.deb`, whose Debian revision `3` grows when upstream rebuilds a published release in place. A bump of `pkgver` cannot build that name, and a rebuild keeps the version. With `upstream.asset_regex` and `upstream.asset_var`, the check reads the value from the asset name, and a new value of the same version goes out as a rebuild, see [Values from release asset names](/features/asset-values/).

### Nightly and prerelease packages

`github-nightly` follows nightly builds in 4 patterns: a fixed tag, dated tags, a separate nightly repository and a channel, see [github-nightly](/strategies/#github-nightly). A release that keeps its tag and its date while its assets are replaced, such as the `nightly` release of `wezterm/wezterm`, is followed by the date of the assets with `github-asset`, see [pkgver() with the wrong strategy](#pkgver-with-the-wrong-strategy-blocked).

A fixed tag keeps its download URL, so a PKGBUILD can save the download under a name with the date, as `neovim-nightly-bin` does with `_date="$(date -u +%Y%m%d)"` and `"$_pkgname-$_date.tar.gz::<url>"`. The checksum of that source must be `SKIP`, and only the digits of the name may change between updates.

### Split packages

A package with a `pkgbase`, a `pkgname` array and a `package_*()` function for each package, as liblinear:

```bash
pkgbase=liblinear
pkgname=(liblinear python-liblinear)
pkgver=2.50
source=("https://www.csie.ntu.edu.tw/~cjlin/$pkgbase/$pkgbase-$pkgver.tar.gz")
```

`pkgver`, `pkgrel`, the sources and the checksums belong to the `pkgbase`, so the update is that of a single package, and the `name` in the package YAML is the `pkgbase`. A line of one package in `.SRCINFO` follows the rule of every line: `depends = foo=1.2.3` from `depends=("foo=$pkgver")` takes the new version. A new or dropped package in the `pkgname` array goes unnoticed, as a new dependency does, see [Packages with changing dependencies](#packages-with-changing-dependencies).

## Not supported (blocked or detected)

aurtomator detects these cases and blocks the update or warns.

### pkgver() with the wrong strategy (BLOCKED)

A PKGBUILD with a `pkgver()` function and a strategy other than `git-latest` or `github-nightly`, such as `github-release`.

**Detection:** a release or tag strategy reports release versions, which do not match what `pkgver()` computes at build time. A `pkgver()` that only prints `pkgver` passes: `cd` lines and one `printf` or `echo` of `$pkgver`, `${pkgver}`, or `pkgver` with its dash replaced, as streamrip has `cd streamrip` and `printf "${pkgver//-/.}"`.

**Correct approach:** a package built from a git checkout uses `git-latest`. A binary from a release tag that never moves drops `pkgver()`, sets `pkgver` to a date and uses `github-asset`, which reads the date of the newest listed asset. The URLs name the tag as text:

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

A version that a project publishes as a text asset is read with [webpage-scrape](/strategies/#webpage-scrape).

### Mixed SKIP and real checksums (BLOCKED)

A PKGBUILD with a `SKIP` and a real hash for a remote source, in any order and in any checksum array:

```bash
source=("git+https://example.com/app.git#commit=1a2b3c4" "https://example.com/data.tar.gz")
sha256sums=('SKIP'
            'abc123def456...')
```

A `SKIP` that makepkg writes itself does not count, since `updpkgsums` keeps it: that of a signature, of an svn source, and of a git, hg or bzr source without the pin makepkg hashes, `#commit=` or `#tag=` for git, `#tag=` or `#revision=` for hg and `#revision=` for bzr. makepkg hashes a fossil source as a download, so its `SKIP` counts.

**Detection:** the audit pairs every checksum, with and without an arch suffix, with its source. A real hash for a URL with `://` beside any other `SKIP` blocks the update, since `updpkgsums` would turn that `SKIP` into a hash and the check of the prepared files refuses a `SKIP` that changes. A real hash for a local file of the AUR repository passes.

**Correct approach:** run `updpkgsums` once and push the hashes it writes, as for a source pinned to a tag or a commit. A download whose file changes under the same URL keeps its `SKIP` and needs a manual update.

### Sources that do not follow pkgver (BLOCKED)

A PKGBUILD whose sources take the version from another variable, as `_pkgver=2025-04-03` with `pkgver="${_pkgver//-/.}"`; a download URL without the version whose file has not changed; or a VCS source pinned to a commit the version does not set, as `git+https://example.org/player.git#commit=$_commit`. `sed` sets only `pkgver`, so the new version would hold the old files.

**Detection:** the `.SRCINFO` check refuses a new `pkgver` when no source URL and no checksum changed while a download has a real checksum or a VCS source is pinned. It checks each architecture, the common sources counting for all of them. A download saved under the new version from the URL and the checksum of the old one is refused even when another source changes. A VCS pin that stays passes beside another source that changes.

**Correct approach:** make `pkgver` the literal and derive the other variable from it:

```bash
pkgver=2025.04.03
_pkgver=${pkgver//./-}
source=("${pkgname}-${_pkgver}.tar.gz::${url}/archive/refs/tags/${_pkgver}.tar.gz")
```

`pkgver_dash: .` turns the dashes of a tag such as `2026-09-10` into dots, as for the date tags of `vinceliuice/WhiteSur-gtk-theme`:

```yaml
name: whitesur-gtk-theme
strategy: github-tag
upstream:
  project: vinceliuice/WhiteSur-gtk-theme
  tag_version_regex: '^([0-9]{4}-[0-9]{2}-[0-9]{2})$'
pkgver_dash: .
```

A derived variable passes when its text is one of the forms of the version in step 5 of publish in [Prepare and publish](/internals/update-process/#prepare-and-publish). A source that needs data the version does not hold, such as a commit hash or a build number, needs a manual update.

### Lines the check cannot read from the PKGBUILD (BLOCKED)

A line of `.SRCINFO` other than `pkgver`, `pkgrel`, `source` and the checksums that holds the version, where the PKGBUILD writes the value with an escaped character, `{a,b}` or `$'...'`, takes it from a variable that does not follow `pkgver`, or derives it from `pkgver` and also writes its text elsewhere outside a comment line. A comment after code counts as text.

**Detection:** verify and publish never run the PKGBUILD, so the check reads its text. A line whose value that text holds must stay as it is, and any other line must take the new version. In these forms the text leads the check to expect another line than makepkg writes, and a correct update stops with a message that names the expected line.

**Correct approach:** write a value that stays as plain text, and derive a value that follows the version from `pkgver`:

```bash
license=('Apache-2.0')
provides=("demo=${pkgver}")
```

### Source URL returns HTML (BLOCKED)

Upstream moves or renames a release, and the old URL redirects to an HTML error or download page.

**Detection:** a `HEAD` request to every `http` and `https` URL of `source` and `source_<arch>`, whatever its checksum, with up to 5 redirects. A status of 400 or more, no status, or `Content-Type: text/html` blocks the update. The check reads the PKGBUILD with `CARCH` set, so a URL built from `$CARCH` is the one makepkg downloads. It skips VCS sources and local files. Without it, `updpkgsums` would hash the HTML page, and the package would fail to install with matching checksums.

### Checksums verify cannot compute (BLOCKED)

A real checksum for a download over `http` or `ftp`, for a git source over a protocol other than `https`, for an `hg` or `bzr` source at a pin makepkg hashes, or for a `fossil` source.

**Detection:** verify computes every checksum other than `SKIP` again from its source, and downloads and clones over `https` only, so any other checksum stops the update. See step 5 of verify in [Prepare and publish](/internals/update-process/#prepare-and-publish).

**Correct approach:** use the `https` URL where the host serves one. A package that needs one of the other sources needs a manual update.

### Packages with patches (WARNING)

A package with `.patch` or `.diff` files in `source=()`. The audit warns: a patch often survives a minor bump and can break on a major one.

### Packages with an epoch (WARNING)

A PKGBUILD with an `epoch` other than 0. The audit warns. An update keeps `epoch`, and `current` holds the version without it. pacman compares the epoch first, so a downgrade that `allow_downgrade: true` publishes does not install over the newer version until the maintainer raises `epoch`.

## Not supported (not detected)

aurtomator cannot detect these cases, and the maintainer watches for them. When the version that needs a hand edit is known in advance, such as a new major of a JDK that needs a newer boot JDK in `makedepends`, an alert holds the update at that version or reports it, see [Update alerts](/features/update-alerts/).

### Packages needing a pkgrel bump

A change of the PKGBUILD at the same `pkgver`, such as a dependency fix, a build flag or a new patch, needs a higher `pkgrel`. aurtomator sets `pkgrel=1` for a new version and raises `pkgrel` alone only for a new value from a release asset name, see [Values from release asset names](/features/asset-values/).

### Packages with changing source URLs

aurtomator does not change `source=()`, so a new URL scheme upstream, such as a move from GitHub to GitLab, `.tar.gz` to `.tar.zst`, a renamed binary or `v1/` to `v2/` in the path, fails the source check or `updpkgsums`, and nothing is pushed. A package whose remote sources are all `SKIP` downloads none of them: a changed URL that answers 404 or HTML stops the update, and one that serves another file is pushed unnoticed.

### Packages with changing dependencies

aurtomator does not change `depends`, `makedepends` or `optdepends`. A new version that needs a library the PKGBUILD does not list fails at run time for its users.

### Packages requiring epoch

When upstream changes its version scheme, as from CalVer to SemVer, the new version can sort lower than the old one and needs an `epoch`. aurtomator cannot tell such a version from a downgrade: it skips the version unless the package YAML sets `allow_downgrade: true`, see [Downgrades and version jumps](/features/downgrades/), and never sets `epoch`, which cannot be undone.

### Packages with version-dependent install scripts

aurtomator does not touch `.install` files. A version that needs migration steps in `post_upgrade()` needs them by hand.

## Rules for safe automation

1. Automate only packages you maintain, since a failure needs your hand.
2. Automate only packages where `pkgver` is the one thing that changes, never one whose upstream often changes dependencies, source URLs or the build system.
3. Watch the issues of your repository: a package that starts failing gets one, and so does a failed run.
4. Build and install a new package by hand once before you add it.
5. Automate a package with patches only when the patches apply across versions.
6. Build your packages with `makepkg -si` now and then after automated pushes.
