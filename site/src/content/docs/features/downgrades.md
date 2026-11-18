---
title: Downgrades and version jumps
---

Upstream versions below `current` reach the AUR only with `allow_downgrade: true` in the package YAML. Without it, `check-all.sh` writes `downgrade_skipped: <version>` and pushes nothing. Pushes by hand leave `current` below the AUR, so the update compares the new version with `pkgver` of the AUR as well and stops below it. AUR repositories whose `.SRCINFO` holds another `pkgver` or `pkgrel` than the PKGBUILD stop the update with `update_failed` and an issue, since the comparison would take the version of the old `.SRCINFO`. Skipped downgrades open no issue and are not failures.

The default protects against lower versions that upstream does not mean as a step back. Without `tag_version_regex`, `github-release` reads `/releases/latest`, and GitHub picks that release by its commit date. Publication dates do not count. Maintenance releases of an older line, made from a newer commit, become the latest release, and without the default aurtomator would push them as downgrades and push the newer version again at the next release.

Upstream also gives lower versions when it:

- deletes and recreates release tags: in the gap `/releases/latest` returns the previous release, so cycles like `v1.2.1 → v1.2.0 → v1.2.1` can take minutes
- rolls back broken releases and removes their tags
- marks older lines as latest again, as when pulled 2.x releases leave 1.x the newest

`allow_downgrade: true` suits upstreams that roll back on purpose, when the AUR package should follow them.

## Logs and statuses

`check-all.sh` logs the word `DOWNGRADE`. In the lines below, the first downgrade is skipped and the second is allowed, once no alert holds it, its cooldown is over and any asset value is found:

```text
! myapp-bin: DOWNGRADE detected 1.2.1 → 1.2.0, skipped: allow_downgrade is not set
! myapp-bin: DOWNGRADE detected 1.2.1 → 1.2.0 (mirroring upstream)
```

`check-update.sh` run alone logs `! myapp-bin: DOWNGRADE 1.2.1 → 1.2.0`, so `grep DOWNGRADE` on run logs finds every case.

| Status | README | Meaning |
|---|---|---|
| `downgrade_skipped: 1.2.0` | `🔻 1.2.0 skipped (downgrade)` | package does not allow it, nothing pushed |
| `available_downgrade: 1.2.0` | `🔻 1.2.0 available (downgrade)` | package allows it, pushed next |
| `downgrade: 1.2.0` | `🔻 downgraded to 1.2.0` | pushed |

None of the three is a failure, and the [statistics](/features/statistics/) card counts pushed downgrades as pushes.

## Version jumps

Versions whose first number has at least two digits more than the first number of `current`, such as `13 → 2026102100` or `4.4215 → 4215`, reach the AUR only with `allow_version_jump: true`. Such steps can come from another version scheme of the same upstream: GrapheneOS tags the standalone releases of `hardened_malloc` `1` to `14` and its GrapheneOS builds, such as `2026102100`, in one repository, and the default tag filter keeps both. Without the flag, `check-all.sh` writes `jump_skipped: <version>`, logs the line below and pushes nothing. The README shows `🔺 2026102100 skipped (version jump)`, and the skip opens no issue and is no failure.

```text
! hardened_malloc: version jump 13 → 2026102100, skipped: allow_version_jump is not set
```

Steps such as `9 → 10` or `99 → 100` add one digit and pass. Packages that move to another scheme on purpose, from `1.9` to `2026.1` for example, set the flag and remove it once `current` holds the new scheme. Where one repository carries two schemes, `tag_version_regex` picks one.
