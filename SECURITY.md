# Security Policy

## Supported versions

Ursprung is in early development. Security fixes are made on `main` and
included in the next release.

## Reporting a vulnerability

Please **do not open a public issue** for security problems. Use GitHub's
[private vulnerability reporting](https://github.com/bhuaysan/ursprung/security/advisories/new)
instead. Include steps to reproduce and the affected version or commit.

You can expect a first response within a week.

## Scope and design notes

Ursprung loads third-party native code: libretro cores are downloaded over
HTTPS from `buildbot.libretro.com` and executed in-process. For that reason the
app is not sandboxed and its hardened runtime allows JIT and unsigned libraries
(`Ursprung/Ursprung.entitlements`). Reports about the core download and loading
path are especially welcome.

Other relevant areas:

- Parsing untrusted files: ZIP archives (`ZipArchive.swift`), cue sheets and
  playlists (`LibraryScanner.swift`), ScreenScraper responses.
- Credentials: ScreenScraper developer credentials are embedded at build time
  (obfuscated, not secret); user account passwords are kept in the Keychain.
  Media URLs returned by ScreenScraper contain credentials and must never be
  logged or persisted.
