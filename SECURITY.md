# Security Policy

## Supported versions

| Version | Supported |
| ------- | --------- |
| latest release | yes |
| older releases | no |

There are no backports. A user repository calls the workflows of aurtomator at a pinned SHA, the SHA of a release tag. It is expected to move the pin to the latest release, and Dependabot opens the pull request that moves it, see [docs/SETUP.md](docs/SETUP.md#the-calling-workflows). Unreleased `main` is not supported.

## Reporting a vulnerability

Report vulnerabilities privately through GitHub's Private Vulnerability Reporting. Do not open a public issue for a security bug.

1. Open <https://github.com/staticwire/aurtomator/security/advisories/new>.
2. Fill in the advisory form: affected components, reproduction steps, impact, and any suggested mitigation.
3. Attach proof-of-concept material to the draft advisory instead of linking to external services.
4. Submit. The advisory stays private between you and the maintainer until it is published.

Expect an acknowledgment within 7 days. aurtomator has one maintainer, and there is no SLA for triage, fix or disclosure after the acknowledgment. Without an acknowledgment after 7 days, submit a new advisory that mentions the first one.

## Scope

In scope:

- `scripts/`: any defect that allows arbitrary code execution, secret exfiltration, or writes outside the working tree.
- `strategies/`: injection through crafted upstream responses, YAML parsing issues, or command injection through package configuration.
- `.github/workflows/`: misconfiguration that leaks the `AUR_SSH_KEY`, `GPG_SIGNING_KEY`, `AUR_GIT_NAME` or `AUR_GIT_EMAIL` secrets into logs, artifacts, pull requests or third-party actions. A user repository passes these secrets to the reusable workflows when it calls them.
- Anything else in this repository that can make a user repository push a compromised package to the AUR without the intent of its maintainer.

Out of scope:

- Vulnerabilities in external tools that aurtomator calls (`makepkg`, `yq`, `curl`, `git`, `namcap`, `shellcheck`, `shfmt`, `bats`). Report those upstream.
- The contents of AUR packages published from user repositories. The maintainer of each user repository is responsible for the packages they publish.
- The model itself: a user repository runs the workflows with its own AUR key, and a pin that is not the SHA of a release tag runs the code of the commit it names.
- Issues in third-party GitHub Actions. Report them to the action's maintainer. aurtomator pins every action by commit SHA.

## Known limitations

Publish compares a line of the prepared `.SRCINFO` other than `pkgver`, `pkgrel`, `source` and the checksums with the AUR copy, and accepts it with the old version or with the new one. Telling which of the two the PKGBUILD yields needs the PKGBUILD to run. Code in the PKGBUILD of a tracked package can therefore keep the old version in such a line of any package updated in the same run, and the AUR then shows a stale description, dependency or relation. Details are in [docs/WORKFLOW.md section 4.4](docs/WORKFLOW.md#44-prepare-and-publish).

## Disclosure

Once a reported issue is fixed, the advisory is published on the repository's Security tab. A CVE assigned through GitHub's CNA is referenced in the published advisory. A user repository gets the fix once the pin of its calling workflows moves to a release that holds the fix. Watching this repository's releases gives a notification when a fix ships.
