---
title: CI quality gate
---

`ci.yml` runs on every push and pull request to `main`.

## Lint job

`ubuntu-latest`, 10-minute timeout. It installs `shellcheck` from apt, and `shfmt` v3.14.1 and `actionlint` v1.7.12 with `go install`, then runs:

```bash
shellcheck -x -S warning scripts/*.sh scripts/lib/*.sh strategies/*.sh tests/helpers/*.sh
shfmt -d -i 2 -ci scripts/*.sh scripts/lib/*.sh strategies/*.sh tests/*.bats tests/helpers/*.sh
actionlint
```

`-x` follows the `source` directives, and `.shellcheckrc` makes shellcheck look for their files next to the script. `-S warning` sets the minimum severity. `-d` fails on any formatting diff, `-i 2` sets two-space indentation, and `-ci` indents `case` branches. `actionlint` checks every file in `.github/workflows/`: the syntax, the expressions, the `needs` of each job, and the `run:` blocks with `shellcheck`. It reads `.github/actionlint.yaml`, which ignores one message in `check-updates.yml` and `validate.yml`: actionlint 1.7.12 does not know the properties `job.workflow_repository` and `job.workflow_sha` and reports them as not defined. The entries go once a release of actionlint knows them.

`actionlint` does not check the `run:` blocks of a composite action. The step `shellcheck the actions` takes them from every `.github/actions/*/action.yml` with the `yq` of the runner image and runs `shellcheck -s bash` on them at its default severity, so an unquoted variable fails the step as it fails `actionlint` in a workflow.

