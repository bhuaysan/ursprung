<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# Re-Review: Standalone / ARMSX2

**Datum:** 09.10.2026  
**Basis:** `main`, HEAD `8fb567e29ec0`, einschließlich der zu Review-Beginn vorhandenen uncommitteten Änderungen in 15 Code-/Testdateien.  
**Referenz:** [Review und Umsetzungsnotizen vom 09.10.2026](STANDALONE_REVIEW_2026-10-09.md).

Die Korrekturen beheben mehrere der ursprünglichen Probleme. Der vollständige Testlauf besteht. Drei relevante Befunde bleiben: ein neuer Überlaufabsturz bei der ZIP64-Prüfung, eine weiterhin unvollständige ZIP-Strukturprüfung und eine vorzeitig aufgehobene Restore-Sperre beim Backend-Wechsel. Die Änderungen sind deshalb noch nicht vollständig freigabefähig.

Anwendungscode, vorhandene Tests und der ursprüngliche Review-Bericht wurden in diesem Re-Review nicht verändert.

## Offene Befunde

| ID | Priorität | Befund | Nachweis |
|---|---|---|---|
| R1 | P1 | Beschädigte ZIP64-Größe lässt die neue Vorprüfung selbst abstürzen | Mit aktuellem Originalcode reproduziert |
| R2 | P1 | Restore-Sperre endet beim Wechsel zu libretro vor dem Ende des alten Emulators | Kontrollflussanalyse und isolierte Prüfung des Original-Prädikats |
| R3 | P2 | Defekte lokale ZIP-Header passieren die neue Strukturprüfung | Mit aktuellem Originalcode reproduziert |

### R1 — P1: Ungesicherte Addition vor der eigentlichen Überlaufprüfung

