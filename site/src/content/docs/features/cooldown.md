---
title: Cooldown
---

A `-git` package gets a new version with every upstream commit, and every push makes its users build the package again at their next upgrade. The cooldown holds the next push of a package for some days after the last one. The AUR does not expect a VCS package to follow every commit: its form to flag a package out of date asks users not to flag a `-git` package only because it lags the latest commit.

`cooldown_days` in the package YAML sets the days, a whole number from 0 to 365. Without it, a `git-latest` package waits 7 days and a package of any other strategy does not wait. `cooldown_days: 0` turns the cooldown off.

```yaml
name: my-package-git
strategy: git-latest
upstream:
  type: github
  project: owner/repo
cooldown_days: 14
```

The days count from `last_updated`, the UTC date that each push writes to the package YAML. A run that finds the new version already on the AUR, as after a push whose commit of the YAML was lost, writes the date of that run. After a push on 2026-11-05 with 7 days, the next push goes out with the first run on 2026-11-12. A package without `last_updated` does not wait, so a new package goes out at once. Delete the `last_updated` line to push a waiting update with the next run. A run started by hand waits as a scheduled run does.

Every push waits: a new version, an allowed downgrade and a rebuild for a new asset value. An arch put back at the version the AUR has does not wait, see [Versions without some arches](/features/missing-arches/). The strategy still runs in every run, so a broken upstream shows at once. A skipped downgrade, a skipped version jump and a held update keep their own status.

A waiting package gets the status `cooldown: <date>` with the day of its push, and the README shows `💤 next update <date>`. The log names both versions:

```text
→ my-package-git: r2378.06ea49d → r2391.1f3c2a7 waits until 2026-11-12
```

A wait is no failure and opens no issue. An open `❌ <package>: check failed` closes, since the check passed. `❌ <package>: update failed` and `✋ <package>: update held` stay open until the version is in the AUR. The journal of [Statistics](/features/statistics/) counts a wait as `up_to_date`.

`validate-pkg.sh` refuses a `cooldown_days` other than a whole number from 0 to 365, and a `last_updated` that is not a date `YYYY-MM-DD` or lies in the future. A package with a new version fails its check on such a value.
