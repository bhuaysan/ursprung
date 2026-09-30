# Feature-Evaluation: Ursprung

Stand: 30. September 2026. Bewertet wurde der aktuelle lokale Arbeitsstand einschließlich geänderter und noch unversionierter Dateien.

## Bewertungsrahmen

Angenommenes Produktziel: eine native Retro-Spielebibliothek für macOS und Apple Silicon, in der Nutzer ihre Sammlung pflegen und Spiele unkompliziert starten und fortsetzen können. „Must-have“ bedeutet hier: vor einer alltagstauglichen Version 1.0. Eine weitere Entwicklungs-Beta muss nicht sämtliche Punkte erfüllen.

Die Bewertung beruht auf statischer Prüfung der Modelle, Bibliotheksverwaltung, Metadaten-Dienste, Einstellungen, Spieleroberfläche, Eingaberouten, Core-/BIOS-Verwaltung, Objective-C-Bridge und vorhandenen Tests. Es wurden keine echten ROMs gestartet, keine Controller praktisch geprüft und keine Builds oder Tests ausgeführt. „Vorhanden“ beschreibt implementierte Funktionen und ist keine Aussage über ihre Kompatibilität mit jedem Spiel und Core.

Die bestehende Datei `CODE_REVIEW.md` enthält historische Findings. Ihre Statusangaben wurden nicht ungeprüft übernommen: Beispielsweise enthält der aktuelle `LibraryDatabase.backUp` bereits Schutz vor Namenskollisionen und fehlgeschlagenen Rollbacks.

## Gesamteinschätzung

Die Basis ist für Version 0.1 bereits breit. Die größten Lücken liegen bei der dauerhaften Pflege und Wiederherstellung der Sammlung sowie bei sicheren, bequemen Spielständen. Diese Funktionen sollten Vorrang vor zusätzlichen Konsolen, Online-Funktionen und aufwendigen Grafikoptionen haben.

Die Architektur bietet dafür brauchbare Ansatzpunkte: Services sind von den Views getrennt; Systeme und Cores sind katalogisiert; Hintergrundarbeit und Emulation haben eigene Ausführungspfade. Größere Erweiterungen benötigen jedoch ein reichhaltigeres Datenmodell als das aktuelle einzelne `Game`-Modell.

## Bereits implementiert

| Bereich | Vorhandene Funktionen | Belege |
|---|---|---|
| Bibliothek | Mehrere ROM-Ordner; rekursiver Scan; Systemerkennung über Ordner/Dateityp; ZIP-Erkennung; Ausblenden referenzierter Disc-Tracks; Erhalt von Spielen aus nicht erreichbaren Bibliotheksordnern | `LibraryScanner.swift:31`, `LibraryStore.swift:79` |
| Browsing | Cover-Raster; Titelsuche, Entwickler- und Genresuche; Systemfilter; Favoriten; zuletzt gespielt; vier Sortierungen; verstellbare Covergröße; Inspector | `LibraryView.swift:108`, `GameGridView.swift:19`, `GameInspector.swift:15` |
| Metadaten | ScreenScraper; CRC-/Dateiname-/Titelsuche; Sprache und Region; Cover, Screenshot, Titelbild, Logo, Fanart; Fortschritt, Abbruch und manuelles erneutes Abrufen | `ScreenScraperClient.swift:108`, `MetadataService.swift:24` |
| Emulation | Core-Download bei Bedarf; manuelles Core-Update; Core-Wahl pro System und Spiel; Core-Optionen; Metal-Ausgabe; OpenGL für Hardware-Cores; Lautstärke, Pause, Hintergrundpause und 4× Fast Forward | `EmulationSession.swift:93`, `CoreManager.swift:71`, `UREmulationRunner.m:170` |
| Spielstände | Quick Save/Load; neun weitere Slots; Vorschaubilder; Löschen; Batteriespielstände pro Spiel-ID; SRAM-Sicherung ungefähr alle zehn Sekunden und beim Entladen | `EmulationSession.swift:354`, `PauseMenuView.swift:133`, `BatterySave.swift:12`, `UREmulationRunner.m:137`, `URLibretroCore.m:352` |
| Eingabe | Tastatur mit frei belegbaren RetroPad-Tasten; GameController, XInput und HID; bis zu vier Ports; HID-Belegung; Maus als Pointer; Home-Taste öffnet das Spielmenü | `InputRouter.swift:56`, `ControlsSettingsView.swift:14`, `GameMetalView.swift:88` |
| BIOS und Datenbank | BIOS-Import per Dateiauswahl/Drag-and-drop, Prüfsummen und Statusanzeigen; kontrollierter Datenbank-Neustart mit Sicherung bei Öffnungsfehler | `BIOSSettingsView.swift:12`, `BIOSManager.swift:41`, `LibraryDatabase.swift:57` |
| Projektqualität | Unit-Tests für Scanner, ZIP, Datenbank-Recovery, Core-Installation, Batteriesave-Pfade und Eingabe-Helfer; CI-Konfiguration; Smoke-Harness | `UrsprungTests/`, `.github/workflows/ci.yml`, `Tools/ursprung-smoke/main.m` |

