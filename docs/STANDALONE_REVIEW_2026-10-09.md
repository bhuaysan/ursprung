<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# Code-Review: Standalone / ARMSX2

**Datum:** 09.10.2026  
**Stand:** `main`, Commit `8fb567e29ec0`, zu Beginn sauberes Arbeitsverzeichnis.  
**Grundlage:** [Standalone-Implementierungsplan](STANDALONE_PLAN.md) und aktuelle Umsetzung einschließlich der Korrekturen zum [Review vom 07.10.2026](STANDALONE_REVIEW_2026-10-07.md).

Die Umsetzung deckt die wesentlichen Bausteine des Plans ab. Die bestehenden Tests bestehen. Es bleiben jedoch Fehler bei konkurrierenden Dateioperationen, verzögerten Speicheraufträgen und der Vorbereitung von Starts. Drei Befunde betreffen mögliche Verluste oder Fehlzuordnungen von Spielständen und sollten zuerst behoben werden.

Dieser Review ändert ausschließlich die Dokumentation. Die beschriebenen Fixes sind Vorschläge, noch keine Implementierung.

## Übersicht

| ID | Priorität | Befund | Nachweis |
|---|---|---|---|
| F1 | P1 | Überholte Startvorbereitung kann die Konfiguration des nächsten Spiels überschreiben | Kontrollflussanalyse |
| F2 | P1 | Ein verspäteter Save löscht die Absicherung des vorherigen Spielstands | Reproduktion mit Originalcode und Fake-PINE |
| F3 | P1 | Restore während eines Saves kann den ausgewählten historischen Stand verlieren | Reproduktion mit Originalcode und Fake-PINE; UI-Pfad geprüft |
| F4 | P2 | Unvollständige `.p2s` werden als ladbar akzeptiert | Reproduktion; Abgleich mit gepinntem ARMSX2-Quellcode |
| F5 | P2 | CUE, M3U und Archive gelangen ungeprüft zum Standalone-Emulator | Kontrollflussanalyse; Abgleich mit gepinntem ARMSX2-Quellcode |
| F6 | P2 | Resume-Bereinigung lässt ältere automatische Stände zurück | Reproduktion mit Originalcode |

P1 bedeutet hier: vor einem Release beheben, weil gespeicherter Fortschritt betroffen sein kann. P2 bezeichnet funktionale Fehler, die unter den jeweils beschriebenen Bedingungen auftreten. Ein Live-Absturz oder eine Beschädigung echter Nutzerdaten wurde nicht herbeigeführt.

## F1 — P1: Überholte Startvorbereitung schreibt weiterhin in die gemeinsame INI

