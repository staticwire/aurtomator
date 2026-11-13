---
title: GPG signing
---

GPG is optional. With it, aurtomator signs every AUR commit with your key, and AUR users can check the signature with `git log --show-signature`. The key is stored as a CI secret, so a leak of the CI secrets exposes it. A dedicated signing subkey limits the damage: you revoke the subkey and keep your master key. The setup script refuses a master key, so pass the ID of the subkey marked `[S]`.

## Create a signing subkey

```bash
# List your master key fingerprint
gpg --list-keys --keyid-format long your-email@example.com

# Add an ed25519 signing subkey, valid for 1 year
gpg --quick-add-key <master-key-fingerprint> ed25519 sign 1y

# Find the new subkey ID: the line starting with "sub" with [S]
gpg --list-keys --keyid-format long your-email@example.com
```

## Export for CI

With `gh`, the setup script exports the key. By hand, for a key without a passphrase:

```bash
gpg --export-secret-subkeys --armor '<subkey-id>!'
```

The `!` exports that subkey alone. Without it, gpg exports every secret subkey of the key, an encryption subkey included. Paste the whole output, the `-----BEGIN PGP PRIVATE KEY BLOCK-----` and `-----END PGP PRIVATE KEY BLOCK-----` lines included, as the secret `GPG_SIGNING_KEY`.

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

CI needs a key without a passphrase. When your subkey has one, the setup script makes a copy without it in a temporary keyring, and three pinentry dialogs open:

| Dialog | Enter | Purpose |
|---|---|---|
| 1st | your passphrase | exports the subkey from your keyring |
| 2nd | your passphrase again | unlocks the key in the temporary keyring, whose GPG agent has no cached passphrase |
| 3rd | nothing, press OK | sets an empty passphrase on the copy |

The passphrase goes through pinentry alone and never appears in a shell variable, an argument, the environment or a pipe. Your key stays as it is. With `gh`, the copy becomes the secret `GPG_SIGNING_KEY`, and without `gh` the script prints it for you to paste. The script deletes the temporary keyring right after, and also when it stops early, on an error, on `Ctrl-C` or when its terminal closes.

The copy exists only while the script runs, so run the two steps together: `./aurtomator.sh setup gpg secrets`. Run alone, `secrets` does not set `GPG_SIGNING_KEY` for a key with a passphrase and prints that command.
