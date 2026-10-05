# Re-Review – Ursprung

**Datum:** 03.10.2026  
**Geprüfter Stand:** `dd0c6c65cb874e0e22e8ccca5c045628c3986e15` (`main`)  
**Änderung:** `Fix data loss and integrity issues from the 2026-10-02 review`  
**Vergleichsbasis:** `b5a9e1d7ca9d2ed5e515550189637f580dab3093`  
**Vorheriger Bericht:** [Code-Review vom 02.10.2026](<CODE_REVIEW_2026-10-02.md>)

## Ergebnis

**Vier belegte Restbefunde: 1 × P1 und 3 × P2.** Die Korrekturen beheben die konkreten ursprünglichen Reproduktionen. Drei verwandte Randfälle bleiben jedoch offen; die Änderung am Audiopuffer führt zusätzlich zu einer neuen Blockade der Wiedergabe.

Die vorhandene Testsuite besteht mit **128 Tests / 154 Testfällen einschließlich Parametrisierungen**, ohne Fehler oder übersprungene Tests. Der **Release-Build besteht ebenfalls**. Alle zehn früheren Swift-Reproduktionen bestehen jetzt; die früheren nativen Reproduktionen für Optionszeiger und Audio-Reset zeigen den alten Fehler ebenfalls nicht mehr.

**Am Anwendungscode, an Repository-Tests, Konfiguration und Scripts wurde nichts geändert.** Im ursprünglichen Projekt wurde ausschließlich dieser neue Bericht angelegt. Zusätzliche Tests und Build-Anpassungen liegen in einer temporären Projektkopie.

| ID | Priorität | Noch offenes Problem | Bezug zum vorherigen Review |
| --- | --- | --- | --- |
| R1 | P1 | Unlesbare ZIP-Datei löscht weiterhin Bibliothekseintrag und Medien | Randfall zu Nr. 2 |
| R2 | P2 | Neuer Audio-Clear kann nach Schnellvorlauf dauerhaftes Schweigen verursachen | Regression durch Korrektur von Nr. 5 |
| R3 | P2 | Bestehende Spiele ohne Änderungsdatum behalten eine veraltete CRC32 | Unvollständige Korrektur von Nr. 7 |
| R4 | P2 | CUE-Unterordnerreferenzen blenden weiterhin die falsche Datei aus | Verwandter Restfall zu Nr. 11 |

**Prioritäten:** P1 bezeichnet hier reproduzierbaren Datenverlust; P2 einen konkreten Funktions- oder Integritätsfehler. Zuerst sollten R1 und anschließend die Audio-Regression R2 behoben werden.

## Status der zwölf ursprünglichen Befunde

„Behoben“ bezieht sich auf den geprüften Fehlermechanismus und die genannten Tests. Bei Restfällen unterscheidet die Tabelle ausdrücklich zwischen der erfolgreichen ursprünglichen Reproduktion und dem weiterhin offenen Bereich.

