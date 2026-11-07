# Windows and Linux downloads

This repository includes a GitHub Actions workflow at `.github/workflows/build.yml`.

## Download a build

1. Open [Actions](https://github.com/gajdorendre76/TV-Pong-Game/actions/workflows/build.yml).
2. Select the latest successful **Build Windows and Linux downloads** run.
3. Scroll to **Artifacts** and download the Windows or Linux ZIP.
4. Unzip it before playing. On Linux, allow the `.x86_64` file to execute.

The Windows download contains an EXE and its PCK data file; keep them together. The Linux download similarly contains a Linux executable and its PCK file.

## Publishing a versioned Release

After confirming the build works, create a tag such as `v1.8.0` from the main branch. The tag-triggered workflow attempts to attach Windows and Linux ZIP downloads to a GitHub Release.

## Notes

- Godot 4 export templates are installed by GitHub Actions.
- Mobile controllers and desktop must be on the same local Wi-Fi.
- QR code generation uses external `qrencode` in this project; this can require additional setup on Windows.
- Confirm redistribution permissions for all game audio, images and videos before publishing downloadable binaries.
