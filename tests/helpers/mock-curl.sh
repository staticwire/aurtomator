#!/usr/bin/env bash
# Mock curl for BATS tests
# Reads URL from args, returns predefined responses based on URL patterns
#
# IMPORTANT: Specific patterns MUST come before wildcard patterns
# to avoid shellcheck SC2221/SC2222 (pattern ordering).

for arg in "$@"; do
  url="$arg"
done

case "$url" in
  # --- Specific error/null patterns (must be before wildcards) ---

  # GitHub Release — null tag_name (404 response)
  *api.github.com/repos/null-owner/null-repo/releases/latest)
    echo '{"message": "Not Found"}'
    ;;
  # GitHub Tags — empty array
  *api.github.com/repos/empty-owner/empty-repo/tags*)
    echo '[]'
    ;;
  # GitLab Tags — empty array
  *gitlab.com/api/v4/projects/empty-group%2Fempty-project/repository/tags*)
    echo '[]'
    ;;
  # Gitea Tags — empty array
  *codeberg.org/api/v1/repos/empty-owner/empty-repo/tags*)
    echo '[]'
    ;;
  # PyPI — null version
  *pypi.org/pypi/null-package/json)
    echo '{"info": {"version": null}}'
    ;;
  # npm — null version
  *registry.npmjs.org/null-package/latest)
    echo '{"version": null}'
    ;;
  # crates.io — null version
  *crates.io/api/v1/crates/null-crate)
    echo '{"crate": {"max_stable_version": null}}'
    ;;
  # Repology — no newest status
  *repology.org/api/v1/project/no-newest)
    echo '[{"status": "outdated", "version": "1.0"}, {"status": "devel", "version": "2.0-rc1"}]'
    ;;
  # Arch repos — empty results
  *archlinux.org/packages/search/json*name=no-such-pkg*)
    echo '{"results": []}'
    ;;
  # KDE tarball — no versions in listing
  *download.kde.org/stable/no-versions-here/*)
    echo '<html><body>Parent Directory</body></html>'
    ;;
  # Webpage scrape — no matching versions
  *example.com/empty-page*)
    echo '<html><body>No downloads here</body></html>'
    ;;

  # --- Normal success patterns (wildcards) ---

  # GitHub Release API
  *api.github.com/repos/*/releases/latest)
    echo '{"tag_name": "v2.0.0"}'
    ;;
  # GitHub Tags API
  *api.github.com/repos/*/tags*)
    echo '[{"name": "v2.0.0"}, {"name": "v1.9.0"}, {"name": "v1.0.0"}]'
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

  # Fallback — error (simulates network failure)
  *)
    echo "Mock curl: unknown URL: $url" >&2
    exit 1
    ;;
esac
