# Code-Review – Ursprung

## Nachprüfung vom 29.09.2026

**Ergebnis:** Neun der zehn ursprünglichen Findings sind behoben. Die automatische Löschung beim Datenbank-Öffnungsfehler wurde ebenfalls entfernt; in der neuen Backup-Fehlerbehandlung bleibt jedoch ein reproduzierbarer Datenverlustpfad. Finding 1 ist deshalb nur teilweise geschlossen. Die historischen Findings weiter unten beschreiben den Stand der Erstprüfung und sind nicht als zehn weiterhin offene Fehler zu lesen.

### Noch offen: [P1] Backup-Fehlerbehandlung löscht ein bereits vorhandenes Backup

**Fundstelle:** `Ursprung/App/LibraryDatabase.swift:44–56`, insbesondere das bedingungslose `removeItem(at: backup)` in Zeile 56. Zusammenhang mit ursprünglichem Finding 1.

**Auslöser:** Der berechnete Backup-Ordner existiert bereits und enthält eine gleichnamige Datenbankdatei. `createDirectory(..., withIntermediateDirectories: true)` akzeptiert den vorhandenen Ordner. Das anschließende `moveItem` scheitert am bereits vorhandenen Ziel. Der `catch` entfernt daraufhin den gesamten Backup-Ordner, obwohl dessen Inhalt aus einem früheren Sicherungsvorgang stammt. Der Standardname verwendet einen Zeitstempel ohne zusätzliche eindeutige Kennung; eine Namenskollision wird weder verhindert noch abgefangen.

**Auswirkung:** Die aktuelle Datenbank bleibt bei dieser konkreten Kollision erhalten, aber die ältere Sicherung wird unwiederbringlich gelöscht. Das widerspricht dem Zweck der neuen Wiederherstellung. Zusätzlich werden mögliche Fehler beim Zurückverschieben bereits bewegter Dateien mit `try?` ignoriert, bevor der Backup-Ordner entfernt wird; bei fehlgeschlagenem Rollback dürfen die dort verbliebenen Dateien ebenfalls nicht gelöscht werden.

**Reproduziert mit unveränderter `LibraryDatabase.swift`:**

1. Eine temporäre `Library.store` mit Inhalt `original-library` anlegen und `backUp(..., stamp: "same-second")` aufrufen.
2. Am ursprünglichen Pfad eine neue Datenbank mit Inhalt `fresh-library` anlegen.
3. `backUp` erneut mit demselben `stamp` aufrufen.
4. Der zweite Aufruf meldet Fehler 516; das zuvor vorhandene Backup ist danach vollständig verschwunden. Die aktuelle Datei enthält weiterhin `fresh-library`.

Das separate Testprogramm meldete:

```text
Backup before retry: true
Retry failed: 516
Backup after retry: false
Current store: fresh-library
```

**Lösungsansatz:** Für jede Sicherung ein exklusiv neu angelegtes Verzeichnis mit kollisionssicherem Namen verwenden, beispielsweise mit zusätzlicher UUID. Einen vorhandenen Backup-Ordner niemals übernehmen oder beim Aufräumen löschen. Beim Rollback Fehler erfassen und noch im Backup liegende Dateien erhalten; den Ordner nur entfernen, wenn sicher keine benötigten Daten mehr darin liegen. Den Speicherort der erhaltenen Dateien in der Fehlermeldung nennen.

**Fehlender Regressionstest:** Zweimal denselben Backup-Namen verwenden und prüfen, dass beim zweiten Aufruf sowohl das erste Backup als auch die aktuelle Datenbank bytegenau erhalten bleiben. Zusätzlich einen Rollback-Fehler injizieren und sicherstellen, dass die noch gesicherten Dateien nicht entfernt werden. Die bestehenden vier `LibraryDatabaseTests` decken diese Fehlerpfade nicht ab.

### Status der ursprünglichen Findings

