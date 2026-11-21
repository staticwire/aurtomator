---
title: Custom strategies
---

Strategies are bash scripts in `strategies/` of aurtomator that print the latest upstream version of a package. Your repository holds no strategies: runs take them from aurtomator at the pinned commit, so new strategies come in through pull requests to aurtomator, see `CONTRIBUTING.md`.

## Contract

- Input: one argument, the package name.
- Success: the version on stdout as one line, exit code 0.
- Failure: error on stderr, non-zero exit code.
- Version: after `pkgver_dash` replaces the dashes, `check-update.sh` refuses versions of more than 64 characters, without digits, or with characters outside `A-Za-z0-9._+`, see [Package YAML](/package-yaml/).

Scripts can use `yq`, `curl` and the `scripts/lib/common.sh` functions below. `common.sh` sets `AURTOMATOR_DIR` to the aurtomator checkout and `AURTOMATOR_DATA_DIR` to the directory with `packages/`, see [Prerequisites](/develop/local-testing/#prerequisites).

## Template

```bash
#!/usr/bin/env bash
# my-strategy - Print the latest version from <source>, see https://aurtomator.dev/strategies/

set -euo pipefail

readonly NAME="${1:?Usage: my-strategy.sh <package-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=../scripts/lib/common.sh
source "${SCRIPT_DIR}/../scripts/lib/common.sh"

pkg_file=$(pkg_file "$NAME")
my_field=$(pkg_get "$pkg_file" .upstream.my_field)

version=$(http_get "https://example.com/api/${my_field}" |
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

## Checklist

1. The script is `strategies/<name>.sh` and executable, where `<name>` is the value of `strategy` in the YAML.
2. It starts with `set -euo pipefail` and sources `scripts/lib/common.sh`, the one file of `scripts/` that `tests/strategies.bats` gives strategies.
3. It sends its requests through `http_get` or `http_get_json`. One test in `tests/strategies.bats` fails when strategies call `curl` themselves.
4. It checks the result for empty strings and for `null` from `yq`, and strips the leading `v` with `${version#v}` where tags look like `v1.0.0`.
5. Its settings stand under `upstream` and in its line of `UPSTREAM_KEYS` in `scripts/validate-pkg.sh`, at its place in the strategy table of `README.md`, with checks of its required fields beside it. Without the line, `validate-pkg.sh` refuses every YAML of the strategy that has `upstream` keys.
6. `tests/helpers/mock-curl.sh` gets the API fixture, and `tests/strategies.bats` the tests.
7. `shellcheck -x -S warning strategies/<name>.sh` and `shfmt -d -i 2 -ci strategies/<name>.sh` pass.
8. The strategy table of `README.md` and `site/src/content/docs/strategies.md` describe it.

## Functions of common.sh

`http_get <url> [curl option]...` runs `curl -sfL --max-time 30` over `https` only, redirects included, and retries timeouts, refused connections and HTTP 408, 429, 500, 502, 503, 504, 522 and 524 answers twice, 5 seconds apart or after the wait of a `Retry-After` header, and starts no retry later than 75 seconds after the first attempt. It reads at most `MAX_ANSWER_MB` megabytes and sends the User-Agent of `USER_AGENT`. Failures print the URL and the curl error and name Cloudflare challenges. In `check-all.sh` runs, hosts that timed out without an answer fail every later request at once. Caller options come after these and win.

| Function | Does |
|---|---|
| `pkg_file <name>` | prints the path of `packages/<name>.yml`, returns 1 when it is missing |
| `pkg_get <file> <yq-query>` | prints one YAML field |
| `require_cmd <cmd>` | exits 1 when the command is not in `PATH` |
| `http_get <url> [curl option]...` | sends requests, see above |
| `http_get_json <url> [curl option]...` | `http_get` that also fails on answers that are no JSON object or array, such as bot check HTML pages |
| `github_api <url>` | `http_get` with the `Authorization` of `GITHUB_TOKEN` when it is set |
| `github_tags <owner/repo>` | `remote_tags` for GitHub repositories |
| `github_release_matching <api> <ere> <pages> [stable] [version] [template]` | prints the release whose tag matches the ERE as JSON: the one published last, or with `version` the one with the newest version. `stable` leaves out pre-releases. Arguments keep their place, so calls with `version` and without `stable` pass an empty fourth one |
| `remote_tags <url>` | prints every tag of a git repository, from `git ls-remote` over `https`, and fails on a listing of more than `MAX_ANSWER_MB` megabytes |
| `tag_versions <ere> [template]` | prints the version in each tag of stdin: the template filled from the groups of the ERE, `\1` by default, or the tag without a leading `v` for an empty ERE |
| `latest_tag_version <tags> <ere> [template]` | prints the highest version among the tags, filtered as the tag strategies filter them |
| `newest_version` | prints the newest version of stdin by `vercmp` |
| `capture_matches <ere>` | prints the first capture group of each match of the ERE in stdin |
