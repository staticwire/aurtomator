---
title: Custom strategies
---

Your repository holds no strategies. A run takes them from `strategies/` of aurtomator at the pinned SHA, so a new strategy comes into aurtomator by a pull request, as `CONTRIBUTING.md` describes. A strategy is a bash script in `strategies/` that finds the latest upstream version of a package.

## Interface contract

- **Input:** one positional argument, the package name.
- **Success:** the version on stdout as one line, exit code 0.
- **Failure:** an error on stderr, a non-zero exit code.
- **Version format:** `check-update.sh` rejects a version with any character outside `A-Za-z0-9._+`, a version of more than 64 characters, and a version without a digit, such as `latest`. `pkgver_dash` replaces the dashes before that check, see [Package YAML](/package-yaml/).

The script can rely on `yq` and `curl`. `scripts/lib/common.sh` provides YAML helpers, `http_get` for requests and logging. It sets `AURTOMATOR_DIR` to the root of the checkout of aurtomator and `AURTOMATOR_DATA_DIR` to the directory with the packages, see [Prerequisites](/develop/local-testing/#prerequisites).

## Template

```bash
#!/usr/bin/env bash
#
# my-strategy - Detect latest version from <source>
#
# Input: package name (reads upstream config from package YAML)
# Output: latest version string

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

1. **Location:** `strategies/<name>.sh`, executable (`chmod +x`). `<name>` is the value of the YAML `strategy` field.
2. **Header:** `set -euo pipefail`, then source `scripts/lib/common.sh` for `pkg_file`, `pkg_get` and logging. `tests/strategies.bats` runs every strategy with `common.sh` as the only file of `scripts/`.
3. **HTTP:** `http_get <url> [curl option]...` from `common.sh`. It runs `curl -sfL --max-time 30` and tries a timeout, a refused connection and an HTTP 408, 429, 500, 502, 503, 504, 522 or 524 answer twice more, 5 seconds apart. `-f` fails on HTTP errors and `-L` follows redirects, over https only: `--proto '=https' --proto-redir '=https'`. An answer is at most `MAX_ANSWER_MB` megabytes, 50 by default, through `--max-filesize`, and an option of the caller comes after these and wins. Every request sends the User-Agent in `USER_AGENT`, `aurtomator/1.0` by default. A failed request prints the URL of the last answer and the error of curl to stderr, and names a Cloudflare challenge, which only a browser passes. In a run of `check-all.sh`, `http_get` remembers the host of a request that ends with curl exit 28 and the status `000`, and fails a later request to that host at once ([Update process](/internals/update-process/)). `http_get_json` fails also on an answer that is not a JSON object or array, such as the HTML page of a bot check after a redirect, and names the URL of that answer. A test in `tests/strategies.bats` fails when a strategy calls `curl` itself.
4. **Result:** check for an empty string and for `null` from `yq`.
5. **Prefix:** strip a leading `v` with `${version#v}` when upstream tags look like `v1.0.0`.
6. **Validation:** in `scripts/validate-pkg.sh`, add a line to `UPSTREAM_KEYS` with the `upstream` keys the strategy reads, at its place in the strategy table of `README.md`, and the checks of its required fields. Without the line, `validate-pkg.sh` refuses every YAML of the strategy that has an `upstream` key, and `tests/validate-pkg.bats` fails. The name of the strategy needs no entry: every script in `strategies/` is a valid strategy.
7. **Tests:** add the API fixture to `tests/helpers/mock-curl.sh` and tests to `tests/strategies.bats`.
8. **Linters:**

   ```bash
   shellcheck -x -S warning strategies/my-strategy.sh
   shfmt -d -i 2 -ci strategies/my-strategy.sh
   ```

9. **Docs:** the strategies table in `README.md`, a section in `site/src/content/docs/strategies.md`, and an example in `packages/example.yml.sample`.

## Functions in lib/common.sh

| Function                        | Description                                         |
|---------------------------------|-----------------------------------------------------|
| `resolve_data_dir`              | Sets `AURTOMATOR_DATA_DIR` to the absolute path of its value, or of the working directory when it is unset or empty, and exits 1 when that is no directory. `common.sh` runs it when it is sourced |
| `pkg_file <name>`               | Resolves `packages/<name>.yml`, returns 1 if missing |
| `pkg_get <file> <yq-query>`     | Reads a field from a YAML file with yq              |
| `pkg_set <file> <query> <val>`  | Writes a field to a YAML file with yq               |
| `pkg_set_current <file> <version> [asset value]` | Writes `current` and, with an asset value, `current_asset` |
| `pkgver_dash <file>`            | Prints the `pkgver_dash` of a package: `_`, `.`, `drop` for `''`, or nothing |
| `to_pkgver <version> <dash> <format>` | Prints the pkgver of an upstream version, with `pkgver_dash` and `pkgver_format` applied. `<dash>` is the output of `pkgver_dash`, and an empty `<dash>` or `<format>` leaves that step out |
| `pkg_asset_var <file>`          | Prints the `upstream.asset_var` of a package or nothing, returns 1 for a name that is not a variable name starting with `_` |
| `require_cmd <cmd>`             | Exits 1 if the command is not in `PATH`             |
| `http_get <url> [curl option]...` | Fetches a URL with `curl`, see [Checklist](#checklist)                |
| `http_get_json <url> [curl option]...` | `http_get` for an API that answers JSON, see [Checklist](#checklist) |
| `github_api <url>`              | `http_get` with an `Authorization` header from `GITHUB_TOKEN` when it is set |
| `github_release_matching <api> <ere> <pages> [stable] [version] [template]` | Prints a release whose tag matches the ERE, as JSON, from the pages of 100 releases up to the first one with fewer than 100, at most `<pages>` pages: the one published last, or with `version` the one with the newest version that the template gives. `stable` leaves out pre-releases. The arguments keep their places, so a call with `version` and without `stable` passes an empty fourth argument |
| `github_tags <owner/repo>`      | `remote_tags` of a GitHub repository, with `GITHUB_TOKEN` when it is set |
| `validate_pkgver <version>`     | Returns 1 for an empty version, one of more than 64 characters, one with a character outside `A-Za-z0-9._+` or one without a digit |
| `validate_asset_value <value>`  | Returns 1 for a value that does not start with a letter or a digit, or holds a character outside `A-Za-z0-9._+~-` |
| `check_asset_option <asset_var> <value>` | Returns 1 when a package with `asset_var` gets no `--asset`, another package gets one, or `validate_asset_value` refuses the value |
| `version_jump <current> <new>`  | Returns 0 when the first number of the new version has at least two digits more than the first number of the current one |
| `valid_date <date>`             | Succeeds when the date is a real date in the form `YYYY-MM-DD` |
| `cooldown_until <file>`         | Prints the first day, `YYYY-MM-DD`, on which the package may be pushed again, or nothing when it has no cooldown or no `last_updated`. Returns 1 when `cooldown_days` or `last_updated` is not valid |
| `remote_tags <url>`             | Prints every tag name of a git repository from `git ls-remote`, over `https` only and without a terminal prompt |
| `release_tags <tags>`           | Prints the tags of the form `v1.2.3` or `1.2.3`, one per line |
| `tag_version_fill <template>`   | Prints the template with `\1` to `\9` replaced by the groups in `BASH_REMATCH`, returns 1 for a group the last match does not have |
| `tag_versions <ere> [template]` | Prints the version in each tag of stdin: the template filled from the groups of the ERE (default: `\1`), or the tag without a leading `v` when the ERE is empty |
| `newest_version`                | Prints the newest of the versions on stdin by `vercmp`, with a dash before a letter dropped and any other dash read as a dot |
| `latest_tag_version <tags> <ere> [template]` | Prints the highest version among the tags, filtered as the tag strategies filter them |
| `capture_matches <ere>`         | Prints the first capture group of every match of the ERE in stdin |
| `ere_valid <ere>`               | Succeeds when bash can compile the ERE              |
| `pcre_valid <regex>`            | Succeeds when `grep -P` can compile the Perl regex  |
| `log_ok <msg>`                  | Prints a green check mark and the message to stderr |
| `log_warn <msg>`                | Prints a yellow `!` and the message to stderr       |
| `log_err <msg>`                 | Prints a red cross and the message to stderr        |
| `log_info <msg>`                | Prints a bold arrow and the message to stderr       |

The logging functions write to stderr and omit ANSI colors when stderr is not a terminal.

## YAML conventions for custom strategies

Put the settings of the strategy under `upstream`, with descriptive names. List them in the header of the strategy script and in the line of the strategy in `UPSTREAM_KEYS`, see [Checklist](#checklist). `validate-pkg.sh` refuses an `upstream` key that the strategy of the package does not read, see [Package YAML](/package-yaml/).

```yaml
name: my-package
strategy: my-strategy
upstream:
  my_field: some-value
  another_field: another-value
```
