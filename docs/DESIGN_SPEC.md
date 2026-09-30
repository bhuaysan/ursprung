# Ursprung — Redesign Design Specification

Phase 2 · 30 September 2026. Living version with comments: https://claude.ai/code/artifact/137d052c-6149-444c-ad10-c7375e536127

This spec redesigns the presentation of every Ursprung surface without changing its workflows, data model or emulation lifecycle. It is based on the code at commit f3595ce (main) and names the current file where a change lands.

Every recommendation carries one label:

- **ESSENTIAL**: fixes a defect, an accessibility gap or an inconsistency named in the brief. Ship before calling the redesign done.
- **RECOMMENDED**: clear improvement at moderate cost. Do it unless a trade-off in section T says otherwise.
- **OPTIONAL**: polish that can wait for a later pass.

Measurements are in points (pt). SwiftUI text styles are named with their default macOS 26 size in brackets, for example `.body` (13 pt).

## A. Product visual direction

Ursprung should feel like a well-lit shelf of games inside a quiet Mac app: the box art carries the colour, the chrome stays monochrome with one accent. Reference points are Finder icon view, Photos and Music, not a game launcher skin.

1. **Artwork is the only saturated content.** Chrome uses system text colours, system materials and the app accent for interaction only. System colours appear as small identity signals, never as large fills. ESSENTIAL
2. **The shelf is the signature.** Box art already sits on a common bottom baseline inside a square slot (`GameGridView.swift:175`). Make that the recognisable trait: aligned baselines, varied box shapes, no card backgrounds behind them. RECOMMENDED
3. **Structure through space and type, not boxes.** No rounded containers around grid items, inspector sections or settings rows beyond what native `Form` draws. Separation comes from spacing tokens (section Q) and text hierarchy. ESSENTIAL
4. **Glass only where things float.** Liquid Glass is used for the toolbar (system), the on-cover Play button, the Player HUD and the pause panel. Never for grid items, the inspector body or nested inside another glass surface. ESSENTIAL
5. **One accent, one meaning.** The coral accent means "interactive or selected". It is not reused for decoration, system identity or status. ESSENTIAL
6. **Calm by default.** Motion is short, has no bounce, and exists only to explain a change (section O). RECOMMENDED
7. **Native before custom.** Use `NavigationSplitView`, `.inspector`, `.searchable`, `Form`, `ContentUnavailableView`, menus and sheets as the platform draws them. Custom drawing is limited to the grid card, the system header, the Player HUD and the pause panel. ESSENTIAL

## B. Library window layout

The three-column structure stays: sidebar, grid, inspector, with a unified toolbar on top. What changes is how the columns share width, where status lives, and which surface owns each action.

| Region | Width | Surface | Owns |
| --- | --- | --- | --- |
| Sidebar | 200–280 pt, ideal 220 | System sidebar material | Library filters, systems, activity footer |
| Toolbar | full width | System glass toolbar | Title + count, view, library commands, search, inspector toggle |
| Content | flexible, ≥ 440 pt target | Window background, no material | System header, grid, empty states |
| Inspector | 280–400 pt, ideal 320 | System inspector background | Selected game detail, actions, core override |

- Keep the window minimum at 820 × 520 pt and the default at 1240 × 800 pt (`UrsprungApp.swift:56`). The narrow-width problem is solved by column priorities (section M), not by a larger minimum. ESSENTIAL
- Content priority when width runs out: grid first, then sidebar, then inspector. The inspector is contextual and is the first column to yield. ESSENTIAL
- The content column never gets its own background colour or material; the grid sits directly on the window background so artwork reads against a neutral field in Light and Dark Mode. ESSENTIAL
- Background activity (scan, metadata, system media, errors) has exactly one home: the sidebar footer, mirrored into a toolbar popover only when the sidebar is hidden (sections C and D). ESSENTIAL
- Game actions have one definition shared by the context menu, the inspector and the menu bar (section G). ESSENTIAL

## C. Sidebar specification

The sidebar stays a native `.sidebar` list with two flat sections; the only custom elements are the system identity dot and the activity footer.

**Structure**

- Section “Library”: All Games, Favorites, Recently Played. Section “Systems”: one row per system that has games, ordered by manufacturer then year (current order). ESSENTIAL
- Make “Systems” collapsible with `Section(isExpanded:)`, state stored in `@AppStorage`. The native disclosure chevron appears on hover of the header. RECOMMENDED
- No manufacturer sub-groups; the list stays one level deep. ESSENTIAL

**Rows**

- Row height, icon size and label font come from the system sidebar metrics, so they follow the user's “Sidebar icon size” setting. No `.frame(height:)`, no custom fonts. ESSENTIAL
- Library rows: SF Symbols `square.grid.2x2`, `heart`, `clock`, rendered by the sidebar in its default accent tint. RECOMMENDED
- System rows: an 8 pt flat circle in the system accent (no gradient), mixed 30 % toward `.primary` as today, with a 0.5 pt `.separator` stroke so near-black and near-white systems stay visible. Centre it in the standard icon slot so text aligns with the Library rows. The dot is decorative: `accessibilityHidden(true)`. RECOMMENDED
- Labels truncate at the tail on one line; a `.help(system.name)` tooltip shows the full name. RECOMMENDED

**States**

- Selected: native sidebar selection (accent capsule when the sidebar is focused, grey when not). No custom selection drawing. ESSENTIAL
- Hover: native only. No hover backgrounds, no hover icons. ESSENTIAL
- Count badges: keep native `.badge(count)` on every row; badges use secondary text and do not compete with labels. Hide the badge on Recently Played, where the number has no meaning. RECOMMENDED

**Activity footer** (replaces `statusFooter`, `SidebarView.swift:60`)

- Pinned with `safeAreaInset(edge: .bottom)`, padding 12 pt horizontal and 10 pt vertical, a hairline `Divider` above it. Hidden entirely when nothing is running and no error is pending. ESSENTIAL
- One row per activity, max three rows, in this order: library scan, metadata fetch, system media fetch, last error. ESSENTIAL
- Row anatomy: 16 pt leading indicator (small `ProgressView`, circular determinate when progress is known) · title in `.subheadline` (11 pt) primary · detail in `.subheadline` secondary with `monospacedDigit()` (“42 of 318”) · trailing 16 pt stop button (`xmark.circle.fill`, secondary, `.help("Stop")`) for cancellable tasks. ESSENTIAL
- Error row: `exclamationmark.triangle.fill` in `.orange`, message in primary text limited to two lines, trailing “Retry” (`.link` button) when the operation can be retried and a dismiss button. The error is not shown in red text. ESSENTIAL
- The currently scraped title is available as `.help()` on the metadata row, not printed. RECOMMENDED

**Narrow widths**

- The sidebar width is 200–280 pt, ideal 220 (today 200–300, ideal 230). Below 1000 pt window width the sidebar is the column that collapses when the user opens the inspector (section M). RECOMMENDED
- When the sidebar is collapsed, the activity footer's content moves into a toolbar activity button (section D) so progress is never lost. ESSENTIAL

## D. Toolbar specification

The toolbar holds four trailing controls plus search, each with one job; progress leaves the toolbar except when the sidebar is hidden.

