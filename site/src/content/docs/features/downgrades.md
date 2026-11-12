---
title: Downgrades and version jumps
---

An upstream version lower than `current` reaches the AUR only when the package YAML sets `allow_downgrade: true`. Without it, `check-all.sh` skips the version, writes `downgrade_skipped: <version>` and pushes nothing. A skipped downgrade opens no issue and does not count as a failure. `--prepare` and `--publish` apply the same rule, so a downgrade of a package without the flag is never prepared or published.

The default guards against a lower version that upstream does not mean as a step back. Without `tag_version_regex`, `github-release` reads `/releases/latest`, and GitHub picks that release by the date of the commit it was made from. The date it was published does not count. A maintenance release of an older line, made from a commit newer than the one of the current release, becomes the latest release. Without the flag, aurtomator would push it as a downgrade and push the newer version again at the next release.

`allow_downgrade: true` fits a package whose upstream does mean it, for example one that rolls back a broken release and the AUR package should follow.

## When does this happen?

- Upstream publishes a maintenance release of an older line, and `/releases/latest` returns it.
- Upstream deletes and recreates a release tag. In the gap, `/releases/latest` returns the previous release, so a cycle like `v1.2.1 → v1.2.0 → v1.2.1` can take only minutes.
- Upstream rolls back a broken release and removes its tag.
- Upstream marks an older release line as latest again, for example when a 2.x release is pulled and 1.x becomes the newest release.

## How to detect downgrades in logs

A comparison that finds the current version newer than the latest one (`vercmp "$current" "$latest"` prints `1`) logs the literal token `DOWNGRADE`. In a CI run, `check-all.sh` logs the first line for a package without `allow_downgrade: true`. For a package with it, the second line follows once no alert holds the update, its cooldown is over and, for a package with `upstream.asset_regex`, its asset value is found:

```text
! myapp-bin: DOWNGRADE detected 1.2.1 → 1.2.0, skipped: allow_downgrade is not set
! myapp-bin: DOWNGRADE detected 1.2.1 → 1.2.0 (mirroring upstream)
```

`check-update.sh` run on its own logs:

```text
! myapp-bin: DOWNGRADE 1.2.1 → 1.2.0
```

`grep DOWNGRADE` on a downloaded run log finds both.

## Status values and README icons

`check-all.sh` writes three status tokens for downgrades to `.status/<pkg>`:

| Token                          | Meaning                                                        |
|--------------------------------|----------------------------------------------------------------|
| `downgrade_skipped: <version>` | A downgrade was found for a package without `allow_downgrade: true`. Nothing is pushed |
| `available_downgrade: <ver>`   | A downgrade the package allows was found and is not pushed yet |
| `downgrade: <version>`         | The downgrade was pushed to the AUR                            |

`update-readme.sh` renders them as:

- `downgrade_skipped: 1.2.0` → `🔻 1.2.0 skipped (downgrade)`
- `available_downgrade: 1.2.0` → `🔻 1.2.0 available (downgrade)`
- `downgrade: 1.2.0` → `🔻 downgraded to 1.2.0`

None of the three is a failure, and the statistics card counts a pushed downgrade as a push, see [Statistics](/aurtomator/features/statistics/).

## Version jumps

An update whose first number has at least two digits more than the first number of `current`, such as `13 → 2026102100` or `4.4215 → 4215`, reaches the AUR only when the package YAML sets `allow_version_jump: true`. Such a step is more often another version scheme of the same upstream than a release: GrapheneOS tags the standalone releases of `hardened_malloc` `1` to `14` and its GrapheneOS builds, such as `2026102100`, in the same repository, and the default tag filter keeps both. Without the flag, `check-all.sh` writes `jump_skipped: <version>`, logs the line below and pushes nothing. `--prepare` and `--publish` apply the same rule. A skipped jump opens no issue and does not count among the failing packages of the statistics card, and `update-readme.sh` renders `jump_skipped: 2026102100` as `🔺 2026102100 skipped (version jump)`.

```text
! hardened_malloc: version jump 13 → 2026102100, skipped: allow_version_jump is not set
```

A step such as `9 → 10` or `99 → 100` adds one digit and passes. A package that moves to another scheme on purpose, from `1.9` to `2026.1` for example, sets the flag and can remove it once `current` holds the new scheme. Where a repository carries two schemes, `tag_version_regex` picks one.
