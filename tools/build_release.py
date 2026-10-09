"""Builds a clean release zip: dist/TALOD-<version>.zip.

The zip holds two folders. TALOD/ has only what the game loads (the files
listed in the TOC) plus README.md, CHANGELOG.md, LICENSE (when present), the
two SavedVariables viewers (tools/census_viewer.py, tools/fishing_viewer.py:
the in-game pages tell players to run them), tools/data_report.py and the
textures in media/textures/ (the source art in media/branding/ stays out).
TALOD_Archive/ is the load-on-demand archive addon, kept in the repository
as a subfolder (the game loads addons only from the top of AddOns), with
its TOC's @project-version@ set to the version. Tests,
docs, generators and developer notes are left out; the build stops if one
of those would be packed, or anything matching .git/info/exclude (local
files kept out of the repository).

    python tools/build_release.py          # build
    python tools/build_release.py --check  # build, then run the test suite against the built package

The build never signs: the zip's Release.lua carries no release note, so it
can be built and tested as often as needed. Signing is a separate step the
developer runs by hand (SIGN_RELEASE.cmd -> release_sign.py sign-package),
which writes dist/TALOD-<version>-signed.zip, the one to upload.
The private key itself is refused everywhere: in the repository before the
build, and in every file of the finished zip (release_sign.py guard).
"""
import fnmatch
import pathlib
import re
import shutil
import subprocess
import sys
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
# The game loads an addon by its folder name, so the package is named after this folder.
PACKAGE = ROOT.name
EXTRA_FILES = ["README.md", "CHANGELOG.md", "Bindings.xml", "tools/census_viewer.py", "tools/fishing_viewer.py", "tools/data_report.py"]
# The archive addon: a second folder in the package (Brand.lua ARCHIVE_ADDON).
ARCHIVE = PACKAGE + "_Archive"
OPTIONAL_FILES = ["LICENSE", "LICENSE.md", "LICENSE.txt"]
# The textures the addon draws (Brand.lua ns.TEX). Copied as binary files; only their names are scanned.
MEDIA_DIR = "media/textures"
MEDIA_SUFFIXES = {".png"}
# Developer-only paths: never in a release.
FORBIDDEN = re.compile(r"(^|/)(\.[^/]+|tests|docs|dist|census|fishing|concept\.md|cache|__pycache__)(/|$)")


# Names that must never appear in a package: assistants and their tools, their instruction files, and the
# local planning notes. Assembled from pieces so this file does not contain them itself.
_J = "".join
LEAK = re.compile("|".join([
    _J(["cla", "ude"]), _J(["anthr", "opic"]), _J(["gem", "ini"]), _J(["chat", "gpt"]), _J(["open", "ai"]),
    _J(["cop", "ilot"]), _J(["ser", "ena"]), _J(["wind", "surf"]), _J(["co", "dex"]), _J([r"\b", "ai", "der"]),
    _J(["AGE", r"NTS?\.md"]), _J(["AGENT", "_Map"]), _J(["PL", r"AN\.md"]), _J(["con", r"cept\.md"]),
    _J([r"(?-i:\b", "A", "I", r"\b)"]), r"\bLLMs?\b", "large language model",
]), re.I)
SKIP_SUFFIXES = {".png", ".jpg", ".tga", ".blp", ".ogg", ".mp3"}


def leaks_in(name, data):
    """Mentions of assistants or developer notes in a file's name or text."""
    found = [name + " (file name)"] if LEAK.search(name) else []
    for n, line in enumerate(data.splitlines(), 1):
        m = LEAK.search(line)
        if m:
            found.append(f"{name}:{n}: {m.group(0)}")
    return found


def local_only(path):
    """True when path matches a pattern in .git/info/exclude (files kept on this machine only)."""
    exclude = ROOT / ".git" / "info" / "exclude"
    if not exclude.exists():
        return False  # a fresh clone has none; the content scan below still covers the package
    for line in exclude.read_text(encoding="utf-8").splitlines():
        pat = line.strip().rstrip("/")
        if not pat or pat.startswith("#"):
            continue
        parts = path.split("/")
        if any(fnmatch.fnmatch(p, pat) for p in parts) or fnmatch.fnmatch(path, pat):
            return True
    return False


