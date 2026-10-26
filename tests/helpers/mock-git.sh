#!/usr/bin/env bash
# Mock git for BATS tests
# Answers ls-remote with predefined tags based on the repository URL and
# runs the real git for every other command. Each ls-remote appends its
# arguments to $TEST_TMPDIR/ls-remote.args and its GIT_* variables to
# $TEST_TMPDIR/ls-remote.env.

if [[ "${1:-}" != ls-remote ]]; then
  exec /usr/bin/git "$@"
fi

echo "$*" >>"$TEST_TMPDIR/ls-remote.args"
env | grep '^GIT_' | sort >>"$TEST_TMPDIR/ls-remote.env"

tags=()
case "${*: -1}" in
  https://github.com/empty-owner/empty-repo.git) ;;
  https://github.com/missing-owner/missing-repo.git)
    echo "fatal: could not read Username for 'https://github.com': terminal prompts disabled" >&2
    exit 128
    ;;
  # 250 build tags ahead of the releases, as in GrapheneOS/hardened_malloc
  https://github.com/paged-owner/paged-repo.git)
    mapfile -t tags < <(printf 'TQ3A.230605.%03d\n' {1..250})
    tags+=(13 14)
    ;;
  https://github.com/custom-prefix/repo.git)
    tags=(bun-v1.3.11 bun-v1.2.0 bun-v1.0.0)
    ;;
  https://github.com/dated-owner/dated-repo.git)
    tags=(2025-12-27 v2025-02-10 2026-09-10)
    ;;
  https://github.com/mixed-owner/mixed-repo.git)
    tags=(latest v2.1.0-rc1 v2.1.0rc2 v2.0.0 v1.9.0)
    ;;
  https://github.com/named-owner/named-repo.git)
    tags=(latest nightly)
    ;;
  # Pre-releases glued to the number, which sort -V puts above the release
  https://github.com/rc-owner/glued-repo.git)
    tags=(v2.0.0 v2.1.0 v2.1.0beta1 v2.1.0rc2)
    ;;
  # A pre-release after a dash, listed after its release
  https://github.com/rc-owner/dash-repo.git)
    tags=(v2.1.0 v2.1.0-rc1)
    ;;
  # The tags of savonet/liquidsoap around 2.5.0-rc1, and a release
  # candidate without a release
  https://github.com/asset-owner/asset-repo.git)
    tags=(v2.4.5 v2.4.6 v2.5.0-rc1 v2.5.0-rc2 rolling-release-v2.5.x)
    ;;
  # Two tags of one version
  https://github.com/asset-owner/twin-repo.git)
    tags=(v1.0.0 1.0.0)
    ;;
  # A tag with a plus sign, which a URL path has to encode
  https://github.com/asset-owner/plus-repo.git)
    tags=(v1.0+1)
    ;;
  https://github.com/*)
    tags=(v2.0.0 v1.9.0 v1.0.0)
    ;;
  # A host without a tags API, as git.sr.ht for wvkbd
  https://git.example.org/~owner/repo)
    tags=(v0.9 v0.19 v0.20 latest)
    ;;
  https://git.example.org/~owner/prefixed)
    tags=(release-1.2 release-1.10 release-1.9)
    ;;
  https://git.example.org/~owner/empty) ;;
  *)
    echo "fatal: unexpected repository ${*: -1}" >&2
    exit 128
    ;;
esac

for tag in "${tags[@]}"; do
  printf '%040d\trefs/tags/%s\n' 0 "$tag"
done