| Nr. | Thema | Ergebnis der Nachprüfung | Beleg |
| --- | --- | --- | --- |
| 1 | Automatische Datenbanklöschung | Teilweise behoben; neues P1 oben offen | `LibraryDatabase.open` verlangt eine Entscheidung und behandelt den zweiten Öffnungsfehler. Vier bestehende Tests bestehen; der zusätzliche Backup-Kollisionstest reproduziert Datenverlust. |
| 2 | Kollidierende Batteriespielstände | Behoben | `BatterySave.url` verwendet die Spiel-UUID; die Migration berücksichtigt Mehrdeutigkeit und vorhandene Zieldateien. Vier Tests bestehen. |
| 3 | Ordnerprüfung mit bloßem Präfix | Behoben | `LibraryPaths.isInside` verlangt die Pfadgrenze; verbleibende Ordner werden berücksichtigt. Vier Tests für Pfadgrenzen, Ordnerentfernung und nicht erreichbare Nachbarordner bestehen. |
| 4 | ZIP64-Absturz | Behoben für den gemeldeten Fehler | Die Nutzdaten werden gegen die Grenzen des Zusatzfelds geprüft. Acht ZIP-Robustheitstests einschließlich leerer und verkürzter ZIP64-Felder bestehen. |
| 5 | Spielwechsel während des Ladens | Behoben | Der Runner wird vor `start` registriert; Stop wartet auch während des Ladens. Zwei zusätzliche separate Runner-Prüfungen mit blockierbarem Test-Core bestehen. |
| 6 | Parallele Core-Installation | Behoben | Aufrufer warten auf denselben Installationstask einschließlich System-Assets. Die beiden vorhandenen Tests bestätigen gemeinsames Warten und gemeinsame Fehlerweitergabe. |
| 7 | Veralteter ZIP-Cache bei gleicher Größe | Behoben | Der Cache berücksichtigt Pfad, Größe und CRC32. Drei Tests für geänderte Inhalte, Cache-Wiederverwendung und fehlgeschlagene Extraktion bestehen. |
| 8 | Veraltete Scan-Ergebnisse | Behoben | Eine geänderte Ordnerrevision verwirft das Ergebnis und löst einen erneuten Scan aus. Der Test mit blockiertem Erstscan und geänderter Ordnerliste besteht. |
| 9 | Menüereignisse ausgefilterter HID-Geräte | Behoben laut Kontrollflussprüfung | Der Menü-Callback übergibt das Gerät; der Router prüft dessen Zugehörigkeit zu `hidGamepads`. Der vorhandene Filtertest besteht. |
| 10 | Hängende Eingaben beim Lernen | Behoben laut Kontrollflussprüfung | Lernende Pads liefern bei jedem `push` einen neutralen Zustand unter Beibehaltung ihres Ports. Beginn, Abschluss und Abbruch synchronisieren den Zustand. Der vorhandene Neutralzustandstest besteht. |

### Verifikation dieser Nachprüfung

- **Gesamter Testlauf erfolgreich:** `make test` mit Xcode 27.0 und Ziel `platform=macOS,arch=arm64`. Das XCResult meldet `Passed`, **53 Tests bzw. 65 Testfälle einschließlich Parametern**, null fehlgeschlagene und null übersprungene Tests.
- Ausführung in einer frischen temporären Projektkopie ohne `.env` und ohne echte generierte Zugangsdaten. Ausschließlich in dieser Kopie wurden die Application-Support-/Cache-Pfade auf ein temporäres Verzeichnis und die Bundle-ID auf eine separate Test-ID gelegt, damit die echte Bibliothek und die Einstellungen der App nicht verwendet werden.
- **Runner separat geprüft:** Die unveränderte `UREmulationRunner.m` wurde mit einem blockierbaren Test-Core kompiliert. Stop durfte vor Freigabe des Ladevorgangs nicht abschließen; danach mussten Start- und Stop-Completion eintreffen und im Erfolgsfall das Spiel entladen sein. Erfolgreiches und fehlgeschlagenes Laden bestehen. Die Audioausgabe war im Test-Subclass deaktiviert; der vollständige SwiftUI-Spielwechsel und echte Emulator-Cores wurden nicht praktisch getestet.
- **Backup-Fehler separat reproduziert:** Das oben beschriebene Programm verwendet die unveränderte neue `LibraryDatabase.swift` und ausschließlich temporäre Dateien. Es wurde kein zusätzlicher Test im Projekt angelegt.
- Keine praktischen Controller-Hardwaretests. Die neuen Input-Routing-Tests prüfen Hilfsfunktionen; die vollständige HID-Callback-Kette wurde ergänzend statisch nachvollzogen.
- SHA-256-Abgleich der zu Beginn erfassten Anwendungs-, Test- und Scriptdateien sowie `project.yml` und `Makefile`: unverändert. Für die Nachprüfung wurde im Projekt ausschließlich dieser Bericht aktualisiert.

