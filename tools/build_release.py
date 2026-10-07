"""Builds a clean release zip: dist/PvPAssist-<version>.zip.

The zip holds one folder, PvPAssist/, with only what the game loads (the
files listed in the TOC) plus README.md, CHANGELOG.md, LICENSE (when present)
and the two SavedVariables viewers (tools/census_viewer.py,
tools/fishing_viewer.py: the in-game pages tell players to run them). Tests,
docs, generators and developer notes are left out; the build stops if one
of those would be packed, or anything matching .git/info/exclude (local
files kept out of the repository).

    python tools/build_release.py          # build
    python tools/build_release.py --check  # build, then run the test suite against the built package
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
EXTRA_FILES = ["README.md", "CHANGELOG.md", "tools/census_viewer.py", "tools/fishing_viewer.py"]
OPTIONAL_FILES = ["LICENSE", "LICENSE.md", "LICENSE.txt"]
# Developer-only paths: never in a release.
FORBIDDEN = re.compile(r"(^|/)(\.[^/]+|tests|docs|dist|census|fishing|concept\.md|cache|__pycache__)(/|$)")


def local_only(path):
    """True when path matches a pattern in .git/info/exclude (files kept on this machine only)."""
    exclude = ROOT / ".git" / "info" / "exclude"
    if not exclude.exists():
        return False
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

    missing = [f for f in files if not (ROOT / f).exists()]
    if missing:
        sys.exit("TOC lists missing files: " + ", ".join(missing))

    dist = ROOT / "dist"
    stage = dist / PACKAGE
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir(parents=True)

    extras = EXTRA_FILES + [f for f in OPTIONAL_FILES if (ROOT / f).exists()]
    blocked = [f for f in files + extras if FORBIDDEN.search(f) or local_only(f)]
    if blocked:
        sys.exit("refusing to package developer files: " + ", ".join(blocked))

    (stage / (PACKAGE + ".toc")).write_text(toc, encoding="utf-8")
    for f in files + extras:
        target = stage / f
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / f, target)

    archive = dist / f"{PACKAGE}-{version}.zip"
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as z:
        for path in sorted(stage.rglob("*")):
            if path.is_file():
                z.write(path, path.relative_to(dist).as_posix())

    print(f"built {archive.relative_to(ROOT)}  ({len(files)} addon files, version {version})")
    for name in sorted(zipfile.ZipFile(archive).namelist()):
        print("   ", name)

    if "--check" in sys.argv:
        result = subprocess.run([sys.executable, str(ROOT / "tests" / "run.py"), "--root", str(stage)])
        sys.exit(result.returncode)


if __name__ == "__main__":
    main()