## Must-haves vor Version 1.0

Aufwand ist eine relative Einschätzung, keine Zeitzusage: S = lokal begrenzte Änderung; M = mehrere Komponenten; L = Datenmodell, Migration und mehrere Abläufe. P0 = Schutz bestehender Nutzerdaten; P1 = vollständiger Alltagsablauf.

### M1 — Spiele wiederfinden, ohne ihre Datenverbindung zu verlieren

**Priorität P0 · Aufwand L · teilweise vorhanden.**

Der Scan gleicht Spiele ausschließlich über den absoluten Pfad ab (`LibraryStore.swift:98`). Eine umbenannte oder verschobene ROM erhält einen neuen `Game`-Datensatz und eine neue UUID. Der alte Datensatz wird aus erreichbaren Ordnern entfernt. Favoriten, Spielzeit und Metadaten gehen damit für diesen Eintrag verloren; die an die alte UUID gebundenen Save-Dateien bleiben auf der Platte, werden vom neuen Eintrag aber nicht mehr gefunden (`BatterySave.swift:12`, `EmulationSession.swift:356`).

Benötigt werden ein Status „Datei fehlt“/„Laufwerk nicht verbunden“, manuelles Neuverknüpfen und eine kontrollierte Wiedererkennung bei Umbenennungen. Scanfehler und Leseberechtigungsprobleme dürfen nicht wie eine erfolgreich gescannte, leere Sammlung behandelt werden. Der Scanner liefert derzeit nur `[ScannedROM]`, ohne ein Ergebnis pro Ordner mit Fehler-/Vollständigkeitsstatus (`LibraryScanner.swift:39`).

**Abnahme:** ROM umbenennen, Ordner verschieben und Laufwerk vorübergehend trennen. Derselbe Bibliothekseintrag behält Favoriten, Historie, Medien und Spielstände. Unsichere Zuordnungen müssen auswählbar bleiben. Inhaltshashes dienen als Hinweis; unterschiedliche Regionen und Hacks dürfen nicht blind zusammengeführt werden.

### M2 — Spielstände gegen Core-Wechsel und Überschreiben absichern

**Priorität P0 · Aufwand M–L · teilweise vorhanden.**

Die Dateien heißen `States/<game UUID>/slotN.state`. Sie enthalten nur den vom Core serialisierten Zustand; `SaveStateSlot` kennt lediglich Slot, Datum und Dateipfade (`EmulationSession.swift:11`, `:356`, `:370`). Core-ID, Core-Version und ROM-Identität werden nicht mitgespeichert. Eine andere Core-Wahl verwendet dieselben Slots; ein weiterer Save kann den vorherigen Zustand überschreiben.

Benötigt werden ein Manifest mit Core-ID/-Version und Inhaltsidentität, getrennte State-Ablagen je Core sowie verständliche Kompatibilitätsmeldungen. Eine Versionsangabe erlaubt Warnungen, garantiert aber keine Kompatibilität. Auch Speicherfehler müssen von „Core unterstützt keine States“ unterscheidbar werden: aktuell zeigt `saveState` für beide Fälle dieselbe Meldung (`EmulationSession.swift:388`). SRAM-Schreibfehler werden nicht an die Oberfläche gemeldet (`URLibretroCore.m:397`).

