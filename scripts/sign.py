#!/usr/bin/env python3
"""Stable local development signing. No trust-store or default-keychain changes."""
import hashlib
import fcntl
import os
import plistlib
from pathlib import Path
import secrets
import shlex
import subprocess
import sys
import tempfile


def run(*args, **kwargs):
    result = subprocess.run(args, capture_output=True, **kwargs)
    if result.returncode:
        # Never print arguments: security commands carry the private keychain password.
        sys.exit(f"{args[0]} {args[1]} failed: {result.stderr.decode().strip()}")
    return result.stdout


os.umask(0o077)
app = Path(sys.argv[1]).resolve()
identifier = plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"]
if identifier != "com.dk.blah":
    sys.exit("Refusing to sign a bundle other than Blah.")
entitlements = Path(__file__).resolve().parent.parent / "Resources/Blah.entitlements"

state = Path.home() / "Library/Application Support/Blah/Signing"
state.mkdir(parents=True, exist_ok=True)
state.chmod(0o700)
keychain = state / "development.keychain-db"
password_file = state / "keychain-password"
certificate = state / "development.cer"
signing_lock = (state / ".lock").open("w")
fcntl.flock(signing_lock, fcntl.LOCK_EX)

files = [keychain, password_file, certificate]
if any(path.exists() for path in files) and not all(path.exists() for path in files):
    sys.exit("Local signing identity is incomplete. Restore it rather than replacing it.")

if not keychain.exists():
    password = secrets.token_hex(32)
    password_file.write_text(password)
    original_search_list = shlex.split(run("security", "list-keychains", "-d", "user").decode())
    try:
        with tempfile.TemporaryDirectory(dir=state) as temp:
            temp = Path(temp)
            config = temp / "certificate.cnf"
            config.write_text("""[req]
prompt = no
distinguished_name = name
x509_extensions = extensions
[name]
CN = Blah Local Development
[extensions]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
""")
            run("openssl", "req", "-new", "-x509", "-newkey", "rsa:2048", "-nodes",
                "-days", "3650", "-config", str(config), "-keyout", str(temp / "key.pem"),
                "-out", str(temp / "certificate.pem"))
            run("openssl", "x509", "-in", str(temp / "certificate.pem"), "-outform", "der", "-out", str(certificate))
            secret_env = {**os.environ, "BLAH_P12_PASSWORD": password}
            run("openssl", "pkcs12", "-export", "-inkey", str(temp / "key.pem"),
                "-in", str(temp / "certificate.pem"), "-out", str(temp / "identity.p12"),
                "-passout", "env:BLAH_P12_PASSWORD", "-keypbe", "PBE-SHA1-3DES",
                "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1", env=secret_env)
            run("security", "create-keychain", "-p", password, str(keychain))
            run("security", "unlock-keychain", "-p", password, str(keychain))
            run("security", "import", str(temp / "identity.p12"), "-k", str(keychain),
                "-P", password, "-T", "/usr/bin/codesign")
            run("security", "set-key-partition-list", "-S", "apple-tool:", "-s", "-k", password, str(keychain))
    finally:
        # security create-keychain can add the new keychain to the user's search list.
        current = shlex.split(run("security", "list-keychains", "-d", "user").decode())
        if current != original_search_list:
            run("security", "list-keychains", "-d", "user", "-s", *original_search_list)
else:
    if not password_file.exists() or not certificate.exists():
        sys.exit("Local signing identity is incomplete. Refusing to replace it or use ad-hoc signing.")
    password = password_file.read_text()

# Pin the certificate itself, not just an app identifier that someone else could claim.
fingerprint = hashlib.sha1(certificate.read_bytes()).hexdigest()
requirement = f'designated => identifier "{identifier}" and certificate leaf = H"{fingerprint}"'
try:
    run("security", "unlock-keychain", "-p", password, str(keychain))
    helper_id = identifier + ".cleanup"
    helper_requirement = f'designated => identifier "{helper_id}" and certificate leaf = H"{fingerprint}"'
    run("codesign", "--force", "--sign", fingerprint, "--keychain", str(keychain),
        "--identifier", helper_id, "--timestamp=none", "--requirements", "=" + helper_requirement,
        str(app / "Contents/MacOS/BlahCleanup"))
    run("codesign", "--force", "--sign", fingerprint, "--keychain", str(keychain),
        "--timestamp=none", "--requirements", "=" + requirement,
        "--entitlements", str(entitlements), str(app))
    run("codesign", "--verify", "--deep", "--strict", str(app))
finally:
    run("security", "lock-keychain", str(keychain))
print("Signed with the persistent local development identity.")