---

## Erstprüfung – historischer Stand vor den Korrekturen

Stand: 29.09.2026 · Basis: `283e963` einschließlich der vorhandenen uncommitteten Änderungen und neuen Dateien.

Geprüft wurden insbesondere die neue HID-/XInput-Eingabeverarbeitung, deren Integration, Start/Stop der Emulation, Core-Installation, Bibliotheksverwaltung und ZIP-Verarbeitung. Die Findings unterscheiden zwischen bestehenden Problemen und Problemen der neuen Änderungen. Anwendungscode, Konfiguration und vorhandene Tests wurden nicht verändert.

P1 bezeichnet hohe Priorität wegen Datenverlust oder Prozessabsturz; P2 bezeichnet funktionale Fehler, die regulär behoben werden sollten. Die Reihenfolge innerhalb einer Priorität ist keine zusätzliche Bewertung.

### 1. [P1] Bei jedem Fehler beim Öffnen der Datenbank wird die Bibliothek gelöscht

**Fundstelle:** `Ursprung/App/UrsprungApp.swift:38–44` · bestehender Code.

**Auslöser und Auswirkung:** Schlägt die Erstellung des `ModelContainer` fehl, entfernt der allgemeine `catch` unmittelbar `Library.store`. Er unterscheidet nicht zwischen einer tatsächlich beschädigten Datenbank, einem Migrationsproblem oder einem anderen Öffnungsfehler. Damit kann ein grundsätzlich behebbarer Fehler zur Löschung der Bibliothek mit Favoriten, Spielzeiten und Metadaten führen. Scheitert der nächste Versuch ebenfalls, beendet `try!` zusätzlich die App. Die ursprüngliche Datenbank steht dann nicht mehr für eine Wiederherstellung zur Verfügung.

**Lösungsansatz:** Bei einem Öffnungsfehler die bestehenden Dateien erhalten und einen Wiederherstellungsdialog anbieten. Vor einer ausdrücklich gewählten Neuerstellung die Datenbank einschließlich vorhandener SQLite-Sidecars sichern. Den zweiten Initialisierungsversuch ebenfalls mit Fehlerbehandlung ausführen.

**Regressionstest:** Einen Fehler bei der Container-Erstellung injizieren. Prüfen, dass die vorhandenen Datenbankdateien unverändert bleiben und die App einen Fehlerzustand statt einer neuen leeren Bibliothek anzeigt.

### 2. [P1] Gleichnamige ROMs teilen denselben Batteriespielstand

**Fundstellen:** `Ursprung/Emulation/EmulationSession.swift:141–145`, `Ursprung/Library/Game.swift:105–107` · bestehender Code.

**Auslöser und Auswirkung:** Zwei Spiele desselben Systems aus unterschiedlichen Verzeichnissen mit identischem Dateistamm, beispielsweise `Original/Game.sfc` und `Hack/Game.sfc`, erhalten beide den Pfad `Saves/snes/Game.srm`. Auch `Game.sfc` und `Game.smc` kollidieren. Obwohl die Bibliothek sie anhand ihres vollständigen Pfades unterscheidet, lädt und überschreibt die Emulation denselben Batteriespielstand. Bei kompatibler Speichergröße kann das unbemerkt den Fortschritt des anderen Spiels ersetzen.

