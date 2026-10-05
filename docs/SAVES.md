# Saves, game identity and backups

How Ursprung keeps progress safe: where saves live, how a game keeps its
saves when its file moves, what a save state is compatible with, and what a
backup contains.

## Game identity

Every library entry has a UUID. Battery saves, save states and artwork are
stored under that UUID, so they belong to the entry, not to a file name.

When a scan no longer finds a game's file, the entry is **not** removed. It is
marked *missing* (`Game.missingSince`), keeps its favourite, play time,
metadata and saves, and shows "File Missing" in the library. It becomes normal
again when

- a later scan finds the file at its old path,
- a scan recognises the file under a new name or in another folder
  (`LibraryMatcher`), or
- the user locates it (Game menu › Locate File…, or Locate… in the inspector).

A scan recognises a renamed or moved file when it belongs to the same system,
has the same size and extension, and either matches the game's known CRC32 or,
for games without a CRC32, still has the same modification date (Finder keeps
it when renaming, moving and copying). A different CRC32 never matches, so
other regions, revisions and hacks stay separate. When the evidence is
ambiguous (several candidates and no identical file name), nothing is matched
and the user decides.

If the located file already has its own entry (it was found as a new game after
the rename), the two entries are merged: favourites and play time are combined
and both entries' saves are kept (see *Conflicts* below).

Games on an unmounted volume or in a folder that could not be read are left as
they are; playing one asks to connect the drive. Only "Remove from Library…"
and removing a library folder delete entries.

## Battery saves

`Saves/<system>/<game id>/<ROM name>.srm` holds the cartridge save RAM
(`RETRO_MEMORY_SAVE_RAM`). Cores that report a separate real-time clock
(`RETRO_MEMORY_RTC`) also get `<ROM name>.rtc` next to it. Both are written
when they change, every 10 seconds and when the game stops. A failed write is
shown in the player once and retried with the next write.

After a ROM is renamed, its save still carries the old name. When it is the
only save in the folder it is renamed to match (`BatterySave.adoptRenamed`).

When a game's system changes (Edit Info…, or a scan that detects another
system), its `<game id>` folder moves to the new system's folder
(`GameSaveFiles.changeSystem`), e.g. a Game Boy Color game that was first
listed as Game Boy keeps its save.

Files that cores manage themselves (memory cards, backup RAM) are named after
the game inside `Saves/<system>/`. They are renamed along with the game when
no other game in the library uses the old name.

Game menu › Import Battery Save… copies a `.srm`/`.sav` file from another
emulator or installation into place. The previous save is kept as a copy.

## Save states

    States/<game id>/<core id>/slotN.state   the core's serialized state
    States/<game id>/<core id>/slotN.png     thumbnail
    States/<game id>/<core id>/slotN.json    manifest

Slot 0 is Quick Save; slots 1–9 are in the pause menu.

### Automatic state

When a game stops (also when Ursprung quits), its state is saved as
`autosave.state` (with `.png` and `.json`) in the core's folder, apart from the
numbered slots. With Settings › Emulation › Resume Where You Left Off, Play
continues from it and the game's menu offers Start from Beginning; otherwise
Play starts fresh and the menu offers Resume. Optionally the automatic state
is also written every 5 minutes. Like a slot, a failed write keeps the
previous file. Cores that cannot save states have no automatic state.

Resuming loads the automatic state right after the game starts and tries
again a few times over two seconds, as some cores reject a state before they
have run a few frames. Until it has loaded (or finally failed), nothing is
written, so quitting meanwhile keeps the state. An automatic state made from
a different version of the game file is not loaded. If the core rejects the
state, the game starts from the beginning.

### Names and history

A state can be named in the pause menu (Rename… on a slot, or the top face
button on a controller) and in the library's Save States window. The name is
stored in the manifest (`"name"`); saving into the slot again starts without a
name.

