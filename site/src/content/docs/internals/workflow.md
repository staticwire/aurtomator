---
title: The workflow
---

## Trigger

`check-updates.yml` of aurtomator runs only when another workflow calls it, `on: workflow_call`. It takes no inputs and declares the secrets `AUR_SSH_KEY`, `GPG_SIGNING_KEY`, `AUR_GIT_NAME` and `AUR_GIT_EMAIL` with `required: false`. Only `publish` reads them, and it stops on an empty `AUR_SSH_KEY` when packages go to the AUR.

The calling workflow of your repository, shown in [The calling workflows](/setup/#the-calling-workflows), carries the schedule `cron: "17 * * * *"` and `workflow_dispatch` for runs by hand. Its job `pins` runs `./aurtomator.sh check-pins` before job `check-updates` calls aurtomator. GitHub delays scheduled runs at the start of each hour, when its load is highest, so the schedule avoids minute 0, and it starts only part of them: in October 2026 a repository with this schedule got about five runs a day. The concurrency group `check-updates` with `cancel-in-progress: false` makes new runs wait for the running one, the `notify` job of [Failed runs](/features/issues/#failed-runs) included.

Job `pipeline` of `ci.yml` calls the same file in aurtomator itself, see [Validate and pipeline jobs](/develop/ci/#validate-and-pipeline-jobs).

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

Called jobs can only lower the permissions of the calling job, so calling jobs that grant less than some job requests make GitHub reject the workflow before any job starts, see [Invalid workflow file](/help/troubleshooting/#invalid-workflow-file-a-nested-job-requests-more-permissions).

The jobs run on `ubuntu-latest` in the image of `ci-image/Dockerfile` of aurtomator, `archlinux:base-devel` pinned by digest, so new images reach the jobs with the secrets only through an aurtomator commit and a move of the pin. Dependabot opens the pull requests that move the digest, and `merge-image` merges them without review while `CI_IMAGE_AUTO_MERGE` is `true`, see [CI image updates](/develop/ci/#ci-image-updates). The digest fixes the image that a job starts from. Every install step upgrades `archlinux-keyring` first, because old keyrings reject packages signed with a newer packager key, then upgrades every package of the image with `pacman -Su` and installs the tools of the job. `bash`, `sudo`, `git`, `openssh` and `gnupg` of `publish` therefore come from the Arch mirrors on the day of the run, and the signatures of the Arch packagers are their one check. `image` has 5 minutes, `issues` 10 and the other jobs 30. `makepkg` refuses to run as root, and PKGBUILD code must not run as root, so the scripts run as user `builder`, which has no `sudo` rights and owns nothing of the workspace.

## The jobs

`image` checks that `job.workflow_sha` is a commit SHA, since an empty one would check out `main` of aurtomator, and reads the pinned image from `ci-image/Dockerfile`.

`check` runs the strategies as `builder` with the read-only workflow token and decides the run. It names the packages with a new version, at most 256, the most jobs one matrix starts; the rest wait for a later run. It sets `work` when some package has a new version, when the README or `aurtomator.sh` changed, or when the day's statistics card differs from `stats/card.svg`.

`prepare` runs one job for each of those packages, `fail-fast: false`, without secrets and without a token: PKGBUILD code can read the environment of every `builder` process through `/proc/<pid>/environ`. It hands over the prepared files and the status of its own package alone, as the artifact `handoff-<package>-<attempt>`.

`verify` runs after `prepare`, failed `prepare` jobs included, takes the newest attempt of each package, and checks the checksums of every prepared update against its sources as `builder`, without secrets and without running PKGBUILDs. Job containers have the Docker socket of the runner, which root can use and `builder` cannot.

`publish` runs for new versions, a changed README or `aurtomator.sh`, and new statistics, also after a failed `prepare` or `verify`. After a failed `verify` it pushes nothing, and every package with a new version gets `update_failed`. It holds the SSH key, the GPG key and the write token, runs no PKGBUILD and no strategy, checks the prepared files, pushes to the AUR, records the statistics and commits to your repository, see [Verified commit](#verified-commit). It sets up the keys only when some prepared update passed `verify`, so runs that change only the package table need no key.

`issues` runs in every run in which `check` succeeded, after `publish` when `publish` runs, and opens and closes the issues, see [Issues](/features/issues/). It checks each status as `--publish` does first, since with `publish` skipped the statuses come as `builder` of `check` wrote them.

## Steps

The defenses of the workflow sit in a few steps that several jobs share through YAML anchors.

- Checkout: `actions/checkout`, pinned by commit SHA like every action, with `persist-credentials: false`, so the token is not written to `.git/config`. The workflow never pushes with git: the status commit goes through the API.
- Add builder: adds `builder` with uid 2000, and fails when that uid owns an account of the image, `$RUNNER_TEMP` or files of the directories that the runner mounts, `/__w`, `/__e` and the tool cache `/__t`, because through them `builder` could change files of the runner or set the outputs of root steps.
- Close files to builder: makes `/data` with mode 0700 for the artifacts of the job, takes the rights of group and others from every file and directory of the checkout except `aurtomator/`, and leaves the workspace with mode 0711, so PKGBUILD code that `prepare` runs as `builder` reads neither the other package YAMLs nor their statuses. It changes no link and nothing a link points to. The runner mounts `/__t` and `/github/home` and `/github/workflow`, the home and the event files of the steps, read-write, and the step takes the write access of group and others from everything in them.
- Check builder: fails when `builder` can write a file of the runner or of root steps, such as the file commands, `$RUNNER_TEMP`, the workspace, `aurtomator/`, `/__t` or `/github/home`, read the checkout or `/data`, use the Docker socket, or get variables whose names start with `GITHUB_`, `ACTIONS_` or `RUNNER_` from `sudo`. It also runs `find` as `builder` over `/__w`, `/__e`, `/__t` and `/github`, since tests of named paths miss the directories below them, and over `aurtomator/` of the workspace, which `find` skips there since `builder` cannot list the workspace. It fails when `sudo` or `find` cannot run as `builder`. Each job with `builder` runs it, so a new runner image or CI image meets it in the first run.
- Run as builder: `.github/actions/run-as-builder` makes `/work` with mode 0700, copies in only the regular files the scripts read, and runs `check-all.sh` there as `builder`. Links `packages/<name>.yml` arrive as links to themselves, so `check-all.sh` fails those YAMLs and reads nothing through them. The package YAMLs and the README come from the checkout, the statuses and prepared updates only from the directories in `/data` that the step names, so files that a pull request commits as `.status/` or `handoff/` reach no job. In `prepare` jobs only the YAML and the status of the package, `_upstream` and the lines of the package in `_arches` and `_assets` come in. Root prints `::stop-commands::` with a random token before the run and the token after it, so text from PKGBUILDs, the AUR or upstreams cannot act as a workflow command, as `::add-mask::true` would hide the outputs of `check` and stop the run.
- Stop builder: kills every `builder` process and fails when one is still running after 30 seconds, so PKGBUILD code ends with its step.
- Hand over: copies the files of `builder` whose names fit, as data, after **Stop builder** succeeded, so root never reads links or names that `builder` chose. In `prepare` jobs, only the files of their package pass.
- Drop the checkouts: removes `.git` and `aurtomator/`, also after a failed step, so the post step of `actions/checkout` finds no `.git/config` that `builder` could have written.
- Artifacts: each job takes the artifact of the job before it by the `artifact-id` from its outputs, because jobs can replace artifacts of the same name. `verify` takes the matrix handoffs by the pattern `handoff-*` and the newest attempt of each package, and uploading one needs the runtime token of a job, which `builder` never gets.
- Setup AUR SSH: fails with `The secret AUR_SSH_KEY is empty` when the secret is missing, and writes the Ed25519 host key that <https://aur.archlinux.org> publishes, with `StrictHostKeyChecking yes`. New AUR host keys reach runs through aurtomator releases.
- Setup GPG: imports `GPG_SIGNING_KEY` for `builder`, takes the ID of its first secret key and signs one line with it. It fails when gpg cannot import the secret or no secret key can sign, as with a public key block, an expired key or a key with a passphrase. Without the secret it skips signing.
- Record statistics: runs `record-events.sh` and `stats-card.sh` as root on the package YAMLs of the checkout and the copies of the run, with 120 seconds, and drops the statistics with a warning when they fail, so the commit of the README and the YAMLs goes on. Both scripts read no YAML through a link and stop when `packages/` is a link.

## README update

`update-readme.sh` rewrites two blocks of `README.md`:

1. The badges between `<!-- BADGES:START -->` and `<!-- BADGES:END -->`: `Validate packages` and `Check AUR Package Updates`, the status of `validate.yml` and `check-updates.yml` of the repository that `GITHUB_REPOSITORY` or the GitHub `origin` names, and `maintained with aurtomator`.
2. The package table between `<!-- PACKAGES:START -->` and `<!-- PACKAGES:END -->`: the statistics card, a row for each package with its name, `current`, strategy, `last_updated` and status label, and the version of aurtomator, see [Updates of aurtomator](/features/aurtomator-updates/). Packages without a status show `✨ new` without `current` and `✅ tracking` with it. Each name links to `https://aur.archlinux.org/pkgbase/<name>`.

While `packages/` holds no package, the script writes nothing, so repositories from the template keep their setup steps in the README. Each marker is a line of its own, once, with the start above the end. Otherwise the script leaves README.md as it is and ends with code 3, as it does when README.md is missing or a link, and the builder step turns that code into a warning, so the run goes on. The table is HTML, because Markdown cells take no attributes, and `nowrap` keeps Strategy, Updated and Status on one line:

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
| `.status/<name>` | `pending: 2.5.0rc1` | asset or arch archive not out yet |
| `.status/<name>` | `new_build: 2.4.6` | rebuild found, not pushed yet |
| `.status/<name>` | `rebuilt: 2.4.6` | rebuild pushed |
| `.status/<name>` | `arch_back: 28+23 aarch64` | arches out are back, not pushed yet |
| `.status/<name>` | `arch_added: 28+23 aarch64` | arches put back at the AUR version, pushed |
| `.status/<name>` | `check_failed: <error>` | check failed |
| `.status/<name>` | `update_failed: <error>` | update failed |
| `.status/_alerts` | package, `hold` or `notice`, note | one line for each alert that fired |
| `.status/_assets` | package, asset value | one line for each value found |
| `.status/_arches` | package, version, arches out or those a wait waits for, start of the wait, and for waits the AUR commit that builds them | see [Versions without some arches](/features/missing-arches/) |
| `.status/_hosts` | package, host | one line for each check that failed on a request, with the host of that request |
| `.status/_without` | package, `current`, arches out | written by `--publish` for each package with `arch_out` |
| `.status/_upstream` | `newer: 0.7.0` or `current: 0.6.0` | latest aurtomator release against `VERSION` |

Fields of the shared files are split by tabs.

## Verified commit

`git push` from the workflow would show as unverified, so `publish` commits through the GitHub Git Data API with the workflow token:

1. Compare the copies of the run with the checkout: `README.md`, every `packages/<name>.yml` the checkout holds, the files of `stats/`, and `aurtomator.sh` against `aurtomator/aurtomator.sh` of the release the run uses. Stop when nothing differs. No other file is committed.
2. Read the head of the branch. When a commit was pushed during the run and changed one of these files, print a notice and commit nothing, since the new tree replaces each file as a whole; the next run writes the statuses again. Otherwise commit on the new head.
3. Create a blob for each changed file, a tree on the base tree and a commit. `aurtomator.sh` gets the mode `100755`. git runs as root only in the checkout, which `builder` never writes.
4. Move the branch ref with `force=false`.

The commit goes to the branch of the run, so runs started by hand from another branch read the package YAMLs of that branch, push their updates to the AUR and commit to that branch. The message is `chore: update package versions [skip ci]` when a package YAML changed, `chore: update package statuses [skip ci]` when only `README.md` and `stats/` changed, and `chore: update package statistics [skip ci]` when only `stats/` changed. With `aurtomator.sh` the message ends in `and aurtomator.sh [skip ci]`, and `aurtomator.sh` alone gives `chore: update aurtomator.sh [skip ci]`. `[skip ci]` keeps the commit from starting the workflows that run on a push. GitHub marks the commit as verified, because the Actions bot creates it through the API.
