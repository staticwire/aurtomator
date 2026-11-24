#!/usr/bin/env bash
# Mock curl for the bats tests: answers by the pattern the URL matches.
# Specific patterns come before the wildcard that covers them, or shellcheck reports SC2221/SC2222.

# The URL is the last argument. curl takes the last -w and the last -o.
write_out=""
out_file=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == -w ]]; then
    write_out="$arg"
  elif [[ "$prev" == -o ]]; then
    out_file="$arg"
  fi
  prev="$arg"
  url="$arg"
done
# Tests that check the options of a request name a file for them in CURL_ARGS_LOG
[[ -z "${CURL_ARGS_LOG:-}" ]] || printf '%s\n' "$*" >>"$CURL_ARGS_LOG"

# With -o the answer goes into that file, and the -w text to stdout
exec {stdout_fd}>&1
if [[ -n "$out_file" ]]; then
  exec >"$out_file"
fi

# Failed requests, as curl -f writes them with the -w texts of http_get and
# http_get_json: the URL on stdout for the latter, the error on stderr
http_error() {
  [[ "$write_out" != '\n%{url_effective}'* ]] || printf '\n%s' "$url" >&"$stdout_fd"
  [[ "$write_out" != *'%{onerror}%{stderr}'* ]] ||
    printf '%s\tThe requested URL returned error: %s\t%s\t' "$url" "$1" "$1" >&2
  exit 22
}

