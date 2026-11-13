---
title: Statistics
---

A repository with a package keeps the history of its packages in `stats/events.csv`, a journal that the job `publish` adds to, and its README shows a card drawn from the journal. When the statistics fail, the run commits the README and the package YAMLs without `stats/`.

## The journal

The first line of `stats/events.csv` is the header, and each line after it is one change of state of a package:

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
| `time` | the UTC time of the run, shared by its rows |
| `package` | the name of the package |
| `event` | the state the package moved to |
| `version` | the version pushed or waited for, or the version of the package at a failure |
| `previous` | the version before a push or a change of version |
| `run` | the id of the workflow run, `https://github.com/<owner>/<repo>/actions/runs/<run>` |

| Event | Written for |
|---|---|
| `updated`, `downgrade`, `rebuilt`, `arch_added` | a push to the AUR, as the status of the same name |
| `held`, `jump_skipped`, `downgrade_skipped`, `pending` | a wait: the update to `version` does not go out yet |
| `check_failed`, `update_failed` | a failure |
| `up_to_date` | a package at its version again after a wait or a failure |
| `tracked` | each package of the run that creates the journal |
| `added` | a package whose YAML is new |
| `removed` | a package whose YAML is gone |

A push is always written. Any other status is written when it differs in kind from the last row of the package: the pushes, `up_to_date`, `tracked` and `added` are one kind, and each wait, each failure and `removed` is a kind of its own. A wait is written again for another version. A package that fails for a month gives one `check_failed` row, so the card counts the times a package started to fail. An update that is not out yet, such as `new_version`, writes no row, and a wait for the [cooldown](/features/cooldown/) counts as `up_to_date`.

An up-to-date package whose `current` changed without a push of the run, by a hand edit or a push whose commit did not land, gets an `updated` row, or `downgrade` when the version went down. A renamed package gets a `removed` and an `added` row. The rows hold no free text: the error of a failure stays in its issue and in the log of its run.

A run only adds lines. A line that a hand edit broke stays in the file, counts for nothing and gets a warning with its line number in the log. A first line other than the header stops the journal until the header is back.

## The card

`stats/card.svg` and `stats/card-dark.svg` show the journal on the day of the run, in the colors of the light and the dark theme of GitHub:

- the repository, the number of packages in `packages/`, the number of failing packages, green at 0 and red otherwise, and the day of the card, so a card no run drew again shows its age
- over the last 7, 30 and 365 days: the packages updated, the pushes to the AUR, the new packages and the failed checks. A column older than the journal is headed `since <month> <day>`
- a heatmap of the pushes of each day over the last 53 weeks, one column per week from Sunday, as on a GitHub profile. A day before the first row has an outline only

Days are UTC days. The first run of a day commits the new card, as `chore: update package statistics [skip ci]` when nothing else changed. In the README the card follows the theme of the reader, and a click on it opens the journal.

## Reading the journal elsewhere

GitHub shows `stats/events.csv` as a table with a search field, for a file of up to 512 KB. Other tools read the journal of a public repository from its raw URL:

- Google Sheets: `=IMPORTDATA("https://raw.githubusercontent.com/<owner>/<repo>/<branch>/stats/events.csv")` in a cell. Sheets reads the URL again about once an hour while the sheet is open.
- Grafana: a query of the type CSV of the Infinity data source, on the same URL.

The raw URL of a private repository needs a token that can read its contents. The Infinity data source can send one, and `IMPORTDATA` cannot.