def main():
    toc_path = next(ROOT.glob("*.toc"))
    toc = toc_path.read_text(encoding="utf-8")
    version = re.search(r"^## Version:\s*(\S+)", toc, re.M).group(1)
    sys.path.insert(0, str(ROOT / "tools"))
    import version as version_tool
    if version_tool.problems():
        sys.exit("version out of step: " + "; ".join(version_tool.problems()))
    files = [line.strip().replace("\\", "/") for line in toc.splitlines()
             if line.strip() and not line.startswith("#")]

    # The private signing key: never in the repository, the stage or the zip (checked again at the end).
    import release_sign
    key_problems = release_sign.guard_tree()
    if key_problems:
        sys.exit("REFUSED: the private signing key is in the repository:\n  " + "\n  ".join(key_problems[:40]))

    missing = [f for f in files if not (ROOT / f).exists()]
    if missing:
        sys.exit("TOC lists missing files: " + ", ".join(missing))

    dist = ROOT / "dist"
    stage = dist / PACKAGE
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir(parents=True)

    extras = EXTRA_FILES + [f for f in OPTIONAL_FILES if (ROOT / f).exists()]
    extras += sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / MEDIA_DIR).glob("*")
                     if p.is_file() and p.suffix.lower() in MEDIA_SUFFIXES)
    blocked = [f for f in files + extras if FORBIDDEN.search(f) or local_only(f)]
    if blocked:
        sys.exit("refusing to package developer files: " + ", ".join(blocked))

    # Scan what is about to ship, by name and by content, whatever the exclude file says.
    leaks = []
    for f in files + extras + [PACKAGE + ".toc"]:
        src = ROOT / (toc_path.name if f == PACKAGE + ".toc" else f)
        if src.suffix.lower() in SKIP_SUFFIXES:
            leaks += leaks_in(f, "")   # binary: the name only
            continue
        leaks += leaks_in(f, src.read_text(encoding="utf-8", errors="replace"))
    if leaks:
        sys.exit("refusing to package, these mention assistants or developer notes:\n  " + "\n  ".join(leaks[:40]))

    (stage / (PACKAGE + ".toc")).write_text(toc, encoding="utf-8")
    for f in files + extras:
        target = stage / f
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / f, target)

    stages = [stage]
    source = ROOT / ARCHIVE
    if (source / f"{ARCHIVE}.toc").exists():
        side = dist / ARCHIVE
        if side.exists():
            shutil.rmtree(side)
        side.mkdir(parents=True)
        side_toc = (source / f"{ARCHIVE}.toc").read_text(encoding="utf-8").replace("@project-version@", version)
        side_files = [line.strip().replace("\\", "/") for line in side_toc.splitlines()
                      if line.strip() and not line.startswith("#")]
        missing = [f for f in side_files if not (source / f).exists()]
        if missing:
            sys.exit(f"{ARCHIVE} TOC lists missing files: " + ", ".join(missing))
        leaks = leaks_in(f"{ARCHIVE}.toc", side_toc)
        for f in side_files:
            leaks += leaks_in(f"{ARCHIVE}/{f}", (source / f).read_text(encoding="utf-8", errors="replace"))
        if leaks:
            sys.exit("refusing to package, these mention assistants or developer notes:\n  " + "\n  ".join(leaks[:40]))
        (side / f"{ARCHIVE}.toc").write_text(side_toc, encoding="utf-8")
        for f in side_files:
            target = side / f
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source / f, target)
        stages.append(side)

    archive = dist / f"{PACKAGE}-{version}.zip"
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as z:
        for folder in stages:
            for path in sorted(folder.rglob("*")):
                if path.is_file():
                    z.write(path, path.relative_to(dist).as_posix())

    # Last look at the finished archive itself.
    with zipfile.ZipFile(archive) as z:
        bad, key_bad, found = [], [], release_sign.needles()
        for info in z.infolist():
            if info.is_dir():
                continue
            data = z.read(info)
            key_bad += release_sign.scan(info.filename, data, found)   # every file, images too
            if pathlib.PurePosixPath(info.filename).suffix.lower() in SKIP_SUFFIXES:
                bad += leaks_in(info.filename, "")   # binary: the name only
                continue
            bad += leaks_in(info.filename, data.decode("utf-8", errors="replace"))
    if key_bad:
        archive.unlink()
        sys.exit("archive removed, REFUSED: it carries the private signing key:\n  " + "\n  ".join(key_bad[:40]))
    if bad:
        archive.unlink()
        sys.exit("archive removed, it mentions assistants or developer notes:\n  " + "\n  ".join(bad[:40]))

    print(f"built {archive.relative_to(ROOT)}  ({len(files)} addon files, version {version})")
    for name in sorted(zipfile.ZipFile(archive).namelist()):
        print("   ", name)

    if "--check" in sys.argv:
        result = subprocess.run([sys.executable, str(ROOT / "tests" / "run.py"), "--root", str(stage)])
        sys.exit(result.returncode)


if __name__ == "__main__":
    main()