The step `shellcheck and shfmt the runner` runs `shellcheck` and `shfmt -d -i 2 -ci` on `aurtomator.sh`, the script that the template and your repository hold, see [The aurtomator.sh script](/setup/#the-aurtomatorsh-script).

## Test job

30-minute timeout. It runs in the image that the `image` job of `ci.yml` reads. That job is the `image` job of [Permissions and container](/internals/workflow/#permissions-and-container) without `Check the pin`, and its checkout takes the commit of the run. It upgrades `archlinux-keyring`, installs `bash bats git go-yq jq curl openssh namcap ruby ruby-erb` and the gems `bashcov` 4.0.0 and `simplecov-cobertura` 4.0.0 with the two gems they need, `simplecov` 1.3.2 and `rexml` 3.4.4. `gem install` names each of the four with its version and resolves no dependency, because gem takes the newest release of a dependency it resolves, and that release would run in a required check. Then it runs:

```bash
bashcov -- tests/helpers/bashcov-bats.sh tests/ --recursive
```

The suite runs once, under bashcov, and a failing test fails the job. bashcov exports `SHELLOPTS` to trace every script the tests start, so those scripts, mocks included, run with the options of the test: `errexit`, `nounset` and `pipefail`. The upload of `coverage/coverage.xml` to Codecov never fails the job.

bashcov 4.0.0 on its own loses trace lines, and with them coverage the suite has. Ruby opens the pipe that bashcov reads in non-blocking mode, so bash drops a line whenever the pipe is full. And bashcov resolves the path of a traced script when it reads the line, after the test may have removed the link it ran the script from. `tests/helpers/bashcov-bats.sh` makes the pipe blocking and keeps the test directories until bashcov exits. bats itself writes most of the trace, so the script passes bashcov only the lines of `.sh` files. `tests/coverage.bats` runs bashcov on a small project and checks the exact count of a line.

The two tests of the `namcap` check in `update-pkg.sh` run the real `namcap`, and the tests in `tests/coverage.bats` run the real `bashcov`. Without them they skip, except when `CI` is set: there a missing `namcap` or `bashcov` fails them.

## CI image updates

Once a month, when Docker Hub has a new `archlinux:base-devel`, Dependabot opens a pull request in aurtomator that changes the digest in `ci-image/Dockerfile`. The `image` jobs read the digest from the pull request, so `test` and the two calls of [Validate and pipeline jobs](#validate-and-pipeline-jobs) run in the new image before the merge. The probe of [Runner probe](#runner-probe) checks the new image for what `builder` rests on.

The `merge-image` job merges such a pull request without a review. It is off until `CI_IMAGE_AUTO_MERGE`, a variable of the aurtomator repository, is `true`. It runs after `lint`, `test`, `validate` and `pipeline` passed, only for a pull request that `dependabot[bot]` opened, on an event Dependabot caused, and gets `contents: write` and `pull-requests: write`. A pull request that changes any other file, a Dependabot update of an action for example, stays open with a notice. Otherwise the job squash-merges it with `--match-head-commit`, so a commit pushed after the tests stops the merge.

With the variable set, a new image reaches `main` of aurtomator after the tests and without a review. Your repository gets it when its pin moves to a release that holds it. A branch rule that requires an approval, or an up-to-date branch after `main` has moved, makes the merge fail, and the pull request waits for a manual merge.

## Validate and pipeline jobs

The two jobs call the reusable workflows of the same commit, with the `./.github/workflows/<file>` form of `uses`, so a change to them runs end to end before the merge. Neither passes a secret.

`validate` calls `validate.yml` with `contents: read`. Your repository calls the same workflow on every push to `main` and on pull requests, see [The calling workflows](/setup/#the-calling-workflows). After the `image` job of [Permissions and container](/internals/workflow/#permissions-and-container), its job `packages` runs in the image with a 10-minute timeout. It upgrades `archlinux-keyring` before the system, installs `git` and `go-yq`, runs **Checkout** and **Checkout aurtomator** as in [Steps](/internals/workflow/#steps), and runs `./aurtomator/scripts/validate-pkg.sh --all` in the step `Validate packages`. It creates no `builder`: `validate-pkg.sh` reads YAML and runs no PKGBUILD. In aurtomator, `packages/` holds `example.yml.sample` alone, so the job there checks the call itself: the pin check, the two checkouts and the container. In your repository, the pull request that moves the pin runs the validator of the new release against your packages before the merge.

`pipeline` calls `check-updates.yml` with `contents: write` and `issues: write`, with aurtomator itself as the repository of the packages. No package exists there, so `image`, `check` and `issues` run, `prepare` and `verify` are skipped, and `publish` is skipped as well: with no package, `update-readme.sh` leaves the README of aurtomator as it is, and the two checkouts hold the same `aurtomator.sh`. The test `update-readme: the README of aurtomator is what the script writes for it` in `tests/scripts.bats` fails when the script changes it. The job shows on GitHub what the BATS tests cannot: that the runner finds the action in `aurtomator/`, that `GITHUB_ACTION_PATH` leads the action to the scripts, that the checkouts at `job.workflow_sha` work in the containers, and that the artifacts pass between the jobs. It runs for a push and for a pull request from a branch of aurtomator, `github.event.pull_request.head.repo.full_name == github.repository`, because a pull request from a fork of aurtomator gets a read-only token.

## Runner probe

`runner-probe.yml` runs only by hand, with `contents: read`: `Run workflow` in the Actions tab, or `gh workflow run runner-probe.yml`. It runs on the branch chosen there, so it can check the pull request of a new image before the merge. Run it after GitHub changes the `ubuntu-latest` image and after the digest in `ci-image/Dockerfile` moves. `builder` in the jobs of [Steps](/internals/workflow/#steps) rests on facts of the runner that no BATS test sees: the account the runner runs as, the owners and modes of what it mounts into a job container, and what `builder` reaches there.

The job `runner` prints `id` of the account the runner runs as on the VM. The job `container` runs in the image that `image` reads, as the jobs of [Steps](/internals/workflow/#steps) do. It installs `sudo` and runs **Add builder**, the step of `check-updates.yml`, which a test in `tests/workflows.bats` keeps equal to it. The step **The mounts** prints `id builder`, the mounts under `/__` from `/proc/self/mountinfo`, and the owner and mode of `/__w`, `/__w/_actions`, `$RUNNER_TEMP`, its `_runner_file_commands`, the workspace, `/__e`, `/__t` and `/var/run/docker.sock`.

The step **What builder reaches** tests as `builder` whether it can write `$GITHUB_ENV`, `$GITHUB_PATH`, `$GITHUB_OUTPUT`, `$GITHUB_STEP_SUMMARY`, `$RUNNER_TEMP`, the workspace, `/__w`, `/__w/_actions` and `/__e`, and whether it can read or write the Docker socket. It prints the exit code of each test and the names of the variables that `sudo` gives `builder`. It fails when a test passes or a name starts with `GITHUB_`, `ACTIONS_` or `RUNNER_`.
