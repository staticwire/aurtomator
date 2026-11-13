---
title: Custom strategies
---

A strategy is a bash script in `strategies/` of aurtomator that prints the latest upstream version of a package. Your repository holds no strategies: a run takes them from aurtomator at the pinned commit, so a new strategy comes in through a pull request to aurtomator, see `CONTRIBUTING.md`.

## Contract

- Input: one argument, the package name.
- Success: the version on stdout as one line, exit code 0.
- Failure: an error on stderr, a non-zero exit code.
- Version: after `pkgver_dash` replaces the dashes, `check-update.sh` refuses a version of more than 64 characters, without a digit, or with a character outside `A-Za-z0-9._+`, see [Package YAML](/package-yaml/).

The script can use `yq`, `curl` and the functions of `scripts/lib/common.sh` below. `common.sh` sets `AURTOMATOR_DIR` to the checkout of aurtomator and `AURTOMATOR_DATA_DIR` to the directory with `packages/`, see [Prerequisites](/develop/local-testing/#prerequisites).

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
2. It starts with `set -euo pipefail` and sources `scripts/lib/common.sh`, the one file of `scripts/` that `tests/strategies.bats` gives a strategy.
3. It sends its requests through `http_get` or `http_get_json`. A test in `tests/strategies.bats` fails when a strategy calls `curl` itself.
4. It checks the result for an empty string and for `null` from `yq`, and strips a leading `v` with `${version#v}` where tags look like `v1.0.0`.
5. Its settings stand under `upstream` and in its line of `UPSTREAM_KEYS` in `scripts/validate-pkg.sh`, at its place in the strategy table of `README.md`, with the checks of its required fields beside it. Without the line, `validate-pkg.sh` refuses every YAML of the strategy that has an `upstream` key.
6. `tests/helpers/mock-curl.sh` gets the API fixture, and `tests/strategies.bats` the tests.
7. `shellcheck -x -S warning strategies/<name>.sh` and `shfmt -d -i 2 -ci strategies/<name>.sh` pass.
8. The strategy table of `README.md` and `site/src/content/docs/strategies.md` describe it.

## Functions of common.sh

`http_get <url> [curl option]...` runs `curl -sfL --max-time 30` over `https` only, redirects included, and tries a timeout, a refused connection and an HTTP 408, 429, 500, 502, 503, 504, 522 or 524 answer twice more, 5 seconds apart. It reads at most `MAX_ANSWER_MB` megabytes and sends the User-Agent of `USER_AGENT`. A failure prints the URL and the error of curl and names a Cloudflare challenge. In a run of `check-all.sh`, a host that timed out without an answer fails every later request at once. An option of the caller comes after these and wins.

| Function | Does |
|---|---|
| `pkg_file <name>` | prints the path of `packages/<name>.yml`, returns 1 when it is missing |
| `pkg_get <file> <yq-query>` | prints a field of the YAML |
| `require_cmd <cmd>` | exits 1 when the command is not in `PATH` |
| `http_get <url> [curl option]...` | sends a request, see above |
| `http_get_json <url> [curl option]...` | `http_get` that also fails on an answer that is no JSON object or array, such as the HTML page of a bot check |
| `github_api <url>` | `http_get` with the `Authorization` of `GITHUB_TOKEN` when it is set |
| `github_tags <owner/repo>` | `remote_tags` of a GitHub repository |
| `github_release_matching <api> <ere> <pages> [stable] [version] [template]` | prints the release whose tag matches the ERE as JSON: the one published last, or with `version` the one with the newest version. `stable` leaves out pre-releases. An argument keeps its place, so a call with `version` and without `stable` passes an empty fourth one |
| `remote_tags <url>` | prints every tag of a git repository, from `git ls-remote` over `https` |
| `tag_versions <ere> [template]` | prints the version in each tag of stdin: the template filled from the groups of the ERE, `\1` by default, or the tag without a leading `v` for an empty ERE |
| `latest_tag_version <tags> <ere> [template]` | prints the highest version among the tags, filtered as the tag strategies filter them |
| `newest_version` | prints the newest version of stdin by `vercmp` |
| `capture_matches <ere>` | prints the first capture group of each match of the ERE in stdin |