Saving into an occupied slot, or deleting a slot's state, does not destroy the
previous state. It moves to `States/<game id>/<core id>/History/` as
`<milliseconds since 1970>-slotN.state` (with its `.png` and `.json`), where the
pause menu's Recently Replaced page and the library's Save States window can
load it or put it back into its slot. The newest 20 per game and core are
kept. The new state is written to a temporary file first, so a failed save
leaves the slot as it was. Automatic states have no history.

The library's Save States window (Game › Save States…) lists every state of a
game, per core. States of the game's current core can start the game
(Play from Here).

States are specific to a core, so every core has its own slots: switching a
game to another core never overwrites the first core's states, and switching
back finds them again.

The manifest records the core ID, the core version (`library_version`), the
ROM's CRC32, file name and size, and the date:

```json
{
  "coreID" : "snes9x",
  "coreVersion" : "1.62.3 46f8a6b",
  "created" : "2026-10-03T12:00:00Z",
  "format" : 1,
  "gameCRC32" : "B19ED489",
  "gameFileName" : "Super Mario World (USA).sfc",
  "gameFileSize" : 524288,
  "name" : "Before the final boss"
}
```

### Compatibility

A save state is a memory snapshot in a core-specific format. It is generally
only readable by the same core, and core updates can change the format.
Ursprung therefore compares the manifest with the running game:

| Difference | What happens |
|---|---|
| Other core | Cannot happen: each core only sees its own states |
| Other core version | The slot shows a warning; loading is attempted. If the core rejects it, the message names the version it was saved with |
| Other ROM (CRC32 or size) | The slot shows a warning; loading is attempted, and a warning says the game may misbehave |
| No manifest (saved before October 2026) | See below |

States saved before states were kept per core lie directly in
`States/<game id>/`. They are not moved, because the core that made them is
unknown. A core sees such a state in every slot it has not used itself,
marked as being of unknown origin. Saving into that slot writes the core's own
state and leaves the old one untouched for other cores.

Battery saves are the portable form of progress: unlike states, they work
across cores and core versions of the same system.

Core updates keep the previous version of the core (`Cores/Previous/`,
recorded with its version in `Cores/versions.json`). If an update can no
longer load a state, Settings › Cores › Go Back to Version … puts the old core
back; the newer one becomes the previous version, so this can be undone.

### Rewind and run-ahead

Rewinding and run-ahead use save states in memory only; nothing is written to
disk. Rewind records a state every frame (every second or fourth frame for
larger states) and keeps the differences between them, compressed, in a
buffer of the size chosen in Settings › Emulation; when it is full, the
oldest seconds go. Cores without save states, and states over 24 MB, can't
rewind. Run-ahead saves and loads a state every frame and is skipped for
hardware-rendered cores and while fast forwarding.

## ROM patches

A game's patches (`.ips`, `.ups`, `.bps`) are copied to
`Extras/<game id>/Patches/`; `patches.json` names the one the game starts
with. The ROM file is never changed: at launch the patched ROM is written to
the cache (`~/Library/Caches/Ursprung/Extracted/<game id>-patched/`) and
handed to the core. UPS and BPS patches carry the checksum of the ROM they
expect, so a patch for another revision is refused with a message instead of
producing a broken game. Disc images and arcade sets can't be patched.

A patched game keeps its progress apart from the original, so a hack never
overwrites the original's save:

    Saves/<system>/<game id>/Patches/<patch name>/<ROM name>.srm
    States/<game id>/<core id>/Patches/<patch name>/slotN.state

The pause menu shows the patched game's own slots; the library's Save States
window lists the original's.

## Screenshots, manuals and cheats

    Extras/<game id>/Screenshots/<date>.png   taken while playing
    Extras/<game id>/Manual/<file>            the manual the user added
    Extras/<game id>/cheats.json              cheat names, codes and on/off

Screenshots are the picture as the player shows it (the core's aspect ratio,
rotated upright, small frames doubled), without filters. Cheats are handed to
the core in their order whenever they change; in RetroAchievements hardcore
mode they are not applied.

## RetroAchievements

