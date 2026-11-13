---
title: The workflow
---

## Trigger

`check-updates.yml` of aurtomator runs only when another workflow calls it: its trigger is `on: workflow_call`. It takes no inputs and declares the secrets `AUR_SSH_KEY`, `GPG_SIGNING_KEY`, `AUR_GIT_NAME` and `AUR_GIT_EMAIL`, each with `required: false`. Only `publish` reads them, and it stops on an empty `AUR_SSH_KEY` when a package goes to the AUR, see [Steps](#steps).

The calling workflow `.github/workflows/check-updates.yml` of your repository, which [The calling workflows](/setup/#the-calling-workflows) shows in full, carries the trigger: the schedule `cron: "17 * * * *"` and `workflow_dispatch` for a run by hand. GitHub delays scheduled runs at the start of an hour, when its load is highest, so the schedule avoids minute 0. GitHub starts only part of the scheduled runs: in October 2026 a repository with this schedule got about five a day, one every five hours. Its job `check-updates` calls the reusable file at the pinned SHA and passes the four secrets by name. The concurrency group `check-updates`, with `cancel-in-progress: false`, serializes runs: a new run waits for the running one. The calling workflow sets the group at its workflow level, so it covers the `notify` job of [Failed runs](/features/issues/#failed-runs) too.

The `pipeline` job of `ci.yml` calls the same file in aurtomator itself, see [Validate and pipeline jobs](/develop/ci/#validate-and-pipeline-jobs).

## Permissions and container

A run checks out two repositories. Every job checks out aurtomator at `job.workflow_sha`, the commit of the workflow file that defines the job, which for a job of `check-updates.yml` is the SHA the calling workflow pins. `image` takes a sparse checkout of `ci-image` into the root of the workspace. The other jobs take the whole repository into `aurtomator/`, and `check`, `prepare`, `verify` and `publish` first check out your repository into the root of the workspace. Every step runs in the root of the workspace. A script in `aurtomator/` takes the packages, the README and `.status/` from the directory it runs in, see [Prerequisites](/develop/local-testing/#prerequisites). The steps that run `check-all.sh` and `update-readme.sh` copy these files of your repository into a directory of the user `builder` and run the scripts there, see [Steps](#steps). Inside the called workflow, the `github` context is that of the calling workflow: `github.repository` names your repository, `github.ref_name` the branch of the run, and `github.token` is the token of your repository, with the permissions below.

The workflow has five jobs after a short `image` job. `image` reads the image from `ci-image/Dockerfile` of aurtomator at `job.workflow_sha`: `archlinux:base-devel`, pinned by digest, so a new image on Docker Hub reaches the jobs with the secrets only through a reviewed commit of aurtomator and a move of the pin. Dependabot updates the digest in aurtomator once a month with a pull request, and `ci.yml` runs the tests in the new image before the merge, see [CI image updates](/develop/ci/#ci-image-updates). The five jobs run in that image on `ubuntu-latest`, `issues` with a 10-minute timeout and the others with 30 minutes, and `vercmp` from pacman, which `check-all.sh` requires, is the reason `check`, `verify` and `publish` need Arch too. Every install step upgrades `archlinux-keyring` before the system, because a pinned image ages and an old keyring rejects packages signed with a newer packager key. `makepkg` refuses to run as root, so the steps that touch packages in `prepare` and `publish` run as a `builder` user, and `check` runs the strategies as `builder` as well. `builder` has no `sudo` rights: the steps run as root and switch to `builder` with `sudo -u builder`. `verify` executes no PKGBUILD and runs `check-all.sh` as `builder` too.

| Job | Permissions | Secrets |
|-----|-------------|---------|
| `check-updates` of your calling workflow | `contents: write` and `issues: write`, the most any job below gets | passes the four secrets by name |
| `image` | `contents: read` | none |
| `check` | `contents: read` | none |
| `prepare` | `contents: read` | none |
| `verify` | `contents: read` | none |
| `publish` | `contents: write` for the status commit | `AUR_SSH_KEY`, `GPG_SIGNING_KEY`, `AUR_GIT_NAME`, `AUR_GIT_EMAIL` |
| `issues` | `contents: read`, `issues: write` for the issues of [Issues](/features/issues/) | none |

The calling job sets the permissions of the token for the whole call, and a job of the called workflow can only lower them. `check-updates.yml` sets `contents: read` at the workflow level, and `publish` and `issues` set the blocks above. A calling job that grants less than a job requests makes GitHub reject the calling workflow before any job starts, see [Invalid workflow file: a nested job requests more permissions](/help/troubleshooting/#invalid-workflow-file-a-nested-job-requests-more-permissions).

`check` decides the run. `prepare` and `verify` run only when a package has a new version. `prepare` runs a job for each package that the output `to-prepare` of `check` names, and `verify` runs also after a failed job of `prepare`, for the packages of the others. `publish` runs for a new version, for a change in `README.md`, and in a repository with a package when `stats/events.csv` is missing or the statistics card of the day differs from `stats/card.svg`, see [Statistics](/features/statistics/). It runs after a failure of `prepare` or `verify` as well. After a failed `verify` it publishes nothing, and every package with a new version gets `update_failed`. A failed job of `prepare` gives `update_failed` to its own package. In most runs nothing changes, and all three are skipped. `issues` runs in every run in which `check` succeeded, after `publish` when `publish` runs.

## Steps

Every checkout uses `actions/checkout`, pinned by commit SHA like every action in aurtomator, with `persist-credentials: false`, so the workflow token is not written to `.git/config`. **Checkout** takes your repository at the commit of the run into the root of the workspace, and **Checkout aurtomator** takes `job.workflow_repository` at `job.workflow_sha` into `aurtomator/`. Your repository comes first: its checkout owns the root of the workspace, and `aurtomator/` is a directory inside it. In `image`, the step **Checkout** takes a sparse checkout of `ci-image` of aurtomator instead, after **Check the pin**. The five jobs after it install their packages first and check out after that. All of them but `issues` install `git`. The workflow never pushes to GitHub with git: the status commit goes through the API.

The four steps that run `check-all.sh` as `builder` stop workflow commands while it runs. Its output carries text that a PKGBUILD, the AUR or an upstream chose: the error text a git server sends, a line of a prepared `.SRCINFO` that `verify` refuses. The runner takes a line as a workflow command when it starts with `::` after leading whitespace, or when it holds `##[` anywhere. A line `::add-mask::true` makes the runner skip the outputs `prepare` and `work` of `check`, so no job after `check` runs. Root prints `::stop-commands::` with a token of 32 hex digits from `/dev/urandom` before the run and `::<token>::` after it, and the runner takes no command in between. The token stays in a variable of root's shell, so `builder` cannot print it. The output goes through a pipe to `cat`, which ends only when no process of `builder` holds the pipe, so nothing `builder` prints comes after the token. The steps run in bash with `pipefail` and exit with the status of `check-all.sh`, or with that of `update-readme.sh` when it runs next.

The four steps use the composite action `.github/actions/run-as-builder` of aurtomator, as `uses: ./aurtomator/.github/actions/run-as-builder`: the runner resolves a `./` path from the root of the workspace. The action makes the directory `/work` with mode 0700 and fails when it exists already, so no earlier step can leave files there. It copies into it the regular files that the scripts read: `packages/*.yml` and `README.md` of your repository, and `.status/` and `handoff/` when the job downloaded them, each by the pattern of its names and never a link. With the input `package`, which each job of `prepare` sets to its package, it copies only `packages/<package>.yml`, `.status/<package>`, `.status/_arches`, `.status/_assets` and `.status/_upstream`, and it fails on a value that is no package name. It checks that `builder` can run `scripts/check-all.sh` of its own checkout, which it finds from `GITHUB_ACTION_PATH`, the directory of its `action.yml`, and runs it as `builder` in that directory with the words of its input `args`. With the input `readme: true`, `scripts/update-readme.sh` runs after it as `builder` when `check-all.sh` succeeded. The input `keep-env` names the variables of the step that `sudo --preserve-env` passes to `builder`, beside `GITHUB_REPOSITORY`, which names your repository for the badges of the README.

The workspace, with `.git` of your repository and `aurtomator/`, stays root's, and `builder` writes only into its own directory. A user who could write `.git/config` of a tree could have root's git run a command, because git runs the commands that some of its settings name, such as `core.fsmonitor`. So `check`, `prepare`, `verify` and `publish` follow the step of `builder` with two steps that `check` defines with the anchors `&stop-builder` and `&hand-over`, **Stop builder** and **Hand over**, and end with **Drop the checkouts**, the anchor `&drop-checkouts`. The three run also after a failed step, **Hand over** only when **Stop builder** succeeded. Root reads what `builder` wrote only through **Hand over**, as data, and runs git only in the commit step of `publish`, in the checkout. **Drop the checkouts** removes `.git` and `aurtomator/` as a second layer: the post step of `actions/checkout` runs git as root at the end of the job and stops at once when `.git/config` is missing.

The jobs pass files to each other as artifacts. A job takes an artifact by the `artifact-id` that the upload step of the job before it gives as a job output, not by its name, with one exception for the handoffs of `prepare`. A job of the run can upload an artifact under any name, and with `overwrite: true` replace the artifact of another job. The replacement gets a new id, and the download by the old one fails. For an empty `artifact-ids`, `actions/download-artifact` downloads every artifact of the run, so an empty id, from a job whose upload did not run, becomes `0`, which no artifact has, and that download fails too. Only `issues` skips its download of `checked` when that id is empty, for a run without a package and without statuses, see step 9 of `check`. A matrix gives no output per job, so `verify` takes the artifacts `handoff-<package>-<attempt>` of the jobs of `prepare` by the pattern `handoff-*`, merged into `handoffs/`. A replacement of one of them would reach `verify`, and it needs the runtime token of a job, which `builder` never gets: `run-as-builder` passes it only `GITHUB_REPOSITORY` and the variables of `keep-env`. A re-run of one job keeps the artifacts of the attempt before, so a job of `prepare` that runs again uploads the handoff of its attempt beside the earlier one, and `verify` takes the newest attempt of each package by its number. Of two artifacts with one name, `actions/download-artifact` takes the one with the higher id, and an artifact made later can have the lower id. `Re-run all jobs` leaves only the artifacts of the new attempt.

`image`:

1. **Check the pin:** fails with `job.workflow_sha is not a commit SHA` unless `job.workflow_sha` is 40 lowercase hex digits. With an empty `ref`, `actions/checkout` takes the default branch of a repository other than the one that triggered the run, so an empty value would run the code of `main` of aurtomator, and no other step would fail. Every other job needs `image`, so this step stops the whole run.
2. **Checkout:** a sparse checkout of `ci-image` of aurtomator, at `job.workflow_sha`.
3. **Read image:** takes the `FROM` line of `ci-image/Dockerfile` and fails unless it is `archlinux:base-devel@sha256:` with a 64-character digest.

`check`:

1. **Require a branch:** fails a run started from a tag, before anything else runs, because the commit of `publish` goes to the branch of the run.
2. **Install dependencies:** `sudo git go-yq`.
3. **Add builder:** adds the user `builder` with the fixed uid 2000, and fails when an account of the image has that uid. The runner mounts its work directory at `/__w` and its own programs at `/__e`, owned by the account it runs as. With the uid of that account, `builder` would own the workspace, the actions and the files through which the steps of root set their outputs and environment variables. So the step also fails when `builder` has the uid of the owner of `$RUNNER_TEMP`, or when `find` finds a file or a directory under `/__w` or `/__e` whose user or group is `builder`, and with an error line when `stat` or `find` itself fails.
4. **Checkout:** your repository.
5. **Checkout aurtomator:** into `aurtomator/`.
6. **Check updates:** runs `check-all.sh` and then `update-readme.sh` as `builder` in its directory, with `GITHUB_TOKEN` set to the read-only workflow token. `sudo --preserve-env` passes the token, so it does not appear on a command line. Workflow commands are stopped while it runs.
7. **Stop builder:** a process of `builder` can outlive its step, so the step stops them all. First, `sudo -u builder kill -KILL -1` signals every process that `builder` may signal, in one system call. A fork that is under way at that moment fails, so a process that forks again and again cannot escape it. Then the step kills every process whose effective or real user is `builder` and waits up to 30 seconds for them to end. A zombie does not count: it runs nothing, and pid 1 of a job container never reaps one. A process that is still running after that fails the step, and so does a process list that `ps` cannot produce. In a job that failed before it created `builder`, the step does nothing.
8. **Hand over:** runs only when **Stop builder** succeeded, and copies the regular files of the directory of `builder` whose names fit: `.status/<name>` to `statuses/`, `handoff/prepared/<package>/PKGBUILD`, `.SRCINFO` and `base` and `handoff/status/<package>` to `upload/`, and `README.md` and `packages/<package>.yml` to `/results/`, a directory of root in the container. `find` follows no link and separates paths with NUL, because a name may hold a newline. A package name never starts with a dot, so `.` and `..` match no path. No process of `builder` runs by then, and `builder` reads each file, so a link swapped in after the test reaches nothing that `builder` cannot read. With the variable `PACKAGE` set, as each job of `prepare` sets it, only the prepared files and the status of that package reach `upload/`.
9. **Decide:** sets the output `prepare` when a status in `statuses/` is `new_version`, `available_downgrade`, `new_build` or `arch_back`. The output `to-prepare` lists those packages as a JSON array of at most 256 names, the most jobs GitHub starts from one matrix. The names past 256 go to `statuses/_deferred`, and a warning gives their count. It sets the output `work` for `prepare`, for a copy of the README in `/results/` that differs from the README of the checkout, for an `aurtomator.sh` of the checkout that is a regular file and differs from `aurtomator/aurtomator.sh`, and in a repository with a package for the statistics: when `stats/events.csv` is missing, or when the card that `stats-card.sh` of `aurtomator/` draws as root from it for the day of the run differs from `stats/card.svg`, see [Statistics](/features/statistics/). A `stats` that is a link or no directory, or a `stats/events.csv` that is a link or no regular file, sets nothing and prints a warning. The output `packages` says whether `packages/` holds a package.
10. **Upload statuses:** uploads `statuses/` as the `checked` artifact with a retention of 1 day. With a package, an empty `statuses/` fails the step. Without one, `statuses/` is empty when the request for the latest release of aurtomator failed, and the step uploads nothing.
11. **Drop the checkouts:** removes `.git` and `aurtomator/`. `rm` removes a link named `aurtomator` and does not follow it.

`prepare`, a job for each package of `to-prepare`, with `fail-fast: false` and the variable `PACKAGE` of the job set to that package:

1. **Install dependencies:** `sudo git openssh namcap jq go-yq pacman-contrib`.
2. **Add builder:** the step of `check`, through the alias `*add-builder`.
3. **Checkout:** your repository.
4. **Checkout aurtomator:** into `aurtomator/`.
5. **Download statuses:** the `checked` artifact to `.status/`.
6. **Prepare updates:** runs `check-all.sh --prepare handoff` as `builder` in its directory, for the package of the job, with its status from `check` and without a token. Code from a PKGBUILD can read the environment of every running process of `builder` through `/proc/<pid>/environ`, so the token stays in `check`. Workflow commands are stopped while it runs.
7. **Stop builder:** the step of `check`, through the alias `*stop-builder`. A process started by a PKGBUILD ends here.
8. **Hand over:** the step of `check`, through the alias `*hand-over`. Code from a PKGBUILD has run in the directory of `builder` by now, and only the prepared files and the status of the package of the job reach `upload/`.
9. **Name the attempt:** moves `upload/` to `handoff-out/<attempt>/`, where `<attempt>` is `github.run_attempt`: 1 for the first attempt of the run, and one more with each re-run.
10. **Upload handoff:** uploads `handoff-out/` as the `handoff-<package>-<attempt>` artifact with `include-hidden-files: true`, because `.SRCINFO` starts with a dot, and a retention of 1 day.
11. **Drop the checkouts:** the step of `check`, through the alias `*drop-checkouts`.

`verify`:

1. **Install dependencies:** `sudo git jq go-yq`.
2. **Add builder:** the step of `check`, through the alias `*add-builder`.
3. **Checkout:** your repository.
4. **Checkout aurtomator:** into `aurtomator/`.
5. **Download statuses:** the `checked` artifact to `.status/`.
6. **Download handoff:** every `handoff-<package>-<attempt>` artifact, merged into `handoffs/`, where the files of each attempt stay in the directory `<attempt>/`.
7. **Take the newest handoffs:** for each package, takes the newest attempt in `handoffs/` that holds its prepared directory or its status, and copies the prepared files and the status of that attempt to `handoff/`. So the failure of a newer attempt wins over the prepared files of an older one. An attempt is a directory whose name is a number without a leading zero. Only regular files of the names that **Hand over** takes are copied, and none with a link on its path.
8. **Verify checksums:** runs `check-all.sh --verify handoff` as `builder` in its directory, on the handoff that step 7 took and with the versions and asset values of the statuses of `check`, see [Prepare and publish](/internals/update-process/#prepare-and-publish). git and curl read the AUR repo and the sources here. A job container has the Docker socket of the runner, which root can use and `builder` cannot. Workflow commands are stopped while it runs.
9. **Stop builder:** the step of `check`, through the alias `*stop-builder`.
10. **Hand over:** the step of `check`, through the alias `*hand-over`.
11. **Upload verified handoff:** uploads `upload/` as the `verified` artifact with `include-hidden-files: true` and a retention of 1 day.
12. **Drop the checkouts:** the step of `check`, through the alias `*drop-checkouts`.

`publish`:

1. **Install dependencies:** `sudo git github-cli openssh gnupg jq go-yq`.
2. **Add builder:** the step of `check`, through the alias `*add-builder`.
3. **Checkout:** your repository.
4. **Checkout aurtomator:** into `aurtomator/`.
5. **Download statuses:** the `checked` artifact to `.status/`.
6. **Download verified handoff:** the `verified` artifact to `handoff/`, when `verify` ran.
7. **Find packages to push:** sets the output `packages` to `true` when `handoff/prepared/` holds a directory, a package that `verify` passed, and to `false` otherwise. Steps 9 and 10 run only with `true`, so a run that pushes nothing to the AUR, such as a run before `setup secrets` or a run that only changes the package table, needs neither key and still commits the README.
8. **Setup workspace:** git identity for `builder` from the `AUR_GIT_NAME` and `AUR_GIT_EMAIL` secrets, default `aurtomator`.
9. **Setup AUR SSH:** fails with `The secret AUR_SSH_KEY is empty` when the secret is empty or the calling workflow does not pass it. Otherwise it writes `AUR_SSH_KEY` to `~builder/.ssh/aur`, writes the Ed25519 host key that <https://aur.archlinux.org> publishes to `known_hosts`, and writes an SSH config with `StrictHostKeyChecking yes` and connection multiplexing. A host that answers with another key fails with `Host key verification failed`. The host key is part of `check-updates.yml` of aurtomator, so a new host key of the AUR reaches a run through a release and a move of the pin.
10. **Setup GPG:** with `GPG_SIGNING_KEY` set, imports the key for `builder`, passes `GPG_KEY_ID` to the later steps and enables commit signing. Without it, the AUR commits are not signed.
11. **Publish updates:** runs `check-all.sh --publish handoff` and then `update-readme.sh` as `builder` in its directory, with `GPG_KEY_ID`, `GIT_AUTHOR_NAME` and `GIT_AUTHOR_EMAIL`, and without `GITHUB_TOKEN`, as it runs no strategy. It keeps the statuses of `check` and checks the prepared files before it pushes, see [Prepare and publish](/internals/update-process/#prepare-and-publish). Workflow commands are stopped while it runs.
12. **Stop builder:** the step of `check`, through the alias `*stop-builder`.
13. **Hand over:** the step of `check`, through the alias `*hand-over`: the statuses, `_alerts`, `_upstream` and `_without` included, the README and the package YAMLs.
14. **Record statistics:** when **Hand over** ran and `packages/` holds a package, runs `record-events.sh` and `stats-card.sh` of `aurtomator/` as root. They read the journal of the checkout, the statuses in `statuses/`, and the package YAMLs of the checkout and of `/results/`, the versions before and after the run, and write `events.csv`, `card.svg` and `card-dark.svg` to `/results/stats/`, see [Statistics](/features/statistics/). Both refuse a journal that is a link or no regular file, and one whose directory is a link or no directory. When a script fails or runs for more than 120 seconds, the step prints a warning, removes the three files and goes on, so the commit of the README and the YAMLs does not wait for the statistics.
15. **Commit changes via API:** see [Verified commit](#verified-commit).
16. **Upload statuses:** also after a failed step, uploads `statuses/` as the `published` artifact with a retention of 1 day. After a failed **Stop builder**, **Hand over** did not run, so `statuses/` does not exist and the step fails. `issues` then fails at its download of `published` and opens or closes no issue in that run, and `notify` opens the issue of the failed run, see [Failed runs](/features/issues/#failed-runs).
17. **Drop the checkouts:** the step of `check`, through the alias `*drop-checkouts`.

Step 15 runs as root with `GH_TOKEN` set to the workflow token, `github.token`. It reads the copies in `/results/` and runs git only in the checkout. Steps 14, 16 and 17 run as root without it.

`issues`:

1. **Install dependencies:** `github-cli`. The image has no git, so the job sets `GH_REPO` to your repository for `gh`.
2. **Checkout aurtomator:** into `aurtomator/`. The job reads no file of your repository, so it does not check it out. Without git in the image, `actions/checkout` downloads the files through the REST API.
3. **Download statuses of check:** the `checked` artifact to `.status/`, when `publish` was skipped and `check` uploaded the artifact. Without `.status/`, the steps after it write an empty summary and open or close no issue.
4. **Download statuses of publish:** the `published` artifact to `.status/`, when `publish` ran.
5. **Check the statuses:** runs `clean_statuses` of `scripts/lib/status.sh`, which checks each status as `check-all.sh --publish` does, because with `publish` skipped the statuses come as `builder` of `check` wrote them. A status of another form, or with a version or a day that check refuses, becomes `check_failed: invalid status from the check run`, an `_upstream` of another form than `newer: <version>` or `current: <version>` is removed, and so is a line of `_without` other than a package name, a version and arch names, split by tabs. **Create issues** runs only after this step succeeded.
6. **Write the run summary:** see [Issues](/features/issues/).
7. **Close resolved issues:** see [Issues](/features/issues/).
8. **Create issues:** see [Issues](/features/issues/).

Steps 7 and 8 run as root with `GH_TOKEN` set to the workflow token. No other user runs code in the workspace of this job, so root writes the bodies with `scripts/lib/issue.sh` of `aurtomator/`.

## README update

`update-readme.sh` rewrites two blocks of `README.md`:

1. **Badges** between `<!-- BADGES:START -->` and `<!-- BADGES:END -->`: the badges `Validate packages` and `Check AUR Package Updates`, the status of `validate.yml` and `check-updates.yml` in your repository, which `GITHUB_REPOSITORY` names in CI and the GitHub `origin` names in a local run, and the badge `maintained with aurtomator`, which links to aurtomator. Without either, the block holds the last badge alone. The badge URLs name the two files, so the calling workflows keep those names.
2. **Package table** between `<!-- PACKAGES:START -->` and `<!-- PACKAGES:END -->`: the statistics card, then a table with a row for each package in `packages/`: its name, `current`, strategy, `last_updated` and the label of its status in `.status/`. A package without a status file shows `✨ new` without `current` and `✅ tracking` with it. Each name links to `https://aur.archlinux.org/pkgbase/<name>`. The AUR shows the base of a split package there and sends any other package to `/packages/<name>`. The version of aurtomator follows the table, see [Updates of aurtomator](/features/aurtomator-updates/).

While `packages/` holds no package, the script writes nothing. A repository made from the template keeps the setup steps in its README until its first package, and the README of aurtomator stays as it is. A README whose last package was removed keeps the table it had. With a package, the table markers are required and the badges are optional. Each marker must be a line of its own, once, with the start marker above the end marker. The script checks this for the table, and for the badges when their start marker is there, and stops before it writes anything otherwise. A line that only quotes a marker in its text is left as it is.

### .status/ directory format

`check-all.sh` writes one file per package:

| Filename               | Content                          | Meaning                                  |
|------------------------|----------------------------------|------------------------------------------|
| `.status/<name>`       | `up_to_date`                     | The package is at the latest version     |
| `.status/<name>`       | `updated: 2.0.0`                 | Pushed to the AUR                        |
| `.status/<name>`       | `new_version: 2.0.0`             | Update found, not pushed yet             |
| `.status/<name>`       | `downgrade: 1.2.0`               | Downgrade pushed to the AUR              |
| `.status/<name>`       | `available_downgrade: 1.2.0`     | Downgrade found, not pushed yet          |
| `.status/<name>`       | `downgrade_skipped: 1.2.0`       | Downgrade found, not allowed by the YAML |
| `.status/<name>`       | `jump_skipped: 2026102100`       | Version jump found, not allowed by the YAML |
| `.status/<name>`       | `held: 29+1`                     | Update paused by an alert with `hold: true` |
| `.status/<name>`       | `cooldown: 2026-11-12`           | Update found, waits for the cooldown until that day, see [Cooldown](/features/cooldown/) |
| `.status/<name>`       | `pending: 2.5.0rc1`              | The release asset of the version, or the archive of an arch, is not out yet, see [Values from release asset names](/features/asset-values/) and [Versions without some arches](/features/missing-arches/) |
| `.status/<name>`       | `new_build: 2.4.6`               | Rebuild of the version the AUR has found, not pushed yet |
| `.status/<name>`       | `rebuilt: 2.4.6`                 | Rebuild pushed to the AUR                |
| `.status/<name>`       | `arch_back: 28+23 aarch64`       | The archives of arches out are there again, not pushed yet, see [Versions without some arches](/features/missing-arches/) |
| `.status/<name>`       | `arch_added: 28+23 aarch64`      | Arches put back at the version the AUR has, pushed to the AUR |
| `.status/<name>`       | `check_failed: <error>`          | The check failed: the strategy, the asset value, an alert rule, the cooldown fields, or the status of the check run |
| `.status/<name>`       | `update_failed: <error>`         | The update failed                        |
| `.status/_alerts`      | `<name>`, `hold` or `notice`, the note, split by tabs | One line for each alert that fired, see [Update alerts](/features/update-alerts/) |
| `.status/_assets`      | `<name>` and the asset value, split by a tab | One line for each value found, see [Values from release asset names](/features/asset-values/) |
| `.status/_arches`      | `<name>`, the version, the arches out, the start of the wait, split by tabs | One line for each package whose check found arches out or a wait, or whose YAML holds `arch_out`, see [Versions without some arches](/features/missing-arches/) |
| `.status/_without`     | `<name>`, `current` and the arches out, split by tabs | Written by `--publish`: one line for each package with `arch_out`, see [Versions without some arches](/features/missing-arches/) |
| `.status/_upstream`    | `newer: 0.7.0` or `current: 0.6.0` | The latest aurtomator release against `VERSION` at the pin, see [Updates of aurtomator](/features/aurtomator-updates/) |

### Package table

The table is HTML, since a Markdown table cell takes no attributes. GitHub keeps `nowrap` on a cell, so Strategy, Updated and Status stay on one line and a long package name wraps.

```html
<table>
<tr><th>Package</th><th>Version</th><th>Strategy</th><th>Updated</th><th>Status</th></tr>
<tr><td><a href="https://aur.archlinux.org/pkgbase/my-package">my-package</a></td><td>1.0.1</td><td nowrap>kde-tarball</td><td nowrap>2026-10-01</td><td nowrap>✅ up to date</td></tr>
<tr><td><a href="https://aur.archlinux.org/pkgbase/other-pkg">other-pkg</a></td><td>2.0.0</td><td nowrap>github-release</td><td nowrap>2026-10-14</td><td nowrap>📦 updated to 2.0.0</td></tr>
</table>
```

## Verified commit

A `git push` from the workflow would show as unverified, so the step commits through the GitHub Git Data API:

1. Compare the copies in `/results/` with the files of the checkout: `README.md` and every `packages/<package-name>.yml` that the checkout holds, which **Hand over** took from `builder`, and `stats/events.csv`, `stats/card.svg` and `stats/card-dark.svg`, which **Record statistics** wrote. A file of `stats/` that the checkout does not have yet counts as changed, so the first run with statistics adds them. When `stats` is a link or no directory, the files of `stats/` stay out of the commit, with a warning. `aurtomator.sh` of the checkout counts as changed when it is a regular file and differs from `aurtomator/aurtomator.sh`, the script of the release the run uses. A missing `aurtomator.sh` stays missing. Stop when no file differs. No other file is committed, and a YAML that is not in your repository is left out.
2. Read the branch head and its tree. A head other than the commit the job checked out means a commit was pushed during the run. The step then lists the tree of the new head, and when a changed file differs there from the checked-out commit, or is gone, or is a new file of `stats/` that the new head holds already, it prints a notice and commits nothing, because the tree of step 3 replaces each file as a whole and would drop that change. The next run starts from the new head and writes the statuses again. A package that this run pushed to the AUR keeps its old `last_updated`: the next run finds the version in the AUR and writes only `current`. When the pushed commits changed none of these files, the step commits on the new head.
3. Create a blob for every changed file from its copy, a tree on the base tree, and a commit. The blob of `aurtomator.sh` comes from `aurtomator/aurtomator.sh`, with the mode `100755` of an executable file, and the other files get `100644`. git runs as root in the checkout, which `builder` never writes, with that one directory as `safe.directory`.
4. Move the branch ref with `force=false`.

The step commits to `github.repository` on `github.ref_name`, your repository and the branch of the run, with the `contents: write` that the calling job grants. A run started by hand from another branch therefore reads the package YAMLs of that branch, pushes their updates to the AUR and commits to that branch, while the schedule runs on the default branch only. The message is `chore: update package versions [skip ci]` when a package YAML changed, `chore: update package statuses [skip ci]` when only `README.md` and files of `stats/` changed, and `chore: update package statistics [skip ci]` when only files of `stats/` changed. With `aurtomator.sh` in the commit, the message ends in `and aurtomator.sh [skip ci]`, and a commit of `aurtomator.sh` alone has the message `chore: update aurtomator.sh [skip ci]`. `[skip ci]` keeps the commit from starting the workflows that run on a push: the calling `validate.yml` in your repository, `ci.yml` in aurtomator. GitHub marks the commit as verified because the Actions bot creates it through the API.
