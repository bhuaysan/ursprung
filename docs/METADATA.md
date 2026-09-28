# Metadata and artwork

Ursprung gets titles, descriptions, release data, ratings and artwork from
[ScreenScraper](https://www.screenscraper.fr), a community-maintained database
of retro games.

## How games are matched

For every game Ursprung asks ScreenScraper's `jeuInfos` endpoint with:

- the ScreenScraper system ID,
- the file name and size,
- the CRC32 of the ROM — for zipped cartridge games the CRC of the game inside
  the archive (read from the ZIP directory, no extraction needed). Files larger
  than 64 MB (disc images) are matched by name and size only.

If nothing is found, Ursprung falls back to a title search (`jeuRecherche`) with
the cleaned-up file name. Games that still don't match are marked
*No match on ScreenScraper*; renaming the file to the official title (e.g. the
No-Intro or Redump name) usually helps. Use **Refetch Metadata** from the
context menu afterwards.

## Language and region

**Settings → Metadata** controls which language descriptions and genres are
shown in and which region's titles, release dates and box art are preferred.
With German and Europe, for example, *Pokémon Rote Edition* with the German box
is used instead of *Pokémon Red Version*. When a text or image is not available
in the preferred language/region, Ursprung falls back to World, Europe, USA,
ScreenScraper's own and Japan, in that order.

Downloaded media per game:

| File | ScreenScraper media type | Used for |
|---|---|---|
| `box.png` | `box-2D` | Grid covers, inspector |
| `screenshot.png` | `ss` | Inspector header (fallback) |
| `title.png` | `sstitle` | Fallback screenshot |
| `logo.png` | `wheel-hd` / `wheel` | Inspector title |
| `fanart.jpg` | `fanart` | Inspector header |

## Quotas and accounts

Anonymous access is limited to one request at a time and a daily quota, so
Ursprung scrapes games one after another. A free ScreenScraper account raises
the limits: enter it in **Settings → Metadata**; the password is stored in the
macOS keychain. If the quota is used up, scraping stops with a message and can
be resumed later with **Fetch Missing Metadata**.

## Developer credentials (for builders)

Every application that uses the ScreenScraper API needs its own *developer*
credentials. They are not part of the repository:

1. Request developer access via the ScreenScraper forum.
2. Copy `.env.example` to `.env` and fill in `SCREENSCRAPER_DEV_ID` and
   `SCREENSCRAPER_DEV_PASSWORD`.
3. Build. `Scripts/generate-secrets.sh` writes them, XOR-obfuscated, into
   `Ursprung/Support/Secrets.generated.swift` (git-ignored). CI can pass the
   same values as environment variables.

The obfuscation only keeps the values out of plain `strings` output — anything
shipped in a binary can be extracted. ScreenScraper's media URLs contain the
credentials, which is why Ursprung never logs or stores them.
