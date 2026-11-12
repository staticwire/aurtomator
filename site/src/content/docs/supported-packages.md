---
title: Supported packages
---

What aurtomator can automate, what it cannot, and how to avoid breaking things.

## Supported

### Simple binary packages (-bin)

Packages that download prebuilt binaries and install them. The source URL contains `${pkgver}`, and the binary format stays the same between versions.

```bash
source=("https://github.com/user/app/releases/download/v${pkgver}/app-${pkgver}-linux-x86_64.tar.gz")
```

Only `pkgver` changes. The URL pattern, binary format and installation steps stay the same, and `updpkgsums` downloads the new binary and updates the checksums.

### Packages with arch-specific sources

Packages with a different source URL per architecture:

```bash
source_x86_64=("https://example.com/app-${pkgver}-x86_64.tar.gz")
source_aarch64=("https://example.com/app-${pkgver}-aarch64.tar.gz")
```

`updpkgsums` handles arch-specific checksum arrays and writes all of them in one block at the place of the first one, so a `sha256sums_<arch>` array next to its `source_<arch>` moves into that block on the first update. Source URL validation covers every `source_<arch>` array. A stable URL pattern is enough.

A release that lacks the archive of one arch would stop the update of every arch at the source check. With `allow_missing_arch`, which is `true` unless the package YAML sets `false`, aurtomator waits 24 hours for the archive, then publishes the version without that arch and puts the arch back once its archive is out, at the same version or with the next one. A version without the archive of `x86_64`, or without the archives of every arch, fails as before. The PKGBUILD needs one `arch=(...)` line of plain arch names at the start of a line, see [Versions without some arches](/aurtomator/features/missing-arches/).

### VCS packages (-git) with the git-latest strategy

Packages that track the latest commit of an upstream repository:

```yaml
strategy: git-latest
upstream:
  type: gitlab
  host: gitlab.example.com
  project: group/project
```

`git-latest` makes a bare clone and computes `r{count}.{hash}`, for example `r435.abc1234`, the usual AUR format for `-git` versions. aurtomator writes this value to `pkgver=`, skips `SKIP` checksums and pushes. By default, a push waits 7 days after the last one, see [Cooldown](/aurtomator/features/cooldown/). A source pinned to `#branch=` needs `upstream.branch` with the same branch, or the count and the hash come from the default branch.

A `pkgver()` function in the PKGBUILD is fine when it produces the same format. The hash takes as many characters as the hash in `current`. A `pkgver()` that follows the `git describe` recipe of the Arch package guidelines, such as `1.4.0.r47.g0bbf5ad`, needs `upstream.describe`: `tags` for `git describe --long --tags`, `annotated` without `--tags`, and `upstream.tag_prefix` for a prefix the recipe cuts off the tag, as `sed 's/^v//'`. `vercmp` reads that form as newer than every `r{count}.{hash}`, so `validate-pkg.sh` refuses a `current` of the other form. A `pkgver()` that counts the commits in another way, as hyprland-git does with `git rev-list --count --cherry-pick`, gives a count the strategy does not reproduce. A user who builds the package later gets a newer value when upstream has moved on, as with every `-git` package on the AUR.

### Packages with VCS checksums (SKIP)

Packages with `SKIP` in a checksum array:

```bash
sha256sums=('SKIP')
```

Or with arch-specific arrays:

```bash
b2sums_x86_64=('SKIP')
b2sums_aarch64=('SKIP')
```

