---
title: Statistics
---

Repositories with packages keep package history in `stats/events.csv`, a journal that job `publish` adds to, and the README shows a card drawn from the journal. When statistics fail, the run commits the README and the package YAMLs without `stats/`.

## The journal

The first line of `stats/events.csv` is the header, and each line after it is one state change of a package:

```text
time,package,event,version,previous,run
2026-11-08T05:17:41Z,myapp-bin,tracked,0.138.0,,42200000001
2026-11-09T10:17:03Z,myapp-bin,updated,0.139.0,0.138.0,42210000002
2026-11-09T10:17:03Z,other-pkg,check_failed,2.5.0rc1,,42210000002
2026-11-10T05:17:22Z,other-pkg,up_to_date,2.5.0rc1,,42220000003
2026-11-10T05:17:22Z,new-pkg,added,1.30.0,,42220000003
```

| Column | Content |
|---|---|
| `time` | UTC time of the run, shared by its rows |
| `package` | package name |
| `event` | state the package moved to |
| `version` | version pushed or waited for, or the package version at a failure |
| `previous` | version before a push or version change |
| `run` | workflow run id, `https://github.com/<owner>/<repo>/actions/runs/<run>` |

| Event | Written for |
|---|---|
| `updated`, `downgrade`, `rebuilt`, `arch_added` | pushes to the AUR, as the status of the same name |
| `held`, `jump_skipped`, `downgrade_skipped`, `pending` | waits: the update to `version` does not go out yet |
| `check_failed`, `update_failed` | failures |
| `up_to_date` | packages at their version again after a wait or a failure |
| `tracked` | each package of the run that creates the journal |
| `added` | packages whose YAML is new |
| `removed` | packages whose YAML is gone |

Pushes are always written. Other statuses are written when they differ in kind from the last row of the package: pushes, `up_to_date`, `tracked` and `added` are one kind, and each wait, each failure and `removed` is a kind of its own. Waits are written again for another version. Packages that fail for a month give one `check_failed` row, so the card counts the times packages started to fail. Updates that are not out yet, such as `new_version`, write no row, and waits for [cooldown](/features/cooldown/) count as `up_to_date`.

Up-to-date packages whose `current` changed without a push of the run, by a hand edit or a push whose commit did not land, get an `updated` row, or `downgrade` when the version went down. Renamed packages get `removed` and `added` rows. Rows hold no free text: errors stay in their issue and in the run log.

Runs only add lines. Lines that a hand edit broke stay in the file, count for nothing and get a warning with their line number in the log. When the first line is not the header, the journal stops until the header is back.

## The card

`stats/card.svg` and `stats/card-dark.svg` show the journal on the day of the run, in the colors of the GitHub light and dark themes:

- repository, number of packages in `packages/`, number of failing packages, green at 0 and red otherwise, and the card date, so cards that no run redrew show their age
- over the last 7, 30 and 365 days: packages updated, pushes to the AUR, new packages and failed checks. Columns older than the journal are headed `since <month> <day>`
- heatmap of daily pushes over the last 53 weeks, one column per week from Sunday, as on GitHub profiles. Days before the first row have an outline only

Days are UTC days. The first run of each day commits the new card, as `chore: update package statistics [skip ci]` when nothing else changed. In the README the card follows the reader's theme, and clicking it opens the journal.

## Reading the journal elsewhere

GitHub shows `stats/events.csv` as a table with a search field, for files of up to 512 KB. Other tools read the journal of public repositories from its raw URL:

- Google Sheets: `=IMPORTDATA("https://raw.githubusercontent.com/<owner>/<repo>/<branch>/stats/events.csv")` in a cell. Sheets reads the URL again about once an hour while the sheet is open.
- Grafana: CSV query of the Infinity data source, on the same URL.

Raw URLs of private repositories need a token that can read their contents. The Infinity data source can send one, and `IMPORTDATA` cannot.
