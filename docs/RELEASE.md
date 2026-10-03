# Releasing

Ursprung is distributed as a signed, notarized disk image on GitHub Releases.
People without Xcode download it there; Ursprung › Check for Updates… compares
the running version with the latest release and opens its page.

## One-time setup

1. **Developer ID certificate.** Join the Apple Developer Program, then create a
   "Developer ID Application" certificate (Xcode › Settings › Accounts › Manage
   Certificates › +). An "Apple Development" certificate cannot be notarized.
2. **Notary credentials.** Create an app-specific password at
   [account.apple.com](https://account.apple.com) and store it in the keychain:

   ```sh
   xcrun notarytool store-credentials ursprung-notary \
       --apple-id <apple id> --team-id <team id> --password <app-specific password>
   ```

3. **ScreenScraper developer credentials** in `.env` (see the README). They are
   compiled into the app; people using a release cannot add them, so a release
   built without them cannot fetch metadata. `make dist` refuses to build
   without them.

## Making a release

1. Raise `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION`) in `project.yml`.
2. Run `make dist`. It builds the Release configuration signed with the first
   Developer ID Application identity (override with `SIGN_IDENTITY`), checks
   the signature, creates `build/dist/Ursprung-<version>.dmg`, notarizes and
   staples it, and writes its SHA-256 checksum next to it.
3. Tag the commit `v<version>`, create a GitHub release for the tag and attach
   the disk image and the `.sha256` file. Check for Updates… reads the tag name
   and the release page from the GitHub API.

`SKIP_NOTARIZE=1 make dist` runs everything except notarization, e.g. to test
the script with an Apple Development certificate; such a disk image is not for
distribution.

## What the build needs

- Hardened runtime with `disable-library-validation`, `allow-jit` and
  `allow-unsigned-executable-memory` (see `Ursprung/Ursprung.entitlements`):
  libretro cores are downloaded at runtime and not signed by us, and dynamic
  recompilers generate code.
- No `get-task-allow` entitlement; `make dist` stops if the signed app has it.