Der Save-RAM-Pfad behandelt ausschließlich `RETRO_MEMORY_SAVE_RAM`; für separat über `RETRO_MEMORY_RTC` bereitgestellte Uhrdaten gibt es keinen entsprechenden Persistenzpfad (`URLibretroCore.m:385`, `libretro.h:515`). Das muss für betroffene Cores mit Zeitfunktionen geprüft und bei Bedarf ergänzt werden.

**Abnahme:** State mit Core A speichern, zu B wechseln und wieder zurück. A bleibt erhalten; inkompatible Dateien werden nicht unkommentiert geladen. Schreibfehler werden sichtbar. Batteriesave und gegebenenfalls RTC-Daten bleiben nach Neustart konsistent.

### M3 — Metadaten und Systemzuordnung korrigierbar machen

**Priorität P1 · Aufwand M · fehlt.**

Der Inspector zeigt Metadaten an, bietet aber keinen Editor, keine eigene Coverauswahl und keine manuelle Systemkorrektur (`GameInspector.swift:152`). Die Titelsuche übernimmt den ersten parsebaren Suchtreffer ohne Nutzerentscheidung (`ScreenScraperClient.swift:133`). Beim erneuten Scrapen werden vorhandene Metadaten überschrieben (`MetadataService.swift:95`).

Benötigt werden „Treffer auswählen“, Titel/System/Details bearbeiten, eigenes Artwork importieren und die Möglichkeit, manuelle Werte beim nächsten Scrape zu schützen. Eine manuelle Systemzuordnung muss auch einen Rescan überstehen; ein bloßes Setzen von `Game.systemID` reicht nicht, da der Scan die Zuordnung wieder ändern kann (`LibraryStore.swift:106`).

**Abnahme:** Ein falsch erkanntes Spiel lässt sich ohne Umbenennen der ROM richtig zuordnen. Eigener Titel und eigenes Cover bleiben nach Neustart, Rescan und Metadaten-Update erhalten. Die Sammlung bleibt auch ohne verfügbaren Metadaten-Dienst pflegbar.

### M4 — Import und Startvoraussetzungen verständlich prüfen

**Priorität P1 · Aufwand M · teilweise vorhanden.**

Nicht erkannte Dateien werden still übersprungen (`LibraryScanner.swift:61`). Es fehlen ein Importbericht mit Ursachen, manuelle Systemwahl und eine Prüfung referenzierter Disc-Dateien. BIOS wird beim Start systemweit geprüft, obwohl Anforderungen auch vom gewählten Core abhängen (`EmulationSession.swift:116`, `:122`). Beispielsweise sind alle PlayStation-BIOS-Dateien im Systemkatalog optional, obwohl die Projektdokumentation für alternative PS1-Cores reale BIOS-Dateien verlangt.

Die BIOS-Regeln müssen zwischen gemeinsam benötigten Dateien und Alternativen unterscheiden. Aktuell genügt bei mehreren Pflichtdateien jede einzelne (`BIOSManager.swift:37`); bei Intellivision sind `exec.bin` und `grom.bin` jedoch beide als erforderlich katalogisiert (`SystemCatalog.swift:262`).

Zusätzlich behandelt der Scanner `.7z` als möglichen Importtyp, während die eigene Vorbereitung nur ZIP extrahiert (`SystemCatalog.swift:298`, `EmulationSession.swift:226`). Der Start muss prüfen, ob der ausgewählte Core das konkrete Format direkt unterstützt; andernfalls verständlich ablehnen oder extrahieren.

**Abnahme:** Der Import nennt erkannte, nicht erkannte und unvollständige Spiele. Bei fehlenden BIOS-/Track-Dateien gibt es eine konkrete Reparaturaktion. „Erkannt“ und „startbereit“ sind unterscheidbar.

### M5 — Automatisch sichern und direkt fortsetzen

**Priorität P1 · Aufwand M · fehlt für Save States.**

Batteriesaves sichern die spielinterne Speicherung, aber nicht automatisch die aktuelle Spielsituation. Es gibt keinen automatischen State beim Beenden, keinen Fortsetzen-Dialog und keinen Einstieg in die States aus der Bibliothek (`EmulationSession.swift:238`, `GameInspector.swift:93`).

Benötigt werden ein eigener Autosave-Bereich, optional periodische States, „Fortsetzen“ im Inspector und die Wahl zwischen letztem Zustand und Neustart. Autosaves müssen von manuellen Slots getrennt sein. Nicht jeder Core unterstützt zuverlässige States; in diesem Fall muss die App passend zurückfallen.

