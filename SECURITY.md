# Security Policy

## Supported versions

| Version | Supported |
| ------- | --------- |
| latest release | yes |
| older releases | no |

There are no backports. User repositories call aurtomator workflows at a pinned SHA, the SHA of a release tag. They are expected to move the pin to the latest release, and Dependabot opens the pull requests that move it, see [The calling workflows](https://aurtomator.dev/setup/#the-calling-workflows). Pins count once their release is published: job `pins` of the calling workflows stops at a tag whose release is a draft or missing. Unreleased `main` is not supported.

## Reporting a vulnerability

Report vulnerabilities privately through GitHub's Private Vulnerability Reporting. Do not open public issues for security bugs.

1. Open <https://github.com/staticwire/aurtomator/security/advisories/new>.
2. Fill in the advisory form: affected components, reproduction steps, impact, and any suggested mitigation.
3. Attach proof-of-concept material to the draft advisory instead of linking to external services.
4. Submit. The advisory stays private between you and the maintainer until it is published.

Expect an acknowledgment within 7 days. aurtomator has one maintainer, and there is no SLA for triage, fix or disclosure after the acknowledgment. Without an acknowledgment after 7 days, submit a new advisory that mentions the first one.

## Scope

In scope:

- `scripts/`: any defect that allows arbitrary code execution, secret exfiltration, or writes outside the working tree.
- `strategies/`: injection through crafted upstream responses, YAML parsing issues, or command injection through package configuration.
- `.github/workflows/` and `.github/actions/`: misconfiguration that leaks the `AUR_SSH_KEY`, `GPG_SIGNING_KEY`, `AUR_GIT_NAME` or `AUR_GIT_EMAIL` secrets into logs, artifacts, pull requests or third-party actions. User repositories pass these secrets to the reusable workflows when they call them.
- Anything else in this repository that can make a user repository push a compromised package to the AUR without the intent of its maintainer.

Out of scope:

- Vulnerabilities in external tools that aurtomator calls (`makepkg`, `yq`, `curl`, `git`, `bsdtar`, `pacman`, `python3`, `ruby`, `namcap`, `shellcheck`, `shfmt`, `bats`). Report those upstream.
- The contents of AUR packages published from user repositories. The maintainer of each user repository is responsible for the packages they publish.
- The model itself: user repositories run the workflows with their own AUR key, and pins that are not the commit of a published release run the code of the commit they name.
- Issues in third-party GitHub Actions. Report them to the action's maintainer. aurtomator pins every action by commit SHA.

## Disclosure

Once a reported issue is fixed, the advisory is published on the repository's Security tab. CVEs assigned through GitHub's CNA are referenced in the published advisory. User repositories get the fix once the pin of their calling workflows moves to a release that holds the fix. Watching this repository's releases gives a notification when a fix ships.