| Nr. | Ursprünglicher Befund | Ergebnis der Nachprüfung |
| --- | --- | --- |
| 1 | Überlappende Bibliotheksordner überschreiben Spieldaten | **Behoben.** Scanner und Store deduplizieren Pfade. UUID, Favorit und Spielzeit bleiben im ursprünglichen Test erhalten. |
| 2 | Unlesbare Unterordner werden als gelöscht behandelt | **Unterordnerfall behoben; Bereich noch offen.** Enumerationsfehler schützen Datensätze. Inhaltslesefehler beim Erkennen einer ZIP-Datei werden weiterhin verschluckt: R1. |
| 3 | BIOS-Selbstimport löscht die installierte Datei | **Behoben.** Dateiidentität wird geprüft; Ersatz erfolgt nach erfolgreicher temporärer Kopie. Selbstimport, erfolgreicher Ersatz und unlesbare Ersatzquelle sind durch bestandene Tests abgedeckt. |
| 4 | Geänderte Core-Option gibt einen noch benutzten C-Zeiger frei | **Behoben.** Optionsstrings bleiben über `_optionCStrings` für die Lebensdauer des Core-Objekts erhalten. Der frühere AddressSanitizer-Test liest den alten Wert ohne Speicherfehler. |
| 5 | Audio-Clear konkurriert mit einem laufenden Leser | **Ursprünglicher Konflikt behoben; neue Regression.** Nur der Leser bewegt jetzt `readIndex`. Die Anbindung an das Vorpuffern der Audioausgabe berücksichtigt den verzögerten Clear jedoch nicht: R2. |
| 6 | Metadatenaufträge bleiben nach Stop und erneutem Enqueue liegen | **Behoben.** Ein neuer Worker startet sofort; die Generation verhindert, dass der alte Worker die neue Queue abschließt. Alter Reproduktionstest und neuer Queue-Test bestehen. |
| 7 | Gleich große ROM-Ersetzung behält alte CRC32 | **Für bereits erfasste Änderungsdaten behoben; Bestandsdaten offen.** Austausch nach einem neuen Scan wird erkannt. Ein vorher vorhandener Datensatz mit `fileModified == nil` bleibt problematisch: R3. |
| 8 | Ersetzte Bilder bleiben im Cache veraltet | **Behoben im geprüften Ablauf.** Die Dateiversion steckt im Cache-Schlüssel und in der Task-ID. Cache-Test und zusätzlicher Test einer bereits angezeigten SwiftUI-View bestätigen das Laden der neuen Version am selben Pfad. Spielstand-Thumbnails verwenden zusätzlich bereits `.id(state.date)`. |
| 9 | ZIP-Extraktion akzeptiert beschädigte Nutzdaten | **Behoben.** Größe und CRC32 werden vor dem Schreiben geprüft. Beschädigte Stored- und Deflate-Payloads werden abgewiesen; ein vorhandenes Ziel bleibt erhalten. |
| 10 | Intellivision wird mit nur einer Pflichtdatei akzeptiert | **Behoben.** Nur explizite Gruppen gelten als Alternativen. Beide Intellivision-Dateien sind erforderlich; Sega-CD-Regionalalternativen funktionieren weiterhin. |
| 11 | M3U unterdrückt referenzierte Discs im Unterordner nicht | **M3U-Fall behoben; verwandter CUE-Fall offen.** M3U-Unterordner- und Elternreferenzen funktionieren. Der CUE-Parser entfernt weiterhin Verzeichniskomponenten: R4. |
| 12 | Fast Forward bleibt nach App-Fokusverlust aktiv | **Behoben für App-Deaktivierung und Pausemenü.** Beide Übergänge lösen den temporären Fast-Forward-Zustand; die entsprechenden Tests bestehen. |

## Noch offene Befunde

### R1 · [P1] Inhaltslesefehler einer ZIP-Datei führen weiterhin zu Datenverlust

**Fundstellen:** [LibraryScanner.swift:138](<../Ursprung/Library/LibraryScanner.swift:138>), [LibraryScanner.swift:98](<../Ursprung/Library/LibraryScanner.swift:98>) und [LibraryStore.swift:147](<../Ursprung/Library/LibraryStore.swift:147>).

**Auslöser:** Eine bereits erkannte `Game.zip` liegt in einem Bibliotheksordner ohne erkennbaren Systemnamen. Das System wird deshalb aus dem Archivinhalt bestimmt. Anschließend wird nur die ZIP-Datei unlesbar, während das Verzeichnis weiterhin aufgelistet werden kann.

**Ursache:** Die neue Fehlerliste erfasst Verzeichnis- und Ressourcenfehler. Dateimetadaten wie Größe und Änderungsdatum lassen sich aber auch bei fehlendem Inhaltsleserecht abfragen. Erst `ZipArchive(url:)` scheitert beim Öffnen; `try?` in `detectSystem` macht daraus kommentarlos `nil`. Der Scanner liefert dadurch weder ein ROM noch einen Eintrag unter `unreadable`.