**Abnahme:** Unterstütztes Spiel schließen, App neu öffnen und direkt fortsetzen. Manuelle Slots bleiben erhalten. Ein fehlgeschlagener Autosave ersetzt keinen funktionierenden älteren Autosave. Abhängigkeit: M2.

### M6 — Sicherung, Wiederherstellung und Save-Import anbieten

**Priorität P0 · Aufwand M–L · fehlt als Nutzerfunktion.**

Die vorhandene Datenbank-Sicherung ist ein Fehlerbehandlungspfad, kein vollständiges Backup. In den Einstellungen lassen sich Daten- und Save-Ordner nur im Finder öffnen (`SettingsView.swift:71`). Bibliothek, States, Batteriesaves, Core-eigene Speicherdateien und Einstellungen liegen an unterschiedlichen Orten beziehungsweise teilweise in `UserDefaults` (`AppPaths.swift:7`, `Preferences.swift:42`).

Benötigt werden versionierter Export/Import mit Vorschau, Wiederherstellung der Spielzuordnungen, Import vorhandener Batteriesaves und dokumentierte State-Kompatibilität. Passwörter gehören nicht ungeschützt in einen Export. Für Datenmodell-Erweiterungen sollte ein expliziter Schema-/Migrationspfad eingeführt werden; aktuell wird direkt `ModelContainer(for: Game.self, ...)` angelegt (`UrsprungApp.swift:43`).

**Abnahme:** Sicherung in eine leere Installation einspielen und Favoriten, Historie, Spielzuordnungen, Speicherstände und relevante Einstellungen wiederfinden. Unvollständige Sicherungen überschreiben vorhandene Daten nicht stillschweigend. Abhängigkeit: M1 und M2.

### M7 — Ordneränderungen erfassen und Spiele dauerhaft ausblenden

**Priorität P1 · Aufwand M · fehlt.**

Rescans erfolgen beim Öffnen der Bibliothek, nach Ordneränderungen und per Nutzeraktion (`LibraryView.swift:68`, `LibraryStore.swift:41`, `AppCommands.swift:20`). Es gibt keine laufende Dateisystemüberwachung. Die README-Aussage zur Synchronisation bei Dateiänderungen ist dadurch weiter gefasst als die aktuelle Implementierung.

„Remove from Library“ löscht lediglich den Datensatz und Medien (`LibraryStore.swift:149`). Liegt die ROM weiter im Bibliotheksordner, wird sie beim nächsten Scan neu aufgenommen. Benötigt werden persistentes Ausblenden/Importausschlüsse mit „wieder einblenden“, zusammengefasste Dateisystemereignisse und kontrollierte Folgescans.

**Abnahme:** Neue ROMs erscheinen während die App geöffnet ist. Ausgeblendete Spiele bleiben nach Rescan und Neustart ausgeblendet. Änderungen lösen keine ungebremste Serie vollständiger Scans aus. Abhängigkeit: M1.

### M8 — Eingabe vollständig konfigurierbar machen

**Priorität P1 · Aufwand M · teilweise vorhanden.**

Tastatur und generische HID-Pads sind konfigurierbar. GameController- und XInput-Pads verwenden in der App feste Zuordnungen; Spielerports ergeben sich automatisch aus Geräteart und Reihenfolge (`InputRouter.swift:104`, `:121`, `:174`, `ControlsSettingsView.swift:24`).

Benötigt werden frei wählbare Spielerports, Remapping für alle Gerätepfade, konfigurierbare Emulator-Hotkeys, ein Eingabetest sowie Profile pro System/Spiel. Deadzone und Achseneinstellungen sollten dort änderbar sein. Spielbezogene Einstellungen fehlen auch für Core-Optionen: die Core-Wahl ist pro Spiel möglich, Optionen werden jedoch ausschließlich pro Core gespeichert (`Preferences.swift:87`).

Zum grundlegenden macOS-Browsing gehört außerdem vollständige Raster-Navigation: implementiert sind links/rechts und Return; auf/ab fehlen (`GameGridView.swift:46`). Accessibility-Labels sind bereits vorhanden, eine praktische VoiceOver-Prüfung steht aus.