case "$url" in
  # --- Specific error/null patterns (must be before wildcards) ---

  # The bot check of a site, as on forge.soutade.fr: a redirect to an HTML
  # page that answers 200
  *codeberg.org/api/v1/repos/gated-owner/gated-repo/tags* | \
    *codeberg.org/api/v1/repos/gated-owner/gated-repo/releases* | \
    *gitlab.com/api/v4/projects/gated-group%2Fgated-project/repository/tags"?per_page=100")
    effective_url="${url%%/api/*}/402.html"
    echo '<!DOCTYPE html><html><body><h1>Are you Human?</h1></body></html>'
    ;;
  # The same page in front of a registry or of archlinux.org
  *registry.npmjs.org/gated-pkg/latest | *pypi.org/pypi/gated-pkg/json | \
    *crates.io/api/v1/crates/gated-pkg | *repology.org/api/v1/project/gated-pkg | \
    *archlinux.org/packages/search/json/?name=gated-pkg)
    host="${url#https://}"
    effective_url="https://${host%%/*}/402.html"
    echo '<!DOCTYPE html><html><body><h1>Are you Human?</h1></body></html>'
    ;;

  # GitHub Release: a body without tag_name. Real 404s are exit 22 with
  # no body, see the tests of curl exit codes.
  *api.github.com/repos/null-owner/null-repo/releases/latest)
    echo '{"message": "Not Found"}'
    ;;
  # GitLab Tags: empty array
  *gitlab.com/api/v4/projects/empty-group%2Fempty-project/repository/tags"?per_page=100")
    echo '[]'
    ;;
  # Gitea Tags: empty array
  *codeberg.org/api/v1/repos/empty-owner/empty-repo/tags"?limit=50")
    echo '[]'
    ;;
  # PyPI: null version
  *pypi.org/pypi/null-package/json)
    echo '{"info": {"version": null}}'
    ;;
  # PyPI: requirements of a made-up project, one name for each case of pin_from
  *pypi.org/pypi/pin-cases/json)
    echo '{"info": {"version": "1.0", "requires_dist": ["ranged>=1.0", "wild==0.0.*", "clauses==1.0,!=1.1", "url @ https://example.org/url.zip", "two==1.0", "two==2.0", "same==1.0", "Same==1.0; os_name == \"posix\"", "py==1.0; python_version < \"3.11\"", "py==2.0; python_version >= \"3.11\"", "win==1.0; sys_platform == \"win32\"", "test==1.0; extra == \"test\""]}}'
    ;;
  *pypi.org/pypi/pin-gone/json)
    http_error 404
    ;;
  # PyPI: releases of made-up projects for the requires rule: a change both ways, a release of
  # current that PyPI lacks, a new release that PyPI lacks, and a server error
  *pypi.org/pypi/mixer/1.0/json)
    echo '{"info": {"version": "1.0", "requires_dist": ["keep", "old-dep"]}}'
    ;;
  *pypi.org/pypi/mixer/2.0/json)
    echo '{"info": {"version": "2.0", "requires_dist": ["keep>=2", "New_Dep>=1", "other-new; sys_platform == \"linux\"", "win-only; sys_platform == \"win32\""]}}'
    ;;
  *pypi.org/pypi/gone/0.1.2/json | *pypi.org/pypi/zensical/0.1.4/json)
    http_error 404
    ;;
  *pypi.org/pypi/flaky/1.0/json)
    http_error 503
    ;;
  # PyPI releases, with the requires_dist of PyPI on 2026-11-23
  *pypi.org/pypi/zensical/json | *pypi.org/pypi/zensical/0.1.3/json)
    echo '{"info": {"version": "0.1.3", "requires_dist": ["click>=8.1.8", "jinja2>=3.1", "markdown>=3.7", "pathspec>=1.0.4", "pygments>=2.20", "pymdown-extensions>=11.0", "pyyaml>=6.0.2", "tomli>=2.4.0", "zensical-ui==0.0.43"]}}'
    ;;
  *pypi.org/pypi/zensical/0.1.2/json)
    echo '{"info": {"version": "0.1.2", "requires_dist": ["click>=8.1.8", "jinja2>=3.1", "markdown>=3.7", "pathspec>=1.0.4", "pygments>=2.20", "pymdown-extensions>=11.0", "pyyaml>=6.0.2", "tomli>=2.4.0", "zensical-ui==0.0.42"]}}'
    ;;
  *pypi.org/pypi/zensical/0.0.74/json)
    echo '{"info": {"version": "0.0.74", "requires_dist": ["click>=8.1.8", "deepmerge>=2.0", "jinja2>=3.1", "markdown>=3.7", "pathspec>=1.0.4", "pygments>=2.20", "pymdown-extensions>=11.0", "pyyaml>=6.0.2", "tomli>=2.4.0", "zensical-ui==0.0.41"]}}'
    ;;
  *pypi.org/pypi/keyring/25.6.0/json)
    echo '{"info": {"version": "25.6.0", "requires_dist": ["pywin32-ctypes>=0.2.0; sys_platform == \"win32\"", "SecretStorage>=3.2; sys_platform == \"linux\"", "jeepney>=0.4.2; sys_platform == \"linux\"", "importlib_metadata>=4.11.4; python_version < \"3.12\"", "jaraco.classes", "importlib_resources; python_version < \"3.9\"", "jaraco.functools", "jaraco.context", "pytest!=8.1.*,>=6; extra == \"test\"", "pyfakefs; extra == \"test\"", "sphinx>=3.5; extra == \"doc\"", "jaraco.packaging>=9.3; extra == \"doc\"", "rst.linker>=1.9; extra == \"doc\"", "furo; extra == \"doc\"", "sphinx-lint; extra == \"doc\"", "jaraco.tidelift>=1.4; extra == \"doc\"", "pytest-checkdocs>=2.4; extra == \"check\"", "pytest-ruff>=0.2.1; sys_platform != \"cygwin\" and extra == \"check\"", "pytest-cov; extra == \"cover\"", "pytest-enabler>=2.2; extra == \"enabler\"", "pytest-mypy; extra == \"type\"", "pygobject-stubs; extra == \"type\"", "shtab; extra == \"type\"", "types-pywin32; extra == \"type\"", "shtab>=1.1.0; extra == \"completion\""]}}'
    ;;
  *pypi.org/pypi/keyring/25.7.0/json)
    echo '{"info": {"version": "25.7.0", "requires_dist": ["pywin32-ctypes>=0.2.0; sys_platform == \"win32\"", "SecretStorage>=3.2; sys_platform == \"linux\"", "jeepney>=0.4.2; sys_platform == \"linux\"", "importlib_metadata>=4.11.4; python_version < \"3.12\"", "jaraco.classes", "jaraco.functools", "jaraco.context", "pytest!=8.1.*,>=6; extra == \"test\"", "pyfakefs; extra == \"test\"", "sphinx>=3.5; extra == \"doc\"", "jaraco.packaging>=9.3; extra == \"doc\"", "rst.linker>=1.9; extra == \"doc\"", "furo; extra == \"doc\"", "sphinx-lint; extra == \"doc\"", "jaraco.tidelift>=1.4; extra == \"doc\"", "pytest-checkdocs>=2.4; extra == \"check\"", "pytest-ruff>=0.2.1; sys_platform != \"cygwin\" and extra == \"check\"", "pytest-cov; extra == \"cover\"", "pytest-enabler>=3.4; extra == \"enabler\"", "pytest-mypy>=1.0.1; extra == \"type\"", "pygobject-stubs; extra == \"type\"", "shtab; extra == \"type\"", "types-pywin32; extra == \"type\"", "shtab>=1.1.0; extra == \"completion\""]}}'
    ;;
  *pypi.org/pypi/black/26.1.0/json)
    echo '{"info": {"version": "26.1.0", "requires_dist": ["click>=8.0.0", "mypy-extensions>=0.4.3", "packaging>=22.0", "pathspec>=1.0.0", "platformdirs>=2", "pytokens>=0.3.0", "tomli>=1.1.0; python_version < \"3.11\"", "typing-extensions>=4.0.1; python_version < \"3.11\"", "colorama>=0.4.3; extra == \"colorama\"", "aiohttp>=3.10; extra == \"d\"", "ipython>=7.8.0; extra == \"jupyter\"", "tokenize-rt>=3.2.0; extra == \"jupyter\"", "uvloop>=0.15.2; extra == \"uvloop\""]}}'
    ;;
  *pypi.org/pypi/black/26.10.1/json)
    echo '{"info": {"version": "26.10.1", "requires_dist": ["click>=8.0.0", "mypy-extensions>=0.4.3", "packaging>=22.0", "pathspec>=1.0.0", "platformdirs>=2", "pytokens~=0.4.0", "tomli>=1.1.0; python_version < \"3.11\"", "typing-extensions>=4.0.1; python_version < \"3.11\"", "colorama>=0.4.3; extra == \"colorama\"", "aiohttp>=3.10; extra == \"d\"", "ipython>=7.8.0; extra == \"jupyter\"", "tokenize-rt>=3.2.0; extra == \"jupyter\"", "uvloop>=0.15.2; sys_platform != \"win32\" and extra == \"uvloop\"", "winloop>=0.5.0; sys_platform == \"win32\" and extra == \"uvloop\""]}}'
    ;;
  # PyPI simple API: the page of a project that a test writes, then the fixture of tests/fixtures
  *pypi.org/simple/*/)
    project=${url%/}
    project=${project##*/}
    if [[ -f "$MOCK_FILES_DIR/simple/$project.json" ]]; then
      cat "$MOCK_FILES_DIR/simple/$project.json"
    elif [[ -f "$FIXTURES_DIR/pypi/simple/$project.json" ]]; then
      cat "$FIXTURES_DIR/pypi/simple/$project.json"
    else
      http_error 404
    fi
    ;;
  # Files of PyPI releases: a file that a test writes, then a .metadata fixture
  *files.pythonhosted.org/*)
    file=${url##*/}
    if [[ -f "$MOCK_FILES_DIR/$file" ]]; then
      cat "$MOCK_FILES_DIR/$file"
    elif [[ -f "$FIXTURES_DIR/pypi/metadata/$file" ]]; then
      cat "$FIXTURES_DIR/pypi/metadata/$file"
    else
      http_error 404
    fi
    ;;
  # AUR RPC: the packages of aur-rpc.json whose Name an arg[] of the URL names
  *aur.archlinux.org/rpc/v5/info*)
    names=""
    IFS='&' read -ra params <<<"${url#*\?}"
    for param in "${params[@]}"; do
      case $param in
        'arg[]='* | arg%5B%5D=* | arg%5b%5d=*) value=${param#*=} ;;
        *) continue ;;
      esac
      value=${value//+/ }
      printf -v value '%b' "${value//%/\\x}"
      names+="$value"$'\n'
    done
    if [[ -f "$MOCK_FILES_DIR/aur-rpc.json" ]]; then
      # shellcheck disable=SC2016 # $n is a variable of yq
      NAMES=$names yq -o json -I0 '[.[] | select(.Name as $n | strenv(NAMES) | split("\n") | any_c(. == $n))] |
        {"version": 5, "type": "multiinfo", "resultcount": length, "results": .}' "$MOCK_FILES_DIR/aur-rpc.json"
    else
      echo '{"version": 5, "type": "multiinfo", "resultcount": 0, "results": []}'
    fi
    ;;
  # npm: null version
  *registry.npmjs.org/null-package/latest)
    echo '{"version": null}'
    ;;
  # crates.io: null version
  *crates.io/api/v1/crates/null-crate)
    echo '{"crate": {"max_stable_version": null}}'
    ;;
  # Repology: the AUR alone is newest, and a second AUR package lags behind it.
  # vercmp puts 1.140.10 above 1.140.9, a string sort does not.
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
  # Repology: the block of a client that sent more than one request per second, a 403 page
  # in HTML, which curl -f does not print
  *repology.org/api/v1/project/blocked-project)
    http_error 403
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
  # Arch repos: a testing build listed before the stable one, as amd-ucode
  *archlinux.org/packages/search/json*name=arch-split*)
    echo '{"results": [{"repo": "core-testing", "epoch": 0, "pkgver": "2.0", "pkgrel": "1"}, {"repo": "core", "epoch": 0, "pkgver": "1.0", "pkgrel": "1"}]}'
    ;;
  # Arch repos: a testing build older than the stable one, and a newer
  # build in kde-unstable
  *archlinux.org/packages/search/json*name=arch-stale*)
    echo '{"results": [{"repo": "extra", "epoch": 0, "pkgver": "3.0", "pkgrel": "1"}, {"repo": "extra-testing", "epoch": 0, "pkgver": "2.9", "pkgrel": "1"}, {"repo": "kde-unstable", "epoch": 0, "pkgver": "9.0", "pkgrel": "1"}]}'
    ;;
  # Arch repos: a package in a testing repository only
  *archlinux.org/packages/search/json*name=arch-testing-only*)
    echo '{"results": [{"repo": "multilib-testing", "epoch": 0, "pkgver": "5.0", "pkgrel": "1"}]}'
    ;;
  # Arch repos: the epoch of the testing build makes it the newer one
  *archlinux.org/packages/search/json*name=arch-epoch*)
    echo '{"results": [{"repo": "extra", "epoch": 1, "pkgver": "2.0", "pkgrel": "1"}, {"repo": "extra-testing", "epoch": 2, "pkgver": "1.0", "pkgrel": "1"}]}'
    ;;
  # Arch repos: a package of multilib
  *archlinux.org/packages/search/json*name=arch-multilib*)
    echo '{"results": [{"repo": "multilib", "epoch": 0, "pkgver": "4.0", "pkgrel": "1"}]}'
    ;;
  # Arch repos: the server reads a + in the query as a space, so only %2B
  # finds libsigc++
  *archlinux.org/packages/search/json*name=libsigc%2B%2B*)
    echo '{"results": [{"repo": "extra", "epoch": 0, "pkgver": "2.12.2", "pkgrel": "1"}]}'
    ;;
  *archlinux.org/packages/search/json*name=libsigc++*)
    echo '{"results": []}'
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
  # Pattern B with a regex, as in servo/servo-nightly-builds: rc releases first, an API order that
  # differs from the publish order, and a draft without published_at
  *"api.github.com/repos/dated-nightly/repo/releases?per_page=100&page=1")
    echo '[{"tag_name": "v0.7.0-rc1", "published_at": "2026-10-01T20:28:19Z"}, {"tag_name": "2026-10-20", "published_at": "2026-10-21T00:00:29Z"}, {"tag_name": "2026-10-21", "published_at": "2026-10-22T00:25:00Z"}, {"tag_name": "2026-10-22", "published_at": null}, {"tag_name": "2026-10-19", "published_at": "2026-10-19T23:28:58Z"}]'
    ;;
  # Last page of 2 releases without a match
  *"api.github.com/repos/short-nightly/repo/releases?per_page=100&page=1")
    echo '[{"tag_name": "v0.7.0-rc1", "published_at": "2026-10-01T20:28:19Z"}, {"tag_name": "v0.6.0-rc2", "published_at": "2026-09-24T16:52:22Z"}]'
    ;;
  # Full page of 100 releases with the match among them, and a later
  # match on page 2
  *"api.github.com/repos/full-nightly/repo/releases?per_page=100&page=1")
    printf '[{"tag_name": "2026-10-21", "published_at": "2026-10-22T00:25:00Z"}'
    for i in $(seq 1 99); do
      printf ', {"tag_name": "v0.%d-rc1", "published_at": "2026-01-01T00:00:00Z"}' "$i"
    done
    printf ']\n'
    ;;
  *"api.github.com/repos/full-nightly/repo/releases?per_page=100&page=2")
    echo '[{"tag_name": "2026-10-23", "published_at": "2026-10-24T00:00:00Z"}]'
    ;;
  # 100 fix releases of the old line, created after the new major and so
  # listed before it, and the major on page 2
  *"api.github.com/repos/two-lines/repo/releases?per_page=100&page=1")
    sep=""
    printf '['
    for i in $(seq 1 100); do
      printf '%s{"tag_name": "v1.0.%d", "published_at": "2026-10-20T%02d:%02d:00Z", "prerelease": false}' "$sep" "$i" $((i / 60)) $((i % 60))
      sep=", "
    done
    printf ']\n'
    ;;
  # The major, and the last release of page 1 again: a release created
  # while the pages are read moves it to page 2
  *"api.github.com/repos/two-lines/repo/releases?per_page=100&page=2")
    echo '[{"tag_name": "v1.0.100", "published_at": "2026-10-20T01:40:00Z", "prerelease": false}, {"tag_name": "v2.0.0", "published_at": "2026-09-01T00:00:00Z", "prerelease": false}]'
    ;;
  # Page of 100 releases without a match, and the match on page 2
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
  *"api.github.com/repos/empty-nightly/repo/releases?per_page=100&page="* | \
    *"api.github.com/repos/empty-nightly/repo/releases?per_page=1")
    echo '[]'
    ;;
  # The first release, which tells a list from an empty one
  *"api.github.com/repos/"*"/releases?per_page=1")
    echo '[{"tag_name": "v0.1", "published_at": "2026-01-01T00:00:00Z"}]'
    ;;
  # Pattern B+D: release names and tags that hold a double quote
  *api.github.com/repos/owner/quoted-repo/releases\?per_page=20)
    echo '[{"tag_name": "v1.0.0", "name": "Stable"}, {"tag_name": "v2.0.0", "name": "Beta \"b\""}, {"tag_name": "nightly-\"q\"-2026-04-01", "name": "Nightly"}]'
    ;;
  # Pattern B: a tag that holds two dates
  *api.github.com/repos/owner/two-dates/releases\?per_page=20)
    echo '[{"tag_name": "build-2026-11-04-from-2026-11-01", "name": "Build"}]'
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
  # Tags with # and %, which the strategies encode in the path
  *api.github.com/repos/*/releases/tags/models%232026)
    echo '{"tag_name": "models#2026", "assets": [{"name": "voice-a.tar.bz2", "updated_at": "2025-12-02T06:55:38Z"}]}'
    ;;
  *api.github.com/repos/*/releases/tags/nightly%25x)
    printf '{"tag_name": "nightly%%x", "body": "NVIM v0.12.0-dev+2713+g925e9e8722", "published_at": "2026-03-27T05:43:19Z"}'
    ;;

  # --- tag_version_regex test patterns (must be before wildcards) ---

  # Custom prefix tag format
  *"api.github.com/repos/custom-prefix/repo/releases?per_page=100&page=1")
    echo '[{"tag_name": "MeshLab-2025.07", "published_at": "2025-07-01T00:00:00Z", "prerelease": false}]'
    ;;
  # Custom suffix tag format
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
  # Dev builds as microsoft/nvx publishes them, one pre-release per commit: the tags
  # hold a commit hash, so only published_at orders them
  *"api.github.com/repos/dev-owner/dev-repo/releases?per_page=100&page=1")
    echo '[{"tag_name": "v0.1.0-dev.1a2b3c4d5e6f", "published_at": "2026-11-16T06:05:53Z", "prerelease": true}, {"tag_name": "v0.1.0-dev.0f9e8d7c6b5a", "published_at": "2026-11-16T09:48:25Z", "prerelease": true}, {"tag_name": "v0.1.0-dev.9c8b7a6f5e4d", "published_at": "2026-11-16T03:34:04Z", "prerelease": true}]'
    ;;
  # Several products in one repository, as tutao/tutanota: an older match
  # first in the API order, a newer pre-release and a draft of the product
  *"api.github.com/repos/multi-product/repo/releases?per_page=100&page=1")
    echo '[{"tag_name": "app-desktop-release-361.0", "published_at": "2026-10-12T08:34:32Z", "prerelease": false}, {"tag_name": "app-web-release-362.0", "published_at": "2026-10-21T08:32:50Z", "prerelease": false}, {"tag_name": "app-desktop-release-363.0", "published_at": "2026-10-22T00:00:00Z", "prerelease": true}, {"tag_name": "app-desktop-release-362.0", "published_at": "2026-10-21T08:33:13Z", "prerelease": false}, {"tag_name": "app-desktop-release-364.0", "published_at": null, "prerelease": false}]'
    ;;
  # Maintenance release of the old line, published after the new line,
  # and a tag that gives an empty version
  *"api.github.com/repos/maint-line/repo/releases?per_page=100&page=1")
    echo '[{"tag_name": "v", "published_at": "2026-10-26T00:00:00Z", "prerelease": false}, {"tag_name": "v2.1.0-rc1", "published_at": "2026-10-25T00:00:00Z", "prerelease": true}, {"tag_name": "v1.9.5", "published_at": "2026-10-20T00:00:00Z", "prerelease": false}, {"tag_name": "v2.0.1", "published_at": "2026-10-01T00:00:00Z", "prerelease": false}, {"tag_name": "v2.0.0", "published_at": "2026-09-20T00:00:00Z", "prerelease": false}]'
    ;;
  # /releases/latest answers 404 when every release is a pre-release, as
  # for FreeTubeApp/FreeTube, and when there is no release at all
  *api.github.com/repos/prerelease-only/repo/releases/latest | \
    *api.github.com/repos/no-releases/repo/releases/latest | \
    *api.github.com/repos/stable-list/repo/releases/latest)
    http_error 404
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
    *codeberg.org/api/v1/repos/dated-owner/dated-repo/tags"?limit=50")
    echo '[{"name": "2025-12-27"}, {"name": "v2025-02-10"}, {"name": "2026-09-10"}]'
    ;;
  # Tags with a prefix, as mesa names its releases
  *gitlab.com/api/v4/projects/prefix-group%2Fprefix-project/repository/tags* | \
    *codeberg.org/api/v1/repos/prefix-owner/prefix-repo/tags"?limit=50")
    echo '[{"name": "mesa-26.2.5"}, {"name": "mesa-26.3.0-rc1"}, {"name": "mesa-26.1.0"}]'
    ;;
  # Tags of which some are not releases, and tags of which none is
  *gitlab.com/api/v4/projects/mixed-group%2Fmixed-project/repository/tags* | \
    *codeberg.org/api/v1/repos/mixed-owner/mixed-repo/tags"?limit=50")
    echo '[{"name": "latest"}, {"name": "v2.1.0-rc1"}, {"name": "v2.1.0rc2"}, {"name": "v2.0.0"}, {"name": "v1.9.0"}]'
    ;;
  *gitlab.com/api/v4/projects/named-group%2Fnamed-project/repository/tags* | \
    *codeberg.org/api/v1/repos/named-owner/named-repo/tags"?limit=50")
    echo '[{"name": "latest"}, {"name": "nightly"}]'
    ;;

  # Gitea releases. /releases/latest answers 404 when no release is outside
  # drafts and pre-releases, and when there is none.
  *codeberg.org/api/v1/repos/no-releases/repo/releases/latest | \
    *codeberg.org/api/v1/repos/prerelease-only/repo/releases/latest | \
    *codeberg.org/api/v1/repos/broken/repo/releases/latest)
    http_error 404
    ;;
  *"codeberg.org/api/v1/repos/no-releases/repo/releases?limit=1" | \
    *"codeberg.org/api/v1/repos/empty/repo/releases?limit=50&page=1" | \
    *"codeberg.org/api/v1/repos/prerelease-only/repo/releases?limit=50&page=2")
    echo '[]'
    ;;
  *"codeberg.org/api/v1/repos/prerelease-only/repo/releases?limit=1" | \
    *"codeberg.org/api/v1/repos/prerelease-only/repo/releases?limit=50&page=1")
    echo '[{"tag_name": "v2.0.0-rc1", "prerelease": true, "draft": false}]'
    ;;
  # Two products in one repository, a pre-release and a draft newer than
  # every release, and the newest release on the second page
  *"codeberg.org/api/v1/repos/multi-product/repo/releases?limit=50&page=1")
    echo '[{"tag_name": "app-web-release-370.0", "prerelease": false, "draft": false}, {"tag_name": "app-desktop-release-367.0", "prerelease": true, "draft": false}, {"tag_name": "app-desktop-release-366.0", "prerelease": false, "draft": true}, {"tag_name": "app-desktop-release-361.0", "prerelease": false, "draft": false}]'
    ;;
  *"codeberg.org/api/v1/repos/multi-product/repo/releases?limit=50&page=2")
    echo '[{"tag_name": "app-desktop-release-365.0", "prerelease": false, "draft": false}]'
    ;;
  *"codeberg.org/api/v1/repos/multi-product/repo/releases?limit=50&page=3")
    echo '[]'
    ;;
  # Release list without an end: page N holds v1.N.0
  *"codeberg.org/api/v1/repos/endless/repo/releases?limit=50&page="*)
    printf '[{"tag_name": "v1.%s.0", "prerelease": false, "draft": false}]\n' "${url##*page=}"
    ;;

  # Releases of savonet/liquidsoap: v2.4.6 with builds for two OCaml versions, v2.5.0-rc1 for one.
  # MOCK_RELEASE_AGE (hours), MOCK_RELEASE_DATE, MOCK_ASSETS and MOCK_RELEASE_STATUS set v2.5.0-rc1.
  *api.github.com/repos/asset-owner/asset-repo/releases/tags/v2.4.6)
    printf '{"tag_name": "v2.4.6", "published_at": "2026-10-09T13:47:40Z", "assets": [%s]}\n' \
      '{"name": "liquidsoap_2.4.6-debian-forky-ocaml4.14.2-3_amd64.deb"}, {"name": "liquidsoap_2.4.6-debian-forky-ocaml5.4.0-3_amd64.deb"}'
    ;;
  *api.github.com/repos/asset-owner/asset-repo/releases/tags/v2.5.0-rc1)
    [[ "${MOCK_RELEASE_STATUS:-200}" == 200 ]] || http_error "$MOCK_RELEASE_STATUS"
    sep=""
    assets=""
    for name in ${MOCK_ASSETS-liquidsoap_2.5.0-debian-forky-ocaml5.5.1-1_amd64.deb liquidsoap_2.5.0-debian-forky-ocaml5.5.1-1_arm64.deb liquidsoap-minimal_2.5.0-debian-forky-ocaml5.5.1-1_amd64.deb liquidsoap_2.5.0-debian-trixie-ocaml5.5.1-1_amd64.deb}; do
      assets+="$sep{\"name\": \"$name\"}"
      sep=", "
    done
    printf '{"tag_name": "v2.5.0-rc1", "published_at": "%s", "assets": [%s]}\n' \
      "${MOCK_RELEASE_DATE:-$(date -u -d "-${MOCK_RELEASE_AGE:-48} hours" +%Y-%m-%dT%H:%M:%SZ)}" "$assets"
    ;;
  # GitHub answers 404 for a tag without a release, as for a draft
  *api.github.com/repos/asset-owner/asset-repo/releases/tags/*)
    http_error 404
    ;;
  # The commit of a tag, dated MOCK_TAG_DATE or MOCK_TAG_AGE hours back (48
  # by default); MOCK_COMMIT_STATUS=500 fails the request
  *api.github.com/repos/asset-owner/asset-repo/commits/*)
    [[ "${MOCK_COMMIT_STATUS:-200}" == 200 ]] || http_error "$MOCK_COMMIT_STATUS"
    printf '{"commit": {"committer": {"date": "%s"}}}\n' \
      "${MOCK_TAG_DATE:-$(date -u -d "-${MOCK_TAG_AGE:-48} hours" +%Y-%m-%dT%H:%M:%SZ)}"
    ;;
  # The release of a tag with a plus sign, only under the encoded name
  *api.github.com/repos/asset-owner/plus-repo/releases/tags/v1.0%2B1)
    echo '{"tag_name": "v1.0+1", "published_at": "2026-10-01T00:00:00Z", "assets": [{"name": "plus_1.0-build7.tar.gz"}]}'
    ;;

  # The latest release of aurtomator itself: the tag in MOCK_UPSTREAM_TAG,
  # v0.6.0 by default, or a failed request for "fail"
  *api.github.com/repos/staticwire/aurtomator/releases/latest)
    [[ "${MOCK_UPSTREAM_TAG:-v0.6.0}" != fail ]] || http_error 404
    printf '{"tag_name": "%s"}\n' "${MOCK_UPSTREAM_TAG:-v0.6.0}"
    ;;

  # --- Normal success patterns (wildcards) ---

  # GitHub Release API
  *api.github.com/repos/*/releases/latest)
    echo '{"tag_name": "v2.0.0"}'
    ;;
  # GitLab Tags API
  *gitlab.com/api/v4/projects/*/repository/tags"?per_page=100")
    echo '[{"name": "v3.1.0"}, {"name": "v3.0.0"}, {"name": "v2.0.0"}]'
    ;;
  # Gitea Tags API
  *codeberg.org/api/v1/repos/*/tags"?limit=50")
    echo '[{"name": "v1.5.0"}, {"name": "v1.4.0"}]'
    ;;
  # Gitea Releases API
  *codeberg.org/api/v1/repos/*/releases/latest)
    echo '{"tag_name": "v2.4.0", "prerelease": false, "draft": false}'
    ;;
  # PyPI JSON API
  *pypi.org/pypi/*/json)
    echo '{"info": {"version": "3.2.1", "requires_dist": null}}'
    ;;
  # npm registry
  *registry.npmjs.org/*/latest)
    echo '{"version": "4.0.0"}'
    ;;
  # Crate whose highest version is a pre-release, as pijul
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
    echo '{"results": [{"repo": "extra", "epoch": 0, "pkgver": "6.10.2", "pkgrel": "1"}]}'
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
  printf '\n%s' "${effective_url:-$url}" >&"$stdout_fd"
fi
