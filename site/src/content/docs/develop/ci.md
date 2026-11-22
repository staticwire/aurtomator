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

`.shellcheckrc` makes shellcheck find `source` files next to the script. `actionlint` checks workflows and their `run:` blocks. `.github/actionlint.yaml` ignores its reports on `job.workflow_repository`, `job.workflow_sha` and the `queue` key of `concurrency` in `release-please.yml`, which actionlint 1.7.12 does not know. Two more steps run `shellcheck -s bash` on the `run:` blocks of every `.github/actions/*/action.yml`, which actionlint skips, and `shellcheck` and `shfmt` on `aurtomator.sh`.

Step `zizmor` runs `zizmorcore/zizmor-action`, pinned like every action. The action installs the zizmor release that its commit names as latest, from a wheel that it checks against the hashes in its own tree, so zizmor moves with the Dependabot updates of the action. zizmor audits the workflows, `.github/actions/*/action.yml` and `.github/dependabot.yml` with its `regular` persona, and its online audits, such as `known-vulnerable-actions` and `impostor-commit`, read GitHub with the token of the job. With `advanced-security: false`, zizmor prints its findings and fails the job, where the default of the action uploads them to code scanning and passes.

Comments `# zizmor: ignore[<audit>]` skip findings on lines that the audits misread, and a test in `tests/workflows.bats` allows them only there:

- `unpinned-images` on `container: ${{ needs.image.outputs.ref }}`: the `image` job accepts only a dated tag pinned by digest.
- `self-repository` on `uses: ./.github/workflows/<file>` in `ci.yml`: actionlint 1.7.12 rejects the `$/` form.
- `self-repository` on `uses: ./aurtomator/.github/actions/run-as-builder`: the action finds the scripts next to its own path, in the `aurtomator/` checkout, and through `$/` it would run them from the copy that the runner downloads.
- `bot-conditions` on the `if` of `merge-image`, which zizmor flags for `github.actor`: the same condition checks the author with `github.event.pull_request.user.login`, the form zizmor recommends, and `github.actor` skips the merge after a push of anyone but Dependabot.

## Test job

