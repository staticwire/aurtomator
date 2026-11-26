---
title: Issues
---

Job `issues` of the workflow opens and closes issues in your repository after every run in which `check` succeeded. Run pages list it as `check-updates / status`. It reads the final status of each package: that of `publish` when `publish` handed over its statuses, and that of `check` otherwise, as after a `publish` job that failed before it reached the packages.

Before it touches issues, the job writes the run summary, which the run page shows under `check-updates / status summary`: counts of all packages and of those up to date, the other packages in a table with their README labels, and errors of failed packages.

| Title | Label | Opens on | Closes on |
|---|---|---|---|
| `❌ <package>: check failed` | `auto-update` | `check_failed` | any other status but `unchecked` |
| `❌ <package>: update failed` | `auto-update` | `update_failed` | `up_to_date`, `updated`, `downgrade`, `rebuilt` or `arch_added`, so the version is in the AUR |
| `❌ <host>: <count> packages failed to check` | `auto-update` | 5 or more failed checks on one host | fewer than 5 failed checks on the host, in runs whose check reached every package |
| `✋ <package>: update held` | `update-held` | `held`, see [Update alerts](/features/update-alerts/) | statuses that close `update failed` |
| `🔔 <package>: <version> notice` | `update-notice` | pushes with alert notes | maintainer, after the edit |
| `⚠️ <package>: <version> without <arches>` | `arch-missing` | pushes without some arches, see [Versions without some arches](/features/missing-arches/) | every arch is back |
| `🚀 aurtomator <release> available` | `aurtomator-update` | newer release, see [Updates of aurtomator](/features/aurtomator-updates/) | pin reaches the latest release, or newer releases get their own issue |
| `❌ Check AUR Package Updates failed` | `auto-update` | failed jobs, see [Failed runs](#failed-runs) | next run without failed jobs |

Packages with `upstream.pin_from` that only wait for the package of their project get no `update held` issue, and the issue of a held update of that package names them, see [pypi](/strategies/#pypi). Packages get no second issue of the same kind while one is open, and issues closed while their package still fails come back in the next run. Each body links the run. Errors hold text from upstream, so they stand in a code block, where links, images and mentions do not render, and keep their last 3900 bytes after a line `[first <n> bytes cut]`. Closing comments name the run and show the new status.

Packages whose YAML you delete get no further check, so the next run closes their `update failed`, `check failed`, `update held` and arch issues with a comment that names the deleted file. YAML files whose `name` differs from their file name get `check_failed` under the file name, and their issues stay open.

Failed checks count for the host of the request they failed on, in lower case, and `api.github.com` and `github.com` are two hosts. Servers write part of the error text, so a URL in it decides nothing. Checks that failed outside a request or on an address with a port or a user name, and all failed updates, get the issue of their package. Host issues stay within 60000 characters: their errors share that room, each with its last 500 characters at least, and the packages past it are named in one line, or counted when their names do not fit either. GitHub refuses bodies over 65536 characters, and the packages of a host issue it refuses get issues of their own. When host issues close, each of their packages that still fails gets its own issue in the same run.

Issues close before new ones open, so packages whose check passes and whose update fails get the check issue closed and an update issue opened in one run. Failed steps close nothing, and failed `publish` jobs close host issues alone, since those rest on the checks. In repositories with Issues turned off, the job prints a notice and opens nothing.

GitHub allows 500 writes of content an hour, so the job writes one a second and at most 450 times a run. Closes past that wait for the next run, and the failed packages past that share one issue, `❌ <count> failed packages of run <number>`, with the first line of each error for as many as 60000 characters hold and the count of the rest, while the run summary holds each whole error. That issue closes once each of its packages recovered or has an issue of its own.

## Failed runs

Runs that fail in `pins`, `image` or `check` never reach job `issues`. For that case, job `notify` of your calling workflow calls `notify-failure.yml` at the same pin after every result but `success`, with `actions: read` and `issues: write`. It opens one issue `❌ Check AUR Package Updates failed` with a link to the run, its branch and the names of the jobs that failed or timed out, and no second one while that issue is open. GitHub marks jobs that ran into their `timeout-minutes` as canceled, so canceled jobs count as timed out once they ran for their time limit. Runs canceled by hand before that have no failed job and get no issue. `notify-failure.yml` knows the time limits of the jobs of `check-updates.yml` alone, so jobs that you add to the calling workflow never count as timed out. Jobs still in the queue when `notify` runs count as failed, since GitHub can end a run with a job that never got a runner.
