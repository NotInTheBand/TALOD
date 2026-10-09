"""Signs release notes so every copy of the addon can tell a real release from a fake.

A copy that hears "version X is out" on the version channel checks the note's
signature against the public key in Release.lua (Signature.lua). Only the
private key can make a signature, and it never leaves this machine.

    python tools/release_sign.py keygen    # once: new key pair; public half into Release.lua
    python tools/release_sign.py sign-package   # BY HAND ONLY (SIGN_RELEASE.cmd): sign the built zip for upload
    python tools/release_sign.py verify    # check Release.lua's note against its key
    python tools/release_sign.py guard     # scan the repository for the private key (also --staged, --push)
    python tools/release_sign.py install-hooks   # git pre-commit / pre-push hooks that run the guard

The private key: the file named by the environment variable <NAME>_SIGNING_KEY,
else ~/.<name>/<NAME>_PRIVATE_SIGNING_KEY.json. It must stay outside the game
folder (the tool refuses a path inside it) and never be committed, packed or
uploaded: .gitignore, .gitattributes and .pkgmeta name its patterns, the git
hooks refuse a commit or push that carries it, and build_release.py refuses a
package with it. The guard finds it by file name, by the marker inside it and
by its numbers, so a renamed copy is caught too.

Back it up: lose it and copies already installed can never trust a newer
release; leak it and anyone can make them show the update window (nothing
worse: the window's download link is built into the addon, never taken from
the note).

Nothing signs automatically. build_release.py builds an unsigned zip (test
builds as often as needed); the developer signs by hand, only a version being
uploaded, with SIGN_RELEASE.cmd (= "sign-package": needs a keyboard and the
version typed back) -> dist/<NAME>-<version>-signed.zip, the one to upload.
The repository's Release.lua is never signed: it is the live install, and a
signed note there would announce the version before the upload is approved.
"""
import base64
import datetime
import json
import math
import os
import pathlib
import re
import secrets
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
RELEASE = ROOT / "Release.lua"
KEY_BYTES = 128          # 1024-bit key: the signature (base64, 172 chars) fits one addon message
E = 65537
LIMB = 24                # Signature.lua's limb width


def name():
    m = re.search(r'^ns\.NAME\s*=\s*"(\w+)"', (ROOT / "Brand.lua").read_text(encoding="utf-8"), re.M)
    return m.group(1)


def key_file_name():
    return "_".join([name().upper(), "PRIVATE", "SIGNING", "KEY"]) + ".json"


def key_path():
    env = os.environ.get(name().upper() + "_SIGNING_KEY")
    path = pathlib.Path(env) if env else pathlib.Path.home() / ("." + name().lower()) / key_file_name()
    # Never inside the repository, nor inside the game folder when the repository sits in one
    # (<game>/<client>/Interface/AddOns/<addon>: AddOns, WTF backups, synced folders).
    full, guarded = path.resolve(), [ROOT]
    if ROOT.parent.name.lower() == "addons" and ROOT.parent.parent.name.lower() == "interface":
        guarded.append(ROOT.parents[3])
    for folder in guarded:
        if full == folder or folder in full.parents:
            sys.exit(f"the signing key must live outside {folder}, not at {path}")
    return path


# --- Guard: the private key never leaves this machine ---------------------
# Built from pieces so this file never contains the marker itself.
def marker():
    return "-".join([name(), "PRIVATE", "SIGNING", "KEY"])


KEY_NAME = re.compile(r"signing.?key|release.?key|\.pem$|\.key$|\.p12$|\.pfx$|id_rsa", re.I)
# A big secret number in a field named d / p / q (how keys are written down).
KEY_FIELD = re.compile(r"""["']?\b(d|p|q)\b["']?\s*[:=]\s*["']?(\d{120,}|[0-9a-fA-F]{120,})""")


def needles():
    """Byte strings that only a copy of the private key would contain."""
    out = [marker().encode()]
    try:
        path = key_path()
        if path.exists():
            d = int(json.loads(path.read_text(encoding="utf-8"))["d"])
            out += [str(d)[:60].encode(), f"{d:x}"[:60].encode(), f"{d:X}"[:60].encode()]
    except (SystemExit, ValueError, KeyError, OSError):
        pass
    return out


