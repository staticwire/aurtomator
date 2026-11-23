---
title: Updates of aurtomator
---

Runs use aurtomator at the commit that the calling workflows pin, the commit of a release tag, and read its version from `VERSION`. Dependabot opens pull requests in your repository that move the pin to new releases, see [The calling workflows](/setup/#the-calling-workflows). The first run on the new pin also updates `aurtomator.sh`, see [Verified commit](/internals/workflow/#verified-commit). `./aurtomator.sh version` prints the release of `aurtomator.sh` and the release of the pin, see [The aurtomator.sh script](/setup/#the-aurtomatorsh-script).

`check-all.sh` logs the version before the first package. Check runs read the latest release of `staticwire/aurtomator` from the GitHub API and compare it with `VERSION`. Newer releases open an issue, and runs close it once the pin reaches that release or a newer one comes out, see [Issues](/features/issues/). Failed requests log warnings, and the run goes on.

`update-readme.sh` writes the version under the package table and links newer releases when they are out:

```text
aurtomator 0.6.0 ([0.7.0 available](https://github.com/staticwire/aurtomator/releases/tag/v0.7.0))
```