**Abnahme:** Zwei Pads bewusst Spieler 1 und 2 zuweisen; Belegung bleibt nach Wiederverbinden erhalten. Verschiedene Spiele können abweichende Belegungen/Optionen benutzen. Alle Rasterzeilen sind per Tastatur erreichbar. Eine allein mit Controller bedienbare Bibliothek bleibt zunächst optional.

### M9 — Metadaten-Abruf zuverlässig fortsetzen und Medien nachladen

**Priorität P1 · Aufwand M · teilweise vorhanden.**

Fortschritt, Abbruch und Fehlerzustände existieren. Die Warteschlange lebt im Speicher; Fehler-/Quota-Unterbrechungen besitzen keinen gespeicherten Wiederaufnahmeplan. Bei HTTP 429 wartet der Worker, stellt das fehlgeschlagene Spiel aber nicht erneut an (`MetadataService.swift:57`). Beim App-Start werden automatisch nur `.pending`-Spiele eingereiht (`LibraryStore.swift:137`).

Fehlgeschlagene einzelne Artwork-Downloads werden ignoriert, anschließend gilt das Spiel als `.matched` (`MetadataService.swift:113`). „Fetch Missing“ überspringt diesen Zustand (`MetadataService.swift:25`) und repariert die fehlenden Spielebilder deshalb nicht. Systemmedien haben bereits einen separaten Nachladepfad; Spielemedien benötigen ebenfalls einen.

**Abnahme:** Netzwerkunterbrechung und Quota-Ende lassen sich kontrolliert fortsetzen. Fehlende Cover werden nachgeladen, ohne sämtliche Texte erneut abzurufen. Account-Verifikation und verständlicher Status sollten im Produkt erreichbar sein; Entwickler-Zugangsdaten dürfen für Endnutzer keine Build-Aufgabe sein.

## Nice-to-haves, geordnet nach Nutzen

| Reihenfolge | Feature | Konkreter Nutzen und Umfang | Aufwand |
|---|---|---|---|
| 1 | Eigene Collections, Tags, Spielstatus und strukturierte Filter | Sammlungen wie „Couch-Coop“, „Als Nächstes“ und „Durchgespielt“; Filter nach Genre, Spielerzahl, Jahr, Metadatenstatus und Verfügbarkeit. Aktuell existieren nur All/Favorites/Recent/System und Textsuche. | M |
| 2 | Mehrfachauswahl und Stapelaktionen; Listenansicht | Große Sammlungen effizient bearbeiten, ausgewählte Spiele scrapen, taggen und ausblenden; Details tabellarisch vergleichen. Das aktuelle Raster hat eine einzelne Auswahl-ID. | M |
| 3 | Drag-and-drop für ROMs und Ordner; Finder-Öffnen | Nativer, schneller Import. Drag-and-drop ist aktuell für BIOS vorhanden, nicht für die Spielebibliothek. Dateiöffnen benötigt einen definierten Import-/Startablauf. | S–M |
| 4 | Varianten und Duplikate gruppieren | Regionen, Revisionen, Übersetzungen und Hacks unterscheiden; bevorzugte Variante wählen. Für sehr große Sammlungen steigt dies zu einem Must-have auf. Die bisherige Titelbereinigung entfernt viele Dateinamen-Zusätze, ohne sie als strukturierte Variantendaten zu speichern. | L |
| 5 | Controller-Navigation in Bibliothek und Pausemenü | Vom Sofa aus Spiele wählen, starten und States laden. Home öffnet bereits das Menü; Navigation und Auswahl über Pad-Eingaben sind noch nicht verdrahtet. | M |
| 6 | Bessere Multi-Disc-Verwaltung | Bestehendes M3U/Disc-Switching um Playlist-Erstellung, Disc-Beschriftung, Reihenfolge und Vollständigkeitsprüfung erweitern. Grundlegender Disc-Wechsel ist bereits vorhanden. | M |
| 7 | Benannte States und State-Verlauf | Speicherpunkte benennen; kürzlich überschriebene States zurückholen; Sammlung der States außerhalb des laufenden Spiels. | M |
| 8 | Rewind, Turbo und konfigurierbares Fast Forward | Komfort beim Spielen; Fast Forward existiert bereits, Geschwindigkeit und Hotkeys sind fest. Rewind braucht begrenzte State-Puffer und Core-Kompatibilitätsprüfung. | M–L |
| 9 | Screenshots, Mediengalerie und Anleitungen | Spielbilder exportieren, vorhandene Medien ansehen und eigene Manuals zuordnen. Interne Frame-Snapshots/State-Thumbnails existieren; ein Nutzerablauf zum Screenshot-Export fehlt. | S–M |
| 10 | ROM-Patches und Cheats | Übersetzungen/Hacks als abgeleitete Inhalte verwalten; Cheats pro Spiel. Der Scanner ignoriert Patchdateien; die Bridge bindet keine Cheat-Funktionen ein. Original-ROMs müssen erhalten bleiben. | M–L |
| 11 | Rumble und zusätzliche Eingabegeräte | Tatsächliches Controller-Feedback; gegebenenfalls Keypads und echte emulierte Tastatur. Rumble wird in der Bridge mit Erfolg quittiert, löst aber keine Hardwareaktion aus (`URLibretroCore.m:637`). | M–L |
| 12 | RetroAchievements | Zusätzliche Motivation; Konto, Erkennung und Statusanzeige. Die bloße Annahme von `SET_SUPPORT_ACHIEVEMENTS` ist noch keine Integration. | L |
| 13 | Core-Versionen, Updateprüfung und Rollback | Bekannten funktionierenden Core erhalten und nach einem problematischen Update wiederherstellen. Manuelles Aktualisieren ist bereits vorhanden; Versionsverwaltung und Rollback fehlen. | M–L |
| 14 | CRT-Presets, Bezels und Latenzoptionen | Mehr Darstellungsfreiheit; vier Filter und Integer Scaling existieren bereits. Run-ahead erfordert gesonderte Prüfung von State-Verhalten und Leistung. | M–L |
| 15 | Cloud-Sync und mehrere Nutzerprofile | Fortschritt auf weiteren Macs bzw. getrennte Speicherstände pro Person. Setzt stabile Identitäten, kompatible State-Verwaltung und Konfliktbehandlung voraus. | L |
| 16 | Netplay und Link-Kabel | Gemeinsam über Netzwerk oder verbundene Handheld-Sessions spielen. Hoher Aufwand; Link-Kabel ist nicht durch zusätzliche lokale Spielerports erledigt. | L |
| 17 | Weitere Computer/Konsolen und externe Emulatoren | Neue Zielgruppen; erst nach zuverlässiger bestehender Systemunterstützung. Vulkan/andere Renderingpfade sind Architekturarbeit, keine einfache Katalogerweiterung. | L |