Der Store sieht einen erfolgreich erreichbaren Ordner und entfernt das vermeintlich verschwundene Spiel einschließlich Medienverzeichnis. Die ZIP-Datei existiert weiterhin. Spielidentität, Favorit und Spielzeit gehen mit dem Datensatz verloren; ein späterer Scan kann sie nicht rekonstruieren.

**Reproduktion und Ergebnis:**

1. Ein synthetisches ZIP mit `Game.sfc` in einen temporären, neutral benannten Ordner schreiben und scannen.
2. Für das angelegte Spiel eine Medien-Datei erzeugen.
3. Die Rechte der ZIP-Datei auf `000` setzen; die Rechte des Ordners unverändert lassen.
4. Erneut scannen.

Beobachtet wurde `LibraryScan(roms: [], unreadable: [])`. Der vorhandene Datensatz und seine Medien-Datei wurden entfernt. Die Dateirechte wurden anschließend wiederhergestellt. Der ursprüngliche Test mit einem unlesbaren **Unterordner** besteht dagegen.

**Empfohlene Korrektur:** Fehler beim Öffnen oder Identifizieren eines vorhandenen Archivs als unvollständige Prüfung an den Scan-Status weitergeben. „Kein unterstütztes Spiel“ und „Datei konnte nicht geprüft werden“ müssen unterscheidbar sein. Bestehende Datensätze und Medien des betroffenen Pfads erhalten.

**Fehlender Regressionstest:** `unreadableArchiveKeepsGameAndMedia()` – die drei Prüfungen für Fehlerstatus, Datensatz und Medien scheitern reproduzierbar.

### R2 · [P2] Der verzögerte Audio-Clear kann das Vorpuffern dauerhaft blockieren

**Fundstellen:** [URAudioRing.c:38](<../Ursprung/Bridge/URAudioRing.c:38>), [URAudioRing.c:49](<../Ursprung/Bridge/URAudioRing.c:49>), [URAudioRing.c:64](<../Ursprung/Bridge/URAudioRing.c:64>) und [UREmulationRunner.m:250](<../Ursprung/Bridge/UREmulationRunner.m:250>).

**Auslöser:** Während Schnellvorlauf wird der Puffer nach jedem Emulationsframe geleert. Die Audioausgabe befindet sich nach einem Unterlauf oder beim Start im Zustand `primed == false`.

**Ursache:** Die Korrektur verschiebt das tatsächliche Leeren in `URAudioRingReadFloat`. `URAudioRingAvailable` meldet den Puffer unter Berücksichtigung des ausstehenden Clears bereits als leer. Der Writer verwendet aus gutem Grund noch den tatsächlichen Leseindex, um einen laufenden Lesevorgang nicht zu überschreiben.

Die bestehende Audio-Callback-Logik ruft bei noch nicht ausreichend vorgepufferten Daten aber überhaupt kein `ReadFloat` auf. Damit wird der Clear nicht bestätigt. Wiederholtes Schreiben und Clear füllt den physischen Puffer, obwohl die gemeldete Verfügbarkeit bei null bleibt. Sobald der Puffer voll ist, entsteht eine Blockade:

- Der Writer kann keine weiteren Frames schreiben.
- Der Audio-Callback wartet auf genügend verfügbare Frames und liest nicht.
- Der ausstehende Clear kann nur durch einen Leseaufruf umgesetzt werden.

**Auswirkung:** Auch nach Loslassen von Fast Forward kann die Session dauerhaft stumm bleiben. Das Loslassen korrigiert den Zustand dieses Puffers nicht.

**Nachweis:** Ein C-Test verwendet die unveränderte aktuelle Ring-Implementierung und dieselbe Priming-Bedingung wie der Audio-Callback. Nach wiederholtem Schreiben/Clear folgen 100 normale Schreib-/Renderzyklen. Bei einer Testkapazität von 16 Frames ergibt sich:

