# SIXTRACK - GitHub upload package

Upload **SIXTRACK_Source.zip** and the `.github/workflows/build-apk.yml` file
to the ROOT of your GitHub repository.

The GitHub Actions workflow:
1. Checks out repository
2. Extracts `SIXTRACK_Source.zip`
3. Generates Android platform files
4. Installs Flutter dependencies
5. Builds debug APK
6. Uploads APK as a downloadable artifact

**Important:** GitHub's web uploader does not automatically unpack ZIP files.
The `.github` folder may be hidden in your phone file manager. Use Chrome's
desktop site mode or GitHub's Create new file option to create the exact
`.github/workflows/build-apk.yml` path.

This project is unverified and may require Dart/Flutter build fixes.
Debug APK is for personal testing, not Play Store release.
