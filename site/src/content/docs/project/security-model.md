---
title: Security model
---

This page says what users can and cannot expect from aurtomator in terms of security, and gives the assurance case behind it: the threat model, the trust boundaries, the design principles and the weaknesses that the code counters. Vulnerabilities go through the [security policy](https://github.com/staticwire/aurtomator/security/policy).

## What you can expect

- Updates reach the AUR only after four jobs of `check-updates.yml` in a row: `check` finds the new version, `prepare` updates the PKGBUILD, the checksums and `.SRCINFO`, `verify` downloads the sources again and checks the checksums, and `publish` pushes to the AUR. Packages that fail a job get no push and get an issue.
- PKGBUILD code runs only as the unprivileged user `builder`, in jobs that hold no secrets. `verify` and `publish` never source a PKGBUILD or run makepkg.
- Only `publish` receives the AUR SSH key and the GPG signing subkey. Every job gets only the token permissions it uses: `contents: read`, plus `contents: write` for `publish` and `issues: write` for `issues`.
- Strategies fetch the answers of upstreams over HTTPS only, with limits on size and time, and a new version passes only with the characters `A-Za-z0-9._+` and within a length limit.
- `validate-pkg.sh` refuses unknown keys and values in package YAML, and package names match `^[a-z0-9][a-z0-9.+_-]*$`.
- Pushes to the AUR go over SSH to its pinned host key. With a GPG signing subkey set, every AUR commit carries its signature, see [GPG signing](/gpg-signing/).
- Your repository runs aurtomator at the commit of a release, which its calling workflows pin by SHA, and `aurtomator.sh` fetches that commit over HTTPS. Releases after v0.13.0 carry an archive of the release commit with a Sigstore signature of the release workflow, see [Verify a release](#verify-a-release).

## What aurtomator does not protect against

- aurtomator checks the version and the checksums of an upstream release, not its code. Malicious releases that upstream publishes in the expected form become updates, and each maintainer stays responsible for the packages they publish.
- aurtomator relies on GitHub, the runners of GitHub Actions, the Arch Linux base image and the tools it calls, such as makepkg, curl, git, yq, gpg and ssh. aurtomator cannot stop a compromise of any of them.
- Calling workflows that pin a commit other than a release run the code of that commit, and no signed release archive covers it.
- Anyone who holds your GitHub account, the secrets of your repository or your AUR key can publish packages in your name, and aurtomator cannot tell them from you.

## Threat model

| Threat | Comes from | Counter |
|---|---|---|
| Crafted answers of upstream APIs and pages | Hostile or compromised upstreams | HTTPS only, limits on size and time, the check of the version characters, and no use of answers as code |
| Hostile PKGBUILD code | Anyone with push access to the AUR repository of a package | Runs only as `builder` in jobs without secrets, and `verify` and `publish` never source it |
| Crafted package YAML | Pull requests to a user repository | `validate-pkg.sh` with allow lists of keys and values |
| Tampered downloads | Network attackers | `verify` downloads every source again over HTTPS and refuses checksums that do not match |
| Theft of secrets | Code that runs in a job | Secrets only in `publish`, which runs no PKGBUILD code, and workflow commands stopped in the output of `builder` |
| Changed dependencies | Actions and the base image | Actions pinned by commit SHA, the base image pinned by digest, and Dependabot pull requests that bring each version a week after its release |

## Trust boundaries

- Upstreams to the `check` job: answers enter as data and pass the checks above.
- The AUR repository to the jobs: PKGBUILD code runs only as `builder`.
- Root to `builder` in each job: `builder` writes only into a directory of its own, and root takes its results as data.
- Jobs without secrets to `publish`: `publish` takes the verified files and checks them against the AUR copy before the push.
- GitHub to your machine: `aurtomator.sh` fetches the pinned commit into a cache that only your account can write, and refuses links in it.

## Design principles

- Least privilege: each job gets only the token permissions it uses, and PKGBUILD code runs as an unprivileged user.
- Separation of privilege: no job holds both PKGBUILD code and the secrets.
- Fail-safe defaults: unknown keys and values fail validation, and a failed check stops the update of its package.
- Complete mediation: `verify` and `publish` check the files of `prepare` again before they use them.
- Defense in depth: an update passes HTTPS downloads, the second download of `verify` and the checks of `publish` before it reaches the AUR.

## Weaknesses countered

| Weakness | Counter |
|---|---|
| CWE-78, OS command injection | Every expansion in double quotes, no `eval`, and ShellCheck on every pull request |
| CWE-94, code injection in workflows | No `${{ }}` expression in any `run` block, and actionlint, zizmor and CodeQL check the workflows |
| CWE-94, code in bash arithmetic | Numbers from servers and the environment match a digit pattern before bash arithmetic |
| CWE-59, link following | Scripts refuse symbolic links in package YAML, prepared AUR files and the cache of `aurtomator.sh` |
| CWE-22, path traversal | Package names match `^[a-z0-9][a-z0-9.+_-]*$`, so they hold no slash |
| CWE-295, certificate validation | curl and git verify TLS certificates, and `publish` pins the host key of the AUR |
| CWE-319, cleartext transmission | Strategies and `verify` download over HTTPS only |
| CWE-400, resource consumption | Limits on the size and time of answers and downloads, and timeouts on every job |
| CWE-345, data authenticity | The second download of `verify`, releases pinned by commit SHA, and signed release archives |
| CWE-532, secrets in logs | Secrets only in `publish`, masked by GitHub, and workflow commands stopped in the output of `builder` |

## Verify a release

Releases after v0.13.0 carry `aurtomator-X.Y.Z.tar.gz`, an archive of the release commit. The release workflow signs it through Sigstore with `actions/attest`: each run gets a short-lived certificate for its own identity, so the project keeps no signing key. Job `sign` of the workflow signs and holds no token of the App, so no step of release-please can ask for the OIDC token that signs. Runs of the workflow wait for each other, so two runs never create the same release. The attestation names the workflow, the branch and the commit of the run, and the GitHub CLI checks all three:

```sh
gh release download vX.Y.Z -R staticwire/aurtomator -p 'aurtomator-X.Y.Z.tar.gz'
gh attestation verify aurtomator-X.Y.Z.tar.gz -R staticwire/aurtomator \
  --signer-workflow staticwire/aurtomator/.github/workflows/release-please.yml \
  --source-ref refs/heads/main --source-digest <SHA that your calling workflows pin>
```

`gh attestation verify` fails unless `release-please.yml` of `staticwire/aurtomator` signed the archive in a run on `main` at that commit.

Beside the archive, these releases carry the attestation in two files. `aurtomator-X.Y.Z.tar.gz.sigstore.json` is its Sigstore bundle, with the certificate of the run. With `--bundle`, `gh attestation verify` reads the attestation from that file in place of the GitHub API:

```sh
gh release download vX.Y.Z -R staticwire/aurtomator -p 'aurtomator-X.Y.Z.tar.gz*'
gh attestation verify aurtomator-X.Y.Z.tar.gz -R staticwire/aurtomator \
  --bundle aurtomator-X.Y.Z.tar.gz.sigstore.json \
  --signer-workflow staticwire/aurtomator/.github/workflows/release-please.yml \
  --source-ref refs/heads/main --source-digest <SHA that your calling workflows pin>
```

`aurtomator-X.Y.Z.tar.gz.intoto.jsonl` holds the SLSA provenance of the archive as an in-toto bundle: the DSSE envelope of the same attestation, on one line.