| Position | Item | Symbol | Tooltip / shortcut | Label |
| --- | --- | --- | --- | --- |
| Leading | Sidebar toggle | system | system, ⌃⌘S | ESSENTIAL |
| Leading | Title + subtitle (“Super Nintendo”, “124 games”) | — | — | ESSENTIAL |
| Trailing group 1 | Activity button (only while the sidebar is collapsed and something runs or failed) | small circular `ProgressView`, or `exclamationmark.triangle` | “Activity” | ESSENTIAL |
| Trailing group 2 | View menu | `square.grid.2x2` | “View Options” | ESSENTIAL |
| Trailing group 3 | Add Folder | `plus` | “Add Folder to Library… (⌘O)” | ESSENTIAL |
| Trailing group 3 | Library menu | `ellipsis.circle` | “Library Actions” | ESSENTIAL |
| Trailing | Search field | system | ⌘F | ESSENTIAL |
| Trailing, last | Inspector toggle | `sidebar.trailing` | “Show/Hide Inspector (⌃⌘I)” | ESSENTIAL |

**Menus**

- View menu (`square.grid.2x2`): inline picker “Sort By” (Title, Recently Added, Recently Played, Release Year) · divider · “Larger Covers ⌘+”, “Smaller Covers ⌘−”, “Default Size ⌘0”. This replaces the filter icon and the slider inside a menu. The sort picker is disabled with a checkmark on “Recently Played” while the Recently Played filter is active, because that filter always sorts by date (`LibraryView.swift:123`). ESSENTIAL
- Library menu (`ellipsis.circle`): “Rescan Library ⇧⌘R” · divider · “Fetch Missing Metadata” · “Refetch All Metadata…” (asks for confirmation, it overwrites existing data) · divider · “Library Folders…” (opens Settings › General). ESSENTIAL
- The `plus` button does one thing: Add Folder. A plus icon never opens a menu of unrelated operations. ESSENTIAL
- Every toolbar command also exists in the menu bar: File gets Add Folder and Rescan (existing); a new “Library” command group under File gets the metadata commands; a new View menu section gets sort and cover size; `InspectorCommands()` supplies the inspector toggle. RECOMMENDED

**Grouping and density**

- Use `ToolbarSpacer(.fixed)` between groups so Liquid Glass renders three separate capsules: [View] · [+ ⋯] · [Inspector]. Search keeps its own capsule. RECOMMENDED
- Icon-only presentation, every item built with `Label(title, systemImage:)` so the title serves as tooltip, VoiceOver label and “Icon and Text” customisation label. ESSENTIAL
- Allow toolbar customisation (`.toolbar(id:)`) with the default set above. OPTIONAL

**Search**

- `.searchable(placement: .toolbar)` stays; prompt “Search Games”. It filters the current sidebar selection by title, developer and genre (current behaviour). ESSENTIAL
- When the current selection is not All Games and search finds nothing, the empty state offers “Search All Games” (section H). RECOMMENDED

**Progress**

- `ScrapeProgressView` is removed from the toolbar. Progress lives in the sidebar activity footer. When the sidebar is collapsed, the activity button appears and opens a popover (width 280 pt) containing the same `ActivityStatusView`. ESSENTIAL
- The activity button never animates beyond the system progress indicator; no badges or colour pulses. RECOMMENDED

## E. Game grid specification

The grid becomes a shelf of box art on the plain window background, with an explicit column count so keyboard navigation, selection and focus work in all four directions.

**Cover sizes**

