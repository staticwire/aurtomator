---
title: Updates of aurtomator
---

A run uses the aurtomator of the commit that the calling workflows pin, the commit of a release tag, and reads its version from `VERSION`. Dependabot opens the pull request in your repository that moves the pin to a new release, see [The calling workflows](/setup/#the-calling-workflows). The first run on the new pin also updates `aurtomator.sh`, see [Verified commit](/internals/workflow/#verified-commit).

`check-all.sh` logs the version before the first package. A check run reads the latest release of `staticwire/aurtomator` from the GitHub API and compares it with `VERSION`. A newer release opens an issue, which a run closes once the pin reaches that release or a newer one comes out, see [Issues](/features/issues/). A failed request logs a warning, and the run goes on.

`update-readme.sh` writes the version under the package table, with a link when a newer release is out:

```text
aurtomator 0.6.0 ([0.7.0 available](https://github.com/staticwire/aurtomator/releases/tag/v0.7.0))
```