**Lösungsansatz:** Batteriespielstände über eine eindeutige Spielidentität ablegen, beispielsweise `Saves/<system>/<game.id>/`. Die bisherige Ablage mit einer kontrollierten Migration berücksichtigen; bei mehrdeutigen Dateinamen keinen Spielstand automatisch mehreren Spielen zuordnen.

**Regressionstest:** Zwei Spiele mit gleichem Dateistamm und System, aber unterschiedlichen Pfaden anlegen. Für beide unterschiedliche SRAM-Inhalte speichern und anschließend getrennt laden.

### 3. [P1] Ordnerentfernung löscht auch Spiele aus ähnlich benannten Nachbarordnern

**Fundstellen:** `Ursprung/Library/LibraryStore.swift:35–39` und `88–94` · bestehender Code.

**Auslöser und Auswirkung:** Die Zugehörigkeit zu einem Ordner wird mit `String.hasPrefix` geprüft. `/ROMs/SNES-hacks/Game.sfc` beginnt ebenfalls mit `/ROMs/SNES`. Wird der Bibliotheksordner `/ROMs/SNES` entfernt, werden dadurch auch Datensätze und Medien aus dem eigenständigen Ordner `/ROMs/SNES-hacks` gelöscht. Die gleiche Prüfung kann beim Rescan Spiele eines nicht erreichbaren Ordners fälschlich einem erreichbaren Nachbarordner zuordnen und entgegen dem Kommentar entfernen. Die ROM-Dateien selbst werden dabei nicht gelöscht.

**Lösungsansatz:** Standardisierte Pfade anhand vollständiger Pfadkomponenten vergleichen oder bei der Nachfahrenprüfung einen abschließenden `/` am Elternpfad verlangen. Beim Entfernen zusätzlich prüfen, ob ein Spiel noch von einem anderen konfigurierten Bibliotheksordner abgedeckt wird.

**Regressionstest:** Beide ähnlich benannten Ordner registrieren, einen entfernen und sicherstellen, dass Datensätze, Favoriten und Medien des anderen erhalten bleiben. Einen entsprechenden Rescan mit einem nicht erreichbaren Nachbarordner ergänzen.

### 4. [P1] Verkürzte ZIP64-Zusatzfelder lassen den Prozess abstürzen

**Fundstelle:** `Ursprung/Support/ZipArchive.swift:149–158` · bestehender Code · separat reproduziert.

**Auslöser und Auswirkung:** Die Schleife prüft nur, ob vier Bytes für Tag und Länge vorhanden sind. Bei Tag `0x0001` werden anschließend bis zu drei 64-Bit-Werte gelesen, ohne die deklarierte Feldlänge und die verbleibenden Bytes zu prüfen. Ein Verzeichniseintrag mit `uncompressedSize = 0xFFFFFFFF` und einem ZIP64-Feld der Länge null erreicht `directory.uint64(at: cursor)` hinter dem Datenende. Das führt zu einem Bounds-Trap statt zu `ZipError.corrupt`. Ein solches Archiv kann bereits bei der Systemerkennung während eines Bibliotheksscans den gesamten Prozess beenden; `try?` fängt den Trap nicht ab.

**Nachweis:** Ein separates Programm mit der unveränderten `ZipArchive.swift` wurde kompiliert. Ein gültiges ZIP wurde erfolgreich gelesen (Exit 0, ein Eintrag). Ein 73 Byte großes Archiv mit dem beschriebenen verkürzten Zusatzfeld beendete denselben Prozess mit Signal 5 (`SIGTRAP`, Python-Rückgabewert `-5`).

**Lösungsansatz:** Vor jedem Zugriff sowohl das Ende des jeweiligen Zusatzfelds als auch das Ende des Verzeichnispuffers prüfen. Die nötige ZIP64-Nutzdatenlänge aus den gesetzten Sentinel-Werten berechnen und unvollständige Felder mit `ZipError.corrupt` ablehnen. Auch Größenkonvertierungen und Offset-Arithmetik auf ungültige Werte prüfen.

