// SPDX-License-Identifier: GPL-3.0-or-later

# Re-Review – Ursprung: Fixes zu c36178a

**Datum:** 07.10.2026  
**Geprüfter Bereich:** `c36178a..2b278e1`  
**Geprüfter Endstand:** `2b278e19756f3a0c4d5800383feb9f2f5f1e3de2`  
**Umfang:** erneute Prüfung der ursprünglichen Befunde, ihrer Fixes und Regressionstests. Der angegebene Bereich enthält lokal neun Commits, nicht zwölf. Spätere Änderungen auf `main` sind nicht Gegenstand dieses Berichts.

**Die Fixserie ist noch nicht vollständig abgeschlossen.** Die wichtigsten Restfehler betreffen den Import-Schutz und weiterhin mögliche Shader-Überschreibungen. Hinzu kommen eine Regression bei alten Drafts und mehrere unvollständig behandelte Fehlerpfade.

Der gezielte Xcode-Testlauf ergab **45 bestanden, zwei übersprungen**. Übersprungen wurden die beiden Tests mit externem Shader-Pack. Zusätzlich wurden Dateisystemfälle mit dem Originalcode in `/tmp` reproduziert. Der Altcode-Abgleich der Regressionstests erfolgte anhand der Implementierungen; ein vollständiger Mutationstestlauf aller Fixes wurde nicht durchgeführt.

**An Anwendungscode, Repository-Tests und Konfiguration wurde für den Review nichts geändert.** Dieser Bericht wurde anschließend auf Wunsch als Markdown-Datei ergänzt. Die Quellverweise zeigen auf den geprüften Commit, damit spätere Änderungen ihre Bedeutung nicht verschieben.

## Bugs

### B1 · P1 · R1: Die Endungsprüfung verhindert weiterhin keinen Zugriff außerhalb des Pakets

