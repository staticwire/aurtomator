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

The job runs in the image that the `image` job of `ci.yml` reads, the job of [Permissions and container](/internals/workflow/#permissions-and-container) without its pin check. It installs `bash bats git go-yq jq curl openssh namcap python ruby ruby-erb ruby-bundler`, and after the checkout `bundle install` installs `bashcov` and `simplecov-cobertura` with their dependencies from `ci-image/Gemfile.lock`. The lock holds each gem at its version with its SHA-256, bundler stops on a gem whose checksum differs, and the frozen mode stops on a lock that lags `ci-image/Gemfile`. Then the job runs the suite once, under bashcov:

```bash
bundle exec bashcov -- tests/helpers/bashcov-bats.sh tests/ --recursive
```

Failing tests fail the job, and the `coverage/coverage.xml` upload to Codecov never does. The upload runs the Codecov CLI that `ci-image/requirements.txt` pins with hashes, installed into `/opt/codecov`, and Dependabot updates those pins. bashcov exports `SHELLOPTS`, so every script the tests start, mocks included, runs with `errexit`, `nounset` and `pipefail`. bashcov 4.0.0 alone loses trace lines: Ruby reads its pipe in non-blocking mode, so bash drops lines when the pipe is full, and bashcov resolves script paths after the test may have removed their link. `tests/helpers/bashcov-bats.sh` makes the pipe blocking, keeps the test directories until bashcov exits and passes on the lines of `.sh` files alone, and `tests/coverage.bats` checks the exact count of one line.

The two tests of the `namcap` check run the real `namcap`, and `tests/coverage.bats` runs the real `bashcov`. Without them the tests skip, and with `CI` set they fail.

## CI image updates

Dependabot opens monthly pull requests for `ci-image/`: the digest of a new `archlinux:base-devel` in `ci-image/Dockerfile`, the gems of `ci-image/Gemfile.lock` and the Python packages of `ci-image/requirements.txt`. It proposes a version a week after its release, so a hostile release has time to be found and pulled, and its security updates skip that week. The `image` jobs read the digest from the pull request, so `test` and `validate` run in the new image before the merge. `pipeline` runs it on `main` after the merge, and **Check builder** of every job with `builder` tests there what `builder` reaches on the runner, see [Steps](/internals/workflow/#steps).

Job `dependency-review` checks the versions that a pull request of `dependabot[bot]` brings against the GitHub Advisory Database with `actions/dependency-review-action`, and fails on a published vulnerability of any severity. Its failure stops `merge-image` and fails `ci-ok`, and the job opens the issue `❌ Dependabot #<number>: published vulnerabilities` with a row for each vulnerability. The database lists no container images, so the check covers the gems and the Python packages, and a new digest passes it.

Job `merge-image` squash-merges such pull requests without review once `CI_IMAGE_AUTO_MERGE`, a Dependabot secret of the aurtomator repository, is `true`. Runs that Dependabot starts read Dependabot secrets and no Actions secrets. With any other value, or without the secret, the job leaves the pull request open. It runs after `lint`, `test`, `validate`, `dependency-review` and `ci-ok` passed, only for pull requests of `dependabot[bot]` that change nothing but `Dockerfile`, `Gemfile`, `Gemfile.lock`, `requirements.in` and `requirements.txt` of `ci-image/`, with `contents: write`, `pull-requests: write` and `actions: write`, and with `--match-head-commit`, so commits pushed after the tests stop the merge. Merges with the workflow token start no workflow on `main`, so the job then starts `ci.yml` on `main` through `workflow_dispatch`, which runs `pipeline` there, and release-please takes the commit at the next push. Branch rules that require an approval or an up-to-date branch make the merge fail, and the pull request waits for a hand merge.

## Validate and pipeline jobs

The two jobs call the reusable workflows of the same commit with `uses: ./.github/workflows/<file>`, so changes to them run end to end before the merge, and neither passes secrets.

`validate` calls `validate.yml` with `contents: read`, as your repository does. Its job `packages` installs `git` and `go-yq` and runs `validate-pkg.sh --all`, without `builder`, since it runs no PKGBUILD. In aurtomator, `packages/` holds `example.yml.sample` alone, so the job checks the call itself: the pin check, the two checkouts and the container.

`pipeline` calls `check-updates.yml` with `contents: write` and `issues: write` and aurtomator as the package repository. With no package there, `image`, `check` and `issues` run and the other jobs are skipped; one test in `tests/scripts.bats` keeps `update-readme.sh` from changing the aurtomator README. The job shows what the BATS tests cannot: the runner finds the action in `aurtomator/`, checkouts at `job.workflow_sha` work in the containers, and artifacts pass between jobs. It runs for pushes and for pull requests from aurtomator branches. Pull requests from forks get a read-only token. Dependabot pull requests skip it too: the permissions of the job would give the image and the actions they bring a token that writes before review, and `ci-ok` counts the skipped job as passed.

## CodeQL

`codeql.yml` analyzes the workflows of the repository with the `security-extended` queries of CodeQL on pull requests to `main`, on pushes to `main` and on Mondays at 03:41 UTC. Default setup of code scanning skips the pull requests of Dependabot, and those move the pins of actions in the workflows, so the repository runs this workflow in its place. Default setup stays off, since GitHub refuses the results of other CodeQL uploads while it is on.

On Dependabot pull requests its job holds `security-events: write`, unlike the jobs that skip them. That token changes code scanning alerts and analyses and nothing else, CodeQL reads the workflows of the pull request and runs none of them, and the only new code that gets the token is a new version of `actions/checkout` or `github/codeql-action` in `codeql.yml` itself.
