---
title: Issues
---

The job `issues` of the workflow opens and closes issues in your repository after every run in which `check` succeeded. The page of the run lists it as `check-updates / status`. It reads the final status of each package: that of `publish` when `publish` ran, and that of `check` otherwise.

Before it touches an issue, the job writes the summary of the run, which the page of the run shows under `check-updates / status summary`: the count of packages and of those up to date, a table of every other package with its README label, and the error of each failed package.

| Title | Label | Opens on | Closes on |
|---|---|---|---|
| `❌ <package>: check failed` | `auto-update` | `check_failed` | any other status but `unchecked` |
| `❌ <package>: update failed` | `auto-update` | `update_failed` | `up_to_date`, `updated`, `downgrade`, `rebuilt` or `arch_added`, so the version is in the AUR |
| `❌ <host>: <count> packages failed to check` | `auto-update` | 5 or more failed checks on one host | fewer than 5 failed checks on the host, in a run whose check reached every package |
| `✋ <package>: update held` | `update-held` | `held`, see [Update alerts](/features/update-alerts/) | the statuses that close `update failed` |
| `🔔 <package>: <version> notice` | `update-notice` | a push with an alert note | the maintainer, after the edit |
| `⚠️ <package>: <version> without <arches>` | `arch-missing` | a push without some arches, see [Versions without some arches](/features/missing-arches/) | every arch is back |
| `🚀 aurtomator <release> available` | `aurtomator-update` | a newer release, see [Updates of aurtomator](/features/aurtomator-updates/) | the pin reaches the latest release, or a newer release gets its own issue |
| `❌ Check AUR Package Updates failed` | `auto-update` | a failed job, see [Failed runs](#failed-runs) | the next run without a failed job |

A package gets no second issue of a kind while one is open, and an issue closed while its package still fails comes back in the next run. Each body links the run. An error holds text from upstream, so it stands in a code block, where links, images and mentions do not render, and keeps its last 4000 characters. A closing comment names the run and shows the new status.

A package whose YAML you delete gets no further check, so the next run closes its `update failed`, `check failed`, `update held` and arch issues with a comment that names the deleted file. A YAML whose `name` differs from its file name gets `check_failed` under the file name, and its issues stay open.

The host of a failed check is that of the first `http://` or `https://` URL in its error, in lower case and without the port, and `api.github.com` and `github.com` are two hosts. An error without a URL, and every failed update, gets the issue of its package. When a host issue closes, each of its packages that still fails gets its own issue in the same run.

Issues close before new ones open, so a package whose check passes and whose update fails gets its check issue closed and an update issue opened in one run. A failed step or a failed `publish` closes nothing. In a repository with Issues turned off, the job prints a notice and opens nothing.

## Failed runs

A run that fails in `pins`, `image` or `check` never reaches the job `issues`. For that case your calling workflow has the job `notify`, which calls `notify-failure.yml` at the same pin after every result but `success`, with `actions: read` and `issues: write`. It opens one issue `❌ Check AUR Package Updates failed` with a link to the run, its branch and the names of the jobs that failed or timed out, and no second one while that issue is open. GitHub marks a job that ran into its `timeout-minutes` as canceled, so a canceled job counts as timed out once it ran for the time limit of its job. A run canceled by hand before that has no failed job and gets no issue.