**Regressionstest:** ZIP64-Felder mit null, sieben und sonst unzureichenden Nutzdatenbytes einlesen. Alle müssen einen regulären Fehler liefern, ohne den Prozess zu beenden.

### 5. [P2] Ein noch ladender Runner wird beim Spielwechsel nicht abgewartet

**Fundstellen:** `Ursprung/Emulation/EmulationSession.swift:152–169` und `237–239`; ergänzend `Ursprung/Bridge/URLibretroCore.m:246–253` · bestehender Code.

**Auslöser und Auswirkung:** Während `runner.start(...)` auf das Laden eines Spiels wartet, existiert der Runner nur als lokale Variable. `self.runner` wird erst nach erfolgreichem Laden gesetzt. Startet der Nutzer währenddessen ein zweites Spiel, findet `shutDownRunner` keinen Runner und kehrt sofort zurück. Das zweite Spiel kann deshalb seinen Core starten, während der erste Core noch lädt. Die Bridge lehnt diesen Versuch mit „Another game is already running.“ ab. Die Generation-Prüfung räumt den ersten Runner erst nach dessen Ladeabschluss auf und verhindert den fehlgeschlagenen zweiten Start nicht.

**Lösungsansatz:** Auch die Vorbereitung bzw. den Start eines Runners als verwalteten Vorgang registrieren und vor dem nächsten Core-Start dessen vollständige Beendigung abwarten. Dabei beachten: `stopWithCompletion` kehrt derzeit bei `running == false` sofort zurück; ein bloßes früheres Setzen von `self.runner` genügt deshalb nicht. Der Runner benötigt einen expliziten Zustand für „lädt“ und eine darauf abgestimmte Stop-/Completion-Semantik.

**Regressionstest:** Einen Test-Core mit blockierbarem `load_game` verwenden. Während Spiel A lädt, Spiel B starten bzw. das Fenster schließen und neu starten. B darf erst nach dem vollständigen Abbau von A laden und muss ohne Belegungsfehler starten.

### 6. [P2] Ein zweiter Installationsaufruf wartet nicht auf den laufenden Download

**Fundstelle:** `Ursprung/Cores/CoreManager.swift:54–64` · bestehender Code.

**Auslöser und Auswirkung:** Läuft die Erstinstallation eines Cores bereits, kehrt `install` wegen `downloads[core.id] != nil` erfolgreich zurück. Ein paralleler `ensureInstalled`-Aufruf erhält dadurch bei einem Core ohne zusätzliche System-Assets sofort den Zielpfad, obwohl die Dylib noch nicht existiert. Beispielsweise kann der Start eines Spiels während der Installation über die Einstellungen mit einem Ladefehler abbrechen. Die Fortschrittsanzeige wird hier gleichzeitig als Synchronisationsmechanismus verwendet, enthält aber kein abwartbares Ergebnis.

**Lösungsansatz:** Pro Core einen gemeinsamen Installationstask speichern. Weitere Aufrufer warten auf dessen Ergebnis und erhalten denselben Erfolg oder Fehler. Dylib und erforderliche System-Assets sollten Bestandteil dieses vollständigen Installationsvorgangs sein; die Fortschrittsdaten bleiben davon getrennt.

**Regressionstest:** Zwei `ensureInstalled`-Aufrufe mit verzögertem Download starten. Nur ein Download darf erfolgen; beide Aufrufe dürfen erst nach der vollständigen Installation erfolgreich zurückkehren. Den gemeinsamen Fehlerfall ebenfalls prüfen.

### 7. [P2] Ein gleich großer ROM-Austausch verwendet weiterhin den alten ZIP-Cache

**Fundstelle:** `Ursprung/Emulation/EmulationSession.swift:214–222` · bestehender Code.

