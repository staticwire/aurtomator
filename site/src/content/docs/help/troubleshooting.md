---
title: Troubleshooting
---

## SSH: Permission denied (publickey)

**Symptom:** `ssh aur@aur.archlinux.org` returns `Permission denied`.

**Causes:**

1. The public key is not on your AUR account. Add it under My Account > SSH Public Key on <https://aur.archlinux.org>.
2. SSH offers another key. Offer this one alone: `ssh -F /dev/null -o IdentitiesOnly=yes -o IdentityAgent=none -i ~/.ssh/aur_ed25519 aur@aur.archlinux.org`
3. The key file is readable by others. Fix it with `chmod 600 ~/.ssh/aur_ed25519`.

## SSH: Host key verification failed

**Symptom:** `./aurtomator.sh setup verify` prints `Host key verification failed.` under `SSH: cannot connect to aur.archlinux.org`.

**Cause:** no known hosts file holds a key of aur.archlinux.org. The check runs ssh with `-F /dev/null` and `BatchMode=yes`, so it reads `~/.ssh/known_hosts`, `~/.ssh/known_hosts2`, `/etc/ssh/ssh_known_hosts` and `/etc/ssh/ssh_known_hosts2` alone and accepts no new host key.

**Fix:** run the command of [step 3](/setup/#3-test-ssh-access) once. Compare the fingerprint that ssh shows with those under "Submitting Packages" on the home page of <https://aur.archlinux.org>, and answer `yes` only when they match.

## GPG: No secret key / unusable secret key

**Symptom:** `gpg --sign` fails with "No secret key" or "Unusable secret key".

**Causes:**

1. The key ID is wrong. `gpg --list-secret-keys --keyid-format long` lists your keys.
2. The subkey expired. `gpg --quick-set-expire <master-key-fingerprint> 1y <subkey-fingerprint>` extends it, and `./aurtomator.sh setup gpg secrets` sets the secret again, since CI holds the earlier copy.
3. The key is in another keyring, such as one of another `GNUPGHOME`.

## gh: not logged in / authentication failed

**Symptom:** `gh auth status` fails, or `gh secret set` returns 403.

**Fixes:**

1. Run `gh auth login`.
2. Check with `gh auth status` that the token has the `repo` scope. A fine-grained token needs write access to "Secrets" of the repository.

Without `gh`, set the secrets in the web UI, see [Manual setup](/setup/#manual-setup-without-gh-cli).

## Secrets not set / workflow fails with missing secret

**Symptom:** the `publish` job fails in `Setup AUR SSH` with `The secret AUR_SSH_KEY is empty`, or with an SSH key error.

**Fixes:**

1. Settings > Secrets and variables > Actions of your repository lists `AUR_SSH_KEY`, `AUR_GIT_NAME`, `AUR_GIT_EMAIL` and, with GPG, `GPG_SIGNING_KEY`.
2. `./aurtomator.sh setup secrets` sets them again.
3. The job `check-updates` of `.github/workflows/check-updates.yml` passes each secret by name, as [The calling workflows](/setup/#the-calling-workflows) shows. `secrets: inherit` passes none, see [Required](/setup/#required).

## Invalid workflow file: a nested job requests more permissions

**Symptom:** a run of a calling workflow fails before any job starts, with `Invalid workflow file` and a line of this form:

```text
The nested job '<job>' is requesting '<permissions>', but is only allowed '<permissions>'
```

**Cause:** the calling job grants less than a job of the called workflow requests, and a called workflow cannot raise the permissions.

**Fix:** give each job of the calling workflow the `permissions` of [The calling workflows](/setup/#the-calling-workflows): `contents: write` and `issues: write` for `check-updates`, `actions: read` and `issues: write` for `notify`, and `contents: read` in `validate.yml`.

## check-update.sh fails: "Strategy not found"

**Symptom:** `Strategy not found or not executable:` and the path of `strategies/<strategy>.sh` in aurtomator.

**Fixes:**

1. `./aurtomator.sh validate-pkg my-package` lists the strategies of the pinned release when `strategy` names none of them.
2. A strategy of a newer release of aurtomator needs the pin of that release, see [The calling workflows](/setup/#the-calling-workflows).

## update-pkg.sh fails: "No PKGBUILD found"

**Symptom:** the clone succeeds, and the script reports `No PKGBUILD found in AUR repo`.

**Cause:** the package does not exist on the AUR yet. aurtomator updates existing packages, so push the first PKGBUILD by hand.

## updpkgsums fails

**Symptom:** `Required command not found: updpkgsums`, or `updpkgsums failed` and no push.

**Causes:**

1. `updpkgsums` is missing: `sudo pacman -S --needed pacman-contrib` installs it.
2. A download fails that the URL check does not cover: a source that is no `http` or `https` URL, or a server that answers a `HEAD` request and refuses the download. A URL that does not resolve after the bump stops the update earlier, with `Source URL validation failed, aborting`.