```text
Aktueller Stand:
written=0 read=0 available=0 physicalUsed=16 primed=0

Nach expliziter Clear-Bestätigung durch einen Leseraufruf mit 0 Frames:
written=4 read=2
```

Der identische Ablauf mit der vorherigen Ring-Implementierung erholt sich: `written=214`, `read=200`, `primed=1`. Die neue Blockade ist damit als Regression eingegrenzt. Separat bestätigt der frühere Zwei-Thread-Test, dass die ursprüngliche Wiederfreigabe verworfener Samples behoben ist.

**Empfohlene Korrektur:** Ausstehende Clears auf dem Audioleser auch während des Vorpufferns verarbeiten, bevor die Entscheidung zum frühen Rücksprung fällt. Die ausschließliche Zuständigkeit des Lesers für `readIndex` beibehalten; ein Rücksetzen durch den Writer würde den ursprünglichen Fehler wieder einführen.

**Fehlender Regressionstest:** Schnellvorlauf bei nicht vorgepufferter Ausgabe, anschließend Normalbetrieb; die Audioausgabe muss ohne Neuinitialisierung wieder anlaufen. Zusätzlich den vorhandenen Zwei-Thread-Konflikt absichern. Ein Test nur der einzelnen Ring-Funktionen ohne Priming-Bedingung würde den neuen Fehler übersehen.

### R3 · [P2] Der erste Scan von Bestandsdaten versieht eine alte CRC32 mit dem neuen Änderungsdatum

**Fundstellen:** [LibraryStore.swift:127](<../Ursprung/Library/LibraryStore.swift:127>) und [MetadataService.swift:100](<../Ursprung/Metadata/MetadataService.swift:100>).

**Auslöser:** Ein bestehender Bibliothekseintrag besitzt eine CRC32, aber noch kein `fileModified`. Dieses Feld ist neu; bei älteren Datensätzen fehlt die Information. Das ROM wurde seit der damaligen CRC-Berechnung durch ein gleich großes ROM ersetzt, bevor der erste Scan mit der korrigierten Version stattfindet.

**Ursache:** `isReplaced` vergleicht das Datum ausdrücklich nur bei `game.fileModified != nil`. Bei unveränderter Größe bleibt die alte CRC32 deshalb erhalten. Direkt danach wird `fileModified` jedoch auf das Änderungsdatum der aktuellen Datei gesetzt. Der anschließende Metadatenabruf sieht nun eine vorhandene CRC32 und ein passendes Datum und berechnet nichts neu. Selbst ein erzwungener Abruf verwendet weiter die falsche ROM-Identität.

**Reproduktion und Ergebnis:** Ein Datensatz im Zustand einer älteren Bibliothek wurde mit drei Bytes Dateigröße, `crc32 = "55BC801D"` und `fileModified = nil` angelegt. Die aktuelle Datei enthält andere drei Bytes mit CRC32 `6C5C20BE`. Nach Scan **und** erzwungenem Metadatenabruf steht weiterhin `55BC801D` im Datensatz. Der Abruf verwendet absichtlich leere Entwicklerzugangsdaten; die Prüfsummenverarbeitung erfolgt vor dem fehlgeschlagenen Offline-Lookup.

**Empfohlene Korrektur:** Eine CRC ohne zugehörige Dateiversion beim ersten Scan als ungeprüft behandeln. Vor Übernahme des aktuellen Datums entweder die CRC neu berechnen oder invalidieren. Dasselbe gilt, wenn ein Änderungsdatum zeitweise nicht ermittelt werden konnte.

**Fehlender Regressionstest:** `legacyGameDoesNotTrustUnversionedChecksum()` – sowohl die Prüfung direkt nach dem Scan als auch die Prüfung nach dem Metadatenabruf scheitern. Der vorhandene Test beginnt dagegen mit einem Scan der neuen Version und besitzt deshalb bereits ein bekanntes Änderungsdatum.