Signing in sends the password once; RetroAchievements returns a token that is
kept in the keychain (`retroachievements:<username>`) and signs in at the next
launch. The password is not stored. When a game starts, rcheevos computes the
RetroAchievements checksum of the file the core receives (the patched ROM, if
any) and loads its achievements; unlocks that can't be sent are retried until
the connection is back. Hardcore mode starts games from the beginning and
turns off loading states, rewind and cheats; core options RetroAchievements
doesn't allow in hardcore mode turn it off for that game.

## Backups

File › Back Up Library… (or Settings › General › Data) writes one zip file:

    Ursprung Backup/
      manifest.json    format "ursprung-backup", version, date, app version,
                       and every file with its size
      library.json     every library entry with its history and metadata
      settings.plist   preferences (library folders, scraper language and
                       region, video, controls and hotkeys for all systems and
                       per system, controller players, core choices and options)
      Saves/           battery saves and core save folders
      States/          save states with thumbnails and manifests
      Media/           artwork
      Extras/          screenshots, manuals, ROM patches and cheats
      Bezels/          bezel images per system

Not included: BIOS files, cores (downloaded again on demand), and the
ScreenScraper password and RetroAchievements token, which stay in the keychain.

File › Restore from Backup… first extracts and checks the backup. If it is not
an Ursprung backup, comes from a newer version, or misses or garbles any file
its manifest lists, nothing is restored. Otherwise a summary asks for
confirmation (optionally including settings), and then

- per-game settings travel with the game: its chosen system, edited fields,
  hidden state, core options and controls, collections, play status and the
  version chosen among a game's variants. Collections are added to the
  current ones; a play status already set is kept;
- every backup entry joins the library entry with the same ID, the same path,
  or the same game by unique CRC32 or unique file name and size. It adds its
  favourite and takes the larger play time and play count, so restoring the
  same backup twice changes nothing. Metadata is only taken over when the
  library entry has none;
- entries without a match are added. If their file is elsewhere on this Mac,
  they are missing until the next scan recognises the file or the user
  locates it;
- saves, states and extras are placed under the matching entry's ID, renamed
  to its file name where needed; artwork and bezel images only fill in what
  is missing;
- library folders from the backup are added to the current ones.

A game must not be running during a backup or restore.

### Conflicts

Wherever two files meet (restoring a backup, merging two entries), nothing is
overwritten. Identical files are skipped. For files that differ, the newer one
(by modification date) is used, and the older one is kept next to it as
`<name> (before restore <date>).<ext>`, `<name> (from backup <date>).<ext>`,
`<name> (before merging <date>).<ext>` or `<name> (merged <date>).<ext>`.
Rename such a copy to the original name to use it instead.

## Library database

`Library.store` is a SwiftData store with an explicit schema history
(`LibrarySchema.swift`). Every change to `Game` adds a schema version and a
migration stage, so a library written by an earlier release opens in a newer
one. The frozen versions keep an exact copy of the model as it shipped.

| Version | Adds |
|---|---|
| 1 | The first library |
| 2 | Missing files (`missingSince`) |
| 3 | Manual system, locked fields, hidden games, incomplete artwork, missing disc tracks, per-game core options and controls |
| 4 | Collections, play status, preferred version among variants |

## Disc playlists

Discs named like `Game (USA) (Disc 1).cue` and `Game (USA) (Disc 2).cue` in
one folder are a disc set. Until a playlist joins them, every disc is a game
of its own; Game › Create Disc Playlist… writes `Game (USA).m3u` next to them.
The disc played most keeps its identity and moves to the playlist, and the
other discs fold into it with their play time, favourites, collections and
saves (see *Conflicts*).

Game › Edit Discs… orders, labels, adds and removes the discs of any .m3u
game and warns about missing files and disc numbers. Labels are written as
`#EXTINF:0,<label>` lines, which cores skip; a playlist without labels stays
a plain list of files. RetroArch's `Disc.cue|Label` form is read too. The
pause menu's Change Disc page shows the labels.