**Auslöser und Auswirkung:** Ein bereits entpacktes ROM wird ausschließlich anhand seiner Dateigröße als aktuell bewertet. Wird das ZIP am selben Pfad durch eine gepatchte oder korrigierte Fassung mit gleichem inneren Dateinamen und gleicher unkomprimierter Größe ersetzt, bleibt die Spiel-ID erhalten und die alte Cache-Datei wird erneut gestartet. Gleich große ROM-Patches sind damit trotz ersetzter Quelldatei nicht wirksam.

**Lösungsansatz:** Den Cache an eine Inhaltsidentität des Archiveintrags binden, mindestens an dessen bereits verfügbaren CRC32-Wert zusammen mit Pfad und Größe. Die Identität separat speichern oder die Cache-Datei dagegen prüfen. Nach fehlgeschlagener Extraktion keine gültige Cache-Markierung hinterlassen.

**Regressionstest:** ZIP A starten, anschließend am gleichen Pfad durch ZIP B mit gleichem Eintragsnamen und gleicher Größe, aber anderen Bytes ersetzen. Der nächste Start muss den Inhalt von B erhalten.

### 8. [P2] Ordneränderungen während eines Scans werden mit einem veralteten Stand überschrieben

**Fundstelle:** `Ursprung/Library/LibraryStore.swift:57–64` und die anschließende Übernahme in `70–95` · bestehender Code.

**Auslöser und Auswirkung:** `rescan` kopiert die Ordnerliste vor dem `await`. Während der Hintergrundscan läuft, können `addFolder` und `removeFolder` diese Liste verändern. Ein dabei angeforderter weiterer Scan wird durch `guard !isScanning` verworfen. Der erste Scan übernimmt anschließend Ergebnisse seines alten Snapshots: Bereits entfernte Ordner können wieder Spiele liefern; neu hinzugefügte Ordner werden nicht eingelesen, bis der Nutzer später erneut scannt. Bei währenddessen entfernten Spielen können neue Datensätze mit neuen IDs entstehen, statt die ursprünglichen Metadaten zu erhalten.

**Lösungsansatz:** Änderungen an der Ordnerliste über eine Generation oder Revision verfolgen. Ergebnisse eines überholten Scans nicht übernehmen und anschließend mit dem aktuellen Stand erneut scannen. Alternativ laufende Scans kontrolliert abbrechen und genau einen Folgescan vormerken.

**Regressionstest:** Einen Scan vor der Ergebnisrückgabe anhalten, währenddessen einen Ordner entfernen und einen anderen hinzufügen. Nach Freigabe muss die Bibliothek ohne zusätzlichen manuellen Rescan exakt den aktuellen konfigurierten Ordnern entsprechen.

### 9. [P2] Ausgefilterte HID-Geräte können weiterhin das Spielmenü auslösen

**Fundstellen:** `Ursprung/Emulation/HIDGamepadManager.swift:164–176`, `Ursprung/Emulation/InputRouter.swift:22–33` · neue Controller-Unterstützung.

**Auslöser und Auswirkung:** Der Router filtert von GameController behandelte HID-Geräte aus `hidGamepads` heraus. Der HID-Manager nimmt diese Geräte dennoch in seine eigene Liste auf und ruft für alle Geräte `onMenuButton` auf. Dieser Callback ist direkt mit dem Menü-Toggle verbunden und durchläuft den Filter nicht. Bei einem ausgeschlossenen Gerät mit einer HID-Menübelegung kann daher eine Taste zusätzlich das Menü öffnen. Wird dieselbe physische Home-Taste auch über GameController gemeldet, kann das Menü zweimal umgeschaltet werden und dadurch scheinbar nicht reagieren. Welche Taste betroffen ist, hängt vom HID-Deskriptor und der gespeicherten bzw. geratenen Belegung ab.

**Lösungsansatz:** Die Entscheidung über die zuständige Eingabequelle auch auf Menüereignisse anwenden. Beispielsweise die Geräteidentität im HID-Callback mitgeben und im Router dieselbe Zulässigkeitsprüfung nutzen wie für den Pad-Zustand. Die Gerätezuordnung bei Verbindungsänderungen aktualisieren.