**Datei:** [ShaderImport.swift:74](https://github.com/bhuaysan/ursprung/blob/2b278e1/Ursprung/Emulation/ShaderImport.swift#L74)

**Fehlerszenario:** Ein Preset verweist mit `../Private/photo.png` auf eine externe Datei → sie wird ohne Warnung importiert. Noch deutlicher: Eine Texturreferenz auf einen **Ordner** `../Private/folder.png` → `copyItem` kopiert diesen rekursiv, einschließlich `notes.txt`. Beide Fälle sind reproduziert.

Auch der unveränderte Ordnerimport erhält absolute Symlinks: Ein importiertes `linked.slang` konnte danach weiterhin eine externe `notes.txt` lesen. Das Kopieren eines Links kopiert dabei nicht automatisch dessen Zielinhalt; es erhält aber den Zugriff auf das externe Ziel.

Die Allowlist ist deshalb kein ausreichender Schutz für R1. Erforderlich sind eine definierte Paketgrenze, Prüfung der aufgelösten Ziele und regulärer Dateien — bereits vor dem Traversieren beziehungsweise Lesen der Abhängigkeiten.

**Sicherheit:** sehr hoch, reproduziert. **Einordnung:** Restfehler.

### B2 · P1 · #3: Die Kollisionsprüfung übersieht unveränderte Dateien und Dateisystem-Aliase

**Datei:** [ShaderDrafts.swift:204](https://github.com/bhuaysan/ursprung/blob/2b278e1/Ursprung/Emulation/ShaderDrafts.swift#L204), [ShaderDrafts.swift:237](https://github.com/bhuaysan/ursprung/blob/2b278e1/Ursprung/Emulation/ShaderDrafts.swift#L237)

Zwei reproduzierte Fehlerwege:

- Bearbeitete Kopie von `library/crt/a.slang` plus unveränderter Pass auf `User/Mixed/crt/a.slang`; speichern als `Mixed.slangp` → die Bibliothekskopie überschreibt den User-Shader. Anschließend verwenden beide Passes dieselbe Datei. Die unveränderte Datei fehlt in `destinations` und damit in der Kollisionsprüfung.
- Eigene Dateien `library/case/a.slang` und `user/case/A.slang` → die Stringprüfung hält ihre Ziele für verschieden. Auf dem verwendeten, nicht zwischen Groß-/Kleinschreibung unterscheidenden Dateisystem überschreibt trotzdem eine die andere.

Der vorhandene Regressionstest deckt ausschließlich die exakte Namenskollision zwischen zwei eigenen Kopien ab.

**Sicherheit:** sehr hoch, beide Fälle reproduziert. **Einordnung:** Restfehler.

### B3 · P2 · #7: Alte Drafts können Änderungen in eine andere Datei schreiben als diejenige, die der Pass verwendet

**Dateien:** [ShaderDrafts.swift:139](https://github.com/bhuaysan/ursprung/blob/2b278e1/Ursprung/Emulation/ShaderDrafts.swift#L139), [ShaderEditor.swift:614](https://github.com/bhuaysan/ursprung/blob/2b278e1/Ursprung/Emulation/ShaderEditor.swift#L614)

**Fehlerszenario:** Ein alter Draft enthält bereits `other/<hash>/a.slang`. Ein weiterer Pass wird aus derselben externen Originaldatei übernommen → `ownCopy` erzeugt zusätzlich die neue Kopie unter dem absoluten Pfad. Der Pass erhält diese neue Kopie; `ownURL` findet über `first` dagegen den alten Herkunftseintrag.

**Ergebnis:** Tippen verändert die alte Kopie, während der ausgewählte Pass die neue kompiliert. Änderungen können im falschen Pass erscheinen oder beim Speichern fehlen.

Die doppelte Herkunftszuordnung und die unterschiedlichen Zielpfade sind reproduziert. Das ist kein akzeptabler reiner Layoutkompromiss; hier braucht es Migration oder eine eindeutige Zuordnung.

**Sicherheit:** sehr hoch. **Einordnung:** neue Regression durch die Pfadumstellung.

### B4 · P2 · #7: Includes über die Grenze zwischen user/, library/ und other/ bleiben defekt

**Datei:** [ShaderDrafts.swift:156](https://github.com/bhuaysan/ursprung/blob/2b278e1/Ursprung/Emulation/ShaderDrafts.swift#L156)

**Fehlerszenario:** `User/cross.slang` enthält `#include "../shared.h"`, wobei `shared.h` außerhalb von `User` liegt → beide Dateien werden kopiert, aber in verschiedene Namensräume verschoben. Der unveränderte Include-Pfad erreicht die Kopie nicht.

Reproduziert: Die ursprüngliche Include-Closure enthält zwei Dateien, diejenige der Draftkopie nur eine.

Für ausschließlich externe Dateien funktioniert der Fix. Als allgemeine Lösung für externe Includes ist er unvollständig. Ein begrenzter unterstützter Umfang wäre vertretbar, wenn solche Fälle erkannt und verständlich abgewiesen würden.

**Sicherheit:** sehr hoch, reproduziert. **Einordnung:** bekannter Restfehler.

### B5 · P2 · #2: History-, Legacy- und Autosave-Löschungen verschlucken weiterhin Fehler

**Datei:** [SaveStates.swift:166](https://github.com/bhuaysan/ursprung/blob/2b278e1/Ursprung/Emulation/SaveStates.swift#L166)

**Fehlerszenario:** Einen History-Spielstand in einem nicht beschreibbaren Verzeichnis löschen → `discard` ruft weiterhin das nicht werfende `delete` mit `try?` auf. Die Datei bleibt bestehen, aber der Aufrufer erhält keinen Fehler; die neue Fehlermeldung erscheint nicht.

Genau dieser Fall wurde reproduziert. Der gefährliche Fallback „Archivierung fehlgeschlagen → endgültig löschen“ ist beseitigt, die Fehlerweitergabe aber nur für normale Slots repariert.

**Sicherheit:** sehr hoch, reproduziert. **Einordnung:** Restfehler.

### B6 · P2 · R3: Nach einem Restore-Fehler läuft das Spiel vorwärts, während UI und Shader weiterhin Rewind verwenden

**Datei:** [UREmulationRunner.m:318](https://github.com/bhuaysan/ursprung/blob/2b278e1/Ursprung/Bridge/UREmulationRunner.m#L318)

**Fehlerszenario:** Rewind-Taste halten, dann schlägt `unserialize` fehl → der Buffer wird freigegeben. Im nächsten Schleifendurchlauf läuft wegen `_rewind == NULL` wieder `runVisibleFrame`.

`runner.isRewinding` und `session.isRewinding` bleiben jedoch bis zum Loslassen gesetzt. Die Anzeige zeigt weiterhin „Rewind“, und der Renderer übergibt weiterhin `direction: -1`, obwohl das Spiel vorwärtsläuft.

Der neue Test ruft `stepBack` direkt auf und prüft weder den folgenden Schleifendurchlauf noch den Session-/Renderer-Status.

**Sicherheit:** hoch, aus dem vollständigen Kontrollfluss. **Einordnung:** Inkonsistenz im neuen Fehlerpfad.

### B7 · P2 · Compile-Ergebnisse werden bei geändertem Core-/Rotationskontext weiterhin akzeptiert

**Datei:** [MetalRenderer.swift:73](https://github.com/bhuaysan/ursprung/blob/2b278e1/Ursprung/Emulation/MetalRenderer.swift#L73), [MetalRenderer.swift:385](https://github.com/bhuaysan/ursprung/blob/2b278e1/Ursprung/Emulation/MetalRenderer.swift#L385)

**Fehlerszenario:** Eine Kompilierung beginnt mit Core A beziehungsweise Rotation 0. Währenddessen wechselt die Quelle oder deren Rotation; das Preset bleibt gleich → `compileGeneration` bleibt unverändert. Das Ergebnis für den alten Kontext wird übernommen.

Bei Presets mit `$CORE$` oder `$CORE-REQ-ROT$` kann damit die falsche Variante aktiv bleiben. Der neue `sourceChanged`-Mechanismus aktualisiert ausschließlich das Bild, nicht den Compile-Kontext.

**Sicherheit:** hoch. **Einordnung:** bereits bestehender Randfall, durch I1 nicht geschlossen; kein zusätzlicher Daten-Race der Warteschlange.

### B8 · P2 · #9: Mehrere Backup-Einträge für dasselbe Zielspiel haben keine deterministische Einstellungspriorität

**Dateien:** [Preferences.swift:241](https://github.com/bhuaysan/ursprung/blob/2b278e1/Ursprung/Support/Preferences.swift#L241), [Backup.swift:301](https://github.com/bhuaysan/ursprung/blob/2b278e1/Ursprung/Support/Backup.swift#L301)

**Fehlerszenario:** Zwei Backup-Spiel-IDs werden vom Plan demselben vorhandenen Spiel zugeordnet und enthalten unterschiedliche Shader-Einstellungen → beide schreiben denselben Preference-Key. Es gewinnt die nicht festgelegte Dictionary-Reihenfolge.

Der Plan erlaubt diesen Fall ausdrücklich. Die neue UUID-Abbildung benötigt daher zusätzlich eine definierte Konfliktregel. Der Test prüft nur eine einzelne Zuordnung.

**Sicherheit:** hoch, aus Plan und Restore-Code. **Einordnung:** neuer Randfall der Zusammenführung.

## Risiken und Bewertung der Kompromisse

- **I1 / #6: Die zentrale Zustandsmaschine wirkt korrekt.** `isCompiling` wird vor dem Taskstart gesetzt; weitere Anforderungen ersetzen nur `pendingPreset`. Veraltete Ergebnisse werden verworfen und starten höchstens den neuesten Nachfolger. A → B → A und Wechsel auf Built-in invalidieren korrekt. Durch `[weak self, queue]` hält der laufende Task den Renderer nicht über die Kompilierung hinweg fest. Für diese Pfade wurde kein weiterer Race- oder Lebensdauerfehler gefunden. Die Wartezeit auf zwei Kompilierungen ist ein vertretbarer Kompromiss. **Sicherheit: hoch.**
- **R3: Der einmalige Run-Ahead-Vorsprung ist vertretbar, aber nicht garantiert exakt N Frames.** Der Fake-Core schlägt ohne Zustandsänderung fehl. Ein echter Core könnte vor `false` bereits Teile seines Zustands verändert haben. Die Abschaltung verhindert weitere Beschleunigung, garantiert aber keinen unbeschädigten Zustand nach dem ersten Fehler. **Sicherheit: hoch hinsichtlich der fehlenden Garantie; kein konkreter betroffener Core nachgewiesen.**
- **#9: Verwerfen nicht zuordenbarer Backup-Keys ist sinnvoll.** Gemeint sind die eingehenden Keys, nicht eine pauschale Löschung bestehender Einstellungen. Dass zugeordnete Spiele ihre Backup-Einstellung erhalten, passt zu „Also restore settings“. Weitere UUID-basierte Per-Spiel-Preference-Keys wurden nicht gefunden. Offen bleibt der unter B8 beschriebene Mehrfachkonflikt.
- **I2: Die echte Fensterbedienung bleibt unbestätigt.** Tastaturhandler und AX-Aktionen sind vorhanden. Der Test beweist weder Fokusübernahme aus dem Code-Editor noch Tab-Erreichbarkeit, VoiceOver-Auffindbarkeit oder die tatsächliche Ausführung der Aktionen. Ein konkreter Fokusfehler wurde nicht nachgewiesen; dieser Punkt ist entsprechend nicht vollständig verifiziert.

## Regressionstests

Die folgende Altcode-Bewertung stammt aus dem Vergleich der Implementierungen; ein vollständiger Mutationstestlauf aller Fixes wurde nicht durchgeführt. Neue Testzugänge beziehungsweise Signaturen müssten beim Rückport der Tests erhalten oder angepasst werden.

| Punkt / Test | Erkennt den ursprünglichen Fehler? | Grenze |
| --- | --- | --- |
| #1 `aReplacedShaderLeavesTheOldFileAlone` | Ja: prüft Tabwechsel, verweigerte Änderung und unverändertes Original. | Gute Verhaltensprüfung. |
| #2 `aStateThatCantBeArchivedIsKept` | Ja: alter Code löscht den Slot und wirft nicht. | Keine Prüfung der anderen Löscharten. |
| #3 `savesFilesOfTheSameNameFromThePackAndTheUserApart` | Ja: alter Code verliert einen Inhalt. | Unveränderte Referenzen und Dateisystem-Aliase fehlen. |
| #4 Draft-Speichern im Player | **Kein eigener Test im Fix-Commit.** | Guards sind im Code vorhanden, aber nicht regressionsgesichert. |
| #5 `hugePassNumbersWithoutAShaderCountDontCrash` | Ja: alter Code läuft bei `Int.max + 1` über. | Deckt den ursprünglichen Crash direkt ab. |
| #6 `returningToTheShowingPresetDropsAnotherCompile` | Ja: alter Code stellt bereits den Status nicht korrekt zurück. | Die abschließende Zwei-Sekunden-Wartezeit beweist nicht, dass B wirklich fertig geworden ist. |
| #7 `keepsIncludesBetweenFoldersOfShadersFromElsewhere` | Ja: die alte Ordner-Hash-Struktur trennt Shader und Include. | Keine alten Drafts oder Übergänge zwischen Namensräumen. |
| #8 beide neuen StillFrame-Tests | Ja: prüfen erhaltene Serial und tatsächlich hochgeladenen Pixel. | Gute Verhaltensprüfungen; Gleichheit der beiden Quell-Serials sollte explizit abgesichert werden. |
| #9 `restoredSettingsFollowTheGamesToTheirNewIDs` | Ja: alter Code schreibt unter die alte UUID. | Keine konkurrierenden Backup-IDs oder vorhandenen Zielwerte. |
| R1 `importLeavesFilesBehindThatArentShadersOrImages` | Ja: alter Code kopiert `id_rsa` und `notes.txt`. | Beweist die Endungsfilterung, nicht die Paketgrenze. |
| R3 `runAheadStopsWhenTheCoreCantGoBack` | Ja: alter Code erreicht nach zehn Aufrufen 30 statt 12 Frames. | Nur unverändernder Fehler des Fake-Cores. |
| R3 `rewindStopsWhenTheCoreCantGoBack` | Ja: alter Code führt trotz Fehler einen weiteren Frame aus. | Folgezustand der laufenden Session fehlt. |
| R3 `runAheadGoesBackToTheRealFrame` | Besteht auch vorher. | Sinnvoller Kontrolltest für den Erfolgsfall. |
| I1 `reloadsWhileCompilingWaitForItAndRunOnce` | Erkennt die frühere Vielzahl von Compile-Starts. | Alle Requests sehen denselben bereits geschriebenen Stand; „neueste Änderung gewinnt“ wird nicht mit verschiedenen Zwischenständen geprüft. |
| I2 `arrowKeysMoveTheZoomedPictureWithinItsEdges` | Prüft nur die neue `pan`-Hilfsfunktion. | Könnte trotz vollständig entfernter Keyboard-/AX-Anbindung bestehen. |

## Verbesserungen und Projektregeln

- Für #6/I1 einen kontrollierbaren Compiler-Testzugang verwenden: Start und Abschluss gezielt freigeben, unterschiedliche Zwischenstände anbieten und nachweislich das veraltete Ergebnis eintreffen lassen. Damit entfallen Zeitfenster als vermeintlicher Abschlussnachweis.
- Die R3-Testinfrastruktur ist **im aktuellen Testbestand ausreichend isoliert**: Nur diese Suite lädt einen Libretro-Core; ihre Tests sind serialisiert und laufen synchron. `.serialized` schützt allerdings keine zukünftige zweite Core-Suite. Außerdem fehlt für das zusätzliche `dlopen` ein passendes `dlclose`. Den Testing-Header auf den Test-/Debug-Build zu begrenzen wäre sinnvoll.
- Die Projektregeln sind für die neuen Dateien und Änderungen eingehalten: SPDX-Header vorhanden, keine neue Third-Party-Abhängigkeit, neue UI-/AX-Texte einschließlich deutscher Übersetzungen vorhanden. Die direkten Runner-Aufrufe außerhalb des Emulationsthreads bleiben auf die ausdrücklich vorgesehene Testinfrastruktur beschränkt.

## Abschlussstatus der ursprünglichen Punkte

| Punkt | Fix-Commit | Bewertung |
| --- | --- | --- |
| #1 | `df1f0ae` | **Vollständig behoben** für das Überschreiben des Originals durch einen veralteten Tab. |
| #2 | `c1f3aa6` | **Teilweise**: gefährlicher Archivierungs-Fallback behoben; andere Löschfehler weiterhin verschluckt. |
| #3 | `df1f0ae` | **Teilweise**: exakte Kollision zweier eigener Kopien behoben; weitere Überschreibpfade bestätigt. |
| #4 | `df1f0ae` | **Behoben**, einschließlich Guard beim tatsächlichen Speichern; Regressionstest fehlt. |
| #5 | `c1f3aa6` | **Vollständig behoben.** |
| #6 | `c1f3aa6` | **Vollständig behoben** für A → B → A. |
| #7 | `078090f` | **Teilweise**, zusätzlich Regression bei alten Drafts. |
| #8 | `1db9fc4` | **Vollständig behoben** für Pause-Serial und Bildwechsel bei gleicher Serial. |
| #9 | `0e34834` | **UUID-Remapping behoben**, Mehrfachzuordnung noch inkonsistent. |
| R1 | `5c506ee` | **Nicht ausreichend behoben.** |
| R3 | `01f3c8e` | **Restore-Fehler abgefangen**, anschließender Rewind-Status noch inkonsistent. |
| I1 | `cb6cb1a` | **Parallelitätsproblem pro Renderer behoben.** |
| I2 | `2b278e1` | **Implementiert, echte Tastatur-/VoiceOver-Bedienung nicht ausreichend verifiziert.** |
| R2 | bewusst unverändert | Wie vereinbart unverändert und weiterhin offen. |

## Behebung (09.10.2026)

| ID | Status | Umsetzung | Test |
|---|---|---|---|
| B1 | behoben | Feste Paketgrenze für einzelne Presets: der tiefste Ordner, der das Preset, seine `#reference`-Presets und deren Shader-Passes enthält (`ShaderImport.package(of:)`). Ist das der Benutzerordner, ein Ordner darüber oder ein ganzes Volume, wird der Import mit Hinweis abgelehnt. Die Grenze steht fest, bevor Includes und Texturen gelesen werden: Dateien außerhalb werden weder gelesen noch verfolgt (`SlangPresetFile.dependencies(of:within:)`); zum Bestimmen der Grenze werden nur `.slangp`-Dateien gelesen. Links werden vor der Prüfung aufgelöst, kopiert werden nur reguläre Dateien (der Inhalt, nicht der Link), also auch kein Ordner `folder.png`. Ordnerimporte kopieren Datei für Datei: Links auf reguläre Dateien im Ordner werden zu Kopien, Links aus dem Ordner hinaus bleiben zurück und werden gemeldet. | `importStaysInsideThePresetsPackage` (Foto, Ordner `folder.png`, Link aus dem Paket, Include außerhalb), `aPackageMayNotBeTheHomeFolderOrAVolume`, `importedFoldersKeepNoLinksOutOfThem`, angepasst `importLeavesFilesBehindThatArentShadersOrImages` |
| B2 | behoben | Alle Dateien, die das gespeicherte Preset liest und die keine eigenen Kopien des Drafts sind (unveränderte Passes samt Includes, Texturen), gelten als belegt; eine eigene Kopie darf dort nicht landen und weicht ins Layout mit erstem Ordner (`library/…`) aus, sonst bricht das Speichern ab. Pfade werden wie auf APFS verglichen: ohne Groß-/Kleinschreibung und Unicode-Form. Rückschreiben an den Ursprung beim Speichern an Ort und Stelle bleibt erlaubt. | `savingKeepsOffFilesOtherPassesUse`, `savingTellsApartNamesThatDifferInCaseOnly` (beide scheitern mit dem alten Code) |


Validierung B1/B2: `xcodebuild … test` mit 447 Tests grün, 2 übersprungen (Shader-Pack).

| ID | Status | Umsetzung | Test |
|---|---|---|---|
| B3 | behoben | `ShaderDrafts.ownCopies` liefert für jede Datei, die der Shader liest, die Kopie, die die kopierte Fassung liest. Der Editor findet die Kopie eines Tabs darüber statt über den ersten Herkunftseintrag; mehrere Kopien derselben Datei (Drafts aus der Zeit vor dem Pfad-Layout) bleiben getrennt, jede gehört zu ihrem Pass. | `copiesTellWhichCopyAPassReads` (Draft mit `other/<hash>/a.slang`) |
| B4 | behoben | Die Dateien einer Include-Gruppe kommen gemeinsam in ein Layout: unter `library/` bzw. `user/`, wenn alle im Pack bzw. im Benutzerordner liegen, sonst alle unter `other/` mit ganzem Pfad. Relative Includes über die Grenze bleiben so gültig. | `keepsIncludesFromTheUsersFolderToElsewhere` |
| B5 | behoben | `SaveStateStore.delete` wirft: Lässt sich die State-Datei nicht löschen, bleibt alles und der Fehler erreicht den Aufrufer; Vorschaubild und Manifest werfen danach. `discard` gibt das für History-, Legacy- und Autosave-States weiter. Nach einem Restore und beim Kürzen der History bleibt ein nicht löschbarer Eintrag bewusst still stehen. | `aStateThatCantBeDeletedReportsIt` (schreibgeschützte Ordner) |
| B6 | behoben | Scheitert der Restore beim Zurückspulen, setzt der Runner `rewinding` selbst zurück und meldet es über `rewindStoppedHandler` (Hauptthread); die Session setzt `isRewinding` zurück, zeigt den Hinweis, dass der Core nicht zurückspulen kann, und der Renderer bekommt wieder `direction: 1`. | `rewindStopsWhenTheCoreCantGoBack` (erweitert), `aFailedRewindTellsTheSession` |
| B7 | behoben | Der Renderer merkt sich den Kontext (Core-Name, Rotation) jedes Kompilats. Ein Ergebnis für einen inzwischen anderen Kontext wird verworfen und neu kompiliert; ändert sich der Kontext, während ein Preset angezeigt wird, kompiliert `draw` es neu. Hinweis: Die eingebundene librashader-Version hat `$CORE$`/`$CORE-REQ-ROT$` im Test weder in `#reference`- noch in Shader-Pfaden ersetzt; das ist getrennt zu prüfen. | `presetsFollowTheCoreAndRotationTheyAreCompiledFor` (zählt Kompilierungen; scheitert mit dem alten Code) |
| B8 | behoben | Feste Regel, wenn mehrere Backup-Spiele in einem Spiel aufgehen: Die Einstellung des eigenen Eintrags (gleiche ID) gewinnt, dann der erste in Backup-Reihenfolge (`Backup.settingsPrecedence`), ohne Rang nach ID, nie nach Dictionary-Reihenfolge. | `restoredSettingsOfJoinedGamesHaveAFixedPrecedence` |

Validierung B3–B8: `xcodebuild … test` mit 453 Tests grün, 2 übersprungen (Shader-Pack); die neuen Tests zu B2 und B7 scheitern mit dem alten Code.
