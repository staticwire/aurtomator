---
title: GPG signing
---

aurtomator works without GPG. With it, every AUR commit is signed with your key, and AUR users can check the signature with `git log --show-signature`. The signing key is stored as a CI secret, so a leak of the CI secrets exposes it as well. A dedicated subkey limits the damage: you revoke the subkey and keep your master key. The setup script refuses a master key, which certifies the others and stays on your machine, so pass the ID of the subkey marked `[S]`.

## Create a dedicated signing subkey

```bash
# List your master key fingerprint
gpg --list-keys --keyid-format long your-email@example.com

# Add an ed25519 signing subkey, valid for 1 year
gpg --quick-add-key <master-key-fingerprint> ed25519 sign 1y

# Find the new subkey ID
gpg --list-keys --keyid-format long your-email@example.com
# Look for the line starting with "sub" with [S] capability
```

## Export for CI

With `gh`, the setup script does this. By hand, for a key without a passphrase:

```bash
gpg --export-secret-subkeys --armor '<subkey-id>!'
```

The `!` exports that subkey alone. Without it, gpg exports every secret subkey of the key, an encryption subkey included.

Paste the full output, including the `-----BEGIN PGP PRIVATE KEY BLOCK-----` and `-----END PGP PRIVATE KEY BLOCK-----` lines, as the `GPG_SIGNING_KEY` secret.

## Configure in setup

Pass the key ID:

```bash
./aurtomator.sh setup --gpg-key <subkey-id>
```

Or run the GPG step and answer `y` to "Enable GPG commit signing? (y/N)":

```bash
./aurtomator.sh setup gpg
```

## Passphrase stripping (3 pinentry dialogs)

CI needs a key without a passphrase. When your subkey has one, the setup script makes a passphrase-free copy in a temporary keyring, and three pinentry dialogs open:

| Dialog | What to enter | Why |
|--------|--------------|-----|
| **1st** | Your current passphrase | Exports the signing subkey from your main keyring |
| **2nd** | Your current passphrase again | Unlocks the key in the temporary keyring |
| **3rd** | Leave empty, press OK | Sets an empty passphrase on the copy for CI |

The second dialog asks again because the temporary keyring runs its own GPG agent, and that agent has not cached the passphrase. The passphrase only goes through pinentry: it never appears in shell variables, command arguments, environment variables or pipes.

Your original key is not modified. With `gh`, the copy is stored as the `GPG_SIGNING_KEY` secret. Without `gh`, the script prints the copy for you to paste as that secret. The temporary keyring is deleted right after, and also when the script stops early: on an error, on `Ctrl-C` or when its terminal closes.

The copy exists only while the script runs, so the `gpg` and `secrets` steps have to run together: `./aurtomator.sh setup gpg secrets`. Run alone, `secrets` does not set `GPG_SIGNING_KEY` for a key with a passphrase and prints that command.