def scan(label, data, found=None):
    """Problems in one file: its name looks like a key, or its bytes carry one."""
    problems = []
    base = label.replace("\\", "/").rsplit("/", 1)[-1]
    if KEY_NAME.search(base):
        problems.append(f"{label}: file name looks like a signing key")
    if any(n and n in data for n in (found if found is not None else needles())):
        problems.append(f"{label}: contains the private signing key")
    elif KEY_FIELD.search(data.decode("utf-8", errors="replace")):
        problems.append(f"{label}: contains what looks like a private key number")
    return problems


def git(*args):
    import subprocess
    return subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, check=True).stdout


def split0(out):
    return [x for x in out.decode("utf-8").split("\0") if x]


def guard_tree():
    """Every file git could commit or a package could take: tracked plus untracked-not-ignored."""
    found, problems = needles(), []
    for rel in split0(git("ls-files", "-z", "--cached", "--others", "--exclude-standard")):
        path = ROOT / rel
        if path.is_file():
            problems += scan(rel, path.read_bytes(), found)
    return problems


def guard_staged():
    found, problems = needles(), []
    for rel in split0(git("diff", "--cached", "--name-only", "-z", "--diff-filter=ACMR")):
        problems += scan(rel, git("show", ":" + rel), found)
    return problems


def guard_push(lines):
    """pre-push: every file added or changed in the commits about to leave."""
    found, problems, zero = needles(), [], "0" * 40
    for line in lines:
        parts = line.split()
        if len(parts) != 4 or parts[1] == zero:
            continue
        local, remote = parts[1], parts[3]
        rng = [local, "--not", "--remotes"] if remote == zero else [f"{remote}..{local}"]
        for commit in git("rev-list", *rng).decode().split():
            out = git("diff-tree", "--no-commit-id", "-r", "-z", "--root", "--diff-filter=ACMR", "--name-only", commit)
            for rel in split0(out):
                problems += [f"{commit[:8]} {p}" for p in scan(rel, git("show", f"{commit}:{rel}"), found)]
    return problems


HOOK = """#!/bin/sh
# Refuses a {what} that would carry the release signing key (tools/release_sign.py guard).
root="$(git rev-parse --show-toplevel)"
for py in python python3 py; do
    if command -v "$py" >/dev/null 2>&1; then exec "$py" "$root/tools/release_sign.py" guard {flag}; fi
done
echo "no python found: cannot check for the signing key, refusing" >&2
exit 1
"""


def install_hooks():
    hooks = ROOT / ".git" / "hooks"
    for hook, what, flag in (("pre-commit", "commit", "--staged"), ("pre-push", "push", "--push")):
        path = hooks / hook
        if path.exists() and "release_sign.py guard" not in path.read_text(encoding="utf-8", errors="replace"):
            sys.exit(f"{path} exists and is not ours: add the guard to it by hand")
        path.write_text(HOOK.format(what=what, flag=flag), encoding="utf-8", newline="\n")
        try:
            path.chmod(0o755)
        except OSError:
            pass
        print(f"installed {path}")


# --- RSA ------------------------------------------------------------------
def probable_prime(n, rounds=48):
    if n < 4:
        return n in (2, 3)
    for p in (3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37):
        if n % p == 0:
            return n == p
    d, r = n - 1, 0
    while d % 2 == 0:
        d, r = d // 2, r + 1
    for _ in range(rounds):
        a = secrets.randbelow(n - 3) + 2
        x = pow(a, d, n)
        if x in (1, n - 1):
            continue
        for _ in range(r - 1):
            x = pow(x, 2, n)
            if x == n - 1:
                break
        else:
            return False
    return True


def prime(bits):
    while True:
        p = secrets.randbits(bits) | (3 << (bits - 2)) | 1   # top two bits set: p * q has the full width
        if probable_prime(p) and math.gcd(E, p - 1) == 1:
            return p


