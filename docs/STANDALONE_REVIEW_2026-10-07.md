<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# Review: Standalone / ARMSX2

**Datum:** 07.10.2026 · **Branch:** `feature/ps2-armsx2`  
**Vergleich:** `main` (`2b278e1`) → `e4941790fd096aa03c37ffe81b6d5053edb8027a`  
**Umfang:** Umsetzung von `docs/STANDALONE_PLAN.md`; nur die wichtigsten Fehler mit Datenverlust- oder Absturzrisiko.

## 1. P1 – Wiederherstellen kann den ausgewählten Spielstand endgültig löschen

**Stelle:** [ARMSX2States.swift:148](</Users/ben/Projekte/Ursprung - Retro Games Library for Mac/Ursprung/Emulation/ARMSX2States.swift:148>)

Bei einer vollen Historie mit 20 Einträgen den ältesten Stand in einen belegten Slot zurückholen: `restore` archiviert zuerst den aktuellen Slot. Dabei begrenzt `archive` die Historie sofort wieder auf 20 Einträge und löscht genau den ausgewählten ältesten Stand. Das anschließende Verschieben dieser Datei schlägt fehl.

**Folge:** Der gewünschte historische Spielstand ist verloren, der aktive Slot bleibt leer. Der zuvor aktive Stand liegt immerhin noch in der Historie.

**Nachweis:** Mit unverändertem Originalcode und temporären Dateien reproduziert: Restore-Fehler, Quelldatei gelöscht, Zieldatei nicht vorhanden.

**Vorschlag:** Den ausgewählten Stand vorab sichern und die Historie erst nach erfolgreichem Restore bereinigen. Bei Fehlern den bisherigen Slot zurücksetzen. Regressionstest: ältesten von 20 Einträgen in einen belegten Slot wiederherstellen.

## 2. P1 – Ein Speicherauftrag kann nach dem Spielwechsel das falsche Spiel überschreiben

**Stellen:** [EmulationSession.swift:1277](</Users/ben/Projekte/Ursprung - Retro Games Library for Mac/Ursprung/Emulation/EmulationSession.swift:1277>), [ARMSX2States.swift:214](</Users/ben/Projekte/Ursprung - Retro Games Library for Mac/Ursprung/Emulation/ARMSX2States.swift:214>)

Save-/Load-Tasks werden beim Beenden nicht abgewartet oder an die Session-Generation gebunden. Gleichzeitig kann das nächste Spiel denselben PINE-Socket-Pfad erhalten; jeder einzelne PINE-Aufruf baut eine neue Verbindung auf. Wechselt der Prozess zwischen Identitätsabfrage und Speicherbefehl, erreicht ein noch laufender Auftrag für Spiel A den Emulator von Spiel B.

**Folge:** Der Auftrag kann einen Slot von B überschreiben, obwohl nur der alte Stand von A archiviert wurde. Auch ein verspäteter Ladebefehl kann B unerwartet zurücksetzen. Alte Tasks verändern zudem den Busy-Status der neuen Session.

**Nachweis:** Mit Original-PINE-/Save-Code und zwei Fake-Servern am nacheinander belegten Socket reproduziert: Nach dem kontrollierten Endpunktwechsel empfängt Server B den für A begonnenen Speicherbefehl. Kein Live-Spielwechsel im echten ARMSX2 getestet.

**Vorschlag:** Einen eigenen Socket-Pfad je Session verwenden und Save-/Load-Tasks beim Shutdown kontrolliert abschließen oder abbrechen. Vor Befehlen und UI-Updates die Session-Generation prüfen; Cancellation muss auch im PINE-/State-Code berücksichtigt werden.

## 3. P1 – Nach einem Rollback wird gegen die falsche Spielstand-Version geprüft

**Stellen:** [EmulationSession.swift:600](</Users/ben/Projekte/Ursprung - Retro Games Library for Mac/Ursprung/Emulation/EmulationSession.swift:600>), [EmulationSession.swift:528](</Users/ben/Projekte/Ursprung - Retro Games Library for Mac/Ursprung/Emulation/EmulationSession.swift:528>), [EmulatorManager.swift:339](</Users/ben/Projekte/Ursprung - Retro Games Library for Mac/Ursprung/Cores/EmulatorManager.swift:339>)

Die Versionsverwaltung kann eine ältere ARMSX2-Version starten. Resume, „Play from Here“ und PINE-Load prüfen jedoch weiterhin gegen `emulator.saveStateVersion` aus dem aktuellen Katalog-Pin. Die installierten Versionsdatensätze speichern keine eigene Formatversion.

**Folge:** Sobald ein Pin-Wechsel das Spielstandsformat verändert, kann Ursprung nach einem Rollback einen für den alten Emulator zu neuen Stand freigeben. Damit versagt die Schutzprüfung vor dem im Plan dokumentierten Fehlerdialog-Absturz; umgekehrt können passende alte Stände abgewiesen werden.

**Nachweis:** Aus dem vollständigen Rollback-/Launch-Kontrollfluss belegt. Bedingter Fehler bei unterschiedlichen Formatversionen; kein Absturz mit zwei realen Emulator-Versionen reproduziert.

**Vorschlag:** Formatversion und notwendige Launch-Metadaten pro installierter Version speichern. Alle Prüfungen müssen die tatsächlich gestartete Version verwenden. Regressionstest mit zwei Pins unterschiedlicher Formatversion und anschließendem Rollback.

## Prüfung

Die gezielten Standalone-, BIOS-, Controls-, Installer-, Prozess-, PINE- und Save-Tests bestanden: **59 Tests / 62 Ausführungen, keine Fehler oder übersprungenen Tests**. Zusätzlich wurden die oben beschriebenen isolierten Reproduktionen ausgeführt. Anwendungscode und Repository-Tests wurden nicht geändert; der bereits vorhandene Review-Bericht blieb unverändert.
