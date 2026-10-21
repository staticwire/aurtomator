# Contributing to aurtomator

aurtomator is a template repository: you fork it and run your own instance. Upstream contributions are welcome and optional.

## Before opening a PR

For anything beyond a typo or a one-line fix, open an issue or a draft PR first to agree on the direction.

A general-purpose build bot, a CI-hosted package build service or a multi-user orchestration system is out of scope. The "Alternatives" section of `README.md` lists tools for that.

## Development setup

```sh
sudo pacman -S --needed git bash shellcheck shfmt bats go-yq
git clone https://github.com/staticwire/aurtomator.git
cd aurtomator
bats tests/ --recursive
```

`namcap` is optional. Two tests skip without it, unless `CI` is set: CI installs `namcap`, so there they fail.

## Conventions

- Bash 5+ with `set -euo pipefail` at the top of every script.
- Functions in `snake_case`, globals in `UPPER_SNAKE`, function-local variables declared with `local`.
- Double-quote every expansion: `"$var"`, `"${array[@]}"`.
- Scripts are `shellcheck` clean and formatted with `shfmt -i 2 -ci`.
- Every new script in `scripts/` and every new strategy in `strategies/` comes with BATS tests. Strategy tests mock the API responses, and the suite makes no network requests.
- Commit messages follow Conventional Commits with a component scope, for example `feat(strategy): add forgejo-tag detection` or `fix(scripts): handle empty version output`.
- GitHub Actions are pinned by commit SHA with a trailing version comment: `uses: actions/checkout@abc1234def5678... # v4.1.7`.

## Running the full check locally

CI runs these commands:

```sh
shellcheck -x -S warning scripts/*.sh strategies/*.sh
shfmt -d -i 2 -ci scripts/*.sh strategies/*.sh
actionlint
bats tests/ --recursive
```

CI runs the suite under bashcov, as `bashcov -- bats tests/ --recursive`. bashcov passes `errexit`, `nounset` and `pipefail` to every script a test starts, so a mock has to work under `set -euo pipefail`.

## PR workflow

PRs are squash-merged. The squash commit subject on `main` must follow Conventional Commits with a scope, so write the PR title and the commit subjects that way. A PR titled `fix strategy bug` is renamed to something like `fix(strategy): handle empty release list from github-release` before it is merged.

Keep PRs focused: one logical change per PR. Unrelated refactors go in a separate PR.

## Adding a new strategy

1. Create `strategies/<name>.sh`. It takes the package name as its only argument, reads the package config with `pkg_get`, prints one version string to stdout and exits non-zero on failure. Start from the closest existing strategy.
2. Add the name to `VALID_STRATEGIES` in `scripts/validate-pkg.sh`, together with any required fields.
3. Add tests to `tests/strategies.bats`, grouped by strategy, and the API fixtures they need to `tests/helpers/mock-curl.sh`.
4. Document the strategy in the strategies table in `README.md` and in `docs/WORKFLOW.md`.
5. Add a usage example to `packages/example.yml.sample`.
6. Run the full local check before opening the PR.

## Reporting bugs

Use the "Bug report" or "New strategy request" issue template. Security issues are never filed as public issues: follow `SECURITY.md`.
