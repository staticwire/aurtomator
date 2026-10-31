# Contributing to aurtomator

aurtomator holds the scripts, the strategies and the reusable workflows. A user repository, created from the template [staticwire/aurtomator-seed](https://github.com/staticwire/aurtomator-seed), holds the package YAMLs and calls the workflows of aurtomator at a pinned SHA, see [docs/SETUP.md](docs/SETUP.md#the-calling-workflows). A run takes the scripts and the strategies from aurtomator at that SHA, so a fix or a new strategy comes here by pull request.

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
- Scripts are `shellcheck` clean. Scripts and tests are formatted with `shfmt -i 2 -ci`.
- Every new script in `scripts/` and every new strategy in `strategies/` comes with BATS tests. Strategy tests mock the API responses, and the suite makes no network requests.
- Commit messages follow Conventional Commits with a component scope, for example `feat(strategy): add forgejo-tag detection` or `fix(scripts): handle empty version output`.
- GitHub Actions are pinned by commit SHA with a trailing version comment: `uses: actions/checkout@abc1234def5678... # v4.1.7`.

## Running the full check locally

CI runs these commands:

```sh
shellcheck -x -S warning scripts/*.sh scripts/lib/*.sh strategies/*.sh tests/helpers/*.sh
shfmt -d -i 2 -ci scripts/*.sh scripts/lib/*.sh strategies/*.sh tests/*.bats tests/helpers/*.sh
actionlint
for action in .github/actions/*/action.yml; do yq '.runs.steps[] | select(has("run")) | .run' "$action" | shellcheck -s bash -; done
./scripts/validate-pkg.sh --all
bats tests/ --recursive
```

CI runs the suite under bashcov, as `bashcov -- tests/helpers/bashcov-bats.sh tests/ --recursive`. bashcov passes `errexit`, `nounset` and `pipefail` to every script a test starts, so a mock has to work under `set -euo pipefail`.

`ci.yml` also calls the reusable workflows of the same commit: the job `validate` calls `validate.yml`, and the job `pipeline` calls `check-updates.yml` with aurtomator itself as the repository of the packages, see [docs/WORKFLOW.md section 6.4](docs/WORKFLOW.md#64-validate-and-pipeline-jobs). A pull request from a fork of aurtomator gets a read-only token, so `pipeline` runs only for a push and for a pull request from a branch of aurtomator.

## PR workflow

PRs are squash-merged. The squash commit subject on `main` must follow Conventional Commits with a scope, so write the PR title and the commit subjects that way. A PR titled `fix strategy bug` is renamed to something like `fix(strategy): handle empty release list from github-release` before it is merged.

Keep PRs focused: one logical change per PR. Unrelated refactors go in a separate PR.

## Releases

aurtomator follows semantic versioning, and `VERSION` holds the version of the code. After a merge to `main`, release-please (`.github/workflows/release-please.yml`) opens or updates a release PR from the commit types since the last release: `fix` raises the patch number, `feat` the minor one, and before 1.0.0 a breaking change raises the minor one too. A `!` after the type and scope marks a breaking change, as in `feat(workflow)!: run as a reusable workflow`. A `docs`, `ci`, `chore` or `test` commit opens no release PR and goes out with the next release. The release PR writes the new version to `VERSION`. Its merge tags `vX.Y.Z` and publishes the release with the notes GitHub generates from the merged PRs. A line `Release-As: X.Y.Z` in the body of a squash commit sets another number.

The workflow runs release-please with the token of a GitHub App installed on the repository, with read and write access to contents, issues and pull requests. It creates the token from the variable `RELEASE_APP_CLIENT_ID` and the secret `RELEASE_APP_PRIVATE_KEY`. With the workflow token instead, GitHub would run the CI of the release PR only after someone with write access approves it.

## Adding a new strategy

1. Create `strategies/<name>.sh`. It takes the package name as its only argument, reads the package config with `pkg_get`, prints one version string to stdout and exits non-zero on failure. Start from the closest existing strategy.
2. In `scripts/validate-pkg.sh`, add a line to `UPSTREAM_KEYS` with the `upstream` keys the strategy reads, at its place in the strategy table of `README.md`, and the checks of its required fields. Without the line, `validate-pkg.sh` refuses every YAML of the strategy that has an `upstream` key. The name of the strategy needs no entry: every script in `strategies/` is a valid strategy.
3. Add tests to `tests/strategies.bats`, grouped by strategy, and the API fixtures they need to `tests/helpers/mock-curl.sh`.
4. Document the strategy in the strategies table in `README.md` and in `docs/WORKFLOW.md`.
5. Add a usage example to `packages/example.yml.sample`.
6. Run the full local check before opening the PR.

## Reporting bugs

Use the "Bug report" or "New strategy request" issue template. Security issues are never filed as public issues: follow `SECURITY.md`.