def new_key():
    bits = KEY_BYTES * 8
    while True:
        p, q = prime(bits // 2), prime(bits // 2)
        n = p * q
        if p != q and n.bit_length() == bits:
            d = pow(E, -1, (p - 1) * (q - 1))
            return {"n": n, "e": E, "d": d}


def padded(text, k=KEY_BYTES):
    data = text.encode("ascii")
    if len(data) > k - 11:
        raise ValueError("note too long")
    return int.from_bytes(b"\x00\x01" + b"\xff" * (k - 3 - len(data)) + b"\x00" + data, "big")


def sign(text, key):
    s = pow(padded(text), key["d"], key["n"])
    return base64.b64encode(s.to_bytes(KEY_BYTES, "big")).decode("ascii")


def verify(text, sig, n):
    s = int.from_bytes(base64.b64decode(sig), "big")
    return s < n and pow(s, E, n) == padded(text)


def note_text(version, day):
    return f"{name()}|{version}|{day}"


# --- Release.lua ------------------------------------------------------------
def public_line(n):
    limbs = math.ceil(KEY_BYTES * 8 / LIMB)
    r2 = pow(2, 2 * LIMB * limbs, n)
    ninv = (-pow(n, -1, 2 ** LIMB)) % 2 ** LIMB
    return (f'ns.RELEASE_KEY = {{ bytes = {KEY_BYTES}, n = "{n:0{KEY_BYTES * 2}x}", '
            f'r2 = "{r2:0{KEY_BYTES * 2}x}", ninv = {ninv} }}')


def note_line(version, day, sig):
    return f'ns.RELEASE_NOTE = {{ v = "{version}", d = "{day}", s = "{sig}" }}'


def replace(text, prefix, line):
    new, count = re.subn(r"^" + re.escape(prefix) + r".*$", lambda _: line, text, count=1, flags=re.M)
    if count != 1:
        sys.exit(f"Release.lua: no line starting with {prefix!r}")
    return new


def read_release(path=None):
    text = (path or RELEASE).read_text(encoding="utf-8")
    key = re.search(r'^ns\.RELEASE_KEY = \{ bytes = (\d+), n = "(\w*)"', text, re.M)
    note = re.search(r'^ns\.RELEASE_NOTE = \{ v = "([^"]+)", d = "([^"]+)", s = "([^"]+)" \}', text, re.M)
    n = int(key.group(2), 16) if key and key.group(2) else None
    return text, n, (note.groups() if note else None)


def load_key():
    path = key_path()
    if not path.exists():
        sys.exit(f"no signing key at {path} (python tools/release_sign.py keygen, or set {name().upper()}_SIGNING_KEY)")
    key = json.loads(path.read_text(encoding="utf-8"))
    return {k: int(key[k]) for k in ("n", "e", "d")}


def key_json(key):
    return json.dumps({
        "marker": marker(),
        "WARNING": "PRIVATE SIGNING KEY. BACK IT UP OFFLINE NOW. NEVER COMMIT, UPLOAD, SHARE OR PASTE IT ANYWHERE.",
        **{k: str(key[k]) for k in ("n", "e", "d")},
    }, indent=1)


def current_version():
    return json.loads((ROOT / "version.json").read_text(encoding="utf-8"))["version"]


def keyboard():
    """True only when a person can type: a real console. On Windows the NUL device
    claims to be a terminal (isatty), so ask the console itself."""
    try:
        if not (sys.stdin and sys.stdin.isatty()):
            return False
        if os.name == "nt":
            import ctypes
            import msvcrt
            mode = ctypes.c_uint()
            handle = msvcrt.get_osfhandle(sys.stdin.fileno())
            return ctypes.windll.kernel32.GetConsoleMode(handle, ctypes.byref(mode)) != 0
        return True
    except (OSError, ValueError, AttributeError):
        return False


def sign_package():
    """dist/<NAME>-<version>.zip -> dist/<NAME>-<version>-signed.zip with the signed note in its Release.lua.

    Run by the developer, by hand, only for a version being uploaded now: copies
    that hear the note tell players the version is out. Never automatic: it
    needs a keyboard (refuses when input is not a terminal) and the version typed
    back. The repository's Release.lua is never signed (it is the live install)."""
    import zipfile
    if not keyboard():
        sys.exit("refused: signing is done by hand only (run SIGN_RELEASE.cmd and type the version)")
    pkg, version = name(), current_version()
    day = datetime.date.today().isoformat()
    src = ROOT / "dist" / f"{pkg}-{version}.zip"
    out = ROOT / "dist" / f"{pkg}-{version}-signed.zip"
    if not src.exists():
        sys.exit(f"no {src.name}: build it first (python tools/build_release.py --check)")
    entry = f"{pkg}/Release.lua"
    print(f"This signs \"{note_text(version, day)}\" into {out.name}.")
    print("Every copy that hears it will tell its player this version is out.")
    print("Only sign a version you are uploading now; never a test build.")
    typed = input(f"Type the version ({version}) to sign, anything else to stop: ").strip()
    if typed != version:
        sys.exit("stopped: nothing signed")
    key = load_key()
    with zipfile.ZipFile(src) as z:
        entries = [(info, z.read(info)) for info in z.infolist()]
    names = [info.filename for info, _ in entries]
    if entry not in names:
        sys.exit(f"{src.name} has no {entry}")
    tmp = ROOT / "dist" / "Release.lua.tmp"
    try:
        tmp.write_bytes(dict(zip(names, (d for _, d in entries)))[entry])
        text, n, _ = read_release(tmp)
        if n != key["n"]:
            sys.exit(f"the package's public key is not the one in {key_path()}")
        sig = sign(note_text(version, day), key)
        signed = replace(text, "ns.RELEASE_NOTE =", note_line(version, day, sig)).encode("utf-8")
    finally:
        if tmp.exists():
            tmp.unlink()
    found, problems = needles(), []
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for info, data in entries:
            data = signed if info.filename == entry else data
            problems += scan(info.filename, data, found)
            z.writestr(info, data)
    if problems:
        out.unlink()
        sys.exit("signed zip removed, REFUSED: it carries the private signing key:\n  " + "\n  ".join(problems[:40]))
    # Read back what was written and check it as a copy of the addon would.
    with zipfile.ZipFile(out) as z:
        back = z.read(entry).decode("utf-8")
    note = re.search(r'^ns\.RELEASE_NOTE = \{ v = "([^"]+)", d = "([^"]+)", s = "([^"]+)" \}', back, re.M)
    if not (note and verify(note_text(note.group(1), note.group(2)), note.group(3), n)):
        out.unlink()
        sys.exit("signed zip removed: its note does not check out")
    print(f"signed: {out}  <- upload this one")


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "keygen":
        path = key_path()
        if path.exists():
            sys.exit(f"{path} exists: a new key would make copies already installed distrust new releases")
        key = new_key()
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(key_json(key), encoding="utf-8")
        text, _, _ = read_release()
        text = replace(text, "ns.RELEASE_KEY =", public_line(key["n"]))
        text = replace(text, "ns.RELEASE_NOTE =", "ns.RELEASE_NOTE = nil")
        RELEASE.write_text(text, encoding="utf-8", newline="\n")
        print(f"private key: {path}  (back it up; never commit it)")
        print("public key written to Release.lua")
    elif cmd == "sign-package":
        sign_package()
    elif cmd == "verify":
        _, n, note = read_release()
        if not n:
            sys.exit("Release.lua has no public key")
        if not note:
            print("Release.lua has no signed note yet")
            return
        ok = verify(note_text(note[0], note[1]), note[2], n)
        print(f"{note_text(note[0], note[1])}: {'valid' if ok else 'INVALID'}")
        sys.exit(0 if ok else 1)
    elif cmd == "guard":
        if "--staged" in argv:
            problems = guard_staged()
        elif "--push" in argv:
            problems = guard_push(sys.stdin.read().splitlines())
        else:
            problems = guard_tree()
        if problems:
            print("REFUSED: the private signing key must never leave this machine:", file=sys.stderr)
            for line in problems[:40]:
                print("  " + line, file=sys.stderr)
            sys.exit(1)
        print("guard: no signing key found")
    elif cmd == "install-hooks":
        install_hooks()
    elif cmd == "migrate-key":
        # One time: the first key file (release_key.json) -> the named file with marker and warning.
        old = pathlib.Path.home() / ("." + name().lower()) / "release_key.json"
        new = key_path()
        if new.exists() or not old.exists():
            sys.exit("nothing to migrate")
        key = {k: int(v) for k, v in json.loads(old.read_text(encoding="utf-8")).items()}
        new.write_text(key_json(key), encoding="utf-8")
        assert load_key() == key
        old.unlink()
        print(f"key moved to {new}")
    else:
        print(__doc__)


if __name__ == "__main__":
    main(sys.argv)
