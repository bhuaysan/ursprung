# Shaders

Ursprung draws every game through a filter. Seven built-in filters (Sharp,
Pixel Perfect, Smooth, Scanlines, CRT, CRT Curved, Handheld LCD) are fast and
always there. On top of them, Ursprung renders **RetroArch slang presets**
(`.slangp`) with [librashader](https://github.com/SnowflakePowered/librashader):
the same CRT, handheld, NTSC and smoothing shaders RetroArch uses, with their
parameters, and a shader editor to change them or build your own.

## Getting the shaders

Open **Settings → Emulation → RetroArch Shaders** and click **Download**, or
choose **RetroArch Shaders…** in any Filter menu and download from there. The
libretro shader pack (about 55 MB, more than 2,500 presets) comes from the
libretro buildbot, like the cores; **Check for Updates** in the same place
fetches a newer one. The shaders are separate open source projects with their
own licences; Ursprung does not ship them.

Presets of your own (for example from a forum or from RetroArch) can be
imported in the shader browser with **Import…**, or dropped onto it. A single
preset brings every file it reads along, so its relative paths keep working.
They end up in **My Shaders**.

Only slang presets work. RetroArch's older `.glslp` and `.cgp` presets are
not supported.

## Choosing a shader

A shader can be set at three levels; the most specific one wins:

1. **A game** — in the game's inspector (**Shader**), or in the player's
   shader panel with **Applies To: This Game**.
2. **A system** — in **Settings → Emulation**, per system, or in the panel.
3. **All systems** — the default for everything else.

The **RetroArch Shaders…** entry in every Filter menu opens the browser:
categories, search, favourites (marked with the star, they also appear
directly in the Filter menus) and your own presets. Presets with many passes
are marked: they need a fast GPU, especially in full screen.

## Tuning a shader while you play

Press **F6** (or choose **Shader…** in the game menu, or **Game → Show Shader
Panel**) to open the shader panel at the side of the picture. The panel lies
over the picture instead of shrinking it, because CRT masks and scanlines
depend on the real output size. The game keeps running; the button at the top
pauses it.

- **Applies To** chooses the level (this game, the system, all systems) and
  the **Shader** menu the preset for it. A note says when a more specific
  level decides the picture.
- **Parameters** are the preset's sliders, in the order the shaders declare
  them. Changes show in the next frame. Values you changed are coloured;
  each slider and **Reset All** go back to the preset's values. Long lists
  have a search field.
- While you drag a slider, everything else fades out. **Hold ⌥** to hide the
  whole panel and see the picture.
- **Save as Preset…** writes your values as a small preset to My Shaders and
  uses it. It only stores the differences and points to the original
  (`#reference`), the same way RetroArch saves presets, so RetroArch can load
  it too.
- **Open in Shader Editor** continues in the editor.

Unsaved changes last until the game closes, as in RetroArch.

## The shader editor

Open it with **Window → Shader Editor** (⌥⌘E), from the shader panel, from
**Settings → Emulation**, or with **Edit Shader…** in the context menu of a
game or of a system in the sidebar.

- **Passes** (left): the preset's shader passes in order. Add passes from
  another preset or a new empty pass, duplicate, remove and reorder them by
  dragging. The lookup textures the preset uses are listed below.
- **Inspector** (right): the selected pass's options (scale, filtering, wrap
  mode, mipmaps, float/sRGB frame buffers, frame count modulo, alias), all
  parameters grouped by the pass that declares them, and the preset's
  textures.
- **Source** (bottom): the `.slang` code of the selected pass, with syntax
  colouring, line numbers, find (⌘F) and undo. Included files open in tabs.
  The preset recompiles 400 ms after you stop typing; errors are listed
  below the code and marked at their line. The last picture that compiled
  keeps showing meanwhile.
- **Preview** (top):
  - with a game running, the player window is the preview: changes show
    there as you make them. Pause and **Next Frame** let you look at one
    frame; **Capture Frame** saves the game's picture at its own resolution
    for later;
  - without a game, a still picture: test patterns (colour bars, grey ramp,
    checkerboard, pixel grid, text) at typical console resolutions, frames
    captured from games (also with **Capture Frame for Shader Editor** in
    the game menu), or any image. Time runs, so animated shaders move;
  - **Compare** shows the picture without the shader on the left, **Zoom**
    magnifies without smoothing (drag the picture to move), **Output**
    renders for a 1080p, 1440p or 4K screen, and **Show** stops after an
    earlier pass.

Shaders of the pack are never changed. Your first edit to one of its files
makes a copy inside your shader, with the files it includes. **Save** (⌘S)
writes the preset and its own files to My Shaders; **Use For** assigns it to
the game, its system or all systems. **More** has New Shader, Open Shader…,
Save As…, Revert…, Show in Finder and **Export as Folder…/Zip…**, which
writes the preset with every file it reads, so it works on its own (for
sharing, or for RetroArch).

## Performance

Every frame of the game runs through all passes of the preset on the GPU.
Simple presets cost a fraction of a millisecond; large ones such as
crt-royale or Mega Bezel can take more than a frame lasts (16.7 ms at 60 fps),
especially at 4K or in full screen. The game then stutters.

The editor shows the GPU time per frame. When a preset needs more than a
frame of the game for a second, the time turns orange, the shader panel says
so, and the player shows a warning once per preset. Lighter variants (`-fast`,
`-lite`), lower quality parameters or a smaller window help.

When a preset can't be loaded (a file is missing, or it uses something
librashader doesn't support), the game falls back to the Sharp filter and
says so; the editor shows the exact error.

## Files and backups

Shaders live in `~/Library/Application Support/Ursprung/Shaders/`:

| Folder | Contents |
|---|---|
| `slang-shaders/` | The downloaded pack; replaced by updates |
| `User/` | Your presets and the shader files they own (**My Shaders**) |
| `Drafts/` | The editor's working copy, saved automatically |

Captured frames are stored with the game in `Extras/<game-id>/ShaderFrames/`.
Backups (File → Back Up Library…) include `User/`, the captured frames and
which shader each game and system uses; the pack is downloaded again.