| Step | Cover slot width | Use |
| --- | --- | --- |
| 1 | 120 pt | Hard minimum; narrow windows only |
| 2 | 150 pt | Dense browsing |
| 3 | 180 pt | Default (today's default) |
| 4 | 220 pt | Comfortable |
| 5 | 260 pt | Showcase |

- The stored `gridSize` becomes one of these five steps, changed with ⌘+ / ⌘− / ⌘0 (section D). Existing stored values snap to the nearest step. RECOMMENDED
- Columns are computed, not `.adaptive`: `columns = max(2, floor((available + spacing) / (step + spacing)))`. Each slot is exactly the chosen step wide; the remaining width goes into the column spacing (at least 20 pt), so both grid edges stay aligned, as in Finder icon view. ⌘+ / ⌘− therefore always change the cover size visibly, at the cost of wider gaps just before another column fits (question 13). ESSENTIAL (up/down navigation needs the count)
- If the chosen step fits fewer than 2 columns, the slot width drops toward 120 pt until 2 columns fit. Only below 2 columns at 120 pt does the grid show 1 column. ESSENTIAL

**Spacing**

- Horizontal padding: 24 pt (20 pt when the content column is narrower than 560 pt). Column spacing: 20 pt. Row spacing: 28 pt. Top padding: 16 pt below the system header or 20 pt without it. Bottom padding: 32 pt. ESSENTIAL

**Card anatomy** (top to bottom)

1. Square slot; box art aspect-fit and bottom-aligned (keeps the shelf baseline). Corner radius 8 pt (6 pt at step 1–2). A 0.5 pt stroke in `.primary.opacity(0.10)` replaces today's white 8 % stroke, which vanishes in Light Mode. ESSENTIAL
2. Resting shadow on the art only: black 18 %, radius 4, y 2. RECOMMENDED
3. Title, 8 pt below the slot: `.body` (13 pt) `.medium`, primary, max 2 lines, tail truncation, full title in `.help()`. ESSENTIAL
4. Metadata line, 2 pt below: `.subheadline` (11 pt) secondary. In All Games, Favorites and Recent: “SNES · 1992”. Inside a system: “1992 · Developer”, because the system is already in the header. RECOMMENDED
5. Favorite: `heart.fill` at `.imageScale(.small)` trailing on the metadata line, in the favorite colour (section P). The heart shape carries the meaning; colour is secondary. ESSENTIAL

**States**

| State | Visual | Label |
| --- | --- | --- |
| Resting | Art + shadow, no chrome | — |
| Hover | Shadow to black 28 %, radius 10, y 5; Play button fades in. No scale. | RECOMMENDED |
| Selected, grid focused | 3 pt accent ring around the actual artwork bounds (not the square slot), 3 pt gap, radius = art radius + 4.5 | ESSENTIAL |
| Selected, grid not focused or window inactive | Same ring in `.secondary` | ESSENTIAL |
| Loading art | Neutral `.quaternary` fill at the system's box aspect; the generated cover appears only when no art URL exists | RECOMMENDED |

- The 3 pt gap lets the window background separate ring and art, so the ring stays visible on red or coral box art. With Increase Contrast the ring grows to 4 pt. ESSENTIAL
- Selection is conveyed by shape (a ring appears), by the ring's accent colour and by the `.isSelected` accessibility trait. It never relies on a colour change of an element that is always visible. ESSENTIAL

**Play affordance**

- A circular glass button (`.glass`, `play.fill`), 32 pt, anchored bottom-trailing on the artwork with 8 pt inset. It shows on hover and permanently on the selected card, so it is never hover-only. ESSENTIAL
- Play is also reachable by double-click, Return, the context menu, the inspector and the menu bar (section G). ESSENTIAL

**Keyboard**

| Key | Action | Label |
| --- | --- | --- |
| ← → | Previous / next game | ESSENTIAL |
| ↑ ↓ | Same column, previous / next row | ESSENTIAL |
| fn← / fn→ (Home/End) | First / last game | RECOMMENDED |
| fn↑ / fn↓ (Page Up/Down) | One visible page | RECOMMENDED |
| Return | Play | ESSENTIAL |
| Typing letters | Jump to first title with that prefix (Finder type-select, 1 s buffer) | RECOMMENDED |
| ⌘⌫ | Remove from Library… (with confirmation) | RECOMMENDED |
| Tab / ⇧Tab | Move focus sidebar → grid → inspector | ESSENTIAL |

- When the grid gains focus with nothing selected, the first visible game is selected. ESSENTIAL
- Keyboard moves scroll the selection into view with `proxy.scrollTo(id)` and no animation, so key repeat stays fluid. ESSENTIAL
- Clicking empty grid space still clears the selection (current behaviour). ESSENTIAL
- Multi-selection stays out of scope. —

## F. System header specification

The 172 pt accent-gradient banner (`GameGridView.swift:98`) becomes an 88 pt library header on the plain window background: logo, one line of context, and an optional small console photo. ESSENTIAL

- **Placement**: first item inside the grid's scroll view, aligned to the grid's horizontal padding (24 / 20 pt), 20 pt from the top. It scrolls away with the content; the toolbar title already shows the system name and count, so nothing needs to stick. ESSENTIAL
- **Height**: 88 pt (72 pt when the content column is narrower than 560 pt). No background, no rounded rectangle, no shadow. ESSENTIAL
- **Logo**: the template-rendered wordmark in `.primary`, max 36 pt high and 240 pt wide, leading-aligned. Without a logo: the system name in `.title` (22 pt) `.semibold`. ESSENTIAL
- **Context line**: 6 pt below the logo, `.callout` (12 pt) secondary: “Nintendo · 1990 · 124 games”, count with `monospacedDigit()`. ESSENTIAL
- **Console photo**: trailing, max 72 pt high and 160 pt wide, aspect-fit, no shadow. Hidden when the content column is narrower than 560 pt. RECOMMENDED
- **Colour**: none by default. The sidebar dot already carries system identity. A faint wash of the system accent (8 % Light, 12 % Dark) fading to clear over 120 pt behind the header is possible but must be evaluated against busy box art. OPTIONAL
- **Other filters**: All Games, Favorites and Recently Played get no header; the toolbar title is enough. ESSENTIAL
- **Accessibility**: one element, label “Super Nintendo, Nintendo, 1990, 124 games”, trait `.isHeader`. ESSENTIAL

## G. Inspector specification

The inspector is a narrower, quieter column: masked artwork on top, a compact title block, one action row, then plain text sections without uppercase headings.

**Frame**

- Width 280–400 pt, ideal 320 (today 300–440, ideal 340). ESSENTIAL
- One vertical scroll view for everything, content padding 16 pt horizontal and 24 pt bottom, `.scrollEdgeEffectStyle(.soft, for: .top)` kept. RECOMMENDED
- No selection: `ContentUnavailableView("No Game Selected", systemImage: "square.stack")` stays. ESSENTIAL

**Artwork**

- Hero: fanart or screenshot, full width, 16:9 (about 180 pt at 320 pt width), `.fill` and clipped. ESSENTIAL
- The fade uses an alpha mask, not a colour overlay: `.mask(LinearGradient(stops: [.init(color: .black, location: 0.55), .init(color: .clear, location: 1)], …))`. Today's overlay fades to `windowBackgroundColor` (`GameInspector.swift:51`), which does not match the inspector background in either mode. A mask fades into whatever surface is behind it. ESSENTIAL
- No hero art: no hero at all. The accent-gradient fallback is removed; the box art moves up with 16 pt top padding. ESSENTIAL
- Box art: max 96 pt wide and 128 pt high, radius 6 pt, the 0.5 pt stroke from the grid, shadow black 25 % radius 8 y 4. With a hero it overlaps the hero bottom by 32 pt at 16 pt leading. RECOMMENDED
- A blurred, scaled copy of the box art as hero when no fanart exists. OPTIONAL

**Title block** (12 pt below the artwork)

- Title: `.title3` (15 pt) `.semibold`, selectable, no line limit. The clear-logo image is removed from the inspector: it duplicates the title. RECOMMENDED
- Subline: `.callout` (12 pt) secondary, “Super Nintendo · 1992”. ESSENTIAL
- Rating: five stars in `.secondary`, filled vs outlined shape, `.caption`; accessibility label “Rating: 4 of 5 stars”. RECOMMENDED

**Action hierarchy** (16 pt below the title block)

| Tier | Action | Inspector | Context menu | Menu bar | Keyboard |
| --- | --- | --- | --- | --- | --- |
| Primary | Play | `.glassProminent` button, flexible width, `.large` | 1st item | Game › Play | Return, double-click |
| Secondary | Add to / Remove from Favorites | `.glass` square button, `heart` / `heart.fill` | 2nd item | Game › Favorite | see section T |
| Overflow | Refetch Metadata | ⋯ menu | after divider | Game | — |
| Overflow | Show in Finder | ⋯ menu | after divider | Game | ⌘R |
| Overflow | Core › (submenu) | Emulation section picker | submenu | — | — |
| Destructive | Remove from Library… | ⋯ menu, last, after divider | last, after divider | Game | ⌘⌫ |

- One `GameActions` definition (section R) feeds all four columns, so labels, symbols, order and enablement are identical everywhere. Today “Remove from Library” exists only in the context menu. ESSENTIAL
- Remove from Library asks for confirmation: “Remove “Title” from the library? The file stays on disk. Play time and favorite status are lost.” Buttons: Remove (destructive), Cancel (default). ESSENTIAL
- While the game is starting, Play shows a small `ProgressView` and “Starting…” and is disabled (today: disabled only). RECOMMENDED
- The favorite button has a toggle trait and the label “Favorite” with value on/off, not two different labels. ESSENTIAL

**Sections** (24 pt apart, no dividers)

- Order: Overview · Details · Activity · Emulation · File. ESSENTIAL
- Section heading: `.headline` (13 pt semibold), primary, sentence case, no tracking. Replaces uppercase caption headings in `InfoSection`. ESSENTIAL
- Rows: `.callout` (12 pt); label column 88 pt, secondary; value primary, selectable; 6 pt row spacing. Empty values are omitted (current behaviour). ESSENTIAL
- Overview: `.callout` secondary, 6 lines, “More” / “Less” link button. ESSENTIAL
- Metadata status: when `scrapeState` is `.notFound` or `.failed`, the Details section starts with an inline status row (section H) with a “Refetch” link button instead of a floating caption. ESSENTIAL
- Emulation: a “Core” row is always shown. With one core it is plain text; with several it is today's menu picker including “System Default (Name)”. RECOMMENDED
- File: Name and CRC32 in `.monospaced()` variants of `.callout`, middle truncation for long file names. RECOMMENDED

## H. Empty, loading and error states

Every state uses one of four presentations, chosen by scope: a full-area `ContentUnavailableView`, an inline status row, the activity footer, or an alert. Nothing else invents its own layout. ESSENTIAL

| Presentation | When | Anatomy |
| --- | --- | --- |
| Full-area | The content column has nothing to show | `ContentUnavailableView`: SF Symbol, title, one-sentence description, at most one prominent and one secondary action |
| Inline status row | One object is incomplete or failed (a game's metadata, a BIOS file, a core) | 16 pt symbol in semantic colour + primary text + optional trailing link button |
| Activity footer | Background work across the library | Section C |
| Alert | A user-initiated action failed and needs a decision, or a destructive confirmation | Native `.alert` / `.confirmationDialog` |

**Library states**

| State | Symbol | Title | Description | Actions | Label |
| --- | --- | --- | --- | --- | --- |
| No library folders | `gamecontroller` | Welcome to Ursprung | Add a folder with your games. Ursprung detects the system and fetches covers from ScreenScraper. | **Add Folder…** (`.glassProminent`, large) | ESSENTIAL |
| Scanning, no games yet | small `ProgressView` | Scanning Library… | “42 games found” when known | — | ESSENTIAL |
| Scan finished, 0 games | `questionmark.folder` | No Games Found | Ursprung didn't recognise any games in your library folders. | **Rescan**, Library Folders… | ESSENTIAL |
| No search results | system `.search` | No Results for “query” | Check the spelling or try a new search. | Search All Games (if not in All Games) | ESSENTIAL |
| Favorites empty | `heart` | No Favorites Yet | Mark a game as favorite in its info panel or context menu. | — | ESSENTIAL |
| Recently Played empty | `clock` | Nothing Played Yet | Games you play appear here. | — | ESSENTIAL |
| Folder unreachable | `externaldrive.badge.exclamationmark` | inline row in the activity footer | “Games on “Volume” are unavailable.” | Show in Settings | RECOMMENDED |

- The “Favorites empty” description no longer says “heart button”; it names where the action is. ESSENTIAL
- Scanning with existing games keeps the grid visible; progress shows only in the activity footer. ESSENTIAL

**Metadata and artwork**

- Scraping never blocks the grid and adds no per-card spinners. ESSENTIAL
- A failed batch leaves a warning row in the activity footer: “Metadata couldn't be fetched”, the reason in one line (e.g. “Daily ScreenScraper quota reached”), Retry and dismiss. ESSENTIAL
- A single game with no match: inspector inline row `questionmark.circle` secondary, “No match on ScreenScraper”, link “Refetch”. ESSENTIAL
- Missing artwork: the generated `PlaceholderCover` stays, with a flatter fill (two stops 8 % apart instead of the white/black diagonal mix) so a system without covers reads as one calm block. RECOMMENDED

**Recoverable errors**

- Errors from background work go to the activity footer; errors from an explicit user action in Settings use the inline status row next to the control that triggered it; alerts only when the user must choose. ESSENTIAL
- Error text is written as what happened plus what to do, never a raw `localizedDescription` alone. RECOMMENDED

## I. Player specification

The Metal surface stays untouched and edge to edge; all overlays share one dark HUD style and sit in two fixed zones, so the game image is never covered in the middle.

**Zones**

| Zone | Content | Inset | Label |
| --- | --- | --- | --- |
| Top centre | Toasts (transient messages) | 16 pt below the safe area | ESSENTIAL |
| Top trailing | Status cluster: FPS, then Fast Forward, stacked 6 pt apart | 16 pt | RECOMMENDED |
| Centre | Preparing panel, failure panel, pause menu | centred | ESSENTIAL |

- Fast Forward moves from bottom centre to the top-trailing status cluster, next to FPS. Both are persistent-while-active indicators and belong together. RECOMMENDED

**HUD capsule** (shared by toasts, FPS, Fast Forward)

- Glass `.regular` in a capsule, forced dark scheme (current), padding 12 pt × 6 pt. ESSENTIAL
- Text `.callout` (12 pt) `.medium`; FPS in `.caption` `monospacedDigit()`, “59.9 fps”. ESSENTIAL
- Optional leading symbol at `.imageScale(.small)`: `forward.fill` for Fast Forward, `square.and.arrow.down` for saved, `square.and.arrow.up` for loaded, `exclamationmark.triangle.fill` (orange) for a failed save. RECOMMENDED
- Not hit-testable, never steals focus. ESSENTIAL

**Toasts**

- Max 3 stacked, 8 pt apart, newest at the bottom, 2.5 s lifetime (current). ESSENTIAL
- Each toast is posted as a VoiceOver announcement (`AccessibilityNotification.Announcement`). ESSENTIAL

**Preparing**

- Dark glass panel, width 300 pt, padding 24 pt, radius 20 pt. Content: game title `.headline`, then the message `.callout` secondary, then a 240 pt linear `ProgressView` while a core downloads, otherwise a regular circular indicator. RECOMMENDED
- Appears only after 300 ms, so quick starts show no flash. RECOMMENDED

**Failure**

- Same panel, max width 420 pt, padding 28 pt. `exclamationmark.triangle.fill` 32 pt in `.orange` (not yellow), title “The game couldn't be started” `.title3` semibold, message `.callout` secondary, centred. ESSENTIAL
- Buttons: “Open Settings” (`.glass`) and “Close” (`.glassProminent`, default action, Esc also closes). When the cause is a missing core or BIOS, “Open Settings” opens the matching tab. RECOMMENDED

**Cursor and chrome**

- The cursor hides after 2 s without movement while running and the menu is closed (`GameMetalView.swift:52` already uses `setHiddenUntilMouseMoves`; keep). ESSENTIAL
- The window toolbar stays hidden while running and shows with the pause menu (current behaviour). ESSENTIAL
- The window title is the game title; the core name is not shown in chrome. ESSENTIAL

## J. Pause menu specification

The pause menu becomes one glass panel with menu-like rows inside it: one glass layer, one prominent button, full keyboard and controller navigation.

**Frame**

- Scrim: black 50 % over the game (today 45 %), no blur. Clicking the scrim resumes (current). ESSENTIAL
- Panel: glass `.regular`, radius 24 pt, padding 20 pt, forced dark scheme. Width 340 pt on Main, 560 pt on Save States and Core Options. Max height: the smaller of 600 pt and window height − 80 pt; content scrolls inside. ESSENTIAL
- Inside the panel, rows are not individual glass buttons. Only Resume uses `.glassProminent`; every other row is a plain row with a highlight shape. This removes today's glass-on-glass stack (`PauseMenuView.swift:113`). ESSENTIAL

**Header**

- Game title `.headline` (13 pt semibold), max 2 lines; core name `.subheadline` (11 pt) secondary. 16 pt below the header, a hairline divider at 20 % white. ESSENTIAL
- Sub-pages add a 28 × 28 pt back button (`chevron.left`) leading the title, labelled “Back”. RECOMMENDED

**Main page rows**

| Group | Row | Symbol | Trailing hint |
| --- | --- | --- | --- |
| 1 | Resume (prominent, default) | `play.fill` | esc |
| 2 | Quick Save | `square.and.arrow.down` | F2 |
| 2 | Quick Load | `square.and.arrow.up` | F4 |
| 2 | Save States… | `square.stack.3d.up` | `chevron.right` |
| 3 | Change Disc (1/3) (multi-disc only) | `opticaldisc` | `chevron.right`, opens a submenu |
| 3 | Core Options… | `slider.horizontal.3` | `chevron.right` |
| 4 | Reset | `arrow.counterclockwise` | ⌥⌘R |
| 4 | Quit Game | `xmark` | —, text in `.red` |

- Rows 36 pt high, 10 pt horizontal padding, 24 pt symbol column, label `.body`, hint `.subheadline` secondary. Groups separated by 8 pt and a hairline divider. ESSENTIAL
- Highlight: radius 8 pt; hover `white 10 %`; keyboard/controller focus accent fill with white text (like an `NSMenu` highlight). Focus and hover never show at the same time on different rows: moving the pointer moves the focus. ESSENTIAL

**Navigation**

| Input | Action | Label |
| --- | --- | --- |
| ↑ ↓ / D-pad | Move focus between rows (wraps) | ESSENTIAL |
| Return / Space / pad confirm button (see section T) | Activate | ESSENTIAL |
| Esc / pad back button / Home | Main: resume. Sub-page: back | ESSENTIAL |
| ⌘[ | Back | RECOMMENDED |

- Focus starts on Resume every time the menu opens; returning from a sub-page focuses the row that opened it. ESSENTIAL
- Controller navigation needs `InputRouter` to route pad input to the menu while it is visible (see section T). RECOMMENDED

**Save States page**

- A fixed 3 × 3 grid of slots 1–9, 12 pt spacing, each slot a 4:3 thumbnail (radius 8 pt) with “Slot 3” `.subheadline` semibold and the date `.caption` secondary below. The grid scrolls if the window is short. ESSENTIAL
- Slots are focusable: arrows move, Return loads an occupied slot, ⌘S saves to the focused slot, Delete deletes (with confirmation). The per-slot Save / Load buttons stay as small plain buttons visible on the focused or hovered slot, so nothing is context-menu-only. ESSENTIAL
- Empty slot: `plus` symbol on a `white 6 %` fill, text “Empty”. ESSENTIAL
- Show the quick-save slot (slot 0) as a tenth, first item labelled “Quick Save”. OPTIONAL

**Core Options page**

- Filter field with `.searchFieldStyle` look at the top, 8 pt below the header. ESSENTIAL
- Rows: title `.body`, description `.subheadline` secondary max 2 lines, picker trailing at max 200 pt; row spacing 10 pt, hairline dividers at 20 % white. ESSENTIAL
- Footer: “Some options apply after a reset.” `.subheadline` secondary, then “Reset Game” and “Restore Defaults” plain buttons trailing. RECOMMENDED

## K. Settings specification

The native Settings scene with toolbar tabs and grouped forms stays; the redesign is a set of rules that every tab follows, so help text, status and actions look the same everywhere.

**Window**

- Keep `Settings { TabView { Tab … } }` with the six tabs in their current order. ESSENTIAL
- Width 700 pt fixed; height ideal 560 pt, min 440 pt, resizable vertically. Today the frame is fixed at 720 × 560 (`UrsprungApp.swift:83`), which clips long tabs like Controls and BIOS. RECOMMENDED
- Metadata tab symbol: `text.below.photo` instead of `sparkles`, which reads as AI. RECOMMENDED

**Rules**

| Element | Rule | Label |
| --- | --- | --- |
| Section title | `Section("Title")` or `header:` with plain `Text`, sentence case, no custom font | ESSENTIAL |
| Help for one control | The control's label gets a second `Text`, which macOS renders as the row's description: `Toggle(isOn:) { Text("Title"); Text("Explanation") }` | ESSENTIAL |
| Help for a whole section | Section `footer:` with plain `Text`; no manual `.font` / `.foregroundStyle` – one shared `.settingsFootnote()` modifier if the grouped style does not style it | ESSENTIAL |
| Free-floating text rows | Not allowed. Today Controls has two, General and BIOS one each | ESSENTIAL |
| Inline status | Trailing in the row: `Label` with symbol + word, symbol in semantic colour, word in secondary (e.g. `checkmark.seal.fill` green + “Verified”) | ESSENTIAL |
| Warning | A row at the top of its section: `exclamationmark.triangle.fill` in `.orange` + primary text. No orange text | ESSENTIAL |
| Error | Same row with `xmark.octagon.fill` in `.red` + primary text + retry link. No red text (today Metadata uses red caption text) | ESSENTIAL |
| Progress | Determinate: 120 pt linear `ProgressView` + Stop button, trailing. Indeterminate: small circular indicator, trailing, before the action that started it | ESSENTIAL |
| Buttons in a section | Last row of the section, trailing-aligned; the most likely action rightmost | RECOMMENDED |
| Lists with add/remove | Native +/− buttons under the list (`square` bordered, 22 pt), as in System Settings | RECOMMENDED |
| Import | “Import…” button + drop target; the result is an inline status row, not a caption | ESSENTIAL |
| Destructive | `role: .destructive`; confirmation when data leaves the library (remove folder, remove core with no replacement) | ESSENTIAL |

**Tab notes**

- General: folder list with +/−; “Rescan” trailing; the last-scan summary becomes the section footer (“318 games found, 4 new, 1 removed.”). Removing a folder asks for confirmation and names how many games leave the library. ESSENTIAL
- Metadata: missing developer credentials become a warning row; the password field gets the description “Stored in your keychain.”; the Library section shows “Matched 214 of 318”, the progress rule and the error rule. ESSENTIAL
- Emulation: toggle explanations move into row descriptions; “Default Cores” keeps its footer. ESSENTIAL
- Controls: two parts – “Game Controllers” (connected pads, player number, Configure…) and keyboard mapping sections using the shared `InputBindingButton` (section L). The two floating explanations become the section footer. ESSENTIAL
- Cores: status column uses the inline status rule; “Installed” stays a menu (Update, Remove); “Experimental” stays a small capsule in `.orange` at 15 % fill with orange text – the only allowed tinted badge. RECOMMENDED
- BIOS: the drop target outline (dashed accent, 3 pt) stays; import results become inline status rows per recognised or unknown file. RECOMMENDED

## L. HID mapping specification

The mapping sheet gets a fixed header and footer around a scrolling form, edits a draft that Done commits and Cancel discards, and shows every reassignment instead of silently moving it.

**Size**

- Width 480 pt. Height ideal 500 pt, min 360 pt, and never taller than the Settings window minus 60 pt. Today it is fixed at 460 × 600 inside a 560 pt window (`HIDGamepadMappingView.swift:50`). Use `.presentationSizing(.form)` with those bounds. ESSENTIAL

**Layout**

1. Header (not scrolling), padding 20 pt: controller name `.headline`, battery level `.subheadline` secondary, instruction “Click an input, then press a button or move a stick.” `.subheadline` secondary. ESSENTIAL
2. Body: grouped `Form`, one section per `RetroInput.Group`, then a “System” section with “Game Menu”. ESSENTIAL
3. Footer (not scrolling), divider above, padding 16 pt: “Restore Defaults” leading; “Cancel” and “Done” trailing, Done is the default action. ESSENTIAL

**Row: `InputBindingButton`** (shared with keyboard mapping in Controls)

| State | Visual | Label |
| --- | --- | --- |
| Assigned | Bordered button, min width 120 pt, binding in `.monospaced()` `.body`; trailing `xmark.circle.fill` clear button (borderless, secondary, “Clear”) | ESSENTIAL |
| Unassigned | Same button showing “Not Assigned” in secondary; no clear button | ESSENTIAL |
| Listening | Accent-tinted bordered button, text “Press a button…”, `dot.radiowaves.left.and.right` leading symbol; one row at a time | ESSENTIAL |
| Just reassigned | The row that lost the binding shows “Not Assigned”; a status line above the footer says “Button 3 moved from Start to B.” with an Undo link, for 6 s or until the next change | RECOMMENDED |

- Listening ends on: a received input (assign), a click on the same button, Esc, or a click anywhere else. Esc while listening cancels only the listening, not the sheet. ESSENTIAL
- Clearing is also available with Delete when the button has keyboard focus. RECOMMENDED
- Changes apply to a draft copy of `gamepad.mapping`; Done writes it, Cancel and ⌘. discard it. Today edits apply immediately and there is no Cancel. RECOMMENDED
- If “Game Menu” is unassigned, a warning row sits at the top of the System section: “Without a Game Menu button, open the menu with esc on the keyboard.” RECOMMENDED
- VoiceOver: each button reads “B, Button 3” with hint “Press to assign a new button”; listening announces “Waiting for input”. ESSENTIAL

## M. Responsive behavior

The content column is protected at ≥ 440 pt by letting the inspector yield on passive resizes and the sidebar yield when the user explicitly opens the inspector in a narrow window. The 820 × 520 pt minimum stays. ESSENTIAL

**Rules**

1. Passive resize (the user drags the window narrower): when the content column would drop below 440 pt, the inspector hides. It comes back automatically when the window is wide enough again, if the user had it open. ESSENTIAL
2. Explicit action (the user opens the inspector while the window is below 1000 pt): the inspector opens and the sidebar collapses. Closing the inspector restores the sidebar if it was collapsed automatically. ESSENTIAL
3. The user's own choices are stored separately from the automatic state (`prefersInspector`, `prefersSidebar`), so automation never overwrites intent. ESSENTIAL
4. Measure with `onGeometryChange` on the split view; drive `NavigationSplitViewVisibility` and the inspector's `isPresented`. No new minimum sizes. ESSENTIAL

**Bands** (defaults: sidebar 220 pt, inspector 300–320 pt, cover step 180 pt)

|  | 820–999 pt | 1000–1299 pt | 1300 pt + |
| --- | --- | --- | --- |
| Sidebar | Visible, 200–220 pt; collapses when the user opens the inspector | Visible, 220 pt | Visible, 220–260 pt |
| Inspector | Hidden by default; opens at 280 pt, sidebar collapses | Visible at 300 pt if preferred | Visible at 320 pt if preferred |
| Content column | 540–780 pt | 480–780 pt | ≥ 760 pt |
| Grid padding | 20 pt | 20 pt below 560 pt content, else 24 pt | 24 pt |
| Columns at step 180 | 2–3 (180 pt slots) | 2–3 | 3–6+ |
| System header | 72 pt, no console photo | 72–88 pt, photo from 560 pt content | 88 pt with photo |
| Toolbar | Activity button appears when the sidebar is collapsed | Full set | Full set |

```text
Default column widths per window band (grid keeps >= 440 pt; the inspector yields first)

820–999 pt     | Sidebar 220 | Grid 600 · 2 columns           |
               Opening the inspector collapses the sidebar: grid 540 + inspector 280, still 2 columns.

1000–1299 pt   | Sidebar 220 | Grid 480 · 2 columns  | Inspector 300 |
               Narrowing the window hides the inspector before the grid drops below 440 pt.

1300 pt +      | Sidebar 220–260 | Grid 760+ · 3+ columns          | Inspector 320 |
               Extra width goes to the grid; covers stay at the chosen 180 pt step, gaps absorb the rest.
```

The grid column (accented) is the only one that never yields; sidebar and inspector give way depending on whether the user resized or opened a panel.

- What resizes: the content column and the grid's slot widths. What collapses: inspector (passive) or sidebar (explicit). What disappears: the console photo below 560 pt content. What scrolls: grid, inspector, pause menu pages and settings forms. What changes density: grid padding (20/24 pt) and header height (72/88 pt). ESSENTIAL
- Height: at the 520 pt minimum, the system header (72 pt) plus one full row of 180 pt covers with titles fits below the toolbar. The inspector scrolls. ESSENTIAL
- Player window (min 480 × 360 pt): the pause panel's max height follows the window (window − 80 pt) and scrolls; the HUD insets stay 16 pt. ESSENTIAL

## N. Accessibility specification

Accessibility is part of each component's definition above; this section collects the requirements and resolves the four known problems.

**Known problems**

| Problem | Resolution | Section | Label |
| --- | --- | --- | --- |
| Selection shown mainly by a coloured ring | Ring around actual art with a gap, grey when unfocused, 4 pt with Increase Contrast, `.isSelected` trait | E | ESSENTIAL |
| Play only on hover | Persistent Play on the selected card; Return, double-click, context menu, inspector, menu bar; VoiceOver action | E, G | ESSENTIAL |
| Grid keyboard navigation incomplete | Explicit column count, ↑↓, Home/End, Page Up/Down, type-select, focus entry selects first item | E | ESSENTIAL |
| Hover scale ignores Reduce Motion | Hover scale removed; every animation goes through `AppAnimation` which checks Reduce Motion | E, O | ESSENTIAL |

**VoiceOver**

- Game card: one element; label “Title”, value “Super Nintendo, 1992, Favorite”; traits `.isButton` and `.isSelected` when selected. Default activation selects (as in Finder); custom actions come from `GameActions`: Play, Add to/Remove from Favorites, Show in Finder, Refetch Metadata, Remove from Library. ESSENTIAL
- Grid container: label “Games”, and the item count is announced on entry through its value (“124 games”). RECOMMENDED
- System header: one element with `.isHeader` (section F). Sidebar system dots hidden. ESSENTIAL
- Toolbar and icon-only buttons: every button is a `Label`, so VoiceOver reads the title. The favorite button is a toggle. The ⋯ menu reads “More Actions”. ESSENTIAL
- Rating reads “Rating: 4 of 5 stars”. ESSENTIAL
- Progress: activity rows expose label (“Fetching metadata”) and value (“42 of 318”); completion and failure are announced. ESSENTIAL
- Player: toasts are announced; the pause menu is a modal container (`.accessibilityAddTraits(.isModal)`) so VoiceOver stays inside it. ESSENTIAL

**Keyboard-only operation**

- Every function in the library window is reachable without a pointer: Tab/⇧Tab between sidebar, search, grid and inspector; all toolbar commands in the menu bar with shortcuts; context menu items duplicated in the Game menu. ESSENTIAL
- Pause menu, save-state grid and mapping sheet are fully keyboard operable (sections J and L). ESSENTIAL
- Respect Full Keyboard Access: custom focusable views (grid, pause rows, slots) show focus with their own highlight because `.focusEffectDisabled()` removes the system ring. ESSENTIAL

**Focus and selection visibility**

- Every custom focus indicator is at least 3 pt thick, or a filled highlight, and meets 3:1 contrast against its surroundings. ESSENTIAL
- Focus that leaves a view never leaves a stale accent highlight behind: selection turns grey (grid) or disappears (pause rows). ESSENTIAL

**Settings for motion, transparency and contrast**

- Reduce Motion: scale, move and width animations become opacity fades of ≤ 0.15 s or no animation (section O). ESSENTIAL
- Reduce Transparency: glass is replaced by the system automatically; the pause scrim becomes 70 % black; HUD capsules stay readable because they force dark scheme. RECOMMENDED
- Increase Contrast: selection ring 4 pt, artwork stroke 1 pt at 25 %. RECOMMENDED

**Non-colour status**

- Every status is symbol + word: Verified / Present / Unknown Version / Missing, Installed / Download, warning, error, favorite (heart shape). Colour only reinforces. ESSENTIAL
- Pointer targets are at least 24 × 24 pt (the on-cover Play button is 32 pt). ESSENTIAL

## O. Motion specification

Motion uses three durations, no spring bounce, and only explains appearing, disappearing or moving surfaces; selection and navigation are instant.

| Token | Curve | Duration | Used for |
| --- | --- | --- | --- |
| `quick` | `.easeOut` | 0.12 s | Hover shadow, Play button fade, row highlights |
| `standard` | `.smooth` (no bounce) | 0.20 s | Toasts, HUD indicators, inline status rows, overview expand |
| `panel` | `.smooth` (no bounce) | 0.25 s | Pause menu open/close and page change, Player panels |

| Moment | Normal | Reduce Motion | Label |
| --- | --- | --- | --- |
| Card hover | Shadow + Play fade, `quick`; no scale | Play appears without fade; shadow change kept | ESSENTIAL |
| Selection ring | Instant | Instant | ESSENTIAL |
| Keyboard scroll to selection | No animation | No animation | ESSENTIAL |
| Sort change, filter change, cover size change | No animation (grid re-lays out) | Same | ESSENTIAL |
| Inspector content on new selection | Instant; hero image fades in 0.15 s when it finishes loading | Instant | RECOMMENDED |
| Inspector show/hide, sidebar collapse | System animation | System | ESSENTIAL |
| Pause menu open/close | Opacity + scale 0.97 → 1, `panel` | Opacity, 0.15 s | ESSENTIAL |
| Pause page change | Cross-fade + width change, `panel` | Cross-fade 0.15 s, width jumps | ESSENTIAL |
| Toasts | Move from top + opacity, `standard` | Opacity | ESSENTIAL |
| Favorite toggle | `.symbolEffect(.replace)` | System handles it | ESSENTIAL |
| Activity footer appear/disappear | Opacity + height, `standard` | Opacity | RECOMMENDED |

- Never animate: layout of many grid items, text changes of counts, progress values (the system indicator animates itself). ESSENTIAL
- No bouncy springs anywhere. `.snappy` and `.bouncy` are not used. ESSENTIAL
- All animation calls go through `AppAnimation` helpers that read `accessibilityReduceMotion`, so no call site checks it by hand (section Q). ESSENTIAL

## P. Color and typography system

Colour comes from the existing `AccentColor` asset and native semantic colours; no new colour sets. Type comes from SwiftUI text styles; no point sizes in view code.

**Colour roles**

| Role | Source | Where | Never |
| --- | --- | --- | --- |
| Accent (interactive, selected) | `AccentColor` asset: coral #FA5A65 light, #FF6F78 dark; users with a non-multicolour system accent get theirs | Selection ring, prominent buttons, focus highlight, links, toggles, listening state | Decoration, system identity, status |
| Destructive | `role: .destructive` (system red) | Remove, Delete, Quit Game | Warnings |
| Error | `.red` on the symbol only | `xmark.octagon.fill`, missing required BIOS | Body text |
| Warning | `.orange` on the symbol only | `exclamationmark.triangle.fill`, unknown BIOS version, failed metadata, player failure icon | Body text; `.yellow` is dropped (fails contrast on light surfaces) |
| Success | `.green` on the symbol only | Verified BIOS, installed core | Body text |
| Favorite | `Color.favorite` = the accent (see section T) | Heart glyph in grid and inspector | Backgrounds |
| Rating | `.secondary` | Star glyphs | — |
| System identity | `GameSystem.accent`, via `GameSystem.identityColor` (mixed 30 % toward `.primary`) | Sidebar dot, placeholder covers, optional header wash | Text, controls, selection |
| Surfaces | Window background, system sidebar and inspector materials, Liquid Glass | — | Custom backgrounds in the content column |

- The only additions are two computed properties: `Color.favorite` and `GameSystem.identityColor`. No `AppColor` type. RECOMMENDED

**Type roles** (macOS default sizes)

| Role | Style | Weight | Colour |
| --- | --- | --- | --- |
| System header name (no logo) | `.title` (22 pt) | semibold | primary |
| Inspector title | `.title3` (15 pt) | semibold | primary |
| Section heading (inspector, pause pages) | `.headline` (13 pt) | semibold (built in) | primary |
| Pause menu title | `.headline` | semibold | primary |
| Game title (grid) | `.body` (13 pt) | medium | primary |
| Body, pause rows, settings labels | `.body` | regular | primary |
| Inspector rows, overview, header context | `.callout` (12 pt) | regular | label secondary, value primary |
| Grid metadata, sidebar activity, descriptions | `.subheadline` (11 pt) | regular | secondary |
| Captions (slot dates, FPS) | `.caption` (10 pt) | regular | secondary |
| HUD text | `.callout` | medium | white (forced dark) |
| Codes (bindings, file names, CRC) | the role's style + `.monospaced()` | — | — |

- Weights allowed: regular, medium, semibold. `.bold` is removed (today: inspector title, pause title, placeholder). ESSENTIAL
- No `.textCase(.uppercase)` or `.tracking` in the app except the placeholder cover's system label. ESSENTIAL
- `.caption2` is not used; 10 pt is the floor. ESSENTIAL
- No `AppTypography` type: the table maps directly to SwiftUI styles and adds nothing an abstraction would protect. RECOMMENDED

## Q. Proposed design tokens

Three small namespaces in one file, `Ursprung/UI/Components/DesignTokens.swift`: `AppSpacing`, `AppMetrics`, `AppAnimation`. Everything else stays SwiftUI-native. ESSENTIAL

**AppSpacing** (4 pt grid)

| Token | Value | Typical use |
| --- | --- | --- |
| `xxs` | 2 pt | Title → metadata line |
| `xs` | 4 pt | Icon → text in tight rows |
| `s` | 8 pt | Art → title, toast stack, group gaps |
| `m` | 12 pt | Footer padding, slot grid spacing, title block gap |
| `l` | 16 pt | Inspector padding, HUD inset, action row gap |
| `xl` | 24 pt | Grid padding, inspector section spacing, panel padding |
| `xxl` | 32 pt | Grid bottom padding |

**AppMetrics**

| Token | Value |
| --- | --- |
| `sidebarWidth` | min 200, ideal 220, max 280 |
| `inspectorWidth` | min 280, ideal 320, max 400 |
| `contentMinWidth` | 440 |
| `compactContentWidth` | 560 (below: 20 pt grid padding, 72 pt header, no console photo) |
| `coverSteps` | 120, 150, 180, 220, 260; default 180 |
| `gridColumnSpacing` / `gridRowSpacing` | 20 / 28 |
| `gridPadding` | 24 (compact 20) |
| `artworkRadius` | 8 (6 at steps 120–150 and inspector box art) |
| `selectionRingWidth` / `selectionRingGap` | 3 (4 with Increase Contrast) / 3 |
| `coverPlayButton` | 32 |
| `systemHeaderHeight` | 88 (compact 72) |
| `panelRadius` | 24 (pause), 20 (player panels) |
| `rowHighlightRadius` | 8 |
| `pauseMenuWidth` | 340 main, 560 sub-pages; max height min(600, window − 80) |
| `mappingSheet` | 480 wide, ideal 500 high |
| `settingsWindow` | 700 wide, ideal 560 high |

**AppAnimation**

```swift
enum AppAnimation {
    static let quick = Animation.easeOut(duration: 0.12)
    static let standard = Animation.smooth(duration: 0.20)
    static let panel = Animation.smooth(duration: 0.25)
    static let reduced = Animation.easeOut(duration: 0.15)
}

extension View {
    /// Uses `reduced` (opacity-only callers) or no animation when Reduce Motion is on.
    func appAnimation(_ animation: Animation, value: some Equatable) -> some View
}

/// `withAnimation` counterpart for event handlers.
func withAppAnimation<R>(_ animation: Animation, reduceMotion: Bool, _ body: () throws -> R) rethrows -> R
```

- Transitions that move or scale get a Reduce Motion variant via one helper, `AnyTransition.appFade(or:)`, which returns `.opacity` when Reduce Motion is on. RECOMMENDED
- Breakpoints are not tokens; they are derived from `contentMinWidth` and `compactContentWidth`, so the rules in section M hold for any sidebar or inspector width. RECOMMENDED

## R. Reusable components

Seven components earn extraction because each has at least two real hosts today or after this redesign; everything else stays private to its view.

| Component | Hosts | Replaces | Label |
| --- | --- | --- | --- |
| `GameActions` (a small struct producing the ordered action list + a `@ViewBuilder` for menus) | Context menu, inspector ⋯ menu and buttons, Game menu in the menu bar, VoiceOver custom actions | `GameGridView.contextMenu`, `GameInspector.actions` | ESSENTIAL |
| `ActivityStatusView` | Sidebar footer, toolbar activity popover | `SidebarView.statusFooter`, `ScrapeProgressView` | ESSENTIAL |
| `InputBindingButton` | Controls tab keyboard mapping, HID mapping sheet | Two copies of the bordered listening button | ESSENTIAL |
| `StatusLabel` (symbol + word, semantic kind: success, warning, error, neutral) | BIOS rows, Cores rows, Settings error/warning rows, inspector metadata status, activity error row | Hard-coded `.foregroundStyle(.green/.orange/.red)` labels | RECOMMENDED |
| `HUDCapsule` | Toasts, FPS, Fast Forward | Three copies of capsule glass styling in `PlayerView` | RECOMMENDED |
| `PlayerPanel` (dark glass container with radius and padding) | Preparing, failure | Two hand-styled panels | RECOMMENDED |
| `ArtworkFrame` (clip, radius, 0.5 pt stroke, optional shadow) | Grid cover, inspector box art, save-state thumbnails | Repeated clip + overlay code | RECOMMENDED |

**Kept as they are, restyled in place**

- `InfoSection` / `InfoRow` (inspector only), `RatingView`, `PlaceholderCover`, `ArtworkImage`. ESSENTIAL

**Not extracted**

- System header, pause menu rows, save-state slot, the toolbar, empty states. Each has one host; the empty states are a `LibraryState` enum switched in `LibraryView`, rendered with native `ContentUnavailableView`. ESSENTIAL
- No wrapper around `Form`, `Section` or buttons. The Settings rules in section K are conventions, plus at most one `.settingsFootnote()` modifier. ESSENTIAL

## S. Screen-by-screen implementation order

Ten steps, each a separate commit that builds, keeps all workflows working and can be checked with `URSPRUNG_SNAPSHOT_DIR` snapshots (glass and Metal layers do not appear in snapshots, so those parts need a manual look).

1. **Tokens and motion helpers**: `DesignTokens.swift` with `AppSpacing`, `AppMetrics`, `AppAnimation`, `appAnimation`, `appFade`. No visual change yet.
2. **Game actions**: `GameActions`, used by context menu and inspector; add Remove from Library to the inspector, confirmation dialog, Game menu items. Removes the action inconsistency first because later steps build on it.
3. **Grid**: explicit columns, cover steps and ⌘+/−, card anatomy, selection ring with focus/unfocus, persistent Play, four-direction keyboard navigation, type-select, VoiceOver element. The largest step; the centre of the redesign.
4. **Responsive layout**: new column widths, inspector/sidebar yielding rules, compact padding.
5. **Toolbar and activity**: new toolbar items and menus, `ActivityStatusView` in the sidebar footer and toolbar popover, menu bar commands, `InspectorCommands`.
6. **Sidebar**: flat dot, collapsible Systems, badge rules.
7. **System header and inspector**: 88 pt header; masked hero, title block, action row, section headings, core row.
8. **Library states**: `LibraryState` enum, all full-area and inline states, error copy.
9. **Player and pause menu**: `HUDCapsule`, `PlayerPanel`, status cluster, then the pause panel with rows, focus model and sub-pages. Controller navigation last within this step, behind the input-routing decision in section T.
10. **Settings and mapping**: Settings rules tab by tab, `StatusLabel`, `InputBindingButton`, mapping sheet with draft/Cancel.

- Each step adds its new strings with German translations to `Localizable.xcstrings` in the same commit. ESSENTIAL
- A VoiceOver and keyboard-only pass closes steps 3, 5, 9 and 10, not the whole project. ESSENTIAL
- Swift Testing coverage where logic exists: column count and cover-step snapping, grid index math for ↑↓ and Page Up/Down, inspector/sidebar yielding decisions, `GameActions` enablement. RECOMMENDED

## T. Open design questions

Each question has a recommended answer that the spec above already assumes; a different decision changes only the named section.

Decided on 30 September 2026: questions 1–12 follow the recommendation; question 13 was added after testing step 3 and is decided as shown. Question 11: `LibraryStore` checks folder reachability on every scan (`LibraryStore.swift:90`) but does not keep the result yet; step 8 adds that property and keeps the row.

| # | Question | Recommendation | Affects |
| --- | --- | --- | --- |
| 1 | Favorite colour: the coral accent or system pink? The two hues are close enough to look like a mistake side by side. | Accent. Selection ring and heart never need to be told apart by colour, because one is a ring and one is a glyph. | P, E, G |
| 2 | Cover size: five discrete steps or keep the continuous slider? | Steps. They make ⌘+/− possible and keep the grid rhythm predictable. | D, E |
| 3 | In a narrow window, should opening the inspector collapse the sidebar, or should the inspector overlay the grid? | Collapse the sidebar; an overlay would hide the selected game. | M |
| 4 | “Remove from Library” is undone by the next rescan because there is no exclusion list (FEATURE_EVALUATION M7). Keep the action as is, or rename it until exclusion exists? | Keep it, and say in the confirmation that a rescan adds the game again, until M7 lands. | G |
| 5 | Pause menu with a controller: which button confirms and which goes back? The pad layout is positional (bottom face = B, SNES style). | Right face confirms, bottom face goes back, matching the SNES layout the mapping already uses; Home always closes. Needs `InputRouter` to route pad input to the menu while it is open. | J |
| 6 | Keyboard shortcut for Favorite? | ⌘D is free in the library window; Photos uses the period key without modifier. Prefer ⌘D for menu discoverability. | G |
| 7 | HID mapping: switch from live edits to draft + Cancel? | Yes; users expect Cancel in a sheet. It is a behaviour change, so it needs explicit approval. | L |
| 8 | Keep the console photo in the system header? | Keep at 72 pt high on wide windows; it is the only place the app shows hardware. | F |
| 9 | Header colour wash per system? | Not in the first pass; evaluate with real libraries later. | F |
| 10 | Base-language spelling: “recognises”, “Behaviour” (British) or American? | Pick one before step 8 writes new copy; American matches macOS system strings. | H, K |
| 11 | Does `LibraryStore` know which folders are unreachable? The “folder unreachable” state needs it. | If not, drop that row from step 8 and track it with M7. | H |
| 12 | Settings window: allow vertical resizing? | Yes, 440 pt min; tabs like Controls and BIOS are long. | K |
| 13 | Cover steps: flexible slots (±20 % around the step) or fixed slot width? With rounding, two steps often give the same column count, so ⌘+ changes almost nothing. | Decided: fixed slot width, the remainder goes into the gaps (section E). | E, M |