The job runs in the image that the `image` job of `ci.yml` reads, the job of [Permissions and container](/internals/workflow/#permissions-and-container) without its pin check. It installs `bash bats git go-yq jq curl openssh namcap python ruby ruby-erb ruby-bundler`, and after the checkout `bundle install` installs `bashcov` and `simplecov-cobertura` with their dependencies from `ci-image/Gemfile.lock`. The lock holds each gem at its version with its SHA-256, bundler stops on a gem whose checksum differs, and the frozen mode stops on a lock that lags `ci-image/Gemfile`. Then the job runs the suite once, under bashcov:

```bash
bundle exec bashcov -- tests/helpers/bashcov-bats.sh tests/ --recursive
```

Failing tests fail the job, and the `coverage/coverage.xml` upload to Codecov never does. The upload runs the Codecov CLI that `ci-image/requirements.txt` pins with hashes, installed into `/opt/codecov`, and Dependabot updates those pins. bashcov exports `SHELLOPTS`, so every script the tests start, mocks included, runs with `errexit`, `nounset` and `pipefail`. bashcov 4.0.0 alone loses trace lines: Ruby reads its pipe in non-blocking mode, so bash drops lines when the pipe is full, and bashcov resolves script paths after the test may have removed their link. `tests/helpers/bashcov-bats.sh` makes the pipe blocking, keeps the test directories until bashcov exits and passes on the lines of `.sh` files alone, and `tests/coverage.bats` checks the exact count of one line.

The two tests of the `namcap` check run the real `namcap`, and `tests/coverage.bats` runs the real `bashcov`. Without them the tests skip, and with `CI` set they fail.

## CI image updates

Dependabot opens monthly pull requests for `ci-image/`: a newer dated tag of `archlinux:base-devel` with its digest in `ci-image/Dockerfile`, the gems of `ci-image/Gemfile.lock` and the Python packages of `ci-image/requirements.txt`. It proposes a version a week after its release, so a hostile release has time to be found and pulled, and its security updates skip that week. Dependabot dates an image by the time Docker Hub got its tag. Arch pushes the tag `base-devel` again with every release, about once a week, and each dated tag, such as `base-devel-20261108.0.623074`, with its own release alone, so the Dockerfile pins a dated tag. The `image` jobs read the tag and the digest from the pull request, so `test` and `validate` run in the new image before the merge. `pipeline` runs it on `main` after the merge, and **Check builder** of every job with `builder` tests there what `builder` reaches on the runner, see [Steps](/internals/workflow/#steps).

Job `dependency-review` checks the versions that a pull request of `dependabot[bot]` brings against the GitHub Advisory Database with `actions/dependency-review-action`, and fails on a published vulnerability of any severity. Its failure stops `merge-image` and fails `ci-ok`, and job `vulnerability-issue` then opens the issue `❌ Dependabot #<number>: published vulnerabilities` with label `dependency-review` and a row for each vulnerability. It opens no second one while an open issue with that label holds the title, and only accounts with triage rights set labels. The pull request can bring a new version of the action itself, which runs before anyone reviews it, so `dependency-review` holds only `contents: read`, and `vulnerability-issue` holds `issues: write` and runs no action. The database lists no container images, so the check covers the gems and the Python packages, and a new digest passes it. The action reads the dependency graph of the repository, which stays on under Settings > Advanced Security. With the graph off, every review fails and opens no issue.

Job `merge-image` squash-merges such pull requests without review once `CI_IMAGE_AUTO_MERGE`, a Dependabot secret of the aurtomator repository, holds `auto-merge-ci-image`. Runs that Dependabot starts read Dependabot secrets and no Actions secrets. GitHub masks the value of a secret in every line of the job log, so the switch takes a word that no other line of the log holds, unlike `true`. With any other value, or without the secret, the job leaves the pull request open. It runs after `lint`, `test`, `validate`, `dependency-review` and `ci-ok` passed, only for pull requests of `dependabot[bot]` that change nothing but `Dockerfile`, `Gemfile`, `Gemfile.lock`, `requirements.in` and `requirements.txt` of `ci-image/`, with `contents: write`, `pull-requests: write` and `actions: write`, and with `--match-head-commit`, so commits pushed after the tests stop the merge. Merges with the workflow token start no workflow on `main`, so the job then starts `ci.yml` and `release-please.yml` there through `workflow_dispatch`. `ci.yml` runs `pipeline` on `main`, and release-please rebuilds an open release pull request on top of the merge. Branch rules that require an approval or an up-to-date branch make the merge fail, and the pull request waits for a hand merge.

## Validate and pipeline jobs

The two jobs call the reusable workflows of the same commit with `uses: ./.github/workflows/<file>`, so changes to them run end to end before the merge, and neither passes secrets.

`validate` calls `validate.yml` with `contents: read`, as your repository does. Its job `packages` installs `git` and `go-yq` and runs `validate-pkg.sh --all`, without `builder`, since it runs no PKGBUILD. In aurtomator, `packages/` holds `example.yml.sample` alone, so the job checks the call itself: the pin check, the two checkouts and the container.

`pipeline` calls `check-updates.yml` with `contents: write` and `issues: write` and aurtomator as the package repository. With no package there, `image`, `check` and `issues` run and the other jobs are skipped; one test in `tests/scripts.bats` keeps `update-readme.sh` from changing the aurtomator README. The job shows what the BATS tests cannot: the runner finds the action in `aurtomator/`, checkouts at `job.workflow_sha` work in the containers, and artifacts pass between jobs. It runs for pushes and for pull requests from aurtomator branches. Pull requests from forks get a read-only token. Dependabot pull requests skip it too: the permissions of the job would give the image and the actions they bring a token that writes before review, and `ci-ok` counts the skipped job as passed.

## CodeQL

`codeql.yml` analyzes the workflows of the repository with the `security-extended` queries of CodeQL on pull requests to `main`, on pushes to `main` and on Mondays at 03:41 UTC. Default setup of code scanning skips the pull requests of Dependabot, and those move the pins of actions in the workflows, so the repository runs this workflow in its place. Default setup stays off, since GitHub refuses the results of other CodeQL uploads while it is on.

On Dependabot pull requests its job holds `security-events: write`, unlike the jobs that skip them. That token changes code scanning alerts and analyses and nothing else, CodeQL reads the workflows of the pull request and runs none of them, and the only new code that gets the token is a new version of `actions/checkout` or `github/codeql-action` in `codeql.yml` itself.

## Spec watch

`scripts/lib/requires.sh` reads the requirements of PyPI releases and their environment markers by four specifications of `pypa/packaging.python.org`: dependency specifiers, version specifiers, name normalization and core metadata. `.github/spec-watch.tsv` lists each file with the SHA of the last commit that the parser follows. `spec-watch.yml` asks the GitHub API for the last commit of each file on Tuesdays at 04:27 UTC and by hand, in `staticwire/aurtomator` alone. When one differs, it opens the issue `📜 PyPA specifications changed` with label `spec-watch`, both SHAs and a link to the history of each changed file, and no second one while that issue is open. Read the commits, update `scripts/lib/requires.sh` and its tests when one changes the meaning of requirements or markers, and set the new SHAs in `.github/spec-watch.tsv`. The next run that finds every SHA of the list closes the issue. The job holds `contents: read` and `issues: write`, and errors of the API fail it.
