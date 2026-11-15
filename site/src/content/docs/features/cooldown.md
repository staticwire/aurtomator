---
title: Cooldown
---

`-git` packages get a new version with every upstream commit, and every push makes their users build the package again at their next upgrade. Cooldown holds the next push of a package for some days after the last one. The AUR does not expect VCS packages to follow every commit: its form for flagging packages out of date asks users not to flag `-git` packages only because they lag the latest commit.

`cooldown_days` in the package YAML sets the wait in whole days, from 0 to 365. Without it, `git-latest` packages wait 7 days and packages of other strategies do not wait. `cooldown_days: 0` turns cooldown off.

```yaml
name: my-package-git
strategy: git-latest
upstream:
  type: github
  project: owner/repo
cooldown_days: 14
```

Days count from `last_updated`, the UTC date that each push writes to the package YAML. Runs that find the new version already on the AUR, as after pushes whose YAML commit was lost, write their own date. After a push on 2026-11-05 with 7 days, the next push goes out with the first run on 2026-11-12. Packages without `last_updated` do not wait, so new packages go out at once. Delete the `last_updated` line, and the next run pushes the waiting update. Runs started by hand wait as scheduled runs do.

Every push waits: new versions, allowed downgrades and rebuilds for new asset values. Arches put back at the version the AUR has do not wait, see [Versions without some arches](/features/missing-arches/). The strategy still runs in every run, so broken upstreams show at once. Skipped downgrades, skipped version jumps and held updates keep their own status.

Waiting packages get status `cooldown: <date>` with the day of their push, and the README shows `💤 next update <date>`. The log names both versions:

```text
→ my-package-git: r2378.06ea49d → r2391.1f3c2a7 waits until 2026-11-12
```

Waiting is no failure and opens no issue. Open `❌ <package>: check failed` issues close, since the check passed. `❌ <package>: update failed` and `✋ <package>: update held` stay open until the version is in the AUR. The [Statistics](/features/statistics/) journal counts waits as `up_to_date`.

`validate-pkg.sh` refuses `cooldown_days` values other than whole numbers from 0 to 365, and `last_updated` values that are not dates `YYYY-MM-DD` or lie in the future. Packages with a new version fail their check on such values.
