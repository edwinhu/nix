# Bootstrap a new machine

Brings a fresh machine up on this flake. Run it with `upmd` from `~/nix` (it opens `up.md` by default); step through with `j`/`k`, `Enter` runs a block and its deps. Assumes Nix (Determinate) is installed and this repo is cloned to `~/nix`.

## 1. GitHub access

The flake pulls `nix-secrets` over SSH, so GitHub auth comes first. The YubiKey FIDO2 resident keys come straight off the key — plug it in, the block prompts for the PIN.

```bash [name:yubikey-keys]
mkdir -p ~/.ssh && chmod 700 ~/.ssh
cd ~/.ssh && ssh-keygen -K
ls -l ~/.ssh/id_*_sk* 2>/dev/null || ls -l ~/.ssh/id_ed25519_sk_rk*
```

`ssh-keygen -K` writes `id_ed25519_sk_rk_*`; rename to `id_nfc_sk` / `id_nano_sk` to match `~/.ssh/config`. Restore `id_github` from its recovery copy in 1Password (Private vault — the agent service account cannot see it) to `~/.ssh/id_github`, mode 600.

```bash [name:github-auth, deps:yubikey-keys]
ssh -T git@github.com 2>&1 | grep -q 'successfully authenticated' && echo "github: ok"
```

## 2. agenix key

Every host shares one decryption key, `~/.ssh/id_ed25519_agenix`. On a machine that already has it, send it:

```text
croc send ~/.ssh/id_ed25519_agenix
```

Then receive here with the code croc prints:

```bash [name:agenix-key]
cd ~/.ssh && croc
chmod 600 ~/.ssh/id_ed25519_agenix
```

```bash [name:check-keys, deps:agenix-key]
cd ~/nix && nix run .#check-keys
```

## 3. Host entry

The machine needs a `userHosts` entry in `flake.nix` naming its `profile` (`full`, `client` or `server`), and a directory under `hosts/`. Hand-edit; nothing to run.

## 4. Build and switch

```bash [name:build, deps:"github-auth | check-keys"]
cd ~/nix && nix flake check
```

```bash [name:switch, deps:build]
cd ~/nix && nix run .#build-switch
```

## 5. Verify

```bash [name:verify, deps:switch]
ls "$XDG_RUNTIME_DIR/agenix/" | head
command -v upmd himalaya morgen
```
