---
title: Governance
---

aurtomator has one maintainer, who makes the final decisions on changes, releases and the scope of the project. Discussions happen in issues and pull requests on GitHub, under the [Code of Conduct](https://github.com/staticwire/aurtomator/blob/main/CODE_OF_CONDUCT.md).

## Roles

| Role | Who | Tasks |
|---|---|---|
| Maintainer | [noctuum](https://github.com/noctuum) | Reviews and merges pull requests, triages issues, answers security reports, publishes releases, and keeps this site current |
| Second owner | [arsenoganesian](https://github.com/arsenoganesian) | Holds admin rights to the repository and the staticwire organization, and takes over from the maintainer if they cannot continue |
| Contributors | Anyone with a GitHub account | Open issues and pull requests as [CONTRIBUTING.md](https://github.com/staticwire/aurtomator/blob/main/CONTRIBUTING.md) describes |
| Bots | Dependabot and the `aurtopacker` GitHub App | Dependabot opens pull requests that update dependencies. `aurtopacker` runs release-please, which opens release pull requests and creates the releases. Job `sign` of the release workflow, which holds no token of the App, signs the archive of each release and attaches it |

## Decisions

Changes reach `main` only through pull requests, and the maintainer merges them once the required checks `lint`, `test` and `ci-ok` pass. The Dependabot updates of `ci-image/` are the exception: job `merge-image` merges them once their checks and the review of their dependencies pass, see [CI image updates](/develop/ci/#ci-image-updates). Pull requests are squash-merged and hold one logical change each. The [roadmap](/project/roadmap/) lists what the project plans and what it does not.

## Continuity

When the maintainer cannot continue, the second owner can create and close issues, merge pull requests and publish releases within a week. The admin rights for this are already in place. Either owner can replace the secrets of the repository, such as the private key of the `aurtopacker` App. The sources of this site live in `site/` of the repository, and the maintainer holds the domain `aurtomator.dev`.
