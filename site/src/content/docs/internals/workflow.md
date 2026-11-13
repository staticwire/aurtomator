---
title: The workflow
---

## Trigger

`check-updates.yml` of aurtomator runs only when another workflow calls it, `on: workflow_call`. It takes no inputs and declares the secrets `AUR_SSH_KEY`, `GPG_SIGNING_KEY`, `AUR_GIT_NAME` and `AUR_GIT_EMAIL` with `required: false`. Only `publish` reads them, and it stops on an empty `AUR_SSH_KEY` when a package goes to the AUR.

The calling workflow of your repository, shown in [The calling workflows](/setup/#the-calling-workflows), carries the schedule `cron: "17 * * * *"` and `workflow_dispatch` for a run by hand. Its job `pins` runs `./aurtomator.sh check-pins` before the job `check-updates` calls aurtomator. GitHub delays scheduled runs at the start of an hour, when its load is highest, so the schedule avoids minute 0, and it starts only part of them: in October 2026 a repository with this schedule got about five runs a day. The concurrency group `check-updates` with `cancel-in-progress: false` makes a new run wait for the running one, the `notify` job of [Failed runs](/features/issues/#failed-runs) included.

The job `pipeline` of `ci.yml` calls the same file in aurtomator itself, see [Validate and pipeline jobs](/develop/ci/#validate-and-pipeline-jobs).

## Permissions and container

Every job checks out aurtomator at `job.workflow_sha`, the commit that the calling workflow pins, into `aurtomator/`, and `check`, `prepare`, `verify` and `publish` check out your repository into the root of the workspace first. Inside the called workflow, `github.repository` names your repository, `github.ref_name` the branch of the run, and `github.token` is the token of your repository with the permissions below.

| Job | Permissions | Secrets |
|---|---|---|
| `check-updates` of your calling workflow | `contents: write` and `issues: write`, the most any job below gets | passes the four secrets by name |
| `image` | `contents: read` | none |
| `check` | `contents: read` | none |
| `prepare` | `contents: read` | none |
| `verify` | `contents: read` | none |
| `publish` | `contents: write` for the status commit | `AUR_SSH_KEY`, `GPG_SIGNING_KEY`, `AUR_GIT_NAME`, `AUR_GIT_EMAIL` |
| `issues` | `contents: read`, `issues: write` for the issues of [Issues](/features/issues/) | none |

A called job can only lower the permissions of the calling job, so a calling job that grants less than a job requests makes GitHub reject the workflow before any job starts, see [Invalid workflow file](/help/troubleshooting/#invalid-workflow-file-a-nested-job-requests-more-permissions).

The jobs run on `ubuntu-latest` in the image of `ci-image/Dockerfile` of aurtomator, `archlinux:base-devel` pinned by digest, so a new image reaches the jobs with the secrets only through a reviewed commit of aurtomator and a move of the pin. `issues` has 10 minutes and the other jobs 30. Every install step upgrades `archlinux-keyring` first, because an old keyring rejects packages signed with a newer packager key. `makepkg` refuses to run as root, and code from a PKGBUILD must not run as root, so the scripts run as the user `builder`, which has no `sudo` rights and owns nothing of the workspace.

## The jobs

`image` checks that `job.workflow_sha` is a commit SHA, since an empty one would check out `main` of aurtomator, and reads the pinned image from `ci-image/Dockerfile`.

`check` runs the strategies as `builder` with the read-only workflow token and decides the run. It names the packages with a new version, at most 256, the most jobs one matrix starts; the rest wait for a later run. It sets `work` when a package has a new version, when the README or `aurtomator.sh` changed, or when the statistics card of the day differs from `stats/card.svg`.

`prepare` runs one job for each of those packages, `fail-fast: false`, without secrets and without a token: code from a PKGBUILD can read the environment of every process of `builder` through `/proc/<pid>/environ`. It hands over the prepared files and the status of its own package alone, as the artifact `handoff-<package>-<attempt>`.

`verify` runs after `prepare`, a failed job of `prepare` included, takes the newest attempt of each package, and checks the checksums of every prepared update against its sources as `builder`, without secrets and without running a PKGBUILD. A job container has the Docker socket of the runner, which root can use and `builder` cannot.

`publish` runs for a new version, a changed README or `aurtomator.sh`, and new statistics, also after a failed `prepare` or `verify`. After a failed `verify` it pushes nothing, and every package with a new version gets `update_failed`. It holds the SSH key, the GPG key and the write token, runs no PKGBUILD and no strategy, checks the prepared files, pushes to the AUR, records the statistics and commits to your repository, see [Verified commit](#verified-commit). It sets up the keys only when a prepared update passed `verify`, so a run that changes only the package table needs no key.

`issues` runs in every run in which `check` succeeded, after `publish` when `publish` runs, and opens and closes the issues, see [Issues](/features/issues/). It checks each status as `--publish` does first, since with `publish` skipped the statuses come as `builder` of `check` wrote them.

## Steps

The defenses of the workflow sit in a few steps that several jobs share through YAML anchors.

- Checkout: `actions/checkout`, pinned by commit SHA like every action, with `persist-credentials: false`, so the token is not written to `.git/config`. The workflow never pushes with git: the status commit goes through the API.
- Add builder: adds `builder` with the uid 2000, and fails when that uid owns an account of the image, `$RUNNER_TEMP` or a file of the work directories of the runner, `/__w` and `/__e`, because through them `builder` could set the outputs of the steps of root.
- Run as builder: `.github/actions/run-as-builder` makes `/work` with mode 0700, copies in only the regular files the scripts read, never a link, and runs `check-all.sh` there as `builder`. Root prints `::stop-commands::` with a random token before the run and the token after it, so text from a PKGBUILD, the AUR or an upstream cannot act as a workflow command, as `::add-mask::true` would hide the outputs of `check` and stop the run.
- Stop builder: kills every process of `builder` and fails when one is still running after 30 seconds, so code from a PKGBUILD ends with its step.
- Hand over: copies the files of `builder` whose names fit, as data, after **Stop builder** succeeded, so root never reads a link or a name that `builder` chose. In a job of `prepare`, only the files of its package pass.
- Drop the checkouts: removes `.git` and `aurtomator/`, also after a failed step, so the post step of `actions/checkout` finds no `.git/config` that `builder` could have written.
- Artifacts: a job takes the artifact of the job before it by the `artifact-id` from its outputs, because a job can replace an artifact of the same name. `verify` takes the handoffs of the matrix by the pattern `handoff-*` and the newest attempt of each package, and uploading one needs the runtime token of a job, which `builder` never gets.
- Setup AUR SSH: fails with `The secret AUR_SSH_KEY is empty` when the secret is missing, and writes the Ed25519 host key that <https://aur.archlinux.org> publishes, with `StrictHostKeyChecking yes`. A new host key of the AUR reaches a run through a release of aurtomator.
- Record statistics: runs `record-events.sh` and `stats-card.sh` as root on the copies of the run, with 120 seconds, and drops the statistics with a warning when they fail, so the commit of the README and the YAMLs goes on.

## README update

`update-readme.sh` rewrites two blocks of `README.md`:

1. The badges between `<!-- BADGES:START -->` and `<!-- BADGES:END -->`: `Validate packages` and `Check AUR Package Updates`, the status of `validate.yml` and `check-updates.yml` of the repository that `GITHUB_REPOSITORY` or the GitHub `origin` names, and `maintained with aurtomator`.
2. The package table between `<!-- PACKAGES:START -->` and `<!-- PACKAGES:END -->`: the statistics card, a row for each package with its name, `current`, strategy, `last_updated` and status label, and the version of aurtomator, see [Updates of aurtomator](/features/aurtomator-updates/). A package without a status shows `✨ new` without `current` and `✅ tracking` with it. Each name links to `https://aur.archlinux.org/pkgbase/<name>`.

While `packages/` holds no package, the script writes nothing, so a repository from the template keeps its setup steps in the README. Each marker is a line of its own, once, with the start above the end, and the script stops before it writes anything otherwise. The table is HTML, because a Markdown cell takes no attributes, and `nowrap` keeps Strategy, Updated and Status on one line:

```html
<table>
<tr><th>Package</th><th>Version</th><th>Strategy</th><th>Updated</th><th>Status</th></tr>
<tr><td><a href="https://aur.archlinux.org/pkgbase/my-package">my-package</a></td><td>1.0.1</td><td nowrap>kde-tarball</td><td nowrap>2026-10-01</td><td nowrap>✅ up to date</td></tr>
<tr><td><a href="https://aur.archlinux.org/pkgbase/other-pkg">other-pkg</a></td><td>2.0.0</td><td nowrap>github-release</td><td nowrap>2026-10-14</td><td nowrap>📦 updated to 2.0.0</td></tr>
</table>
```

## .status/ directory format

`check-all.sh` writes one file per package and a few shared files:

| File | Content | Meaning |
|---|---|---|
| `.status/<name>` | `up_to_date` | at the latest version |
| `.status/<name>` | `new_version: 2.0.0` | update found, not pushed yet |
| `.status/<name>` | `updated: 2.0.0` | pushed to the AUR |
| `.status/<name>` | `available_downgrade: 1.2.0` | downgrade found, not pushed yet |
| `.status/<name>` | `downgrade: 1.2.0` | downgrade pushed |
| `.status/<name>` | `downgrade_skipped: 1.2.0` | downgrade the YAML does not allow |
| `.status/<name>` | `jump_skipped: 2026102100` | version jump the YAML does not allow |
| `.status/<name>` | `held: 29+1` | held by an alert, see [Update alerts](/features/update-alerts/) |
| `.status/<name>` | `cooldown: 2026-11-12` | waits until that day, see [Cooldown](/features/cooldown/) |
| `.status/<name>` | `pending: 2.5.0rc1` | an asset or the archive of an arch is not out yet |
| `.status/<name>` | `new_build: 2.4.6` | rebuild found, not pushed yet |
| `.status/<name>` | `rebuilt: 2.4.6` | rebuild pushed |
| `.status/<name>` | `arch_back: 28+23 aarch64` | arches out are back, not pushed yet |
| `.status/<name>` | `arch_added: 28+23 aarch64` | arches put back at the version of the AUR, pushed |
| `.status/<name>` | `check_failed: <error>` | the check failed |
| `.status/<name>` | `update_failed: <error>` | the update failed |
| `.status/_alerts` | the package, `hold` or `notice`, the note | one line for each alert that fired |
| `.status/_assets` | the package, the asset value | one line for each value found |
| `.status/_arches` | the package, the version, the arches out, the start of the wait | see [Versions without some arches](/features/missing-arches/) |
| `.status/_without` | the package, `current`, the arches out | written by `--publish` for each package with `arch_out` |
| `.status/_upstream` | `newer: 0.7.0` or `current: 0.6.0` | the latest release of aurtomator against `VERSION` |

The fields of the shared files are split by tabs.

## Verified commit

A `git push` from the workflow would show as unverified, so `publish` commits through the GitHub Git Data API with the workflow token:

1. Compare the copies of the run with the checkout: `README.md`, every `packages/<name>.yml` the checkout holds, the files of `stats/`, and `aurtomator.sh` against `aurtomator/aurtomator.sh` of the release the run uses. Stop when nothing differs. No other file is committed.
2. Read the head of the branch. When a commit was pushed during the run and changed one of these files, print a notice and commit nothing, since the new tree replaces each file as a whole; the next run writes the statuses again. Otherwise commit on the new head.
3. Create a blob for each changed file, a tree on the base tree and a commit. `aurtomator.sh` gets the mode `100755`. git runs as root only in the checkout, which `builder` never writes.
4. Move the branch ref with `force=false`.

The commit goes to the branch of the run, so a run started by hand from another branch reads the package YAMLs of that branch, pushes their updates to the AUR and commits to that branch. The message is `chore: update package versions [skip ci]` when a package YAML changed, `chore: update package statuses [skip ci]` when only `README.md` and `stats/` changed, and `chore: update package statistics [skip ci]` when only `stats/` changed. With `aurtomator.sh` the message ends in `and aurtomator.sh [skip ci]`, and `aurtomator.sh` alone gives `chore: update aurtomator.sh [skip ci]`. `[skip ci]` keeps the commit from starting the workflows that run on a push. GitHub marks the commit as verified, because the Actions bot creates it through the API.
