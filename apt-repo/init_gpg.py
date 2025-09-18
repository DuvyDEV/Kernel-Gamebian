#!/usr/bin/env python3
import os, subprocess

GNUPGHOME = "/gnupg"
UID = "Pablo M. Duval <pabloduval@proton.me>"

def run(cmd, env=None, check=True, capture=False):
    return subprocess.run(
        cmd,
        env=env,
        check=check,
        text=True,
        capture_output=capture,
    )

def have_secret_for_uid(env):
    res = run(["gpg", "--list-secret-keys", "--with-colons", UID],
              env=env, check=False, capture=True)
    return any(line.startswith("sec:") for line in res.stdout.splitlines())

def main():
    os.makedirs(GNUPGHOME, exist_ok=True)
    os.chmod(GNUPGHOME, 0o700)
    env = dict(os.environ, GNUPGHOME=GNUPGHOME)

    if have_secret_for_uid(env):
        return

    # 1) Intento: ed25519 (sign), sin passphrase, modo loopback
    p = subprocess.run(
        ["gpg", "--batch", "--pinentry-mode", "loopback", "--passphrase", "",
         "--quick-generate-key", UID, "ed25519", "sign", "0"],
        env=env, text=True, capture_output=True
    )

    if p.returncode != 0:
        # 2) Fallback: RSA 3072 (sign)
        p2 = subprocess.run(
            ["gpg", "--batch", "--pinentry-mode", "loopback", "--passphrase", "",
             "--quick-generate-key", UID, "rsa3072", "sign", "0"],
            env=env, text=True, capture_output=True
        )
        if p2.returncode != 0:
            raise SystemExit(f"ERROR: no se pudo generar la clave GPG\n{p.stderr}\n{p2.stderr}")

    if not have_secret_for_uid(env):
        raise SystemExit("ERROR: clave GPG no presente tras generarse")

if __name__ == "__main__":
    main()

