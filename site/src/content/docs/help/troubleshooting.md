---
title: Troubleshooting
---

## SSH: Permission denied (publickey)

**Symptom:** `ssh aur@aur.archlinux.org` returns `Permission denied`.

**Causes:**

1. The public key is not on your AUR account. Add it under My Account > SSH Public Key on <https://aur.archlinux.org>.
2. SSH picks the wrong key. Offer that key alone: `ssh -F /dev/null -o IdentitiesOnly=yes -o IdentityAgent=none -i ~/.ssh/aur_ed25519 aur@aur.archlinux.org`
3. The key file permissions are too open. Fix them with `chmod 600 ~/.ssh/aur_ed25519`.

## SSH: Host key verification failed

**Symptom:** `./aurtomator.sh setup verify` prints `Host key verification failed.` under `SSH: cannot connect to aur.archlinux.org`.

**Cause:** no known hosts file holds a key of aur.archlinux.org. The check runs ssh with `-F /dev/null` and `BatchMode=yes`: it reads `~/.ssh/known_hosts`, `~/.ssh/known_hosts2`, `/etc/ssh/ssh_known_hosts` and `/etc/ssh/ssh_known_hosts2` alone, never a `UserKnownHostsFile` of `~/.ssh/config`, and it accepts no new host key. CI accepts none either: it brings the host key of the AUR in its own `known_hosts`.

**Fix:** run the command of [step 3](/aurtomator/setup/#3-test-ssh-access) once. ssh shows the fingerprint of the host key: compare it with the fingerprints under "Submitting Packages" on the home page of <https://aur.archlinux.org>, and answer `yes` only when they match. ssh then saves the key to `~/.ssh/known_hosts`.

## GPG: No secret key / unusable secret key

**Symptom:** `gpg --sign` fails with "No secret key" or "Unusable secret key".

**Causes:**

1. The key ID is wrong. List your keys: `gpg --list-secret-keys --keyid-format long`
2. The subkey expired. Check with `gpg --list-keys <key-id>` and extend it with `gpg --quick-set-expire <master-key-fingerprint> 1y <subkey-fingerprint>`. CI holds the copy of the key made before, so `./aurtomator.sh setup gpg secrets` sets the secret again.
3. The key is in another keyring, for example under a different `GNUPGHOME`.

## gh: not logged in / authentication failed

**Symptom:** `gh auth status` fails or `gh secret set` returns 403.

**Fixes:**

1. Run `gh auth login` and complete the flow.
2. Check that the token has the `repo` scope: `gh auth status`
3. A fine-grained token needs write access to "Secrets" on the repository.

Without `gh`, set the secrets in the web UI: see [Manual setup](/aurtomator/setup/#manual-setup-without-gh-cli).

## Secrets not set / workflow fails with missing secret

**Symptom:** The `publish` job fails in `Setup AUR SSH` with `The secret AUR_SSH_KEY is empty`, or with SSH key errors.

**Fixes:**

1. Open Settings > Secrets and variables > Actions in your repository. It lists `AUR_SSH_KEY`, `AUR_GIT_NAME`, `AUR_GIT_EMAIL` and, with GPG, `GPG_SIGNING_KEY`.
2. Run `./aurtomator.sh setup secrets` to push them again.
3. The `check-updates` job of `.github/workflows/check-updates.yml` passes each secret by name, as [The calling workflows](/aurtomator/setup/#the-calling-workflows) shows. `secrets: inherit` passes none to aurtomator, see [Required](/aurtomator/setup/#required).

## Invalid workflow file: a nested job requests more permissions

**Symptom:** A run of a calling workflow fails before any job starts, with `Invalid workflow file` and a line of this form:

```text
The nested job '<job>' is requesting '<permissions>', but is only allowed '<permissions>'
```

**Cause:** The calling job grants less than a job of the called workflow requests. A called workflow can lower the permissions of the calling job but cannot raise them.

**Fix:** Give each job of the calling workflow the `permissions` block that [The calling workflows](/aurtomator/setup/#the-calling-workflows) shows: `contents: write` and `issues: write` for `check-updates`, `actions: read` and `issues: write` for `notify`, and `contents: read` in `validate.yml`.

## check-update.sh fails: "Strategy not found"

**Symptom:** `Strategy not found or not executable:` followed by the path of `strategies/<strategy>.sh` in aurtomator.

**Fixes:**

1. `./aurtomator.sh validate-pkg my-package` lists the strategies of the pinned release when the `strategy` field names none of them.
2. A strategy that a newer release of aurtomator adds needs the pin of that release, see [The calling workflows](/aurtomator/setup/#the-calling-workflows).

## update-pkg.sh fails: "No PKGBUILD found"

**Symptom:** The clone succeeds, and the script reports `No PKGBUILD found in AUR repo`.

**Cause:** The package does not exist on the AUR yet. aurtomator updates **existing** AUR packages and does not create new ones. Push your first PKGBUILD to the AUR by hand.

## updpkgsums fails

**Symptom:** `Required command not found: updpkgsums`, or `updpkgsums failed` with a refusal to push.

**Causes:**

1. `updpkgsums` is not installed. Install it with `sudo pacman -S --needed pacman-contrib`.
2. A download fails that the URL check before `updpkgsums` does not cover: a source that is not an `http` or `https` URL, or a server that answers a `HEAD` request and refuses the download. A source URL that does not resolve after the version bump stops the update earlier, with `Source URL validation failed, aborting`. Check the `source=()` array.