### R4 · [P2] Der CUE-Parser entfernt weiterhin den Unterordner einer Track-Referenz

**Fundstellen:** [LibraryScanner.swift:243](<../Ursprung/Library/LibraryScanner.swift:243>) und [LibraryScanner.swift:182](<../Ursprung/Library/LibraryScanner.swift:182>).

**Auslöser:** Eine CUE-Datei enthält einen relativen Track-Pfad mit Verzeichniskomponente, zum Beispiel `FILE "Tracks/Track.bin" BINARY`.

**Ursache:** Der neue Ausschluss arbeitet korrekt mit vollständigen Zielpfaden. `CueSheet.referencedFiles` liefert jedoch weiterhin ausschließlich `lastPathComponent`. Aus `Tracks/Track.bin` wird dadurch bereits vor der neuen Pfadauflösung `Track.bin`. Der Scanner unterdrückt somit einen anderen Pfad und listet den tatsächlich referenzierten Track weiter als eigenständiges Spiel.

**Reproduktion:**

```text
PSX/
  Disc.cue          # FILE "Tracks/Track.bin" BINARY
  Track.bin         # anderes, nicht referenziertes Image
  Tracks/
    Track.bin       # tatsächlich referenzierter Track
```

**Erwartet:** `Disc.cue`, `Track.bin`  
**Tatsächlich:** `Disc.cue`, `Tracks/Track.bin`

Die unabhängige Datei wird fälschlich ausgeblendet. Falls dafür bereits ein Bibliothekseintrag existiert, behandelt der Store diesen beim Rescan als verschwunden. Der ursprüngliche M3U-Unterordnerfall und die neuen M3U-Tests bestehen; der CUE-Fall wird von ihnen nicht abgedeckt.

**Empfohlene Korrektur:** Den vollständigen Referenztext aus dem CUE-Parser zurückgeben und erst relativ zur Descriptor-Datei auflösen. Auch `../` und Windows-Pfadtrenner in den Regressionstest aufnehmen.

**Fehlender Regressionstest:** `cueReferencePreservesItsSubdirectory()` – scheitert mit der oben angegebenen Dateiliste.

## Prüfverfahren und Belege

### Umfang und Isolation

Geprüft wurden alle **22 geänderten Dateien** des Korrektur-Commits sowie die für ihre Auswirkungen relevanten Aufrufer, insbesondere Audio-Callback, Scanner/Store, Metadatenabruf und SwiftUI-Bildanzeige. Dies ist eine Nachprüfung der zwölf Befunde und ihrer Korrekturen, keine erneute Vollinventur aller unveränderten Projektbereiche.

Die Tests liefen in einer separaten Kopie der versionierten Projektdateien. Nur dort wurden Application-Support-/Cache-Pfade und Bundle-IDs auf einen eigenen temporären Namensraum umgestellt. Echte ROMs, BIOS-Dateien, `.env`, lokale Signing-Einstellungen und bestehende generierte Zugangsdaten wurden nicht übernommen. Zusätzliche Swift-Tests, C-Harnesses und ein synthetischer Test-Core liegen ausschließlich außerhalb des Repositorys. Die geprüften Implementierungen blieben auch in der Testkopie unverändert; ausgenommen sind die ausdrücklich genannten Umgebungspfade und Bundle-IDs.

### Ausgeführte Prüfungen

