---
title: CI quality gate
---

`ci.yml` runs on every push and pull request to `main`.

## Lint job

The job installs `shellcheck` from apt, and `shfmt` v3.14.1 and `actionlint` v1.7.12 with `go install`, then runs:

```bash
shellcheck -x -S warning scripts/*.sh scripts/lib/*.sh strategies/*.sh tests/helpers/*.sh
shfmt -d -i 2 -ci scripts/*.sh scripts/lib/*.sh strategies/*.sh tests/*.bats tests/helpers/*.sh
actionlint
```

`.shellcheckrc` makes shellcheck find the files of `source` next to the script. `actionlint` checks the workflows and their `run:` blocks. `.github/actionlint.yaml` ignores its report on `job.workflow_repository` and `job.workflow_sha`, which actionlint 1.7.12 does not know. Two more steps run `shellcheck -s bash` on the `run:` blocks of every `.github/actions/*/action.yml`, which actionlint skips, and `shellcheck` and `shfmt` on `aurtomator.sh`.

## Test job

The job runs in the image that the `image` job of `ci.yml` reads, the job of [Permissions and container](/internals/workflow/#permissions-and-container) without its pin check. It installs `bash bats git go-yq jq curl openssh namcap ruby ruby-erb` and the gems `bashcov` 4.0.0, `simplecov-cobertura` 4.0.0, `simplecov` 1.3.2 and `rexml` 3.4.4, each at its version and without resolving dependencies, so no newer release of a gem runs in a required check. Then it runs the suite once, under bashcov:

```bash
bashcov -- tests/helpers/bashcov-bats.sh tests/ --recursive
```

A failing test fails the job, and the upload of `coverage/coverage.xml` to Codecov never does. bashcov exports `SHELLOPTS`, so every script the tests start, mocks included, runs with `errexit`, `nounset` and `pipefail`. bashcov 4.0.0 alone loses trace lines: Ruby reads its pipe in non-blocking mode, so bash drops a line when the pipe is full, and bashcov resolves a script path after the test may have removed its link. `tests/helpers/bashcov-bats.sh` makes the pipe blocking, keeps the test directories until bashcov exits and passes on the lines of `.sh` files alone, and `tests/coverage.bats` checks the exact count of one line.

The two tests of the `namcap` check run the real `namcap`, and `tests/coverage.bats` runs the real `bashcov`. Without them the tests skip, and with `CI` set they fail.

## CI image updates

When Docker Hub has a new `archlinux:base-devel`, Dependabot opens a monthly pull request that changes the digest in `ci-image/Dockerfile`. The `image` jobs read the digest from the pull request, so `test` and the jobs of [Validate and pipeline jobs](#validate-and-pipeline-jobs) run in the new image before the merge, and [Runner probe](#runner-probe) checks it by hand.

The job `merge-image` squash-merges such a pull request without a review once `CI_IMAGE_AUTO_MERGE`, a variable of the aurtomator repository, is `true`. It runs after `lint`, `test`, `validate`, `pipeline` and `ci-ok` passed, only for a pull request of `dependabot[bot]` that changes the digest alone, with `contents: write` and `pull-requests: write`, and with `--match-head-commit`, so a commit pushed after the tests stops the merge. A merge with the workflow token starts no workflow on `main`, so release-please takes the commit at the next push. A branch rule that requires an approval or an up-to-date branch makes the merge fail, and the pull request waits for a hand merge.

## Validate and pipeline jobs

The two jobs call the reusable workflows of the same commit with `uses: ./.github/workflows/<file>`, so a change to them runs end to end before the merge, and neither passes a secret.

`validate` calls `validate.yml` with `contents: read`, as your repository does. Its job `packages` installs `git` and `go-yq` and runs `validate-pkg.sh --all`, without `builder`, since it runs no PKGBUILD. In aurtomator, `packages/` holds `example.yml.sample` alone, so the job checks the call itself: the pin check, the two checkouts and the container.

`pipeline` calls `check-updates.yml` with `contents: write` and `issues: write` and aurtomator as the repository of the packages. With no package there, `image`, `check` and `issues` run and the other jobs are skipped; a test in `tests/scripts.bats` keeps `update-readme.sh` from changing the README of aurtomator. The job shows what the BATS tests cannot: the runner finds the action in `aurtomator/`, the checkouts at `job.workflow_sha` work in the containers, and the artifacts pass between the jobs. It runs for a push and for a pull request from a branch of aurtomator, since a pull request from a fork gets a read-only token.

## Runner probe

`runner-probe.yml` runs by hand only, with `contents: read`: `gh workflow run runner-probe.yml`, on any branch. Run it after GitHub changes `ubuntu-latest` and after the digest in `ci-image/Dockerfile` moves. The defenses of [Steps](/internals/workflow/#steps) rest on facts of the runner that no BATS test sees: the account it runs as, the owners and modes of what it mounts into a job container, and what `builder` reaches there.

The job `runner` prints `id` of the account of the runner. The job `container` runs **Add builder** of `check-updates.yml`, which a test in `tests/workflows.bats` keeps equal, prints the mounts under `/__` with their owners and modes, and tests as `builder` whether it can write `$GITHUB_ENV`, `$GITHUB_PATH`, `$GITHUB_OUTPUT`, `$GITHUB_STEP_SUMMARY`, `$RUNNER_TEMP`, the workspace, `/__w`, `/__w/_actions` and `/__e`, or reach the Docker socket. It fails when one of these tests passes, or when `sudo` gives `builder` a variable whose name starts with `GITHUB_`, `ACTIONS_` or `RUNNER_`.