**Regressionstest:** Ein durch den Router ausgeschlossenes HID-Gerät mit gültiger Menübelegung simulieren. Sein HID-Ereignis darf kein Menü-Toggle auslösen; die autorisierte GameController-Quelle muss genau eines auslösen. Die betroffenen Hardwarekombinationen wurden in diesem Review nicht praktisch getestet.

### 10. [P2] Der Lernmodus kann gedrückte Eingaben im Core hängen lassen

**Fundstelle:** `Ursprung/Emulation/HIDGamepadManager.swift:141–146` und `169–177`; ergänzend `Ursprung/Emulation/InputRouter.swift:159–160` · neue Controller-Unterstützung.

**Auslöser und Auswirkung:** Während des Lernens wird der Snapshot aktualisiert, aber die Funktion kehrt vor `onInput` zurück. Auch `cancelLearning` synchronisiert den Zustand nicht. Wird beispielsweise eine bereits im Spiel gehaltene Taste während des Lernens losgelassen und die Zuordnung anschließend abgebrochen, bleibt die Taste im Core bis zum nächsten weitergeleiteten Eingabeereignis gedrückt. Umgekehrt ist die dokumentierte Unterdrückung nicht vollständig: Ein Tastaturereignis oder ein anderer Controller kann `InputRouter.push()` auslösen, das den aktuellen Snapshot des gerade lernenden Pads trotzdem übernimmt.

**Lösungsansatz:** Lernende Pads im Router ausdrücklich von der Spiel-Eingabe ausschließen. Beim Eintritt einen neutralen Zustand und beim Abschluss bzw. Abbruch den aktuellen zulässigen Zustand an den Core übertragen. Die Unterdrückung muss für alle Auslöser von `push()` gelten, nicht nur für den HID-Callback.

**Regressionstest:** Taste halten, Lernen beginnen, Taste loslassen, Lernen abbrechen und danach keine weitere Eingabe senden: Der Core muss neutral sein. Zusätzlich während des Lernens Tastatur und zweiten Controller betätigen und sicherstellen, dass keine Eingabe des lernenden Pads durchgereicht wird.

### Durchgeführte Verifikation und Grenzen

- Statische Prüfung des aktuellen Quellstands einschließlich der neuen, noch unversionierten Controller-Dateien. Weitere nicht aufgeführte Auffälligkeiten wurden nicht als bestätigte Findings aufgenommen.
- Projekt und Test-Target in einer temporären Kopie ohne `.env` oder echte generierte Zugangsdaten erfolgreich mit Xcode 27.0, Ziel `platform=macOS,arch=arm64`, gebaut: `xcodebuild -project Ursprung.xcodeproj -scheme Ursprung -derivedDataPath build/DerivedData -destination 'platform=macOS,arch=arm64' build-for-testing -quiet` (Exit 0).
- Der erste Versuch mit `make test` scheiterte an Sandbox-Beschränkungen für Swift-Makros bzw. Xcode-Dienste. Der anschließende Build außerhalb dieser Sandbox war erfolgreich. Die vorhandene Testsuite wurde damit kompiliert, aber nicht erfolgreich ausgeführt; es wird kein bestandener Testlauf behauptet.
- Separater ausführbarer ZIP-Reproduktionstest mit unverändertem Parser: gültiges Archiv erfolgreich gelesen, beschädigtes ZIP64-Zusatzfeld reproduzierbar mit `SIGTRAP` abgestürzt.
- Die anderen Findings ergeben sich aus den angegebenen Daten- und Kontrollflüssen. Die beschriebenen Regressionstests sind Vorschläge und wurden nicht dem Projekt hinzugefügt. Keine praktischen Tests mit Controllern oder echten ROMs/Core-Downloads durchgeführt.

Die einzige für dieses Review im Projekt neu angelegte Datei ist dieser Bericht.
