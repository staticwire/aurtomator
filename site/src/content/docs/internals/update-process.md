---
title: Update process
---

`update-pkg.sh` updates one package. `check-all.sh --update` runs it for every package with a new version, and the workflow splits the same update into prepare, verify and publish, see [Prepare and publish](#prepare-and-publish).

## Time limits

Outside `--update`, `check-all.sh` gives each package 120 seconds for `check-update.sh` and 300 seconds each for `update-pkg.sh`, `verify-pkg.sh` and `publish-pkg.sh`. `timeout` ends the script with everything it started, and the package gets `check_failed: timed out after 120 s` or `update_failed: timed out after 300 s`, with the URL of the request that was running, as in `check_failed: https://github.com/owner/repo.git: timed out after 120 s`. `AURTOMATOR_CHECK_TIMEOUT` and `AURTOMATOR_UPDATE_TIMEOUT` change the limits. `--update` has none, because it runs on a terminal, where git and ssh can ask for a passphrase.

A check that fails before its limit runs once more after all the other packages and a pause of 60 seconds, `AURTOMATOR_RECHECK_DELAY`, and the second result counts. A check that ran out of time, or failed on a silent host, runs once, so a run without network does not take twice as long.

A host that times out without any answer is silent for the rest of the run: every later request to it fails at once with `<url>: <host> did not answer earlier in this run`, so a silent host costs one check, whatever the number of its packages. A check that runs out of time during a request to a host makes it silent when one more `HEAD` request of 10 seconds gets no answer either. A refused connection, a failed DNS lookup, an HTTP error, an answer that stops halfway and a redirect to a silent host do not. A URL with a user name or a port, such as `https://git.example.com:8443/`, never makes its host silent, since curl contacts another host or port than the bare name.

## Arguments

```text
update-pkg.sh <package-name> <new-version> [--asset <value>] [--arch-out <arches>] [--dry-run] [--prepare <dir>]
verify-pkg.sh <package-name> <version> <prepared-dir> [--asset <value>] [--arch-out <arches>]
publish-pkg.sh <package-name> <version> <prepared-dir> [--asset <value>] [--arch-out <arches>] [--dry-run]
check-asset.sh <package-name> <pkgver>
check-arch.sh <package-name> <version> [--asset <value>]
check-all.sh [--update | --prepare <dir> | --verify <dir> | --publish <dir>] [--dry-run]
```

## Step-by-step

1. Read `.aurtomator.conf` as data, see [Configuration file](/setup/#configuration-file). In CI, `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL` and `GPG_KEY_ID` come from the workflow.
2. Clone `ssh://aur@aur.archlinux.org/<package-name>.git` after 2 seconds, with up to 3 attempts 5 seconds apart. A clone without a PKGBUILD stops the update.
3. Reset `master` to `origin/master` when the clone lands on a detached `HEAD`, so the push is a fast-forward.
4. Warn when the PKGBUILD has no `# Maintainer:` line.
5. Audit the PKGBUILD: `pkgver()` with the wrong strategy and mixed checksums block the update, and patches and an `epoch` other than 0 warn, see [Supported packages](/supported-packages/).
6. Set `pkgver` with `sed` and `pkgrel` to 1, or to the `pkgrel` of the AUR when the AUR has the version already, and the line of `upstream.asset_var`, see [Values from release asset names](/features/asset-values/). When `pkgver` and `pkgrel` of the AUR hold these values already, read as bash reads them, the script writes `current` and `current_asset` and exits with code 2. A dry run writes neither.
7. Check every `http` and `https` source URL, whatever its checksum. Then run `updpkgsums` and `makepkg --verifysource --skippgpcheck`, unless a checksum holds a `SKIP` that makepkg does not write itself, see [Packages with VCS checksums](/supported-packages/#packages-with-vcs-checksums-skip). Any failure stops the update.
8. Run `namcap` when it is installed. Its errors stop the update, and its warnings are printed.
9. Regenerate `.SRCINFO` with `makepkg --printsrcinfo`.
10. Check `PKGBUILD` and `.SRCINFO` against the clone, as steps 4 and 5 of publish do. A refused file stops the update.
11. With `--dry-run`, print the diff of the PKGBUILD and stop.
12. Commit as `<new-version> release from <strategy>`, or `<new-version>-<pkgrel> release from <strategy>` for a rebuild, authored by `GIT_AUTHOR_NAME` and `GIT_AUTHOR_EMAIL`, by default `aurtomator` and `aurtomator@users.noreply.github.com`. With `GPG_KEY_ID`, sign the commit, and push it unsigned when signing fails.
13. Push, with up to 3 attempts 5 seconds apart.
14. Write `current`, `current_asset` and `last_updated` to the package YAML.

`AURTOMATOR_CLONE_DELAY` and `AURTOMATOR_RETRY_DELAY` change the 2 and the 5 seconds.

## Prepare and publish

A PKGBUILD is a bash script, and steps 5 and 7 to 9 run it. Whoever can push to the AUR repository of a package, a co-maintainer for example, runs code there. The workflow splits the update so that this code never runs where the SSH key, the GPG key or a write token is: prepare runs it in a job of its own for each package, verify checks the checksums against the sources, and publish pushes files that neither job can change on the way.

**Prepare**, `update-pkg.sh --prepare <dir>`, holds no secrets:

1. Clone `https://aur.archlinux.org/<package-name>.git` anonymously.
2. Run steps 3 to 9. With `--arch-out`, the update also changes the `arch=(...)` line, see [Versions without some arches](/features/missing-arches/).
3. Write `PKGBUILD`, `.SRCINFO` and the commit id of `HEAD` as `base` to `<dir>/<package-name>/`. Nothing is committed. Exit code 2 means the AUR has the version already.

**Verify**, `verify-pkg.sh <package-name> <version> <dir>/<package-name>`, holds no secrets and never runs the PKGBUILD or `makepkg`:

1. The prepared directory passes step 1 of publish.
2. Clone anonymously with `--no-checkout`, and exit with code 3 when `HEAD` is not `base`: the AUR moved after the prepare. The files of `HEAD` are written out with `git ls-tree` and `git cat-file`, so no link, attribute or filter of the repository applies. Prepared files equal to these end the verify with exit code 0.
3. At the version of the AUR, the prepared files must be those of the AUR. Otherwise they pass steps 4 and 5 of publish with `<version>` and the asset value of `--asset`, before anything is downloaded.
4. Each checksum array of the prepared `PKGBUILD` holds the values of its key in the prepared `.SRCINFO`.
5. Every checksum other than `SKIP` matches its source, computed as makepkg computes it. A file of the AUR repository with the name of the source comes first. A remote source is downloaded over `https` alone, redirects included, and a download stops past 600 MiB or below 100 KiB/s for 60 seconds; the downloads of one package share 1 GiB. A git source at `#tag=` or a full `#commit=` is fetched alone over `https` with the same limits, and its checksum is that of `git archive --format tar`, as makepkg computes it. A checksum of a download over `http` or `ftp`, or of another VCS, cannot be checked and stops the verify.
6. Any mismatch stops the verify with exit code 1.

**Publish**, `publish-pkg.sh <package-name> <version> <dir>/<package-name>`, holds the keys and never runs the PKGBUILD or `makepkg`:

1. The prepared directory is no symlink, `PKGBUILD`, `.SRCINFO` and `base` are regular files, and `base` is a commit id.
2. Clone over SSH with `--no-checkout` and write the AUR copy as verify does. When `HEAD` is not `base`, exit with code 3.
3. At the version and asset value of the AUR, the prepared files must be those of the AUR: the publish sets `current` and exits with code 2. Otherwise the prepared `pkgver` must be `<version>`. With `--arch-out`, an update that changes `arch=(...)` at the version of the AUR goes on to step 4, see [Versions without some arches](/features/missing-arches/).
4. The prepared `PKGBUILD` may differ from the AUR copy only in `pkgver=`, which is `<version>`; in `pkgrel=`, which is `1`, or that of the AUR at its own version, or as [Values from release asset names](/features/asset-values/) sets it; in the line of `upstream.asset_var`; and in the values of the checksum arrays. The arrays keep their names, lengths and `SKIP` positions and hold quoted hex checksums or `SKIP`, in their places or in one block at the place of the first, as `updpkgsums` writes them. A comment or an empty line inside an array must be one the AUR copy has, since `updpkgsums` writes none, and a backslash on the closing line stops the publish, since bash joins the next line to the assignment.
5. The prepared `.SRCINFO` has as many lines as the AUR copy, empty lines at the end left out, and each line follows from the AUR copy:
   - A `source` line is the AUR line with the old version replaced by `<version>`. A source that is `SKIP` everywhere may also change the digits of its saved name, the part before `::`, as `neovim-20261014.tar.gz` becomes `neovim-20261016.tar.gz`.
   - Any other line whose value the text of the AUR `PKGBUILD` holds, outside its `pkgver=`, `pkgrel=`, asset and checksum lines and its comment lines, stays as it is, as `GPL-2.0` does at version `2.0`. Any other line takes the new version, as `provides = demo=2.1` does from `provides=("demo=${pkgver}")`.
   - A replacement also covers the forms a PKGBUILD often derives from `pkgver`: dots and plus signs as underscores (`1_86_0`, `28_21` of `28+21`), the part before the first `+` (`0.13.0` of `0.13.0+dev+1853+g6edb38ca98`), the version without its last component while it keeps a dot (`6.19` of `6.19.0`), the dash forms of `pkgver_dash` and the upstream version of `pkgver_format`. A form counts only where it does not continue a number, and each part of a line is replaced once. Any other form, or a version replaced in one place and kept in another, stops the publish.
   - When `pkgver` changes, at least one source URL or checksum changes for each architecture where a download has a real checksum or a VCS source is pinned. A download saved under a new name with the URL and the checksum of the old one is refused, since it holds the old file, see [Sources that do not follow pkgver](/supported-packages/#sources-that-do-not-follow-pkgver-blocked).
6. Any other difference, and a NUL byte in either file, stops the publish with exit code 1. The two files then enter the index of the clone byte for byte, through `git hash-object --no-filters`, because `git add` would pass them through the attributes of the AUR repository, and `working-tree-encoding=UTF-7` there turns `+AAo-` in a comment into a new line. Steps 12 to 14 follow.

The AUR serves the description, the dependencies and the licenses of a package from `.SRCINFO`, and AUR helpers such as yay parse it. Code in prepare writes the `.SRCINFO` of its package, so step 5 derives every line from the text of the PKGBUILD, which verify and publish read without running it. In three cases that text does not tell how makepkg writes a line, and a correct update stops, see [Lines the check cannot read from the PKGBUILD](/supported-packages/#lines-the-check-cannot-read-from-the-pkgbuild-blocked).

`check-all.sh --prepare <dir>` runs no strategy. It takes the versions from the statuses of the check run, `new_version`, `available_downgrade`, `new_build` and `arch_back`, with the asset values and arch lines of that run, and applies the rules of downgrades, version jumps, alerts and the cooldown again. A failed preparation becomes `update_failed`. `--verify <dir>` runs `verify-pkg.sh` for every prepared package with the same versions, removes an update that fails, and starts no package after 20 minutes, `AURTOMATOR_VERIFY_BUDGET`, so its job ends within 30. Its loop starts at another package each hour, so slow sources cannot hold back the same packages in every run. `--publish <dir>` takes the same statuses again, contacts no upstream host while the keys are in place, and publishes each prepared update. Exit code 3 of verify or publish leaves the package to the next run, which prepares it again. A run prepares at most 256 packages and leaves the rest for a later run.