## Konkrete Funktionsprobleme vor neuen Komfortfeatures

1. **Entfernen ist nicht dauerhaft:** `remove` speichert keinen Ausschluss; `apply` importiert die weiterhin vorhandene Datei wieder. Dabei entsteht auch eine neue Save-Zuordnung. Lösung: Ausblenden/Importausschluss plus Neuverknüpfung, nicht nur Datensatz löschen.
2. **Save States sind nicht nach Core getrennt:** Die Pfade verwenden nur Spiel-UUID und Slot. Ein Save mit Core B kann den Slot von Core A ersetzen. Lösung: Core-getrennte Ablage und Manifest.
3. **BIOS-Pflichtdateien werden pauschal als Alternativen behandelt:** Sobald bei mehreren erforderlichen Dateien eine vorhanden ist, liefert `missingRequired` keine fehlenden Dateien. Intellivision ist ein konkreter Gegenfall. Lösung: explizite Anforderungsgruppen und Regeln je Core.
4. **Fehlende Spielebilder werden trotz „Fetch Missing“ nicht nachgeladen:** Der Zustand `.matched` beschreibt den Metadatentreffer, nicht die Vollständigkeit der Medien. Lösung: separate Medienzustände und gezieltes Nachladen.
5. **Computer-Tastatur ist unvollständig:** MSX ist katalogisiert, doch Tastatureingaben werden nur zu RetroPad-Eingaben übersetzt. Die Bridge nimmt `SET_KEYBOARD_CALLBACK` an, speichert/bedient ihn jedoch nicht und beantwortet `RETRO_DEVICE_KEYBOARD` nicht (`URLibretroCore.m:828`, `:1098`). Das begrenzt Tastatur-/Textfunktionen betroffener Spiele; es beweist nicht, dass sämtliche MSX-Spiele unspielbar sind. Für vollwertig beworbene Computerunterstützung muss dies umgesetzt oder die Einschränkung klar gezeigt werden.

