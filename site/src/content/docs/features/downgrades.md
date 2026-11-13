---
title: Downgrades and version jumps
---

An upstream version below `current` reaches the AUR only with `allow_downgrade: true` in the package YAML. Without it, `check-all.sh` writes `downgrade_skipped: <version>` and pushes nothing. A skipped downgrade opens no issue and is no failure.

The default protects against a lower version that upstream does not mean as a step back. Without `tag_version_regex`, `github-release` reads `/releases/latest`, and GitHub picks that release by the date of the commit it was made from. The date of publication does not count. A maintenance release of an older line, made from a newer commit, becomes the latest release, and without the default aurtomator would push it as a downgrade and push the newer version again at the next release.

A lower version also comes from upstream when it:

- deletes and recreates a release tag: in the gap `/releases/latest` returns the previous release, so a cycle like `v1.2.1 → v1.2.0 → v1.2.1` can take minutes
- rolls back a broken release and removes its tag
- marks an older line as latest again, as when a pulled 2.x release leaves 1.x the newest

`allow_downgrade: true` suits an upstream that rolls back on purpose, when the AUR package should follow it.

## Logs and statuses

`check-all.sh` logs the word `DOWNGRADE`. The first line below is a skipped downgrade. The second is an allowed one, once no alert holds it, its cooldown is over and any asset value is found:

```text
! myapp-bin: DOWNGRADE detected 1.2.1 → 1.2.0, skipped: allow_downgrade is not set
! myapp-bin: DOWNGRADE detected 1.2.1 → 1.2.0 (mirroring upstream)
```

`check-update.sh` run alone logs `! myapp-bin: DOWNGRADE 1.2.1 → 1.2.0`, so `grep DOWNGRADE` on a run log finds every case.

| Status | README | Meaning |
|---|---|---|
| `downgrade_skipped: 1.2.0` | `🔻 1.2.0 skipped (downgrade)` | the package does not allow it, nothing is pushed |
| `available_downgrade: 1.2.0` | `🔻 1.2.0 available (downgrade)` | the package allows it, the push comes next |
| `downgrade: 1.2.0` | `🔻 downgraded to 1.2.0` | pushed |

None of the three is a failure, and the [statistics](/features/statistics/) card counts a pushed downgrade as a push.

## Version jumps

A version whose first number has at least two digits more than the first number of `current`, such as `13 → 2026102100` or `4.4215 → 4215`, reaches the AUR only with `allow_version_jump: true`. Such a step can be another version scheme of the same upstream: GrapheneOS tags the standalone releases of `hardened_malloc` `1` to `14` and its GrapheneOS builds, such as `2026102100`, in one repository, and the default tag filter keeps both. Without the flag, `check-all.sh` writes `jump_skipped: <version>`, logs the line below and pushes nothing. The README shows `🔺 2026102100 skipped (version jump)`, and the skip opens no issue and is no failure.

```text
! hardened_malloc: version jump 13 → 2026102100, skipped: allow_version_jump is not set
```

A step such as `9 → 10` or `99 → 100` adds one digit and passes. A package that moves to another scheme on purpose, from `1.9` to `2026.1` for example, sets the flag and removes it once `current` holds the new scheme. Where a repository carries two schemes, `tag_version_regex` picks one.