**Stellen:** [EmulationSession.swift:539](../Ursprung/Emulation/EmulationSession.swift#L539), [ARMSX2Launch.swift:103](../Ursprung/Emulation/ARMSX2Launch.swift#L103), [PCSX2Config.swift:188](../Ursprung/Emulation/PCSX2Config.swift#L188).

**Auslöser:** Spiel A startet, während dessen Vorbereitung noch läuft wird Spiel B gestartet. Das ist über die Bibliothek möglich: Jeder Aufruf von `play` erzeugt einen eigenen Launch-Task. Besonders relevant ist eine verzögerte Dateiprüfung auf einem langsamen Datenträger.

`Self.prepare` läuft mit `@concurrent` und schreibt bereits die gemeinsame `data/ARMSX2/inis/PCSX2.ini`. Erst nach dessen Rückkehr prüft der Aufrufer die Session-Generation. `shutDownRunner` wartet auf einen laufenden Emulator, aber nicht auf eine noch aktive Vorbereitung.

Damit ist folgende Reihenfolge möglich:

1. Vorbereitung A wartet beim Lesen der Spieldatei oder Disc-Metadaten.
2. Vorbereitung B schreibt ihre Ordner und Einstellungen; B kann jetzt starten.
3. A schreibt danach seine Konfiguration in dieselbe Datei.
4. Die Generation-Prüfung verwirft A erst nach diesem Schreibvorgang.

**Folge:** Liest B die INI nach Schritt 3, verwendet es unter anderem den Memory-Card- und Savestate-Ordner von A. Ursprung überwacht weiterhin die Ordner von B. Auch spätere Einstellungsübernahmen können die falsche Konfiguration lesen. Das atomare Schreiben verhindert eine teilweise INI, aber nicht die falsche Reihenfolge vollständiger Dateien.

**Fix-Vorschlag:** Vorbereitung und Veröffentlichung trennen. BIOS-/Disc-/State-Prüfungen dürfen im Hintergrund laufen und ein Ergebnis liefern. Das Schreiben der gemeinsamen INI und der Prozessstart müssen exklusiv pro Emulator erfolgen, nach erneuter Generation-Prüfung. In diesem Abschnitt darf kein anderer Launch dazwischenkommen. Alternativ alte Vorbereitungen vollständig abwarten, bevor die nächste schreiben darf. Nur einen weiteren Cancellation-Check in `prepare` einzubauen schließt das Zeitfenster nicht zuverlässig.

**Regressionstest:** A vor dem Konfigurationsschreiben kontrolliert blockieren, B anfordern und A anschließend freigeben. Ein Fake-Emulator muss beim Start ausschließlich Bs Memory-Card-/State-Ordner lesen; A darf danach keine gemeinsame Konfiguration mehr verändern.

**Evidenzgrenze:** Aus dem aktuellen Kontrollfluss belegt; das konkrete Timing wurde nicht mit zwei echten ARMSX2-Starts reproduziert.

## F2 — P1: Timeout entfernt eine Sicherung, obwohl der Save noch ankommen kann

**Stellen:** [ARMSX2States.swift:235](../Ursprung/Emulation/ARMSX2States.swift#L235), [ARMSX2States.swift:325](../Ursprung/Emulation/ARMSX2States.swift#L325).

**Auslöser:** ARMSX2 bestätigt den Speicherbefehl, schreibt den neuen Slot aber erst nach Ursprungs Wartefrist. PINE bestätigt laut Plan lediglich das Einreihen des Auftrags; Ursprung kann den Auftrag anschließend nicht zurücknehmen.

Vor dem Befehl wird der bisherige Slot in die Historie kopiert. Bei Timeout oder einem anderen Fehler prüft `save` einmal den Änderungszeitpunkt. Ist der neue Stand noch nicht da, entfernt `unarchive` die Sicherungskopie. Ein später fertiggestellter Save überschreibt dann den bisherigen Slot ohne erhaltene Historie. Eine verlorene PINE-Antwort kann ebenfalls einen bereits angenommenen Auftrag als Fehler erscheinen lassen.

**Reproduktion:** Original-Implementierung von `ARMSX2States.save`, echter `PINEClient`, Fake-Server mit erfolgreicher Bestätigung. Test-Timeout auf 150 ms verkürzt, neue Datei nach 700 ms atomar geschrieben. Ergebnis:

```text
Late save: returned notSaved
Late save: slot= NEW SAVE history= 0
```

Die verkürzten Zeiten machen denselben Ablauf deterministisch; produktiv beträgt die Wartefrist zehn Sekunden.

**Fix-Vorschlag:** Ab dem möglicherweise übertragenen Speicherbefehl ist ein Timeout ein unbekannter Ausgang. Die vorherige Version muss in der Historie bleiben. Nur wenn sicher noch kein Befehl gesendet wurde oder der Emulator ihn eindeutig abgelehnt hat, darf die Sicherung zurückgenommen werden. Späte Dateischreibvorgänge nachbeobachten und den UI-Status aktualisieren; ein weiterer Save sollte nicht unkontrolliert mit dem noch offenen Auftrag konkurrieren.

**Regressionstest:** Erfolgreiche Bestätigung, Dateiersetzung erst nach Timeout. Der alte Inhalt muss danach weiterhin in der Historie liegen. Zusätzlich Verbindungsabbruch nach Befehlsannahme testen.

## F3 — P1: Restore und Speichern sind nicht gegeneinander gesperrt

**Stellen:** [SaveStatesBrowser.swift:155](../Ursprung/UI/Library/SaveStatesBrowser.swift#L155), [SaveStatesBrowser.swift:218](../Ursprung/UI/Library/SaveStatesBrowser.swift#L218), [ARMSX2States.swift:154](../Ursprung/Emulation/ARMSX2States.swift#L154).

**Auslöser:** In „Save States“ einen Save auslösen und vor dessen Fertigstellung einen historischen Stand in denselben Slot zurückholen. Der Save-Button berücksichtigt `canUseExternalStates`, Restore, Delete und Rename besitzen diese Sperre nicht. Restore ruft den Dateispeicher direkt auf.

**Ablauf:** Save archiviert den aktuellen Slot und sendet den PINE-Befehl. Restore verschiebt anschließend den ausgewählten historischen Stand in den aktiven Slot. Der bereits angenommene Save ersetzt diesen Slot danach. Seine Sicherung enthält aber den Inhalt von vor dem Restore. Der ausgewählte historische Stand liegt nun weder im Slot noch in der Historie.

**Reproduktion:** Mit Original-Save-/Restore-Code und verzögert schreibendem Fake-PINE-Server bestätigt:

```text
Concurrent restore: slot= NEW SAVE selected history state preserved= false
```

Zusätzlich kann der Restore allein den Änderungszeitpunkt erhöhen und damit die reine Zeitstempelprüfung des Saves verfrüht als erfolgreich erscheinen lassen.

**Fix-Vorschlag:** Alle von Ursprung ausgelösten Mutationen des State-Ordners über dieselbe Operationsverwaltung führen. Restore/Delete/Rename müssen während laufender oder ungeklärter Save-/Load-Aufträge gesperrt oder eingereiht werden, einschließlich bereits geöffneter Bestätigungsdialoge. Für die kleinste robuste Änderung Restore während einer aktiven Standalone-Session deaktivieren: ARMSX2s eigene Hotkeys schreiben unabhängig von Ursprungs Busy-Flag. Eine weitergehende Lösung muss auch diese externen Änderungen berücksichtigen.

**Regressionstest:** Save nach Befehlsannahme pausieren, Restore desselben Slots anfordern, Save fertigstellen. Beide zuvor vorhandenen Inhalte müssen erhalten bleiben beziehungsweise Restore muss nachvollziehbar abgewiesen werden. Die UI-Sperre und den Schutz im Service separat prüfen.

## F4 — P2: Versionsnummer wird mit vollständiger Ladbarkeit gleichgesetzt

**Stellen:** [ARMSX2States.swift:188](../Ursprung/Emulation/ARMSX2States.swift#L188), [ARMSX2States.swift:203](../Ursprung/Emulation/ARMSX2States.swift#L203), [ARMSX2Launch.swift:127](../Ursprung/Emulation/ARMSX2Launch.swift#L127).

**Auslöser:** Ein beschädigter oder unvollständiger Spielstand hat noch einen lesbaren, kompatiblen Versionseintrag. `isLoadable` prüft ausschließlich diesen ZIP-Eintrag und die Versionsnummer.

**Reproduktion:** ZIP mit genau einer Datei `PCSX2 Savestate Version.id`, Inhalt `0x9A590000` als vier Little-Endian-Bytes. `isLoadable(..., by: 0x9A590000)` liefert `true`, obwohl keinerlei emulierter Zustand enthalten ist.

Der gepinnte Emulator verlangt beim tatsächlichen Laden unter anderem `PCSX2 Internal Structures.dat` und weitere Pflichtkomponenten. Sein Ladepfad weist fehlende Komponenten zurück; beim Start mit `-statefile` wird daraus `StartupFailure`. Siehe [ARMSX2 SaveState.cpp am Pin](https://github.com/ARMSX2/ARMSX2/blob/46c06fe7ca/pcsx2/SaveState.cpp#L1437) und [VMManager.cpp](https://github.com/ARMSX2/ARMSX2/blob/46c06fe7ca/pcsx2/VMManager.cpp#L2263).

**Folge:** Die Schutzprüfung verhindert diesen Startfehler nicht. Im laut Plan von abstürzenden Fehlerdialogen betroffenen macOS-Umfeld kann damit erneut der dokumentierte Absturzpfad erreicht werden. Ein echter Emulator-Absturz wurde hier nicht ausgelöst.

**Fix-Vorschlag:** Formatkompatibilität und strukturelle Integrität getrennt prüfen. Mindestens Pflichtdateien, plausible Größen und gültige Bereiche der ZIP-Einträge gegen den Pin validieren. Für vollständige Integritätsprüfung müssen auch die komprimierten Nutzdaten geprüft werden; der vorhandene ZIP-Reader unterstützt deren Zstd-Methode 93 bisher nicht. Eine strukturelle Vorprüfung verbessert den Schutz, garantiert aber noch keine vollständige Ladbarkeit. Der Name und die UI sollten diese Grenze nicht verschleiern.

**Regressionstest:** Version vorhanden, Pflichtdatei fehlt; abgeschnittener Nutzdatenbereich; defekte komprimierte Nutzdaten; vollständiger gültiger Fixture-State. Die bisherigen Minimal-Fixtures müssen als reine Versionstestdaten kenntlich bleiben, statt eine vollständige Ladbarkeit zu belegen.

## F5 — P2: Erkannte Disc-Deskriptoren und Archive werden nicht für ARMSX2 aufgelöst

**Stellen:** [LibraryScanner.swift:186](../Ursprung/Library/LibraryScanner.swift#L186), [LibraryScanner.swift:255](../Ursprung/Library/LibraryScanner.swift#L255), [ARMSX2Launch.swift:145](../Ursprung/Emulation/ARMSX2Launch.swift#L145), [LibraryView.swift:933](../Ursprung/UI/Library/LibraryView.swift#L933).

**Auslöser:** Ein PS2-Spiel liegt als CUE/BIN, M3U mit mehreren Images oder ZIP vor. Scanner und Disc-Menü behandeln PS2 wie die übrigen Disc-Systeme. Referenzierte BIN-/ISO-Dateien werden als eigene Bibliothekseinträge ausgeblendet.

Der Standalone-Launch übergibt jedoch `game.fileURL` unverändert. Die Content-Vorbereitung des libretro-Pfads wird nicht erreicht. ARMSX2s gepinnter Startpfad übergibt gewöhnliche Dateinamen an den ISO-Leser; dessen Reader-Auswahl kennt CHD, CSO/ZSO, GZ und Dumps, aber keinen CUE-/M3U-Parser oder ZIP-Entpacker. Siehe [AutoDetectSource](https://github.com/ARMSX2/ARMSX2/blob/46c06fe7ca/pcsx2/VMManager.cpp#L1546) und [InputIsoFile.cpp](https://github.com/ARMSX2/ARMSX2/blob/46c06fe7ca/pcsx2/CDVD/InputIsoFile.cpp#L40).

**Folge:** Statt des eigentlichen Images erhält der Emulator den Deskriptor beziehungsweise das Archiv. Kleine Textdeskriptoren scheitern an der Image-Erkennung; größere ungeeignete Dateien können als falsches Medium interpretiert werden. Bei CUE/M3U verschwinden gleichzeitig die direkt startbaren referenzierten Images aus der Bibliotheksansicht. „Create Disc Playlist“ kann so aus zuvor startbaren PS2-Discs einen nicht startbaren Eintrag machen.

**Fix-Vorschlag:** Unterstützte Eingabeformate als Backend-Fähigkeit modellieren und vor dem Prozessstart auflösen. Für unterstützte einfache CUE-Dateien das zugehörige Datenimage wählen. M3U benötigt eine definierte Disc-Auswahl und einen passenden Wechselmechanismus; bis dahin Erstellung und Start für dieses Backend gezielt verhindern und referenzierte Images sichtbar lassen. Archive entweder unterstützt entpacken oder vor dem Launch mit einer konkreten Meldung ablehnen. Ein gemeinsames `discSystems`-Flag reicht für diese Fähigkeiten nicht aus.

**Regressionstest:** PS2-Ordner mit CUE/BIN, M3U mit zwei ISO-Dateien sowie ZIP/7z scannen und den vollständigen Launch-Pfad prüfen. Erwartet wird ein vom Backend unterstütztes Image oder eine kontrollierte Ablehnung; kein ungeprüfter Deskriptor als CLI-Spielargument.

**Evidenzgrenze:** Durch lokalen Kontrollfluss und den Reader des gepinnten Emulators belegt; kein zusätzlicher Live-Start dieser Formate.

## F6 — P2: Nach dem Löschen des neuesten Resume-Stands wird ein älterer wieder aktiv

**Stelle:** [ARMSX2States.swift:338](../Ursprung/Emulation/ARMSX2States.swift#L338).

**Auslöser:** Ein Spielordner enthält mehrere reguläre `.resume.p2s`, beispielsweise nach dem Zusammenführen von Bibliothekseinträgen unterschiedlicher Discs/Revisionen. Das Dateimodell sieht mehrere Resume-Dateien ausdrücklich vor. Anschließend endet eine Session sauber ohne neuen Resume-Stand, etwa über den Schließen-Button von ARMSX2.

`removeStaleResumeState` löscht ausschließlich die aktuell neueste Resume-Datei. Bei der nächsten Abfrage wird die zweitneueste Datei automatisch zum Resume-Kandidaten, obwohl auch sie vor dem gerade beendeten Spiel liegt.

**Reproduktion:** Zwei unterschiedlich benannte Resume-Dateien mit Änderungsdatum vor Session-Beginn erzeugt, Bereinigung einmal aufgerufen. Danach liefert `resumeState` weiterhin die ältere Datei.

**Folge:** „Resume“ kann einen noch älteren Zustand anbieten und starten. Damit wird gerade die Schutzregel des Plans verletzt, nach einem Beenden ohne frischen Resume-Stand nicht hinter den aktuellen Memory-Card-Fortschritt zurückzuspringen.

**Fix-Vorschlag:** Alle veralteten automatischen Kandidaten dieser Session invalidieren. Alte Zustände anderer Discs können bei Bedarf als manuelle Historie erhalten bleiben, dürfen jedoch nicht automatisch nachrücken. Zusätzlich den automatischen Kandidaten an die Disc-Identität binden, statt nur den neuesten Zeitstempel des gesamten Ordners zu verwenden.

**Regressionstest:** Zwei alte Resume-Dateien → kein automatischer Kandidat nach sauberem Ende ohne neuen Stand. Eine neue und eine alte Datei → nur die neue darf automatisch gewählt werden. Crash-Fall separat prüfen: Die im Plan beabsichtigte Wiederherstellungsmöglichkeit bleibt erhalten.

## Weitere Verbesserungsmöglichkeiten

1. **Kompatibilität vor der Aktion zeigen.** [LibraryView.swift:855](../Ursprung/UI/Library/LibraryView.swift#L855) berechnet „Resume“ nur aus der Existenz einer Datei. Der Browser erlaubt „Play from Here“ anhand der Core-ID. Nach einem Rollback können beide Aktionen einen inkompatiblen Stand anbieten; Resume startet dann still von vorn. Die Formatversion der tatsächlich aktiven Installation schon für diese Anzeige nutzen. Inkompatible Stände sichtbar, aber deaktiviert mit Grund darstellen. Das erhält die Daten und vermeidet die im Plan erwähnte irreführende Verfügbarkeit.

2. **Externe State-Änderungen beobachten.** [SaveStatesBrowser.swift:86](../Ursprung/UI/Library/SaveStatesBrowser.swift#L86) lädt beim Öffnen und bei Änderungen von `session.slots` neu. ARMSX2-Hotkeys aktualisieren diese Property nicht. Ein Beobachter für den State-Ordner oder eine Aktualisierung beim Aktivieren der Bibliothek würde extern erzeugte Saves und Thumbnails zeitnah anzeigen. `.part` weiterhin ignorieren und Ereignisse bündeln.

3. **Wiederherstellungs- und Persistenzfehler anzeigen.** Restore verschluckt Fehler mit `try?` im Browser; [EmulatorManager.swift:211](../Ursprung/Cores/EmulatorManager.swift#L211) tut dasselbe beim Speichern von `versions.json`. Ein fehlgeschlagener Restore sollte eine konkrete Meldung erhalten. Versionswechsel erst nach erfolgreicher Persistenz als abgeschlossen ausweisen; bei einem Fehler den vorherigen Zustand erhalten. Das verhindert, dass ein Rollback nur bis zum nächsten App-Start zu gelten scheint.

4. **Temporäre Ordner auch bei abgebrochenen Starts entfernen.** `ARMSX2Launch.prepare` legt den PINE-Ordner an, bevor sämtliche Prüfungen abgeschlossen sind. Die aktuelle Entfernung hängt am Prozessende. Ungültige gewählte States, ein fehlgeschlagener Prozessstart oder eine überholte Vorbereitung können daher Ordner zurücklassen. Die vorbereitete Ressource bis zur erfolgreichen Übergabe an `ExternalSession` über einen eindeutigen Besitzer mit Fehlerbereinigung verwalten.

5. **PINE-Status und Shutdown konsequent abbilden.** `watchPINE` endet nach dem ersten Frame beziehungsweise dem einmaligen Verbindungs-Timeout. Spätere Verfügbarkeit wird nicht mehr abgebildet. Außerdem berücksichtigt `canUseExternalStates` keinen laufenden Shutdown. Bei Wiederaktivierung oder nach Verbindungsfehlern kontrolliert neu verbinden; beim Beenden sofort alle neuen Save-/Load-Aufträge sperren. Für „State loaded“ ist zu beachten, dass die PINE-Antwort nur die Annahme bestätigt: Ohne echte Abschlussbestätigung besser „Laden angefordert“ anzeigen.

## Bereits behobene Befunde vom 07.10.2026

- **Restore bei voller Historie:** `restore` verschiebt den aktuellen Slot ohne vorheriges Pruning und bereinigt erst nach erfolgreichem Restore. Die damalige Löschung des ältesten ausgewählten Eintrags ist damit adressiert. F3 oben betrifft eine andere Konkurrenzsituation.
- **Save-/Load-Befehle erreichen die nächste Session:** Eigene PINE-Ordner pro Start, Warten auf State-Tasks beim normalen Shutdown und Prozessidentitätsprüfungen vor UI-Updates sind vorhanden. F1 betrifft dagegen die weiterhin gemeinsam geschriebene INI.
- **Falsche State-Version nach Rollback:** `EmulatorVersionRecord.saveStateVersion`, Auflösung über die aktive Version und Weitergabe in Launch/Load sind vorhanden. Bei unbekannter älterer Formatversion wird geschlossen abgelehnt.

## Prüfung und Grenzen

**Bestehende Tests:** 68 Tests / 71 Ausführungen einschließlich Parameterfällen, keine Fehler und keine übersprungenen Tests. Ausgeführt wurden `StandaloneLaunchTests`, `ExternalSessionTests`, `EmulatorManagerTests`, `ARMSX2ControlsTests`, `PS2SupportTests`, `PS2SavesTests`, `PINEClientTests`, `ARMSX2ControlTests` und `BIOSManagerTests` über `xcodebuild test` für macOS arm64. Das sind gezielte Tests, kein vollständiger Lauf aller Repository-Tests.

Der erste Versuch innerhalb der Sandbox scheiterte vor den Tests am Signierungszugriff. Die anschließenden regulären lokalen Xcode-Läufe bestanden. Xcode meldete QoS-Warnungen beim Fake-PINE-Testserver; daraus wird hier kein Produktfehler abgeleitet.

**Zusätzliche Reproduktionen:** Ein isoliertes Swift-Programm in `/tmp` kompilierte die unveränderten Dateien `ARMSX2States.swift`, `SaveStates.swift`, `PINEClient.swift`, `ZipArchive.swift` und `FileMerge.swift`. Der Fake-PINE-Server stammt aus den vorhandenen Tests. Nur die außerhalb dieses Ausschnitts liegenden Typen `GraphicsAPI` und `StandaloneLaunchError` wurden minimal ersetzt. Die Reproduktionen verwendeten synthetische Inhalte und temporäre Ordner, keine echten Spielstände. F2, F3, F4 und F6 wurden damit nachgewiesen.

**Upstream-Abgleich:** Für F4 und F5 wurden `SaveState.cpp`, `VMManager.cpp` und `CDVD/InputIsoFile.cpp` aus dem im Plan genannten Commit `46c06fe7ca` gelesen, nicht aus dem wechselnden Hauptbranch.

**Nicht durchgeführt:** Live-Spiele, Controller-/Fullscreen-Prüfungen, echter Emulator-Crash, erzwungene Beschädigung einer Memory Card, vollständiger erneuter Download mit Signaturprüfung oder manueller Rollback zwischen zwei realen Emulator-Versionen. F1 bleibt ein aus dem Kontrollfluss abgeleiteter Race-Befund.

## Empfohlene Umsetzung

Zuerst F1–F3 als gemeinsame Arbeit an der Serialisierung von Launch- und State-Operationen beheben. Danach die Vorprüfung und Formatbehandlung aus F4/F5 sowie die Resume-Auswahl aus F6 ergänzen. Für jeden Fix den beschriebenen Fehlerfall als Regressionstest aufnehmen; anschließend die manuellen Standalone-Checks aus Phase 8 des Plans wiederholen.

## Umsetzung (09.10.2026)

| ID | Status | Änderung | Regressionstest |
|---|---|---|---|
| F1 | behoben | `ARMSX2Launch.prepare` schreibt keine INI mehr. `writeSettings()` (heute `writeSharedFiles()`) läuft nach der letzten Generation-Prüfung und ohne Suspension Point bis zum Prozessstart; dasselbe gilt für das Einstellungsfenster. | `onlyTheLaunchThatStartsTouchesTheSharedFiles`, `preparesArgumentsEnvironmentAndSettings` |
| F2 | behoben | Sobald der Save-Befehl ARMSX2 erreicht haben kann, bleibt die Kopie in der Historie. Zurückgenommen wird sie nur bei `unreachable`/`refused`. Das Manifest wird kopiert statt verschoben und erst nach einem geschriebenen Save neben dem Slot entfernt. | `aSaveThatDoesNotLandInTimeKeepsTheCopy`, `aRefusedSaveLeavesTheSlotAsItWas` |
| F3 | behoben (kleinste robuste Variante) | „Restore“ ist für die States des Standalone-Emulators gesperrt, solange dessen Spiel startet oder läuft (Button, Kontextmenü und Funktion selbst). | – (UI-Sperre; nicht automatisiert getestet) |
| F4 | behoben | `isLoadable` prüft zusätzlich alle Pflichteinträge des Pins (`ARMSX2States.requiredEntries`): vorhanden, nicht leer, Daten vor dem Central Directory. Die Zstd-Nutzdaten werden weiterhin nicht geprüft; der Doc-Kommentar sagt das. | `refusesIncompleteStates` |
| F5 | behoben | `ARMSX2Launch.discImage(for:)`: CUE → erstes Image, das ARMSX2 liest; CCD → `.img`; M3U, ZIP/7z und unbekannte Formate werden mit einer konkreten Meldung abgelehnt. „Create Disc Playlist“ wird für Standalone-Systeme nicht mehr angeboten. | `startsTheDiscImageARMSX2Reads` |
| F6 | behoben | `removeStaleResumeState` entfernt alle regulären Resume-States vor Session-Beginn; zusammengeführte Kopien bleiben. | `noOlderResumeStateMovesUp` |

Weitere Verbesserungen:

- **2 umgesetzt:** Während einer Standalone-Session beobachtet ein FSEvents-Watcher den State-Ordner und lädt die Slots neu. Damit erscheinen Hotkey-Saves und verspätete Saves (F2) auch im offenen Browser.
- **3 umgesetzt:** Ein fehlgeschlagener Restore zeigt eine Meldung. `EmulatorManager.restorePreviousVersion` und `activate` speichern `versions.json` zuerst und übernehmen den Wechsel erst danach; ein Fehler erscheint in Settings › Cores (`goingBackOnlyCountsOnceItIsSaved`).
- **4 umgesetzt:** Der PINE-Ordner wird bei fehlgeschlagener, überholter oder abgebrochener Vorbereitung entfernt.
- **5 teilweise:** Save/Load sind während eines laufenden Shutdowns gesperrt (`canUseExternalStates` und die Funktionen selbst). Ein erneuter PINE-Verbindungsaufbau und der Toast-Text „Laden angefordert“ sind offen.
- **1 offen:** Die Kompatibilität vorab anzeigen müsste beim Rendern das ZIP-Verzeichnis jedes States lesen. Das braucht einen Cache und ist bewusst nicht Teil dieses Fixes.

Offen bleiben außerdem: Ein Save nach einem Timeout kann weiterhin mit dem noch ausstehenden ARMSX2-Auftrag konkurrieren (es geht nur ein unbestätigter State verloren, keine Historie). F6 bindet den automatischen Kandidaten nicht an die Disc-Identität.

**Tests:** 438 Tests in 95 Suites: 436 bestanden, zwei übersprungen (`SlangPresetTests/everyPackPresetRoundTrips`, `ShaderLibraryTests/realPackUnpacksAndIndexes`, beide brauchen `URSPRUNG_SHADER_PACK`), keiner fehlgeschlagen (`xcodebuild test`, macOS arm64). Mit echtem ARMSX2 wurde nicht live geprüft.

Nachträge aus dem [Re-Review](STANDALONE_REREVIEW_2026-10-09.md): R1–R3 und die Log-Datei aus F1 sind dort im Abschnitt „Umsetzung“ beschrieben.
