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

`.shellcheckrc` makes shellcheck find `source` files next to the script. `actionlint` checks workflows and their `run:` blocks. `.github/actionlint.yaml` ignores its report on `job.workflow_repository` and `job.workflow_sha`, which actionlint 1.7.12 does not know. Two more steps run `shellcheck -s bash` on the `run:` blocks of every `.github/actions/*/action.yml`, which actionlint skips, and `shellcheck` and `shfmt` on `aurtomator.sh`.

## Test job

The job runs in the image that the `image` job of `ci.yml` reads, the job of [Permissions and container](/internals/workflow/#permissions-and-container) without its pin check. It installs `bash bats git go-yq jq curl openssh namcap ruby ruby-erb` and gems `bashcov` 4.0.0, `simplecov-cobertura` 4.0.0, `simplecov` 1.3.2 and `rexml` 3.4.4, each at its version and without resolving dependencies, so no newer gem release runs in a required check. Then it runs the suite once, under bashcov:

```bash
bashcov -- tests/helpers/bashcov-bats.sh tests/ --recursive
```

Failing tests fail the job, and the `coverage/coverage.xml` upload to Codecov never does. bashcov exports `SHELLOPTS`, so every script the tests start, mocks included, runs with `errexit`, `nounset` and `pipefail`. bashcov 4.0.0 alone loses trace lines: Ruby reads its pipe in non-blocking mode, so bash drops lines when the pipe is full, and bashcov resolves script paths after the test may have removed their link. `tests/helpers/bashcov-bats.sh` makes the pipe blocking, keeps the test directories until bashcov exits and passes on the lines of `.sh` files alone, and `tests/coverage.bats` checks the exact count of one line.

The two tests of the `namcap` check run the real `namcap`, and `tests/coverage.bats` runs the real `bashcov`. Without them the tests skip, and with `CI` set they fail.

## CI image updates

When Docker Hub has a new `archlinux:base-devel`, Dependabot opens a monthly pull request that changes the digest in `ci-image/Dockerfile`. The `image` jobs read the digest from the pull request, so `test` and `validate` run in the new image before the merge. `pipeline` runs it after the merge, and **Check builder** of every job with `builder` tests there what `builder` reaches on the runner, see [Steps](/internals/workflow/#steps).

Job `merge-image` squash-merges such pull requests without review once `CI_IMAGE_AUTO_MERGE`, a variable of the aurtomator repository, is `true`. It runs after `lint`, `test`, `validate` and `ci-ok` passed, only for pull requests of `dependabot[bot]` that change the digest alone, with `contents: write` and `pull-requests: write`, and with `--match-head-commit`, so commits pushed after the tests stop the merge. Merges with the workflow token start no workflow on `main`, so release-please takes the commit at the next push. Branch rules that require an approval or an up-to-date branch make the merge fail, and the pull request waits for a hand merge.

## Validate and pipeline jobs

The two jobs call the reusable workflows of the same commit with `uses: ./.github/workflows/<file>`, so changes to them run end to end before the merge, and neither passes secrets.

`validate` calls `validate.yml` with `contents: read`, as your repository does. Its job `packages` installs `git` and `go-yq` and runs `validate-pkg.sh --all`, without `builder`, since it runs no PKGBUILD. In aurtomator, `packages/` holds `example.yml.sample` alone, so the job checks the call itself: the pin check, the two checkouts and the container.

`pipeline` calls `check-updates.yml` with `contents: write` and `issues: write` and aurtomator as the package repository. With no package there, `image`, `check` and `issues` run and the other jobs are skipped; one test in `tests/scripts.bats` keeps `update-readme.sh` from changing the aurtomator README. The job shows what the BATS tests cannot: the runner finds the action in `aurtomator/`, checkouts at `job.workflow_sha` work in the containers, and artifacts pass between jobs. It runs for pushes and for pull requests from aurtomator branches. Pull requests from forks get a read-only token. Dependabot pull requests skip it too: the permissions of the job would give the image and the actions they bring a token that writes before review, and `ci-ok` counts the skipped job as passed.