**Stelle:** [ARMSX2States.swift:229](../Ursprung/Emulation/ARMSX2States.swift#L229).

Die neue Prüfung berechnet:

```swift
entry.localHeaderOffset.addingReportingOverflow(header + entry.compressedSize)
```

`addingReportingOverflow` schützt nur die äußere Addition. `header + entry.compressedSize` wird vorher als normale, überlaufprüfende Swift-Addition ausgewertet. Der ZIP-Parser kann `compressedSize` aus einem ZIP64-Extra-Feld als beliebigen `UInt64` übernehmen.

**Auslöser:** Ein State besitzt einen gültigen Versionseintrag und für einen Pflichteintrag eine beschädigte ZIP64-Längenangabe nahe `UInt64.max`. Der neue Validator erreicht die Addition und bricht mit einem Arithmetic Trap ab. `try?` im Aufrufer fängt diesen Prozessabsturz nicht ab.

**Reproduktion:** Synthetisches `.p2s` mit allen erwarteten Dateinamen; im Central Directory des ersten Pflichteintrags `compressedSize = 0xFFFFFFFF` gesetzt und als ZIP64-Wert `UInt64.max` hinterlegt. Die Metadaten des Central Directory wurden korrekt angepasst. Der Aufruf von `ARMSX2States.isLoadable` im isolierten Programm mit unveränderten Produktdateien beendet den Prozess mit SIGTRAP, Shell-Exitcode 133.

**Folge:** Die Prüfung einer beschädigten Resume-Datei oder eines ausgewählten States kann Ursprung selbst beenden, statt den State kontrolliert abzulehnen. Dies ist ein neuer Fehler im Fix für F4.

**Fix-Vorschlag:** Jede Addition separat mit `addingReportingOverflow` absichern oder subtraktiv gegen die verbleibende Dateilänge prüfen. Beispielsweise zuerst den tatsächlichen Datenoffset sicher bestimmen, dann `dataOffset <= directoryOffset` und `compressedSize <= directoryOffset - dataOffset` prüfen. Vorher keine ungeschützte Summe aus Dateimetadaten bilden.

**Regressionstest:** Ein ZIP64-Pflichteintrag mit `UInt64.max` und weitere Grenzwerte müssen `false` liefern. Die Ablehnung darf weder einen Trap noch eine große Speicherallokation auslösen. Auch der Überlauf von Headeroffset plus Headerlänge gehört in diesen Test.

### R2 — P1: Restore wird während eines Backend-Wechsels wieder freigegeben

**Stellen:** [SaveStatesBrowser.swift:190](../Ursprung/UI/Library/SaveStatesBrowser.swift#L190), [EmulationSession.swift:251](../Ursprung/Emulation/EmulationSession.swift#L251), [EmulationSession.swift:697](../Ursprung/Emulation/EmulationSession.swift#L697), [EmulationSession.swift:807](../Ursprung/Emulation/EmulationSession.swift#L807).

Die neue Restore-Sperre verwendet `session.isStandaloneGameActive`. Diese Property beschreibt während `.preparing` das Backend des angeforderten nächsten Spiels, nicht zuverlässig den noch laufenden Prozess.

**Ablauf:**

1. PS2-Spiel A läuft; ein Save wurde angenommen und ist noch nicht fertig.
2. Ein libretro-Spiel B wird gestartet. `launch` setzt sofort `standaloneName = nil` und `phase = .preparing(...)`.
3. `shutDownRunner` wartet auf As State-Task und danach auf ARMSX2s Ende. Währenddessen bleiben `external`, die State-Ordner und zunächst auch `gameID` von A erhalten.
4. `isStandaloneGameActive` liefert schon `false`. Im State-Browser von A liefern sowohl die UI-Sperre als auch die erneute Prüfung in `restore` deshalb keine Blockierung mehr.
5. Ein Restore in diesem Zeitfenster kann wieder von As ausstehendem Save überschrieben werden. Der ausgewählte historische Inhalt war zuvor aus der Historie herausverschoben worden: derselbe Verlustmechanismus wie im ursprünglichen F3.

Ein langsamer Save beziehungsweise das Herunterfahren hält dieses Zeitfenster über die jeweiligen `await`-Punkte offen. Auch das Öffnen der ARMSX2-Einstellungen nutzt dieselbe Aktivitätsprüfung und kann während dieses Übergangs zu früh erlaubt werden.

**Nachweis:** Die Reihenfolge ist im aktuellen Launch-/Shutdown-Code belegt. Das unverändert übernommene Prädikat wurde zusätzlich mit dem Übergangszustand `.preparing`, `standaloneName == nil` und weiterhin vorhandenem externem Prozess ausgewertet: Ergebnis `false`. Das ist kein automatisierter UI-Test und keine erneute Live-Reproduktion des Datenverlusts mit ARMSX2.

**Fix-Vorschlag:** Die Sperre an die tatsächliche Lebensdauer des externen Prozesses und dessen State-Ordner binden. Die Session sollte beispielsweise eine Abfrage „darf dieser State-Ordner verändert werden?“ anbieten, die einen vorhandenen beziehungsweise herunterfahrenden externen Prozess und noch laufende State-Operationen berücksichtigt. Die Besitzdaten des alten Spiels erst nach vollständigem Abschluss freigeben. Das Zielbackend von B darf die Sperre für A nicht beeinflussen.

**Regressionstest:** A mit einem kontrolliert blockierten Save laufen lassen, B mit libretro-Backend anfordern, dann die Restore-Freigabe für A prüfen. Sie muss bis zum Abschluss von Save und Prozessende gesperrt bleiben. Das Öffnen des Standalone-Einstellungsfensters im selben Übergang ebenfalls prüfen.

### R3 — P2: Central-Directory-Angaben ersetzen keine Prüfung der lokalen Header

**Stelle:** [ARMSX2States.swift:224](../Ursprung/Emulation/ARMSX2States.swift#L224).

`hasRequiredEntries` liest die lokalen ZIP-Header der Pflichtdateien nicht. Es schätzt deren Länge mit `30 + entry.path.utf8.count` und prüft lediglich die im Central Directory angegebene komprimierte Größe gegen dessen Anfang.

Damit bleiben unter anderem ein falscher lokaler Header-Magic, eine abweichende lokale Namenslänge und die tatsächliche Länge des lokalen Extra-Felds unberücksichtigt. Die Existenz eines Eintrags im Central Directory beweist nicht, dass der zugehörige lokale Eintrag lesbar ist.

**Reproduktion:** In einer strukturellen Fixture-Datei mit allen Pflichtdateien ausschließlich die vier Magic-Bytes des lokalen Headers von `GS.bin` überschrieben. Der Versionseintrag und das Central Directory blieben unverändert. Ergebnis mit dem aktuellen Originalcode:

```text
isLoadable= true
GS.bin read failed: corrupt
```

Der zweite Aufruf verwendet Ursprungs eigenen `ZipArchive.data(of:)`. Bereits dieser erkennt den Defekt, den die vorgeschaltete Ladbarkeitsprüfung übersieht.

**Folge:** Strukturell unlesbare States werden weiterhin an den Emulator übergeben. Der ursprüngliche F4 ist für fehlende Dateinamen korrigiert, aber nicht für beschädigte lokale ZIP-Strukturen. Dies ist unabhängig von der ausdrücklich dokumentierten Einschränkung, Zstd-Nutzdaten nicht zu dekomprimieren oder vollständig zu prüfen.

**Fix-Vorschlag:** Einen gemeinsamen ZIP-Helfer für die Validierung lokaler Einträge verwenden. Dieser liest den tatsächlichen Header, prüft Signatur und relevante Konsistenzmerkmale, berücksichtigt lokale Namens- und Extra-Länge und berechnet den Datenbereich überlaufsicher. Die Strukturprüfung kann auch für Methode 93 erfolgen, ohne deren Nutzdaten zu dekomprimieren. Die verbleibende Grenze der Nutzdatenprüfung weiterhin dokumentieren.

**Regressionstest:** Falscher lokaler Header-Magic, fehlender Header, Datenbereich hinter dem Central Directory sowie ein Extra-Feld, durch das der reale Datenbereich zu groß wird. Dazu eine unabhängige gültige Fixture. Die Liste erwarteter Pflichtdateien ausschließlich aus `ARMSX2States.requiredEntries` zu erzeugen, prüft deren Übereinstimmung mit dem Emulator nicht.

## Status der ursprünglichen sechs Befunde

| Befund | Ergebnis des Re-Reviews |
|---|---|
| F1: gemeinsame INI aus überholter Vorbereitung | **Für die INI behoben.** `prepare` schreibt sie nicht mehr; Generation-Prüfung, `writeSettings` und Prozessstart folgen ohne Suspension Point. Eine verbleibende gemeinsame Log-Mutation ist unten vermerkt. |
| F2: Historieverlust nach Save-Timeout | **Ursprünglicher Timeout-Fall behoben.** Bei unbekanntem Ausgang bleibt die Kopie erhalten. Der neue Test schreibt tatsächlich nach Ende der Wartefrist und prüft die erhaltene Historie. Fehler beim Lesen einer PINE-Antwort werden als `malformedReply`/`timedOut` behandelt und führen ebenfalls nicht zur Rücknahme der Sicherung. |
| F3: Restore konkurriert mit Save | **Teilweise behoben.** Laufende Standalone-Sessions sperren Restore im Button, Kontextmenü und Handler. Beim Wechsel zu libretro fällt diese Sperre zu früh weg: R2. |
| F4: unvollständiger State gilt als ladbar | **Teilweise behoben; neue Regression.** Fehlende Pflichtdateien werden erkannt. Die neuen Negativtests zeigen R1 und R3. |
| F5: ungeprüfte Deskriptoren und Archive | **Launch-Pfad korrigiert.** Einfache CUE-Dateien werden auf ein unterstütztes Image aufgelöst, CCD auf IMG; M3U und Archive werden vor dem Prozessstart abgelehnt. Neue Standalone-Playlists werden nicht mehr angeboten. Bestehende PS2-M3U-Dateien verstecken ihre Images beim Scan allerdings weiterhin. |
| F6: älterer Resume-Stand rückt nach | **Ursprünglicher Fehler behoben.** Endet die Session ohne frischen Resume-Stand, entfernt die Bereinigung alle regulären alten Kandidaten. Zusammengeführte Kopien bleiben erhalten. Eine Bindung an die Disc-Identität bleibt bewusst offen. |

## Ergänzende Hinweise

- **F1: gemeinsame Log-Datei bleibt eine Nebenwirkung von `prepare`.** [ARMSX2Launch.swift:149](../Ursprung/Emulation/ARMSX2Launch.swift#L149) löscht weiterhin `request.logFile` vor der Generation-Prüfung des Aufrufers. Eine verspätete Vorbereitung A kann somit die bereits geöffnete Log-Datei von B entfernen. Bei einem anschließenden Fehler fehlt die Diagnose am erwarteten Pfad. Auch die Log-Ersetzung in den exklusiven Startabschnitt verschieben oder pro Session einen eigenen Log-Pfad verwenden.
- **F5: Scanner-Verhalten ist unverändert.** Bestehende PS2-M3U-Dateien unterdrücken weiterhin ihre referenzierten Images. Der neue Fehlertext bietet als Ausweg das Löschen der Playlist an. Besser diese Deskriptoren für das Backend beim Scan gesondert behandeln und startbare Images sichtbar halten; die User-Datei muss dafür nicht gelöscht werden. Auch mehrteilige CUE-Dateien sind durch die Auswahl nur des ersten passenden Images nicht vollständig unterstützt.
- **Versionswechsel und Fehleranzeige:** `activate` und Rollback persistieren vor der Übernahme des neuen Zustands; der neue Fehlerfalltest für Rollback besteht. Restore-Fehler werden jetzt angezeigt. Diese Korrekturen sind nachvollziehbar.
- **Beobachtung und temporäre Ressourcen:** Der State-Watcher sowie die Bereinigung des PINE-Ordners in den Fehlerpfaden sind vorhanden. Die Sperre neuer Save-/Load-Anfragen bei `shutdown != nil` ist ebenfalls umgesetzt. Diese Ergänzungen beheben aber nicht R2, weil Restore eine andere Sperrabfrage verwendet.
- **Bewusst offene Punkte:** Kompatibilitätsanzeige vor „Resume“/„Play from Here“, erneuter PINE-Verbindungsaufbau und ein zum bloßen Auftragseingang passender Load-Toast sind weiterhin offen. Nach einem Save-Timeout wird ein weiterer Save weiterhin zugelassen; der erste Auftrag kann dabei noch laufen. Dies ist im aktualisierten Ausgangsbericht bereits benannt und wird hier nicht als überraschende neue Regression gezählt.

## Tests und Nachweisgrenzen

**Vollständiger Xcode-Lauf:** `xcodebuild test`, macOS arm64, erfolgreich. Die XCResult-Zusammenfassung weist **438 Testfälle insgesamt, 436 bestanden, zwei übersprungen, null fehlgeschlagen** aus. Mit Parameterfällen sind es **479 bestandene Ausführungen**. Die beiden übersprungenen Tests sind `SlangPresetTests/everyPackPresetRoundTrips()` und `ShaderLibraryTests/realPackUnpacksAndIndexes()`; beide setzen ein über `URSPRUNG_SHADER_PACK` bereitgestelltes echtes Shader-Paket voraus. Die Angabe „alle 438 Tests bestehen“ im Umsetzungsbericht ist deshalb für diesen Lauf genauer als „436 bestanden, zwei übersprungen“ zu formulieren.

**Zusätzliche Prüfungen:** R1/R3 wurden mit einem separaten Swift-Programm unter `/tmp` reproduziert. Es kompiliert die unveränderten Produktdateien `ARMSX2States.swift`, `SaveStates.swift`, `PINEClient.swift`, `ZipArchive.swift` und `FileMerge.swift`; lediglich die nicht benötigten umgebenden Typen `GraphicsAPI` und `StandaloneLaunchError` sind minimal ersetzt. Der Trap betraf ausschließlich dieses Testprogramm. Die ZIP-Dateien sind synthetisch; echte Nutzerdaten wurden nicht verwendet. R2 wurde durch den Kontrollfluss und die isolierte Auswertung des unveränderten Aktivitäts-Prädikats geprüft.

**Testlücken:** Die neuen Repository-Tests decken weder extreme ZIP64-Größen noch defekte lokale Header ab. `onlyTheLaunchThatStartsWritesTheSettings` bestätigt die Trennung von Vorbereitung und INI-Schreiben, simuliert aber keinen konkurrierenden Session-Wechsel. Für die Restore-Sperre fehlt ein Integrationstest des Übergangs Standalone → libretro.

Kein Live-ARMSX2-Start, kein erneuter Controller-/Fullscreen-Test und keine echte Memory-Card-Operation wurden durchgeführt. Die grünen Tests ersetzen diese manuellen Prüfungen nicht. `git diff --check` meldet keine Formatfehler.

## Nächste Änderungen

R1 und R3 gemeinsam über eine robuste Prüfung tatsächlicher ZIP-Einträge beheben. Für R2 die Sperre vom Zielbackend lösen und an die noch vorhandene externe Session binden. Danach genau diese Negativfälle ergänzen und den Testlauf sowie die manuellen Checks aus Phase 8 des Standalone-Plans wiederholen.

## Umsetzung (09.10.2026)

| ID | Status | Änderung | Regressionstest |
|---|---|---|---|
| R1 | behoben | `ZipArchive.dataOffset(of:in:)` vergleicht Werte aus der Datei nur, statt sie ungeprüft zu addieren: Header-Offset und Datenbereich müssen vor dem Central Directory liegen, `compressedSize <= directoryOffset - dataOffset`. `data(of:)` und die State-Prüfung nutzen denselben Helfer. | `refusesStatesWithDamagedZipStructures` (ZIP64-Größen und -Offsets bis `UInt64.max`, auch Offset plus Header; `isLoadable` und `data(of:)`) |
| R2 | behoben | Neue Session-Abfragen: `standaloneMayWriteStates(of:)` gilt, solange der externe Prozess des Spiels existiert (auch während er sich beendet) oder sein Standalone-Start läuft; `isStandaloneEmulatorInUse` ebenso für das Einstellungsfenster (Button, `openStandaloneSettings`, Prüfung vor dem INI-Schreiben). Das Backend des nächsten Spiels spielt keine Rolle mehr. | `statesStayLockedUntilTheEmulatorHasQuit` (Ersatzprozess, der sich erst auf Signal beendet; Wechsel zu einem Spiel ohne Standalone-Emulator) |
| R3 | behoben | `ZipArchive.hasIntactLocalHeaders(_:)` liest die echten lokalen Header der Pflichteinträge: Signatur, gleiche Methode wie im Central Directory, lokale Namens- und Extra-Länge. Nutzdaten werden weiterhin nicht dekomprimiert (Zstd). | `refusesStatesWithDamagedZipStructures` (falscher Magic, andere Methode, zu langes lokales Extra-Feld, Offset mitten in den Eintrag), `refusesIncompleteStates` erkennt jetzt schon ein fehlendes Byte |

Ergänzende Hinweise:

- **F1, Log-Datei:** Das Löschen des alten Logs ist aus `prepare` in `writeSharedFiles()` (vormals `writeSettings()`) gewandert und läuft damit im exklusiven Startabschnitt (`onlyTheLaunchThatStartsTouchesTheSharedFiles`).
- **Unabhängige Fixture:** `handmadeZip(files:zip64:)` in `TestSupport.swift` baut States Byte für Byte ohne `/usr/bin/zip`; der gültige Fall muss bestehen. Die Liste `ARMSX2States.requiredEntries` bleibt aus `SaveState.cpp` des Pins abgeleitet. Ob sie zum Emulator passt, zeigt erst ein echter ARMSX2-State.
- **Testseam:** `EmulationSession.adoptExternalForTesting` (nur `DEBUG`) setzt einen laufenden Prozess als Standalone-Session ein.
- **Weiter offen:** Bestehende PS2-M3U-Dateien verstecken ihre Images beim Scan weiterhin. Mehrteilige CUE-Dateien starten mit dem ersten passenden Image. Eine ZIP64-`uncompressedSize`, die nicht zur Nutzlast passt, kann Ursprung ohne Dekompression nicht erkennen.

**Tests:** 440 Tests in 95 Suites: 438 bestanden, zwei übersprungen (dieselben Shader-Pack-Tests), keiner fehlgeschlagen (`xcodebuild test`, macOS arm64). Kein Live-Test mit ARMSX2.
