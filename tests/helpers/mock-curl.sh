#!/usr/bin/env bash
# Mock curl for BATS tests
# Reads URL from args, returns predefined responses based on URL patterns
#
# IMPORTANT: Specific patterns MUST come before wildcard patterns
# to avoid shellcheck SC2221/SC2222 (pattern ordering).

# The URL is the last argument. curl takes the last -w.
write_out=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == -w ]]; then
    write_out="$arg"
  fi
  prev="$arg"
  url="$arg"
done

case "$url" in
  # --- Specific error/null patterns (must be before wildcards) ---

  # The bot check of a site, as on forge.soutade.fr: a redirect to an HTML
  # page that answers 200
  *codeberg.org/api/v1/repos/gated-owner/gated-repo/tags* | \
    *gitlab.com/api/v4/projects/gated-group%2Fgated-project/repository/tags*)
    effective_url="${url%%/api/*}/402.html"
    echo '<!DOCTYPE html><html><body><h1>Are you Human?</h1></body></html>'
    ;;

  # GitHub Release: a body without tag_name. A real 404 is exit 22 with
  # no body, see the tests of curl exit codes.
  *api.github.com/repos/null-owner/null-repo/releases/latest)
    echo '{"message": "Not Found"}'
    ;;
  # GitLab Tags: empty array
  *gitlab.com/api/v4/projects/empty-group%2Fempty-project/repository/tags*)
    echo '[]'
    ;;
  # Gitea Tags: empty array
  *codeberg.org/api/v1/repos/empty-owner/empty-repo/tags*)
    echo '[]'
    ;;
  # PyPI: null version
  *pypi.org/pypi/null-package/json)
    echo '{"info": {"version": null}}'
    ;;
  # npm: null version
  *registry.npmjs.org/null-package/latest)
    echo '{"version": null}'
    ;;
  # crates.io: null version
  *crates.io/api/v1/crates/null-crate)
    echo '{"crate": {"max_stable_version": null}}'
    ;;
  # Repology: the AUR alone is newest, as for bluemail, and a second AUR
  # package lags behind it. vercmp puts 1.140.10 above 1.140.9, a string
  # sort does not.
  *repology.org/api/v1/project/aur-ahead)
    echo '[{"repo": "aur", "status": "newest", "version": "1.143.44"}, {"repo": "aur", "status": "outdated", "version": "1.142.0"}, {"repo": "nix_stable_24_05", "status": "outdated", "version": "1.140.9"}, {"repo": "nix_unstable", "status": "outdated", "version": "1.140.10"}]'
    ;;
  # Repology: only the AUR is newest, and an outdated pre-release is glued
  # to the number of an outdated release
  *repology.org/api/v1/project/rc-outdated)
    echo '[{"repo": "aur", "status": "newest", "version": "1.1"}, {"repo": "fedora_40", "status": "outdated", "version": "1.0"}, {"repo": "debian_13", "status": "outdated", "version": "1.0rc1"}]'
    ;;
  # Repology: libversion puts 1.0rc1 below 1.0, sort -V above it
  *repology.org/api/v1/project/rc-order)
    echo '[{"repo": "debian_13", "status": "outdated", "version": "1.0rc1"}, {"repo": "arch", "status": "newest", "version": "1.0"}]'
    ;;
  # Repology: no newest or outdated entry outside the AUR
  *repology.org/api/v1/project/aur-only)
    echo '[{"repo": "aur", "status": "newest", "version": "2.0"}, {"repo": "debian_unstable", "status": "devel", "version": "2.1rc1"}, {"repo": "debian_12", "status": "legacy", "version": "0.9"}]'
    ;;
  # Repology: a project it does not know, as wingide
  *repology.org/api/v1/project/missing-project)
    echo '[]'
    ;;
  # Arch repos: empty results
  *archlinux.org/packages/search/json*name=no-such-pkg*)
    echo '{"results": []}'
    ;;
  # Arch repos: an entry without pkgver
  *archlinux.org/packages/search/json*name=no-pkgver*)
    echo '{"results": [{"repo": "extra", "pkgname": "no-pkgver"}]}'
    ;;
  # Arch repos: an entry with an epoch, as ffmpeg 2:9.0.2-2
  *archlinux.org/packages/search/json*name=ffmpeg*)
    echo '{"results": [{"repo": "extra", "epoch": 2, "pkgver": "9.0.2", "pkgrel": "2"}]}'
    ;;
  # KDE tarball: no versions in listing
  *download.kde.org/stable/no-versions-here/*)
    echo '<html><body>Parent Directory</body></html>'
    ;;
  # KDE tarball: a flat directory with builds for other systems, as kdiff3
  *download.kde.org/stable/kdiff3/)
    echo '<a href="kdiff3-1.12.6-macos-arm64.dmg">kdiff3-1.12.6-macos-arm64.dmg</a>'
    echo '<a href="kdiff3-1.12.5.tar.xz">kdiff3-1.12.5.tar.xz</a>'
    echo '<a href="kdiff3-1.12.6.tar.xz">kdiff3-1.12.6.tar.xz</a>'
    ;;
  # KDE tarball: a flat directory of pre-releases outside stable/
  *download.kde.org/unstable/alkimia/)
    echo '<a href="alkimia-8.1.76.tar.xz">alkimia-8.1.76.tar.xz</a>'
    echo '<a href="alkimia-8.1.80.tar.xz">alkimia-8.1.80.tar.xz</a>'
    echo '<a href="alkimia-8.1.80.tar.xz.sig">alkimia-8.1.80.tar.xz.sig</a>'
    ;;
  # KDE tarball: a dot in the name must match a dot alone
  *download.kde.org/stable/kio.s3/)
    echo '<a href="kioXs3-9.9.9.tar.xz">kioXs3-9.9.9.tar.xz</a>'
    echo '<a href="kio.s3-1.0.0.tar.xz">kio.s3-1.0.0.tar.xz</a>'
    ;;
  # KDE tarball: a directory per version, as Plasma. sort -V puts 6.10.0
  # above 6.9.5, a string sort does not.
  *download.kde.org/stable/plasma/)
    echo '<a href="6.9.5/">6.9.5/</a>'
    echo '<a href="6.10.0/">6.10.0/</a>'
    ;;
  *download.kde.org/stable/plasma/6.10.0/)
    echo '<a href="oxygen-6.10.0.tar.xz">oxygen-6.10.0.tar.xz</a>'
    echo '<a href="oxygen-6.10.0.tar.xz.sig">oxygen-6.10.0.tar.xz.sig</a>'
    ;;
  # KDE tarball: a directory per series, as Frameworks
  *download.kde.org/stable/frameworks/)
    echo '<a href="6.9/">6.9/</a>'
    echo '<a href="6.10/">6.10/</a>'
    ;;
  *download.kde.org/stable/frameworks/6.10/)
    echo '<a href="kio-6.10.0.tar.xz">kio-6.10.0.tar.xz</a>'
    echo '<a href="kio-6.10.1.tar.xz">kio-6.10.1.tar.xz</a>'
    ;;
  # KDE tarball: the sources of a version under src/, as Gear
  *download.kde.org/stable/release-service/)
    echo '<a href="26.08.1/">26.08.1/</a>'
    echo '<a href="26.08.2/">26.08.2/</a>'
    ;;
  *download.kde.org/stable/release-service/26.08.2/)
    echo '<a href="macos/">macos/</a>'
    echo '<a href="src/">src/</a>'
    echo '<a href="windows/">windows/</a>'
    ;;
  *download.kde.org/stable/release-service/26.08.2/src/)
    echo '<a href="okular-26.08.2.tar.xz">okular-26.08.2.tar.xz</a>'
    ;;
  # KDE tarball: version directories beside others, as krita
  *download.kde.org/stable/krita/)
    echo '<a href="6.0.4/">6.0.4/</a>'
    echo '<a href="FastSketchPlugin-1.1.0/">FastSketchPlugin-1.1.0/</a>'
    echo '<a href="updates/">updates/</a>'
    ;;
  *download.kde.org/stable/krita/6.0.4/)
    echo '<a href="krita-6.0.4.tar.gz">krita-6.0.4.tar.gz</a>'
    echo '<a href="krita-6.0.4.tar.xz">krita-6.0.4.tar.xz</a>'
    ;;
  # KDE tarball: old tarballs beside a newer version directory
  *download.kde.org/stable/moved/)
    echo '<a href="moved-1.9.0.tar.xz">moved-1.9.0.tar.xz</a>'
    echo '<a href="2.0.0/">2.0.0/</a>'
    ;;
  *download.kde.org/stable/moved/2.0.0/)
    echo '<a href="moved-2.0.0.tar.xz">moved-2.0.0.tar.xz</a>'
    ;;
  # KDE tarball: a newer tarball beside older version directories
  *download.kde.org/stable/flat-again/)
    echo '<a href="2.0.0/">2.0.0/</a>'
    echo '<a href="flat-again-3.0.0.tar.xz">flat-again-3.0.0.tar.xz</a>'
    ;;
  *download.kde.org/stable/flat-again/2.0.0/)
    echo '<a href="flat-again-2.0.0.tar.xz">flat-again-2.0.0.tar.xz</a>'
    ;;
  # KDE tarball: a version directory whose listing fails
  *download.kde.org/unstable/broken/)
    echo '<a href="2.0.0/">2.0.0/</a>'
    ;;
  # Webpage scrape: no matching versions
  *example.com/empty-page*)
    echo '<html><body>No downloads here</body></html>'
    ;;
  # GitHub Asset: a body without assets
  *api.github.com/repos/null-owner/null-repo/releases/tags/*)
    echo '{"message": "Not Found"}'
    ;;

  # --- GitHub Nightly patterns (before wildcards) ---

  # Custom nightly tag (must be before wildcard nightly pattern)
  *api.github.com/repos/custom-nightly/repo/releases/tags/nightly)
    printf '{"tag_name": "nightly-v3.5.0-rc1", "body": "Some nightly build", "published_at": "2026-03-27T05:43:19Z"}'
    ;;
  # Pattern A: fixed nightly tag
  *api.github.com/repos/*/releases/tags/nightly)
    printf '{"tag_name": "nightly", "body": "NVIM v0.12.0-dev+2713+g925e9e8722\\nSome other text", "published_at": "2026-03-27T05:43:19Z"}'
    ;;
  # Pattern B with a regex, as servo/servo-nightly-builds: the rc releases
  # come first, the API order is not the publish order, and a draft holds
  # no published_at
  *"api.github.com/repos/dated-nightly/repo/releases?per_page=100&page=1")
    echo '[{"tag_name": "v0.7.0-rc1", "published_at": "2026-10-01T20:28:19Z"}, {"tag_name": "2026-10-20", "published_at": "2026-10-21T00:00:29Z"}, {"tag_name": "2026-10-21", "published_at": "2026-10-22T00:25:00Z"}, {"tag_name": "2026-10-22", "published_at": null}, {"tag_name": "2026-10-19", "published_at": "2026-10-19T23:28:58Z"}]'
    ;;
  # A last page of 2 releases without a match
  *"api.github.com/repos/short-nightly/repo/releases?per_page=100&page=1")
    echo '[{"tag_name": "v0.7.0-rc1", "published_at": "2026-10-01T20:28:19Z"}, {"tag_name": "v0.6.0-rc2", "published_at": "2026-09-24T16:52:22Z"}]'
    ;;
  # A full page of 100 releases with the match among them
  *"api.github.com/repos/full-nightly/repo/releases?per_page=100&page=1")
    printf '[{"tag_name": "2026-10-21", "published_at": "2026-10-22T00:25:00Z"}'
    for i in $(seq 1 99); do
      printf ', {"tag_name": "v0.%d-rc1", "published_at": "2026-01-01T00:00:00Z"}' "$i"
    done
    printf ']\n'
    ;;
  # A page of 100 releases without a match, and the match on page 2
  *"api.github.com/repos/later-nightly/repo/releases?per_page=100&page=2")
    echo '[{"tag_name": "2026-10-21", "published_at": "2026-10-22T00:25:00Z"}]'
    ;;
  *"api.github.com/repos/later-nightly/repo/releases?per_page=100&page="* | \
    *"api.github.com/repos/no-nightly/repo/releases?per_page=100&page="*)
    sep=""
    printf '['
    for i in $(seq 1 100); do
      printf '%s{"tag_name": "v0.%d-rc1", "published_at": "2026-01-01T00:00:00Z"}' "$sep" "$i"
      sep=", "
    done
    printf ']\n'
    ;;
  # GitHub answered [] for a page of ruffle-rs/ruffle that a retry filled
  *"api.github.com/repos/empty-nightly/repo/releases?per_page=100&page="*)
    echo '[]'
    ;;
  # Pattern B+D: release names and tags that hold a double quote
  *api.github.com/repos/owner/quoted-repo/releases\?per_page=20)
    echo '[{"tag_name": "v1.0.0", "name": "Stable"}, {"tag_name": "v2.0.0", "name": "Beta \"b\""}, {"tag_name": "nightly-\"q\"-2026-04-01", "name": "Nightly"}]'
    ;;
  # Pattern B+D: releases list (for dated tags and channel filter)
  *api.github.com/repos/*/releases\?per_page=20)
    echo '[{"tag_name": "nightly-2026-03-26", "name": "Nightly v9.0.1", "published_at": "2026-03-26T00:00:00Z"}, {"tag_name": "nightly-2026-03-25", "name": "Stable v8.0.0", "published_at": "2026-03-25T00:00:00Z"}]'
    ;;

  # --- GitHub Asset pattern (before wildcards) ---

  # Fixed release tag whose assets get re-uploaded
  *api.github.com/repos/*/releases/tags/models)
    echo '{"tag_name": "models", "assets": [{"name": "voice-a.tar.bz2", "updated_at": "2025-12-02T06:55:38Z"}, {"name": "voice-b.tar.bz2", "updated_at": "2026-01-15T10:00:00Z"}, {"name": "voice-c.tar.bz2", "updated_at": "2024-03-09T00:00:00Z"}, {"name": "voice-d.tar.bz2", "updated_at": "soon"}]}'
    ;;

  # --- tag_version_regex test patterns (must be before wildcards) ---

  # Custom prefix tag format
  *api.github.com/repos/custom-prefix/repo/releases/latest)
    echo '{"tag_name": "MeshLab-2025.07"}'
    ;;
  *"api.github.com/repos/custom-prefix/repo/releases?per_page=100&page=1")
    echo '[{"tag_name": "MeshLab-2025.07", "published_at": "2025-07-01T00:00:00Z", "prerelease": false}]'
    ;;
  # Custom suffix tag format
  *api.github.com/repos/custom-suffix/repo/releases/latest)
    echo '{"tag_name": "0.1.8-stable"}'
    ;;
  *"api.github.com/repos/custom-suffix/repo/releases?per_page=100&page=1")
    echo '[{"tag_name": "0.1.8-stable", "published_at": "2025-10-27T17:18:07Z", "prerelease": false}]'
    ;;
  # Date tags, as servo names its nightlies and vinceliuice its themes.
  # servo published 2026-10-21 after midnight UTC.
  *api.github.com/repos/dated-owner/dated-repo/releases/latest)
    echo '{"tag_name": "2026-10-21", "published_at": "2026-10-22T00:25:00Z"}'
    ;;
  *"api.github.com/repos/dated-owner/dated-repo/releases?per_page=100&page=1")
    echo '[{"tag_name": "2026-10-21", "published_at": "2026-10-22T00:25:00Z", "prerelease": false}]'
    ;;
  # Several products in one repository, as tutao/tutanota: an older match
  # first in the API order, a newer pre-release and a draft of the product
  *"api.github.com/repos/multi-product/repo/releases?per_page=100&page=1")
    echo '[{"tag_name": "app-desktop-release-361.0", "published_at": "2026-10-12T08:34:32Z", "prerelease": false}, {"tag_name": "app-web-release-362.0", "published_at": "2026-10-21T08:32:50Z", "prerelease": false}, {"tag_name": "app-desktop-release-363.0", "published_at": "2026-10-22T00:00:00Z", "prerelease": true}, {"tag_name": "app-desktop-release-362.0", "published_at": "2026-10-21T08:33:13Z", "prerelease": false}, {"tag_name": "app-desktop-release-364.0", "published_at": null, "prerelease": false}]'
    ;;
  # /releases/latest answers 404 when every release is a pre-release, as
  # for FreeTubeApp/FreeTube, and when there is no release at all
  *api.github.com/repos/prerelease-only/repo/releases/latest | \
    *api.github.com/repos/no-releases/repo/releases/latest | \
    *api.github.com/repos/stable-list/repo/releases/latest)
    exit 22
    ;;
  *"api.github.com/repos/prerelease-only/repo/releases?per_page=100" | \
    *"api.github.com/repos/prerelease-only/repo/releases?per_page=100&page=1")
    echo '[{"tag_name": "v0.25.3-beta", "published_at": "2026-10-01T00:00:00Z", "prerelease": true}]'
    ;;
  *"api.github.com/repos/no-releases/repo/releases?per_page=100")
    echo '[]'
    ;;
  *"api.github.com/repos/stable-list/repo/releases?per_page=100")
    echo '[{"tag_name": "v2.0.0", "published_at": "2026-10-01T00:00:00Z", "prerelease": false}]'
    ;;
  *gitlab.com/api/v4/projects/dated-group%2Fdated-project/repository/tags* | \
    *codeberg.org/api/v1/repos/dated-owner/dated-repo/tags*)
    echo '[{"name": "2025-12-27"}, {"name": "v2025-02-10"}, {"name": "2026-09-10"}]'
    ;;
  # Tags with a prefix, as mesa names its releases
  *gitlab.com/api/v4/projects/prefix-group%2Fprefix-project/repository/tags* | \
    *codeberg.org/api/v1/repos/prefix-owner/prefix-repo/tags*)
    echo '[{"name": "mesa-26.2.5"}, {"name": "mesa-26.3.0-rc1"}, {"name": "mesa-26.1.0"}]'
    ;;
  # Tags of which some are not releases, and tags of which none is
  *gitlab.com/api/v4/projects/mixed-group%2Fmixed-project/repository/tags* | \
    *codeberg.org/api/v1/repos/mixed-owner/mixed-repo/tags*)
    echo '[{"name": "latest"}, {"name": "v2.1.0-rc1"}, {"name": "v2.1.0rc2"}, {"name": "v2.0.0"}, {"name": "v1.9.0"}]'
    ;;
  *gitlab.com/api/v4/projects/named-group%2Fnamed-project/repository/tags* | \
    *codeberg.org/api/v1/repos/named-owner/named-repo/tags*)
    echo '[{"name": "latest"}, {"name": "nightly"}]'
    ;;

  # The latest release of aurtomator itself: the tag in MOCK_UPSTREAM_TAG,
  # v0.6.0 by default, or a failed request for "fail"
  *api.github.com/repos/staticwire/aurtomator/releases/latest)
    [[ "${MOCK_UPSTREAM_TAG:-v0.6.0}" != fail ]] || exit 22
    printf '{"tag_name": "%s"}\n' "${MOCK_UPSTREAM_TAG:-v0.6.0}"
    ;;

  # --- Normal success patterns (wildcards) ---

  # GitHub Release API
  *api.github.com/repos/*/releases/latest)
    echo '{"tag_name": "v2.0.0"}'
    ;;
  # GitLab Tags API
  *gitlab.com/api/v4/projects/*/repository/tags*)
    echo '[{"name": "v3.1.0"}, {"name": "v3.0.0"}, {"name": "v2.0.0"}]'
    ;;
  # Gitea Tags API
  *codeberg.org/api/v1/repos/*/tags*)
    echo '[{"name": "v1.5.0"}, {"name": "v1.4.0"}]'
    ;;
  # PyPI JSON API
  *pypi.org/pypi/*/json)
    echo '{"info": {"version": "3.2.1"}}'
    ;;
  # npm registry
  *registry.npmjs.org/*/latest)
    echo '{"version": "4.0.0"}'
    ;;
  # A crate whose highest version is a pre-release, as pijul
  *crates.io/api/v1/crates/pre-crate)
    echo '{"crate": {"max_version": "1.0.0-beta.24", "max_stable_version": "0.15.0"}}'
    ;;
  # crates.io API
  *crates.io/api/v1/crates/*)
    echo '{"crate": {"max_stable_version": "1.0.204"}}'
    ;;
  # Repology API
  *repology.org/api/v1/project/*)
    echo '[{"status": "newest", "version": "5.0.0"}, {"status": "outdated", "version": "4.0.0"}]'
    ;;
  # Arch repos API
  *archlinux.org/packages/search/json*)
    echo '{"results": [{"pkgver": "6.10.2", "pkgrel": "1"}]}'
    ;;
  # KDE tarball directory listing
  *download.kde.org/stable/*)
    pkg_name="${url##*/stable/}"
    pkg_name="${pkg_name%%/*}"
    echo "<a href=\"${pkg_name}-1.0.1.tar.xz\">${pkg_name}-1.0.1.tar.xz</a>"
    echo "<a href=\"${pkg_name}-1.0.0.tar.xz\">${pkg_name}-1.0.0.tar.xz</a>"
    ;;
  # Webpage scrape (generic HTML)
  *example.com/releases*)
    echo '<a href="/download/test-scrape-7.0.0.tar.gz">test-scrape-7.0.0.tar.gz</a>'
    ;;
  # Webpage scrape: a release and a pre-release glued to its number
  *example.com/prereleases*)
    echo '<a href="test-scrape-2.0.0.tar.gz">test-scrape-2.0.0.tar.gz</a>'
    echo '<a href="test-scrape-2.1.0.tar.gz">test-scrape-2.1.0.tar.gz</a>'
    echo '<a href="test-scrape-2.1.0rc1.tar.gz">test-scrape-2.1.0rc1.tar.gz</a>'
    ;;

  # Fallback: error, simulates a network failure
  *)
    echo "Mock curl: unknown URL: $url" >&2
    exit 1
    ;;
esac

# http_get_json asks for the URL of the last answer after the body
if [[ "$write_out" == '\n%{url_effective}'* ]]; then
  printf '\n%s' "${effective_url:-$url}"
fi
