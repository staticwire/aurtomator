# Contributing to aurtomator

aurtomator holds the scripts, the strategies and the reusable workflows. A user repository, made from the template [staticwire/aurtomator-seed](https://github.com/staticwire/aurtomator-seed), holds the package YAMLs and calls the workflows of aurtomator at a pinned SHA, see [The calling workflows](https://aurtomator.dev/setup/#the-calling-workflows). A fix or a new strategy therefore comes here by pull request.

## Before opening a PR

For anything beyond a typo or a one-line fix, open an issue or a draft PR first to agree on the direction. A general-purpose build bot, a hosted build service or a multi-user orchestration system is out of scope, and the Alternatives section of `README.md` lists tools for that.

## Development setup

```sh
sudo pacman -S --needed git bash shellcheck shfmt actionlint bats go-yq jq openssh
git clone https://github.com/staticwire/aurtomator.git
cd aurtomator
bats tests/ --recursive
```

`namcap` is optional: two tests skip without it, unless `CI` is set.

## Conventions

- Bash 5+ with `set -euo pipefail` at the top of every script.
- Functions in `snake_case`, globals in `UPPER_SNAKE`, function variables declared with `local`.
- Every expansion in double quotes: `"$var"`, `"${array[@]}"`.
- Scripts pass `shellcheck`, and scripts and tests are formatted with `shfmt -i 2 -ci`.
- A new script in `scripts/` or strategy in `strategies/` comes with BATS tests. Strategy tests mock the API answers, and the suite sends no request to the network.
- Commit messages follow Conventional Commits with a component scope, as `feat(strategy): add forgejo-tag detection` or `fix(scripts): handle empty version output`.
- GitHub Actions are pinned by commit SHA with the version in a comment: `uses: actions/checkout@abc1234def5678... # v4.1.7`.

## Running the full check locally

CI runs these commands:

```sh
shellcheck -x -S warning scripts/*.sh scripts/lib/*.sh strategies/*.sh tests/helpers/*.sh
shfmt -d -i 2 -ci scripts/*.sh scripts/lib/*.sh strategies/*.sh tests/*.bats tests/helpers/*.sh
actionlint
for action in .github/actions/*/action.yml; do yq '.runs.steps[] | select(has("run")) | .run' "$action" | shellcheck -s bash -; done
shellcheck aurtomator.sh
shfmt -d -i 2 -ci aurtomator.sh
./scripts/validate-pkg.sh --all
bats tests/ --recursive
```

CI runs the suite under bashcov, which passes `errexit`, `nounset` and `pipefail` to every script a test starts, so a mock has to work under `set -euo pipefail`. `ci.yml` also calls `validate.yml` and `check-updates.yml` of the same commit, with aurtomator itself as the repository of the packages, see [Validate and pipeline jobs](https://aurtomator.dev/develop/ci/#validate-and-pipeline-jobs). A pull request from a fork gets a read-only token, so the job `pipeline` runs only for a push and for a pull request from a branch of aurtomator.

## PR workflow

PRs are squash-merged, so the PR title becomes the commit subject on `main` and follows Conventional Commits with a scope, as `fix(strategy): handle empty release list from github-release`. One PR holds one logical change, and an unrelated refactor goes into another PR.

## Releases

aurtomator follows semantic versioning, and `VERSION` holds the version of the code. After a merge to `main`, release-please (`.github/workflows/release-please.yml`) opens or updates a release PR from the commit types since the last release: `fix` raises the patch number, `feat` the minor one, and before 1.0.0 a breaking change, marked with `!` as in `feat(workflow)!: run as a reusable workflow`, raises the minor one too. A `docs`, `ci`, `chore` or `test` commit opens no release PR and goes out with the next release. The release PR writes `VERSION`, and its merge tags `vX.Y.Z` and publishes the release with the notes GitHub generates. A line `Release-As: X.Y.Z` in the body of a squash commit sets another number.

release-please runs with the token of a GitHub App of the repository, which reads and writes contents, issues and pull requests, made from the variable `RELEASE_APP_CLIENT_ID` and the secret `RELEASE_APP_PRIVATE_KEY`. With the workflow token, GitHub would run the CI of the release PR only after an approval.

## Adding a new strategy

1. Create `strategies/<name>.sh` from the closest strategy. It takes the package name as its only argument, reads its settings with `pkg_get`, prints one version on stdout and exits non-zero on failure, see [Custom strategies](https://aurtomator.dev/custom-strategies/).
2. In `scripts/validate-pkg.sh`, add a line to `UPSTREAM_KEYS` with the `upstream` keys of the strategy, at its place in the strategy table of `README.md`, and the checks of its required fields.
3. Add tests to `tests/strategies.bats` and the API fixtures to `tests/helpers/mock-curl.sh`.
4. Describe the strategy in the table of `README.md` and in `site/src/content/docs/strategies.md`.
5. Run the full check before opening the PR.

## Reporting bugs

Use the "Bug report" or "New strategy request" issue template. A security issue is never a public issue: follow `SECURITY.md`.
