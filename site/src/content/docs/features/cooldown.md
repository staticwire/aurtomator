---
title: Cooldown
---

A `-git` package gets a new version with every upstream commit, and each push makes the AUR helpers of its users build the package again at their next upgrade. The cooldown holds the next push of a package until some days after the last one. The AUR does not expect a VCS package to follow every commit: its form to flag a package out of date asks users not to flag a `-git` package whose version lags the latest commit, and to flag it only when the sources moved or the PKGBUILD needs a change.

`cooldown_days` in the package YAML sets the days, a whole number from 0 to 365. Without it, a package of the `git-latest` strategy waits 7 days, and a package of any other strategy does not wait. `cooldown_days: 0` turns the cooldown off, and a package of any strategy can set days of its own:

```yaml
name: my-package-git
strategy: git-latest
upstream:
  type: github
  project: owner/repo
cooldown_days: 14
```

The days count from `last_updated`, the UTC date that a push writes to the package YAML, see step 14 of [Step-by-step](/internals/update-process/#step-by-step). The next push goes out with the first run on the day `last_updated` plus `cooldown_days`: after a push on 2026-11-05, with 7 days, the next one goes out with the first run on 2026-11-12. A run that finds the version in the AUR already writes `current` and leaves `last_updated` as it is. A package without `last_updated` has no cooldown, so a new package is pushed at once, and that push writes the date.

The cooldown holds every push: a new version, a downgrade that the package allows, and a rebuild for a new asset value. An arch put back at the version the AUR has is no new version and does not wait, see [Versions without some arches](/features/missing-arches/). `check-all.sh` applies it after the checks of [Downgrades and version jumps](/features/downgrades/) and [Update alerts](/features/update-alerts/), so a skipped downgrade or version jump and a held update keep their statuses. It applies it before it looks up the asset value of a new version, so a waiting package sends no request for that value. The strategy runs in every run, and an upstream repository that was deleted fails the check in the next run, as before. Only the push waits.

A waiting package gets the status `cooldown: <date>`, with the day its push goes out, and `check-all.sh` logs:

```text
→ my-package-git: r2378.06ea49d → r2391.1f3c2a7 waits until 2026-11-12
```

`update-readme.sh` renders `cooldown: 2026-11-12` as `💤 next update 2026-11-12`. A package in its cooldown without a newer version is `up_to_date`, as before. The status holds no version, so the package table changes when a wait starts and at the push, and new upstream commits during the wait leave it as it is.

Nothing about a wait counts as a failure. The run summary lists the package with its label and shows no error for it, and no issue opens. An open `❌ <package>: check failed` closes, because the check passed, while `❌ <package>: update failed` and `✋ <package>: update held` stay open until the version is in the AUR, see [Issues](/features/issues/). The journal counts a wait as `up_to_date` at the version of the package and writes the push as `updated`, see [Statistics](/features/statistics/), so the statistics card counts no wait among the failing packages.

A waiting update goes out with the next run once the `last_updated` line of its package is deleted, and that push writes the date again. A run started by hand follows the cooldown as a scheduled run does.

`--prepare` and `--publish` keep a `cooldown` of the check run, as they keep `held`, and apply the cooldown again to `new_version`, `available_downgrade` and `new_build`, see [Prepare and publish](/internals/update-process/#prepare-and-publish). A `cooldown` status without a valid date becomes `check_failed: invalid status from the check run`, and so does a status whose version `validate_pkgver` refuses, of any kind.

`validate-pkg.sh` refuses a `cooldown_days` that is not a whole number from 0 to 365, a `last_updated` that is not a date `YYYY-MM-DD`, and a `last_updated` later than the current UTC date, since a typo in the year would hold the package for years. A package with a new version fails its check when its `cooldown_days` is not valid, or when its `last_updated` is not a date while the cooldown is on. The status then is `check_failed: cooldown_days must be a whole number from 0 to 365: <value>` or `check_failed: last_updated must be a date YYYY-MM-DD: <value>`.
