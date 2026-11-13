---
title: Updates of aurtomator
---

`VERSION` in the root of aurtomator holds its version, and the release PR of aurtomator writes it, see `CONTRIBUTING.md`. A run reads it from the checkout in `aurtomator/`, so the version a run uses is that of the SHA the calling workflows pin, the SHA of a release tag. Dependabot opens the pull request in your repository that moves the pin to a new release, see [The calling workflows](/setup/#the-calling-workflows). The first run on the new pin also updates `aurtomator.sh` to that release, see [Verified commit](/internals/workflow/#verified-commit).

`check-all.sh` logs the version before the first package, in every mode but `--verify`. In a check run and with `--update`, it reads the latest release of `staticwire/aurtomator` from the GitHub API, with `GITHUB_TOKEN` when it is set, and compares it with `VERSION` by `vercmp`. It writes `newer: <release>` or `current: <release>` to `.status/_upstream` and logs a line when the release is newer. A failed request, or a tag other than `vX.Y.Z`, logs a warning and writes nothing, and the run goes on. `--prepare` and `--publish` run no request and carry `.status/_upstream` of the check run. Without `VERSION`, it asks nothing.

`update-readme.sh` writes the version under the package table, and with `newer:` a link to the release:

```text
aurtomator 0.6.0 ([0.7.0 available](https://github.com/staticwire/aurtomator/releases/tag/v0.7.0))
```

A run that could not read the release writes the line without the link.

A newer release also opens an issue, and a run closes it once the pin names that release or a newer one is out, see [Issues](/features/issues/).