| Prüfung | Ergebnis |
| --- | --- |
| Unveränderte bestehende Swift-Testsuite | **128 Tests / 154 Testfälle bestanden**, 0 Fehler, 0 übersprungen |
| Release-Build | **Erfolgreich**, Exit 0 |
| Zehn frühere Swift-Reproduktionen, an neue Signaturen angepasst | **10 bestanden** |
| Vier zusätzliche Randfall-/View-Tests | **1 bestanden, 3 reproduzierbar fehlgeschlagen**: R1, R3 und R4 |
| Gemeinsamer abschließender Lauf der 14 Zusatztests | **11 bestanden, 3 fehlgeschlagen** |
| Früherer Optionszeiger-Test mit AddressSanitizer, neu kompiliert | **Bestanden**, `value=a`, Exit 0, kein ASan-Befund |
| Früherer Audio-Test mit zwei Threads, neu kompiliert | Nach Abschluss des laufenden Lesers bleibt `available=0`; alter Fehler nicht mehr reproduziert |
| Neuer Audio-Test mit Priming-Bedingung | **Regression R2 bestätigt**, Exit 1; gleicher Ablauf mit alter Implementierung Exit 0 |
| SHA-256-Abgleich der 127 vorab erfassten Projektdateien einschließlich vorhandener unversionierter Dateien | **Keine Änderungen** |

Die drei fehlgeschlagenen Swift-Zusatztests formulieren das gewünschte Verhalten und belegen die Restfehler. Sie gehören nicht zur unveränderten bestehenden Testsuite.

Der erste Versuch einer Pixelprüfung der SwiftUI-View lieferte bereits für das Ausgangsbild transparente AppKit-Snapshots und war deshalb kein gültiger Produktnachweis. Der abschließende View-Test prüft stattdessen, dass die tatsächliche Lade-Task der vorhandenen View zunächst die Ausgangsversion und nach Dateiersatz die neue Version in den Cache lädt. Dieser Test besteht. Eine visuelle Screenshot-Verifikation wird daraus nicht abgeleitet.

### Nachvollziehbare lokale Artefakte

Die temporären Belege liegen im Verzeichnis `/var/folders/81/qfsm_y7s5_db2h31nwjjjmrw0000gn/T/ursprung-rereview-20261003-u5jn2opc/` und können später vom System entfernt werden. Die wesentlichen Schritte und Resultate sind deshalb oben vollständig beschrieben.

- [Ergebnis der bestehenden Testsuite](/var/folders/81/qfsm_y7s5_db2h31nwjjjmrw0000gn/T/ursprung-rereview-20261003-u5jn2opc/baseline-summary.json)
- [Abschließendes Ergebnis der 14 Zusatztests](/var/folders/81/qfsm_y7s5_db2h31nwjjjmrw0000gn/T/ursprung-rereview-20261003-u5jn2opc/final-probes-summary.json)
- [Zusätzliche Re-Review-Tests](/var/folders/81/qfsm_y7s5_db2h31nwjjjmrw0000gn/T/ursprung-rereview-20261003-u5jn2opc/project/UrsprungTests/ReReviewProbes.swift)
- [Audio-Reproduktion mit Priming-Bedingung](/var/folders/81/qfsm_y7s5_db2h31nwjjjmrw0000gn/T/ursprung-rereview-20261003-u5jn2opc/ring-prime-probe.c)
- [Release-Build-Log](/var/folders/81/qfsm_y7s5_db2h31nwjjjmrw0000gn/T/ursprung-rereview-20261003-u5jn2opc/release.log)

### Grenzen der Aussage

Getestet wurde mit Xcode 27.0 auf Apple Silicon; die Result-Bundles melden macOS 27.0. Die Mindestversion macOS 26 wurde nicht zusätzlich ausgeführt. Die Audio-Regression wurde mit der echten Ring-Implementierung und nachgebildeter Callback-Bedingung belegt, ohne echten Emulator-Core oder Hardware-Audioausgabe. Der Bestandsdaten-Test bildet den Zustand ohne `fileModified` im Modell nach; eine komplette Migration einer historischen Datenbankdatei wurde nicht durchgeführt. Netzwerkabrufe mit echten ScreenScraper-Zugangsdaten und manuelle Spiel-/Controller-Abläufe waren nicht Teil dieser Nachprüfung.
