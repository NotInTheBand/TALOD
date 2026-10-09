@echo off
rem Signs the release you are about to upload. Run it by hand, only for that.
rem
rem   1. python tools\build_release.py --check     (builds dist\TALOD-<version>.zip, unsigned)
rem   2. double-click this file and type the version back when asked
rem   3. upload dist\TALOD-<version>-signed.zip
rem
rem Every copy that hears the signed note tells its player the version is out,
rem so never sign a test build. Uses your private key (outside this folder);
rem the key itself never goes into the zip (checked before it is written).
cd /d "%~dp0"
python tools\release_sign.py sign-package
echo.
pause