aurtomator reads every checksum array, with and without an arch suffix. A `SKIP` at any position makes it skip `updpkgsums`, which would otherwise replace the `SKIP` of a download with a real hash and clone the repository of every VCS source. The `SKIP` of a signature is the exception, see [Sources with a signature](#sources-with-a-signature). `updpkgsums` also runs next to a `SKIP` that makepkg gives a VCS source itself, see [Mixed SKIP and real checksums](#mixed-skip-and-real-checksums-blocked), when a remote source has a real hash. The source URLs are checked either way, see [Source URL returns HTML](#source-url-returns-html-blocked).

A real hash for a remote source next to a `SKIP` that makepkg does not give itself is blocked by the PKGBUILD audit. See "Mixed SKIP and real checksums" below.

### Sources with a signature

Packages that download a file and its detached signature, as `lib32-gettext` does:

```bash
source=("https://example.com/app-${pkgver}.tar.gz"{,.sig})
sha256sums=('abc123def456...'
            'SKIP')
```

makepkg gives `SKIP` to every source whose file name ends in `.sig`, `.sign` or `.asc`, and `updpkgsums` writes that `SKIP` again. When every `SKIP` of the PKGBUILD belongs to such a source, aurtomator runs steps 5 to 7 as for a package without `SKIP`, and the other sources get new checksums. For a source with a name before `::`, makepkg reads that name and not the URL.

aurtomator does not check the signature. It runs `makepkg --verifysource` with `--skippgpcheck`, and verify skips every `SKIP`, see step 5 of verify in [Prepare and publish](/aurtomator/internals/update-process/#prepare-and-publish).

### Non-standard tag formats (tag_version_regex)

`github-release`, `github-tag`, `github-nightly`, `gitlab-tag`, `gitea-tag`, `gitea-release` and `git-tag` accept `tag_version_regex` for unusual tag names:

```yaml
upstream:
  project: user/app
  tag_version_regex: '^release-v?([0-9.]+)-stable$'
```

The first capture group of the ERE is the version, whatever the format of the tag, for example `0.1.8-stable`, `release-v2.3.0` or `app/v1.5.0`. bash takes the group, so the regex may hold `|`, in a group after the version: `^v?([0-9.]+)(-stable|)$`. With `github-release`, the regex also picks the release of one product in a repository that releases several, see [github-release](/aurtomator/strategies/#github-release).

`tag_version_replace` builds the version from more than one group, with `\1` to `\9`. For the date tag `2026-09-10`, `'^([0-9]{4})-([0-9]{2})-([0-9]{2})$'` with `'\1.\2.\3'` gives `2026.09.10`. See [github-release](/aurtomator/strategies/#github-release).

### Versions with a dash (pkgver_dash)

npm and crates.io versions can hold a dash, such as `1.9.0-1` or `0.10.26+cargo-0.100.0`, and `pkgver` cannot. `pkgver_dash` names the character that stands for it:

```yaml
name: nodejs-myapp
strategy: npm
upstream:
  registry: myapp
pkgver_dash: _
```

`check-update.sh` replaces every `-` in the output of the strategy, whatever the strategy, and the PKGBUILD turns it back where a source URL needs it, as nodejs-inshellisense does with `${pkgver//_/-}`. The `.SRCINFO` check of verify and publish counts that form as the version. A pre-release in this form, such as `1.0.0.beta.24`, sorts above its final release, so the final release is skipped as a downgrade, and the AUR package needs an `epoch`, which aurtomator does not write. `_` and `.` are allowed, and `vercmp` reads them the same. `''` is allowed too and drops the dash: `2.5.0-rc1` becomes `2.5.0rc1`, which sorts below `2.5.0`, so the final release needs no epoch, and the PKGBUILD puts the dash back as in `${pkgver/rc/-rc}`, see [Package YAML](/aurtomator/package-yaml/). `crates` with `prerelease: true` needs the field, see [crates](/aurtomator/strategies/#crates).

### Versions with text around the upstream version (pkgver_format)

Some PKGBUILDs put a fixed text around the upstream version, such as `4.4215` for build `4215`, and cut it off again in the source URL. `pkgver_format` names that text, with `%s` in place of the upstream version:

```yaml
name: my-package
strategy: webpage-scrape
upstream:
  url: https://example.com/updates.json
  pattern: '"latest_version": ([0-9]+)'
pkgver_format: '4.%s'
```

`check-update.sh` puts the output of the strategy in place of `%s`, whatever the strategy, and the PKGBUILD cuts the text off where a source URL needs the upstream version, as with `${pkgver#4.}`. The `.SRCINFO` check of verify and publish counts the upstream version inside the old and the new `pkgver` as the version. See [Package YAML](/aurtomator/package-yaml/).

### Release asset names with more than the version (asset_regex)

Some upstreams name their release assets with more than the version and raise that part by hand. `savonet/liquidsoap` publishes `liquidsoap_2.4.6-debian-forky-ocaml5.4.0-3_amd64.deb`, where `ocaml5.4.0` follows the release line and the Debian revision `3` grows when upstream rebuilds a published release in place: v2.4.6 was published on 2026-10-09, and its assets all date from 2026-10-18 and end in `-3`. A bump of `pkgver` alone cannot build that name, and a rebuild leaves the version as it is. The PKGBUILD keeps the variable part on a line of its own, and the package YAML says where it comes from:

```yaml
name: liquidsoap-bin
strategy: github-tag
upstream:
  project: savonet/liquidsoap
  tag_version_regex: '^v([0-9.]+(-rc[0-9]+)?)$'
  asset_regex: '^liquidsoap_([0-9.]+-debian-forky-ocaml5\.[0-9.]+-[0-9]+)_amd64\.deb$'
  asset_var: _deb
pkgver_dash: ''
```

```bash
pkgver=2.5.0rc1
_deb=2.5.0-debian-forky-ocaml5.5.1-1
pkgrel=1
...
_tag="v${pkgver/rc/-rc}"
_release="https://github.com/savonet/liquidsoap/releases/download/${_tag}"
source_x86_64=("${_release}/liquidsoap_${_deb}_amd64.deb")
source_aarch64=("${_release}/liquidsoap_${_deb}_arm64.deb")
```

The check finds the one asset of the release of the new version that `asset_regex` matches and writes its capture group to the `_deb=` line. The group takes the whole variable part, version included, so a release candidate whose asset name holds no `rc` needs nothing more. It has to take enough of the asset name to occur only where the PKGBUILD uses it, never as the version or other text of a line. A new value of the version the AUR has is published as a rebuild with the next `pkgrel`. The download keeps the upstream name, which holds the value: a name such as `${pkgname}-${pkgver}-amd64.deb::<url>` stays the same through a rebuild, and makepkg then takes the old file from the build directory and fails on its checksum. Only `github-tag` and `github-release` take `asset_regex`. See [Values from release asset names](/aurtomator/features/asset-values/).

### Nightly and prerelease packages

`github-nightly` tracks nightly builds in 4 patterns:

- **Fixed tag**, for example the neovim `nightly` tag, moved daily
- **Dated tags**, for example `nightly-2026-03-26`, or any tag form with `nightly_tag_regex`
- **Separate nightly repo**, for example yt-dlp-nightly-builds. It reads `/releases/latest`, which skips pre-releases, so a repository that files its nightlies as pre-releases, such as ruffle, needs dated tags.
- **Channel filter**, for example the brave-browser Nightly channel

The version comes from the tag name, the release body, the tag date or the publish date. `strategies/github-nightly.sh` lists the fields. A release that keeps its tag and its publish date while its assets are replaced, such as the `nightly` release of `wezterm/wezterm`, published in 2019, is tracked by the date of the assets with `github-asset`, see [pkgver() with the wrong strategy](#pkgver-with-the-wrong-strategy-blocked). `date_format` sets the form of the two dates, `YYYY.MM.DD` by default, and `'%Y%m%d'` fits a `pkgver` such as `20251213`. See [github-nightly](/aurtomator/strategies/#github-nightly).

A fixed tag keeps its download URL, so a PKGBUILD can save the download under a name with the date, as `neovim-nightly-bin` does with `_date="$(date -u +%Y%m%d)"` and `"$_pkgname-$_date.tar.gz::<url>"`. This works when the checksum of that source is `SKIP`: only the digits of the name may change from one update to the next. See step 5 of publish in [Prepare and publish](/aurtomator/internals/update-process/#prepare-and-publish).

### Split packages

Packages with a `pkgbase`, a `pkgname` array and a `package_*()` function for each package, as liblinear:

```bash
pkgbase=liblinear
pkgname=(liblinear python-liblinear)
pkgver=2.50
source=("https://www.csie.ntu.edu.tw/~cjlin/$pkgbase/$pkgbase-$pkgver.tar.gz")
```

`pkgver`, `pkgrel`, the sources and the checksums belong to the `pkgbase`, so the update is the same as for a single package. The AUR keeps a split package in one git repository named after the `pkgbase`, and the `name` in the package YAML is that `pkgbase`. A line in the section of one package in `.SRCINFO` follows the same rule as every other line: `depends = foo=1.2.3` from `depends=("foo=$pkgver")` must take the new version, since the PKGBUILD does not hold `foo=1.2.3` as text.

A change of the `pkgname` array upstream, a new package or a dropped one, is not detected, as with `depends`. See [Packages with changing dependencies](#packages-with-changing-dependencies).

## Not supported (blocked or detected)

aurtomator detects these cases and blocks the update or warns.

### pkgver() with the wrong strategy (BLOCKED)

A PKGBUILD with a `pkgver()` function and a strategy other than `git-latest` or `github-nightly`, for example `github-release`.

**Detection:** `audit_pkgbuild()` checks for a `pkgver()` function and the strategy. Release and tag strategies report release versions, which do not match what `pkgver()` computes at build time. A `pkgver()` that only prints `pkgver` passes: `cd` lines and one `printf` or `echo` of `$pkgver`, `${pkgver}` or `pkgver` with its dash replaced, such as `${pkgver//-/.}` or `${pkgver/-/_}`, as streamrip has `cd streamrip` and `printf "${pkgver//-/.}"`. `pkgver` holds no dash, so such a function prints the `pkgver` that `sed` sets.

**Correct approach:** a package built from a git checkout uses `strategy: git-latest`. A binary from a release tag that never moves drops `pkgver()` and sets `pkgver` to a date, which `github-asset` takes from the `updated_at` of the newest listed asset. The URLs name the tag as text:

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

A URL built from `$pkgver`, such as `releases/download/${pkgver}/` for the tag `continuous`, would point at a tag named after the date, which does not exist. The source URL check stops that bump on the 404, see [Source URL returns HTML](#source-url-returns-html-blocked). A version that a project publishes as a text asset is read with `webpage-scrape`, see [webpage-scrape](/aurtomator/strategies/#webpage-scrape).

### Mixed SKIP and real checksums (BLOCKED)

A PKGBUILD with a `SKIP` and a real hash for a remote source, in any order and in any checksum array. A `SKIP` that makepkg 7.1 writes itself does not count, since `updpkgsums` keeps it: that of a signature, see [Sources with a signature](#sources-with-a-signature), that of an svn source, and that of a git, hg or bzr source without the pin makepkg hashes, which is `#commit=` or `#tag=` for git, `#tag=` or `#revision=` for hg and `#revision=` for bzr. makepkg clones a fossil repository into one file and hashes it as a download, so the `SKIP` of a fossil source counts with or without a pin.

```bash
source=("git+https://example.com/app.git#commit=1a2b3c4" "https://example.com/data.tar.gz")
sha256sums=('SKIP'
            'abc123def456...')
```

**Detection:** `audit_pkgbuild()` sources the PKGBUILD and pairs every entry of every checksum array (`ck`, `md5`, `sha1`, `sha224`, `sha256`, `sha384`, `sha512`, `b2`, with and without an arch suffix) with the entry at the same index of `source` or `source_<arch>`. A real hash for a URL with `://` next to any other `SKIP` blocks the update. A real hash for a local file is allowed, because that file lives in the AUR repo and does not change between versions.

`update-pkg.sh` runs `updpkgsums` for the real hash, which would turn such a `SKIP` into a hash, and the check of the prepared files refuses a `SKIP` that changes.

**Correct approach:** run `updpkgsums` once and push the PKGBUILD with the hashes it writes, so the AUR copy holds them, as for a source pinned to a tag or a commit. A download whose file changes under the same URL has to keep its `SKIP`, and such a package needs a manual update.

### Sources that do not follow pkgver (BLOCKED)

A PKGBUILD whose sources take the version from another variable, as with `_pkgver=2025-04-03` and `pkgver="${_pkgver//-/.}"`, a download URL without the version, such as `https://example.org/download/latest/player.tar.zst`, whose file has not changed, or a VCS source pinned to a commit the version does not set, as with `source=("git+https://example.org/player.git#commit=$_commit")`. The version in the name a download is saved under does not count, as in `"player-$pkgver.zip::https://example.org/archive/$_commit.zip"`.

**Detection:** the `.SRCINFO` check refuses a new `pkgver` when no source URL, the part after `::`, and no checksum changed and a download over `http`, `https` or `ftp` has a real checksum, or a VCS source is pinned by `#commit=`, `#tag=` or `#revision=`. It checks this for each architecture, the common sources counting for all of them, so a `source_aarch64` built from its own `_armver` is refused while `source_x86_64` follows `pkgver`. A download saved under the new version from the URL and the checksum of the old one is refused even when another source changes. A VCS pin that stays counts only when nothing else changes: a pin next to a LICENSE fetched from the tag passes. Verify and publish run it, and `update-pkg.sh` runs it before the commit. See step 5 of publish in [Prepare and publish](/aurtomator/internals/update-process/#prepare-and-publish).

`sed` sets only `pkgver`. When the sources stay the same, `updpkgsums` hashes the old files again, and makepkg checks out the same pin, so the new version would hold the old files.

**Correct approach:** make `pkgver` the literal and derive the other variable from it, so `sed` sets the value the sources are built from. `_pkgver=2025-04-03` with `pkgver="${_pkgver//-/.}"` becomes:

```bash
pkgver=2025.04.03
_pkgver=${pkgver//./-}
source=("${pkgname}-${_pkgver}.tar.gz::${url}/archive/refs/tags/${_pkgver}.tar.gz")
```

`pkgver_dash: .` turns the dashes of a tag such as `2026-09-10` into dots, and the `.SRCINFO` check counts `2026-09-10` as a form of `2026.09.10`. The package YAML for the date tags of `vinceliuice/WhiteSur-gtk-theme`:

```yaml
name: whitesur-gtk-theme
strategy: github-tag
upstream:
  project: vinceliuice/WhiteSur-gtk-theme
  tag_version_regex: '^([0-9]{4}-[0-9]{2}-[0-9]{2})$'
pkgver_dash: .
```

The `.SRCINFO` check accepts a derived variable whose text is one of the forms of the version listed in step 5 of publish in [Prepare and publish](/aurtomator/internals/update-process/#prepare-and-publish). A source that needs data the version does not hold, such as a commit hash or a build number, cannot be derived from `pkgver` and needs a manual update.

### Lines the check cannot read from the PKGBUILD (BLOCKED)

A line of `.SRCINFO` other than `pkgver`, `pkgrel`, `source` and the checksums that holds the version, where the PKGBUILD writes the value with an escaped character, `{a,b}` or `$'...'`, takes the version from a variable that does not follow `pkgver`, or derives the value from `pkgver` and also writes its text elsewhere outside a comment line. A comment after code counts as text.

**Detection:** the `.SRCINFO` check looks up the value of each such line, the part after ` = `, in the text of the AUR PKGBUILD without its `pkgver=` and `pkgrel=` lines, the line of `upstream.asset_var`, its checksum arrays and its comment lines. A line whose value that text holds must stay as it is, and any other line must take the new version. A prepared line that differs stops the update, and the message names the line the check expected. Publish and verify run it, and `update-pkg.sh` runs it before the commit. See step 5 of publish in [Prepare and publish](/aurtomator/internals/update-process/#prepare-and-publish).

Verify and publish never run the PKGBUILD, so the check reads only its text. In these forms the text leads it to expect another line than makepkg writes, and a correct update stops.

**Correct approach:** write a value that holds the version as plain text when it stays, and derive it from `pkgver` when it follows the version:

```bash
license=('Apache-2.0')
provides=("demo=${pkgver}")
```

### Source URL returns HTML (BLOCKED)

Upstream moves or renames a release, and the old URL now redirects to an HTML error or download page.

**Detection:** `validate_source_urls()` sends a HEAD request to every URL in `source` and in each `source_<arch>` array and follows up to 5 redirects. curl reports the status and the `Content-Type` of the last response. A status of 400 or above, a missing status, or `Content-Type: text/html` in any letter case blocks the update. The script does not parse the headers itself, because the server chose that text. The check covers every `http` and `https` URL, whatever its checksum, and leaves out VCS sources and local files. It reads the PKGBUILD with `CARCH` set, as makepkg does, so a URL built from `$CARCH` is the one makepkg downloads. A source with a `SKIP` checksum is checked too, because no later step downloads it. An update that takes an arch out of `arch=()` skips the `source_<arch>` array of that arch, see [Versions without some arches](/aurtomator/features/missing-arches/).

Without this check, `updpkgsums` would hash the HTML page. The checksums would match and the package would fail to install.

### Checksums verify cannot compute (BLOCKED)

A real checksum for a download over `http` or `ftp`, for a git source over another protocol than `https`, for an `hg` or `bzr` source at a pin makepkg hashes, or for a `fossil` source.

**Detection:** the verify job computes every checksum other than `SKIP` again from its source, as makepkg does. It downloads over `https` only and clones git sources over `https` only, so any other checksum stops the update. See step 5 of verify in [Prepare and publish](/aurtomator/internals/update-process/#prepare-and-publish).

**Correct approach:** use the `https` URL of the download where the host serves one. A package that needs one of the other sources needs a manual update.

### Packages with patches (WARNING)

Packages with `.patch` or `.diff` files in `source=()`.

**Detection:** `audit_pkgbuild()` warns and does not block. Patches often survive a minor version bump and can break on a major one. The maintainer accepts that risk.

### Packages with an epoch (WARNING)

Packages whose PKGBUILD sets `epoch` to a value other than 0.

**Detection:** `audit_pkgbuild()` warns and does not block. An update sets `pkgver` and `pkgrel` and keeps `epoch` as it is, and `current` in the package YAML holds the version without the epoch. pacman compares the epoch before `pkgver`, so a downgrade that `allow_downgrade: true` publishes keeps the old epoch, and pacman does not install it over the newer version until the maintainer raises `epoch` by hand.

## Not supported (not detected)

aurtomator cannot detect these cases. The maintainer has to watch for them. When the version that needs the change is known in advance, such as a new major of a JDK that needs a newer boot JDK in `makedepends`, an alert in the package YAML pauses the update at that version or reports it, see [Update alerts](/aurtomator/features/update-alerts/).

### Packages needing a pkgrel bump

When `pkgver` stays the same and the PKGBUILD changes (dependency fix, build flag, patch update), `pkgrel` has to be incremented. aurtomator sets `pkgrel=1` for a new version, and raises `pkgrel` alone only for a rebuild that changes a value from a release asset name, see [Values from release asset names](/aurtomator/features/asset-values/). Any other pkgrel-only bump needs a human decision.

### Packages with changing source URLs

When upstream changes the download URL format:

- GitHub to GitLab migration
- `.tar.gz` to `.tar.zst`
- Binary renamed: `app-linux-x86_64` to `app-linux-amd64`
- Major version path change: `v1/app.tar.gz` to `v2/app.tar.gz`

aurtomator does not modify `source=()`. After such a change, source URL validation or `updpkgsums` fails and aurtomator refuses to push. That failure is safe. In a package whose remote sources are all `SKIP`, no step downloads one: a changed URL that answers 404 or an HTML page stops the update, and one that serves another file is pushed unnoticed.

### Packages with changing dependencies

aurtomator does not modify `depends`, `makedepends` or `optdepends`. When a new version needs a library that was not listed before, users can hit runtime errors.

### Packages requiring epoch

When upstream changes its versioning scheme, for example from CalVer to SemVer, and the new version compares lower than the old one, `epoch` is needed. aurtomator cannot tell such a version from a downgrade. It skips the version unless the package YAML sets `allow_downgrade: true`, see [Downgrades and version jumps](/aurtomator/features/downgrades/), and it never sets `epoch`. It warns about an `epoch` the PKGBUILD already has, see [Packages with an epoch](#packages-with-an-epoch-warning). Setting it cannot be undone and needs maintainer judgment.

### Packages with version-dependent install scripts

aurtomator does not touch `.install` files. When a new version needs migration steps in `post_upgrade()`, the maintainer updates them by hand.

## Rules for safe automation

1. **Only automate packages you actively maintain.** When something breaks, you fix it by hand.
2. **Only automate packages where pkgver is the only thing that changes.** Do not automate a package whose upstream often changes dependencies, source URLs or the build system.
3. **Watch your issues.** aurtomator opens a GitHub Issue when a package starts failing and when a run of the workflow fails.
4. **Test a new package by hand first.** Build and install it once before adding it to aurtomator.
5. **Do not automate packages with patches** unless the patches are known to apply across versions.
6. **Check your packages after automated pushes.** Build them now and then with `makepkg -si` to confirm they build and work.
