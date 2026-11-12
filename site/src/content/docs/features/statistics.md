---
title: Statistics
---

A repository with a package keeps the history of its packages in `stats/events.csv`, a journal that `publish` adds to, and its README shows a card drawn from the journal. Root runs the two scripts in **Record statistics** of `publish`, see [Steps](/internals/workflow/#steps): `record-events.sh` writes the journal, and `stats-card.sh` draws the card. When either fails, the run commits the README and the package YAMLs without `stats/`.

## The journal

`stats/events.csv` is a CSV file. Its first line is the header, and each line after it is one change of state of a package:

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
| `time` | The time in UTC when the run wrote the row, as `2026-11-09T10:17:03Z`. The rows of a run share it |
| `package` | The name of the package |
| `event` | What the package moved to, see the table of events |
| `version` | The version of the event: the version pushed or waited for, or the version of the package at a failure |
| `previous` | The version before a push or a change of version, empty for the other events |
| `run` | The id of the workflow run, which opens at `https://github.com/<owner>/<repo>/actions/runs/<run>` |

The rows hold no free text. The error of a failure stays in its issue and in the log of its run.

| Event | Written for |
|---|---|
| `updated`, `downgrade`, `rebuilt`, `arch_added` | A push to the AUR, as the status of the same name |
| `held`, `jump_skipped`, `downgrade_skipped`, `pending` | A wait: the update to `version` does not go out yet |
| `check_failed`, `update_failed` | A failure |
| `up_to_date` | A package at its version again after a wait or a failure, or at the first version known of it |
| `tracked` | Each package of the run that creates the journal |
| `added` | A package whose YAML is new |
| `removed` | A package whose YAML is gone |

The statuses of an update that is not out yet, `new_version`, `available_downgrade`, `new_build` and `arch_back`, write no row. A wait for the cooldown, `cooldown: <date>`, counts as `up_to_date` at the version of the package, see [Cooldown](/features/cooldown/).

`record-events.sh` compares the final status of each package with the last row of the package:

1. A push is always written, with `previous` set to `current` of the package before the run.
2. A status of another class than the last row is written. The pushes, `up_to_date`, `tracked` and `added` form one class, and each wait, each failure and `removed` is a class of its own.
3. An up-to-date package whose `current` after the run differs from the version of its last row that is no wait is written as `updated`, or as `downgrade` when `vercmp` puts the new version lower, with `previous`. This catches a version that changed without a push of the run: a hand edit of `current`, or a push whose commit did not land.
4. A wait is written again for another version.
5. Nothing else is written.

A package with a YAML and no row gets `added` first, or `tracked` in the run that creates the journal, with its `current` before the run. A package with rows and no YAML gets `removed` once, and a renamed package gets a `removed` and an `added`. A package that fails for a month gives one `check_failed` row, so the failed checks on the card count the times a package started to fail.

A run only adds lines to the journal. A line that is not a row, such as one a hand edit broke, stays in the file, counts for nothing and gets a warning with its line number in the log of the run. A first line other than the header stops `record-events.sh`, and the journal gets no rows until the header is back.

## The card

`stats-card.sh` draws `stats/card.svg` and `stats/card-dark.svg` from the journal for the day of the run. A card is 680 by 356 pixels, in the colors of the light or the dark theme of GitHub:

- The header names the repository and the number of packages in `packages/`. The number of packages whose last row is a failure follows it, in green when it is 0 and in red otherwise. The day of the card stands below them, as `updated Nov 8, 2026`, so a card that no run drew again shows its age.
- The table counts four things over the last 7, 30 and 365 days, the day of the run included. `Packages updated` counts the packages with at least one push, `Pushes to AUR` the pushes, `New packages` the `added` rows, and `Failed checks` the rows of `check_failed` and `update_failed`. While the journal is younger than a column, the column is headed `since <month> <day>` with the day of the first row.
- The heatmap shows the pushes of each day of the last 53 weeks, one column for each week from Sunday, as on the profile page of GitHub. The shades have fixed steps at 1, 2, 4 and 6 pushes a day, so one busy day leaves the shades of the other days as they are. A day before the first row of the journal has an outline only, so a day without data looks different from a day without a push.

Days are UTC days. The same journal, packages and day give the same bytes.

**Decide** of `check` draws the card of the day from the committed journal and sets `work` when it differs from `stats/card.svg`. The windows of the card move once a day, so the first run of a day commits a new card, as `chore: update package statistics [skip ci]` when nothing else changed, and the later runs of that day find it unchanged. The first run with statistics commits the journal with a `tracked` row for each package, both cards and the new block of the README together.

## Reading the journal elsewhere

GitHub shows `stats/events.csv` as a table with a search field, for a file of up to 512 KB. Other tools read the journal of a public repository from its raw URL:

- Google Sheets: `=IMPORTDATA("https://raw.githubusercontent.com/<owner>/<repo>/<branch>/stats/events.csv")` in a cell. Sheets reads the URL again about once an hour while the sheet is open.
- Grafana: a query of the type CSV of the Infinity data source, on the same URL.

For a private repository, the raw URL needs a token that can read the contents of the repository. The Infinity data source can send one with its authentication, and `IMPORTDATA` sends none.

## Statistics card

The package block starts with the cards that **Record statistics** of `publish` draws in `stats/`, see [The card](#the-card):

```html
<a href="stats/events.csv">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="stats/card-dark.svg">
  <img width="100%" alt="Packages updated, pushes to AUR, new packages and failed checks over 7, 30 and 365 days" src="stats/card.svg">
</picture>
</a>
```

GitHub shows `card-dark.svg` in its dark theme and `card.svg` in its light one, and a click on the card opens the journal. The card takes the width of the README, and the SVG scales with it. The block is the same in every run, so new numbers change the files in `stats/` and leave the README as it is.