Diese Punkte ergeben sich aus dem aktuellen Daten- und Kontrollfluss. Es handelt sich nicht um behauptete praktische Reproduktion mit echten Cores oder Controllern.

## Empfohlene Roadmap

| Etappe | Ziel | Inhalt | Fertig, wenn … |
|---|---|---|---|
| A | Bestehende Sammlung und Fortschritt schützen | M1, M2; BIOS-Regeln aus M4; Datenmodell-/Migrationsgrundlage für M6 | Verschieben, Core-Wechsel und unvollständige Scans die Datenzuordnung erhalten; Fehler verständlich gemeldet werden. |
| B | Alltagsablauf vervollständigen | M3, restliches M4, M5, M6, M7, M9; Tastaturnavigation aus M8 | Nutzer falsch erkannte Spiele reparieren, fortsetzen, ausblenden und eine vollständige Sicherung wiederherstellen können. |
| C | Sammlung und Multiplayer komfortabler machen | Restliches M8; Collections/Filter, Stapelaktionen, Varianten und Controller-Navigation | Größere Sammlungen und mehrere Pads ohne wiederholte manuelle Einrichtung nutzbar sind. |
| D | Zusätzliche Spiel- und Online-Funktionen | Rewind, Cheats/Patches, Achievements, Grafikpresets; später Sync/Netplay und neue Plattformen | Kernabläufe stabil sind und die Erweiterung zur gewünschten Zielgruppe passt. |

Keinen vollständigen Export-/Cloud-Sync und keine Variantenautomatik vor stabiler Spielidentität bauen. Autosave/Resume zuerst mit Core- und State-Kompatibilität verbinden. Andernfalls vergrößern die neuen Funktionen die heutigen Zuordnungsprobleme.

## Veröffentlichung und Qualität

Für eine Veröffentlichung an Nutzer ohne Xcode fehlt im Repository ein fertig definierter Distributionsablauf: das Projekt verwendet Ad-hoc-Signing (`project.yml:26`), `make release` baut lokal, und die CI baut/testet, enthält aber keine Paketierung oder Notarisierung. Ein signierter, notarisierter Download mit einem nachvollziehbaren Updateweg ist für diese Zielgruppe erforderlich. Automatische App-Updates sind eine optionale Komfortfunktion; manuelle Core-Updates existieren bereits.

Die bestehenden Unit-Tests sind eine brauchbare Grundlage. Die sichtbarsten Lücken in der Verifikation sind Start/Stop/Spielwechsel mit einem Test-Core, State-Kompatibilität und Schreibfehler, Save-/RTC-Verhalten, Firmware-Anforderungsgruppen, unvollständige Scans sowie die praktischen Controller-/Fensterabläufe. Der Smoke-Harness ist vorhanden, aber kein automatisierter Nachweis für die gesamte Unterstützungsmatrix. Keine zusätzlichen reinen UI-Abbildtests nötig; entscheidend sind Datenverlust-, Zuordnungs- und Lebenszyklusfälle.

macOS 26+ und ausschließlich arm64 sind derzeit explizite Produktgrenzen. Ältere macOS-Versionen oder Intel-Unterstützung sind Zielgruppenentscheidungen, kein automatisch fehlendes Must-have.

## Externe Einordnung

Die Priorisierung ist eine Produkteinschätzung aus dem lokalen Code. Zwei vorhandene Frontend-Konzepte stützen sie: [OpenEmus offizielle Save-State-Dokumentation](https://github.com/OpenEmu/OpenEmu/wiki/User-guide:-Save-states) beschreibt automatische Fortsetzung und weist auf Core-/Update-Kompatibilität hin. [Libretros Dokumentation zu Overrides](https://docs.libretro.com/guides/overrides/) beschreibt Einstellungen und Eingabebelegungen je Core, Inhaltsordner und Spiel. Daraus folgt keine Pflicht, sämtliche RetroArch-Funktionen nachzubauen.

Die gemeinsam benötigten Intellivision-BIOS-Dateien sind außerdem im [offiziellen FreeIntv-User-Guide](https://github.com/libretro/FreeIntv/blob/master/USER_GUIDE.md) dokumentiert.
