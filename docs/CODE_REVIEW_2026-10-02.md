# Umfangreicher Code-Review – Ursprung

**Datum:** 02.10.2026 · **Basis:** `b5a9e1d7ca9d2ed5e515550189637f580dab3093` (`main`) · **Art:** erneute Prüfung des aktuellen Gesamtstands.

## Ergebnis

**12 belegte Befunde: 4 × P1 und 8 × P2.** Die wichtigsten Probleme betreffen den Verlust von Bibliotheksdaten bei Scans, einen destruktiven BIOS-Import und die Lebensdauer von Optionswerten in der nativen Bridge. Alle zwölf Befunde wurden mit gezielten Prüfungen ihrer jeweiligen Fehlermechanismen bestätigt. Die vollständigen Benutzerabläufe mit echten Emulator-Cores und Controller-Hardware wurden nicht praktisch nachgestellt.

Die vorhandene Testsuite besteht: **110 Tests / 136 Testfälle einschließlich Parametrisierungen, keine Fehler, keine übersprungenen Tests.** Zusätzlich lässt sich die Release-Konfiguration erfolgreich bauen. Die neuen Reproduktionen zeigen Fehlerpfade, die die vorhandenen Tests noch nicht abdecken.

**Am ursprünglichen Anwendungscode, an Tests, Konfiguration und Scripts wurde nichts geändert.** Die einzige im Projekt neu angelegte Datei ist dieser Bericht. Der ältere Bericht bleibt unverändert; seine als offen bezeichnete Backup-Schwachstelle ist im heutigen Code inzwischen behoben.

### Prioritäten

- **P1 – hoch:** zeitnah beheben; reproduzierbarer Datenverlust oder ungültiger nativer Speicherzugriff.
- **P2 – mittel:** konkreter Funktions- oder Integritätsfehler mit benennbarem Auslöser.

| Nr. | Priorität | Befund | Nachweis |
| --- | --- | --- | --- |
| 1 | P1 | Überlappende Bibliotheksordner überschreiben Identität, Favoriten und Spielzeit | SwiftData-Reproduktion |
| 2 | P1 | Unlesbare Unterordner werden als gelöschte Spiele behandelt | Dateisystem-/SwiftData-Reproduktion |
| 3 | P1 | Erneuter Import einer installierten BIOS-Datei löscht die Quelldatei | Import-Reproduktion |
| 4 | P1 | Geänderte Core-Optionen können bereits ausgegebene C-Zeiger freigeben | AddressSanitizer: `heap-use-after-free` |
| 5 | P2 | Audio-Reset konkurriert mit dem Leser und macht verworfene Samples wieder verfügbar | C-Test mit zwei Threads |
| 6 | P2 | Neue Metadaten-Aufträge können nach „Stop“ dauerhaft liegen bleiben | Kontrollierte Task-Abfolge |
| 7 | P2 | Gleich große ROM-Ersetzungen behalten eine veraltete CRC32 | Scan-Reproduktion |
| 8 | P2 | Ersetzte Bilder und Spielstand-Thumbnails bleiben im Cache veraltet | Bildcache-Reproduktion |
| 9 | P2 | ZIP-Extraktion akzeptiert beschädigte Nutzdaten ohne CRC-Prüfung | Beschädigtes Testarchiv |
| 10 | P2 | Die BIOS-Prüfung akzeptiert eine unvollständige Intellivision-Firmware | BIOS-Status-Reproduktion |
| 11 | P2 | Playlists unterdrücken referenzierte Discs in Unterordnern nicht | Scanner-Reproduktion |
| 12 | P2 | Fast Forward bleibt nach einem Fokusverlust aktiv | Zustandsprüfung nach App-Deaktivierung |

## Befunde im Detail

### 1. [P1] Überlappende Bibliotheksordner überschreiben bestehende Spieldaten

**Fundstellen:** [LibraryStore.swift:116](<../Ursprung/Library/LibraryStore.swift:116>), insbesondere Zeilen 118–128; [LibraryScanner.swift:31](<../Ursprung/Library/LibraryScanner.swift:31>).

**Auslöser:** Sowohl einen übergeordneten Ordner als auch einen enthaltenen Systemordner registrieren, beispielsweise `/ROMs` und `/ROMs/SNES`, und erneut scannen. `addFolder` verhindert nur identische Einträge. Der Scanner hängt die Ergebnisse aller Ordner zusammen und liefert das gleiche ROM mehrfach.

**Ursache und Auswirkung:** Beim ersten Auftreten entfernt `apply` das vorhandene Spiel mit `byPath.removeValue(forKey:)` aus dem Nachschlageverzeichnis. Das zweite Auftreten wird deshalb als neues Spiel behandelt. SwiftData führt den neuen Datensatz aufgrund des eindeutigen `path` mit dem bestehenden zusammen und übernimmt dabei dessen neu initialisierte Werte. Im Test blieb genau ein Spiel erhalten, aber mit **neuer UUID, `isFavorite = false` und `playTime = 0` statt 1234 Sekunden**. Damit ändern sich auch die UUID-basierten Verzeichnisse für SRAM, Save States und Medien; vorhandene Dateien werden über die neue Spielidentität nicht mehr gefunden.

**Reproduktion:** Ein Spiel aus `SNES/Game.sfc` speichern, als Favorit markieren und Spielzeit setzen. Mit beiden Ordnern scannen. Die Assertions für stabile UUID, Favorit und Spielzeit schlagen fehl. Die Spieldatei selbst bleibt bestehen.

**Lösungsvorschlag:** Scan-Ergebnisse vor der Übernahme anhand normalisierter absoluter Pfade deduplizieren. Den Bestand für die gesamte Verarbeitung als Lookup erhalten und separat festhalten, welche Pfade gesehen wurden. Überschneidungen in der Ordnerliste dürfen keine Datenneuanlage auslösen.

**Regressionstest:** Eltern- und Kindordner gemeinsam scannen, auch nach App-Neustart. UUID, Metadaten, Favorit, Spielzeit und Zuordnung vorhandener Saves müssen unverändert bleiben.

### 2. [P1] Ein unlesbarer Unterordner löscht Bibliothekseinträge und Medien

**Fundstellen:** [LibraryScanner.swift:42](<../Ursprung/Library/LibraryScanner.swift:42>), Zeilen 42–48; [LibraryStore.swift:102](<../Ursprung/Library/LibraryStore.swift:102>) und [LibraryStore.swift:137](<../Ursprung/Library/LibraryStore.swift:137>).

**Auslöser:** Ein bereits eingelesener Unterordner wird unlesbar, während sein registrierter Elternordner weiterhin existiert. Denkbar sind geänderte Rechte oder Zugriffsfehler während eines Scans. Praktisch geprüft wurde ein entzogener Lese-/Suchzugriff mittels Dateirechten.

**Ursache und Auswirkung:** Der Scanner liefert ausschließlich gefundene Spiele, ohne Fehler- oder Vollständigkeitsstatus. Verzeichnis- und Ressourcenfehler werden nicht an den Store weitergegeben. Dieser betrachtet einen Ordner bereits bei `fileExists` als erreichbar und interpretiert jedes fehlende Ergebnis darunter als verschwundenes ROM. Er entfernt den Datensatz und sein Medienverzeichnis. Favoriten, Spielzeiten und Spielidentität gehen verloren; die ROM-Datei existiert weiterhin.

**Reproduktion:** Ein Spiel in einem Unterordner einlesen, dessen Rechte auf `000` setzen und den übergeordneten Bibliotheksordner erneut scannen. Der Test erwartet weiterhin einen Datensatz, findet aber **null**. Die Rechte wurden im Test anschließend wiederhergestellt. Es wurden ausschließlich temporäre Dateien verwendet.

**Lösungsvorschlag:** Scanner-Ergebnisse um erfolgreich vollständig gelesene Bereiche und Fehler ergänzen. Fehlende Spiele nur aus sicher vollständig gescannten Bereichen entfernen. Zugriffsfehler als Warnung anzeigen und bestehende Datensätze in betroffenen Bereichen erhalten.

**Regressionstest:** Unlesbarer Unterordner sowie ein während des Scans auftretender Lesefehler. Die Bibliotheksdaten und Medien der betroffenen Spiele müssen erhalten bleiben; ein tatsächlich gelöschtes ROM aus einem erfolgreich gescannten Bereich soll weiterhin entfernt werden.

### 3. [P1] Der Selbstimport eines BIOS löscht die installierte Datei

**Fundstelle:** [BIOSManager.swift:93](<../Ursprung/Cores/BIOSManager.swift:93>), insbesondere Zeilen 95–100.

**Auslöser:** Über „Open System Folder“ eine bereits installierte BIOS-Datei auswählen und diese erneut importieren; alternativ den Systemordner selbst in die Importfläche ziehen.

**Ursache und Auswirkung:** Vor dem Kopieren wird eine existierende Zieldatei gelöscht. Wenn Quelle und Ziel dieselbe Datei sind, entfernt der Import damit seine eigene Quelle. Das anschließende `copyItem` scheitert. Die UI erhält lediglich einen Eintrag unter `unknown` und zeigt „Not Recognized“, obwohl eine zuvor vorhandene BIOS-Datei gelöscht wurde. Auch bei einer anderen Quelle kann ein Kopierfehler nach dem Löschen das bisher funktionierende Ziel verlieren lassen.

**Reproduktion:** Eine synthetische `System/disksys.rom` anlegen und deren URL an `importFiles` übergeben. Danach liefert `fileExists` **false**. Für die Reproduktion genügt die ohnehin unterstützte Erkennung am Dateinamen; echte BIOS-Inhalte wurden nicht benutzt.

**Lösungsvorschlag:** Quelle und Ziel einschließlich ihrer tatsächlichen Dateiidentität vergleichen und den Selbstimport ohne Löschung behandeln. Andere Importe zuerst in eine temporäre Datei kopieren und erst nach Erfolg atomar ersetzen. Kopierfehler von unbekannten Dateien unterscheiden.

**Regressionstest:** Selbstimport, derselbe Pfad mit abweichender Großschreibung auf einem entsprechenden Dateisystem und fehlgeschlagener Ersatz einer vorhandenen Datei. Der vorherige Inhalt muss erhalten bleiben.

### 4. [P1] Core-Optionswerte können nach ihrer Ausgabe an den Core freigegeben werden

**Fundstellen:** [URLibretroCore.m:564](<../Ursprung/Bridge/URLibretroCore.m:564>), insbesondere Zeile 575; [URLibretroCore.m:536](<../Ursprung/Bridge/URLibretroCore.m:536>); [EmulationSession.swift:486](<../Ursprung/Emulation/EmulationSession.swift:486>), Zeilen 486–498.

**Auslöser:** Der Core erhält über `GET_VARIABLE` den C-Zeiger eines Optionswerts. Bevor er diesen Wert fertig gelesen hat, wird derselbe Wert von der UI ersetzt oder zurückgesetzt.

**Ursache und Auswirkung:** `optionValueCString` gibt `NSData.bytes` zurück. Die Synchronisierung schützt nur den Zugriff innerhalb der Methode, nicht die nachfolgende Verwendung des Zeigers durch den Core. `storeOption` ersetzt das einzige dauerhaft gehaltene `NSData` und kann dadurch den zuvor ausgegebenen Speicher freigeben. `setCoreOption` und `resetCoreOptions` schreiben direkt auf dem MainActor, ohne Übergabe an die Emulations-Command-Queue. Ein angefordertes Pausieren ist keine Bestätigung, dass ein bereits laufender Core-Aufruf beendet ist.

**Nachweis:** Die unveränderte native Bridge wurde zusammen mit einem minimalen synthetischen Core und einem separaten Testprogramm mit AddressSanitizer kompiliert. Das Testprogramm holt einen Optionszeiger, ersetzt den Wert und liest anschließend den alten Zeiger. Ergebnis: **`AddressSanitizer: heap-use-after-free`**, Prozessabbruch mit Exit 134. Der Freigabe-Stack führt über `storeOption:value:` und `setValue:forOption:`. Der Test belegt die Speicherlebensdauer; er ist kein beobachteter Absturz eines realen Spiels in der UI.

**Lösungsvorschlag:** Änderungen mindestens zwischen Core-Aufrufen auf dem Emulationsthread anwenden und eine definierte Lebensdauer ausgegebener Optionsstrings sicherstellen. Falls Cores Zeiger länger halten dürfen, alte Werte entsprechend lange behalten. Ein Lock ausschließlich um den Dictionary-Zugriff reicht nicht aus.

**Regressionstest:** Einen Test-Core zwischen Optionsabfrage und Auswertung anhalten, parallel den Wert ändern und die Auswertung fortsetzen. Unter AddressSanitizer darf kein ungültiger Zugriff auftreten. Auch das Zurücksetzen mehrerer Optionen prüfen.

### 5. [P2] Audio-Reset und Audio-Leser schreiben gleichzeitig den Leseindex

**Fundstellen:** [URAudioRing.c:21](<../Ursprung/Bridge/URAudioRing.c:21>) und [URAudioRing.c:47](<../Ursprung/Bridge/URAudioRing.c:47>), insbesondere Zeile 63; Aufruf bei [UREmulationRunner.m:173](<../Ursprung/Bridge/UREmulationRunner.m:173>).

**Auslöser:** Fast Forward oder die Überfüllungskorrektur leert den Ring auf dem Emulationsthread, während der Audiothread gerade Samples liest.

**Ursache und Auswirkung:** `URAudioRingClear` setzt `readIndex` auf den aktuellen Schreibindex. Ein bereits laufender Leser hält jedoch einen älteren lokalen Wert `r` und schreibt am Ende unconditionally `r + n` zurück. Damit kann er den Reset rückgängig machen und bereits verworfene Daten erneut verfügbar machen. Zusätzlich kann der Produzent nach dem Reset wieder Speicher beschreiben, den der alte Lesevorgang noch verwendet. Atomare Indexzugriffe allein lösen diesen Konflikt nicht.

**Reproduktion mit unveränderter C-Datei:** Ein separater Zwei-Thread-Test verwendet einen vergrößerten Ring, um das Zeitfenster sicher zu treffen:

```text
Immediately after clear: read=8000000 available=0
After already-running read completes: read=4000000 available=4000000
```

Ohne einen weiteren Schreibvorgang erscheinen vier Millionen zuvor verworfene Frames wieder als verfügbar. In der App sind veraltete bzw. gestörte Audioausgaben und falsche Füllstände möglich. Hörbare Aussetzer mit realer Audiohardware wurden nicht gemessen.

**Lösungsvorschlag:** Den Consumer allein für seinen Leseindex verantwortlich machen, beispielsweise einen Reset-Auftrag auf dem Audiothread verarbeiten oder den Consumer vor einem Reset sicher anhalten. Dabei auch die Lebensdauer der noch gelesenen Samplebereiche berücksichtigen.

**Regressionstest:** Überlappende Read-/Clear-/Write-Vorgänge gezielt synchronisieren. Ein abgeschlossenes Clear darf keine alten Samples wieder verfügbar werden lassen.

### 6. [P2] Nach Abbruch können neu eingereihte Metadaten-Aufträge ohne Worker bleiben

**Fundstellen:** [MetadataService.swift:24](<../Ursprung/Metadata/MetadataService.swift:24>), Zeilen 24–44; [MetadataService.swift:70](<../Ursprung/Metadata/MetadataService.swift:70>), Zeilen 70–75.

**Auslöser:** Metadatenabruf stoppen und einen neuen Abruf anfordern, bevor der abgebrochene Worker vollständig ausgelaufen ist. Das kann auch durch einen Scan mit neuen Spielen passieren.

**Ursache und Auswirkung:** `cancel` markiert den Worker als abgebrochen und leert die Queue, lässt `worker` aber gesetzt. Ein folgender `enqueue` fügt neue IDs hinzu; `startIfNeeded` startet wegen des vorhandenen Workers nichts. Der alte Task endet anschließend wegen seiner Cancellation, setzt `worker = nil` und startet die inzwischen gefüllte Queue nicht erneut. Ein weiterer Abruf derselben Spiele wird durch die Deduplizierung verworfen. Die UI zeigt keine laufende Verarbeitung, obwohl Arbeit aussteht.

**Reproduktion:** `enqueue(A)`, `cancel()`, `enqueue(B)` vor dem ersten Task-Yield ausführen. Das Ende des Workers abwarten und B nochmals anfordern. **B bleibt `.pending`.** Der isolierte Build besitzt keine API-Zugangsdaten: Eine tatsächlich ausgeführte Anfrage würde unmittelbar `.failed` ergeben. Der Test benötigt keinen Netzwerkzugriff.

**Lösungsvorschlag:** Worker und Queue über eine eindeutige Generation verwalten. Nach dem Ende eines abgebrochenen Workers gegebenenfalls einen neuen Worker für später hinzugefügte Aufträge starten. Deduplizierung darf das Starten einer vorhandenen, aber inaktiven Queue nicht verhindern.

**Regressionstest:** Abbrechen während einer blockierten Anfrage, neue Spiele einreihen und denselben Abruf wiederholen. Neue Arbeit muss genau einmal verarbeitet werden.

### 7. [P2] ROM-Austausch bei gleicher Größe lässt die gespeicherte CRC32 unverändert

**Fundstellen:** [LibraryStore.swift:120](<../Ursprung/Library/LibraryStore.swift:120>), Zeilen 120–123; Verwendung bei [MetadataService.swift:81](<../Ursprung/Metadata/MetadataService.swift:81>), Zeilen 81–89.

**Auslöser:** Ein ROM am bestehenden Pfad durch eine andere Version oder einen Patch gleicher Größe ersetzen und neu scannen. Der gleiche Fehler betrifft ZIPs, deren äußere Größe unverändert bleibt, obwohl der Scanner einen anderen CRC-Wert des Eintrags erkennt.

**Ursache und Auswirkung:** Die CRC wird nur aktualisiert, wenn sich `fileSize` ändert. Bei normalen ROMs wird der zuvor berechnete Wert nicht invalidiert; bei ZIPs kann sogar der neu gelesene Wert ignoriert werden. Der Metadatenabruf berechnet einen Hash nur bei `nil` neu und sendet deshalb auch bei einem erzwungenen Refetch die alte Inhaltskennung. Die tatsächliche Wirkung auf einen externen Treffer hängt von der Antwort des Dienstes ab; die falsche Anfrageidentität ist durch den Code eindeutig.

**Reproduktion:** Drei Bytes einlesen, CRC32 speichern, durch drei andere Bytes ersetzen und scannen. Der gespeicherte Wert bleibt **`55BC801D`**. Der Zusatztest für die Invalidierung schlägt fehl.

**Lösungsvorschlag:** Inhaltsänderungen zusätzlich anhand einer geeigneten Dateirevision erkennen. Eine neu aus dem ZIP gelesene CRC unabhängig von der Archivgröße vergleichen; normale ROM-Hashes bei erkennbarer Änderung invalidieren und vor einem ausdrücklich angeforderten Refetch gegebenenfalls neu berechnen.

**Regressionstest:** ROM und ZIP jeweils durch gleich große, inhaltlich andere Dateien ersetzen. Die beim nächsten Scraping verwendete CRC muss die neuen Bytes identifizieren.

### 8. [P2] Bildcache zeigt nach einem Austausch weiterhin alte Cover und Save-State-Thumbnails

**Fundstellen:** [Artwork.swift:20](<../Ursprung/UI/Components/Artwork.swift:20>) und [Artwork.swift:43](<../Ursprung/UI/Components/Artwork.swift:43>); [Artwork.swift:77](<../Ursprung/UI/Components/Artwork.swift:77>); Schreibpfad bei [MetadataService.swift:105](<../Ursprung/Metadata/MetadataService.swift:105>). Save-State-Anzeige: [PauseMenuView.swift:502](<../Ursprung/UI/Player/PauseMenuView.swift:502>).

**Auslöser:** Bereits angezeigte Metadatenbilder erneut herunterladen oder einen bereits angezeigten Save-State-Slot überschreiben.

**Ursache und Auswirkung:** Der Cache-Schlüssel besteht nur aus Pfad und Zielauflösung. Die Dateien werden am gleichen Pfad ersetzt. `invalidate()` besitzt keinen Aufrufer im Anwendungscode. Außerdem startet `.task(id: url)` bei unveränderter URL nicht neu. Bei Save States erzeugt `.id(state.date)` zwar eine neue View, diese lädt jedoch dieselbe URL aus demselben alten Cache. So kann ein Thumbnail einen anderen Spielzustand anzeigen als den tatsächlich gespeicherten Slot.

**Reproduktion:** Eine rote PNG laden, am selben Pfad atomar durch eine blaue PNG ersetzen und erneut laden. Der Cache liefert **dasselbe `CGImage`-Objekt**. Die Prüfung auf einen erneuten Ladevorgang schlägt fehl.

**Lösungsvorschlag:** Bildidentität um eine Inhaltsrevision erweitern oder beim erfolgreichen Schreiben gezielt invalidieren. Dieselbe Revision muss auch die Lade-Task der View neu starten. Dies für Metadaten und Save-State-Thumbnails gemeinsam lösen.

**Regressionstest:** Ein angezeigtes Cover und einen belegten Save-State-Slot überschreiben. Die Anzeige muss in derselben Sitzung die neuen Pixel zeigen.

### 9. [P2] ZIP-Nutzdaten werden ohne CRC-Prüfung als erfolgreich extrahiert behandelt

**Fundstelle:** [ZipArchive.swift:70](<../Ursprung/Support/ZipArchive.swift:70>), Zeilen 70–83; Cache-Markierung bei [ZipArchive.swift:100](<../Ursprung/Support/ZipArchive.swift:100>).

**Auslöser:** Ein Archiv enthält beschädigte Nutzdaten bei weiterhin plausiblen Offsets und Größen. Beim unkomprimierten ZIP-Verfahren genügt ein einzelnes verändertes Nutzdatenbyte.

**Ursache und Auswirkung:** Der Parser liest die erwartete CRC32, prüft sie nach der Extraktion aber nicht. Bei Methode 0 wird zusätzlich die ausgegebene Länge nicht gegen `uncompressedSize` geprüft. Die Extraktion gilt als erfolgreich; `extractCached` kann dafür eine gültig wirkende Identitätsdatei schreiben. Bei Core-Updates kann so ein beschädigter Inhalt die vorherige Installation ersetzen. CRC32 würde Übertragungs-/Dateibeschädigungen erkennen; sie wäre keine kryptografische Authentizitätsprüfung.

**Reproduktion:** Ein gültiges ZIP mit `ZIP_STORED` erzeugen und ein Byte im Dateinhalt verändern, ohne die zentrale CRC zu ändern. `extract` schreibt den beschädigten Inhalt ohne Fehler; der Test `zipRejectsCorruptPayload` schlägt fehl.

**Lösungsvorschlag:** Ausgabegröße und CRC für sämtliche unterstützten Verfahren vor der Übernahme prüfen. Bei einem Fehler weder eine Cache-Markierung setzen noch eine vorhandene Core-Installation ersetzen.

**Regressionstest:** Nutzdatenfehler bei Stored und Deflate sowie widersprüchliche Größen prüfen. Vorhandene Ziele müssen im Fehlerfall erhalten bleiben.

### 10. [P2] Intellivision gilt bereits mit nur einer seiner zwei Pflichtdateien als startbereit

**Fundstelle:** [BIOSManager.swift:34](<../Ursprung/Cores/BIOSManager.swift:34>), insbesondere Zeile 37; Katalog: [SystemCatalog.swift:259](<../Ursprung/Systems/SystemCatalog.swift:259>).

**Auslöser:** Nur `exec.bin` ist vorhanden, `grom.bin` fehlt – oder umgekehrt.

**Ursache und Auswirkung:** Die Methode behandelt alle Systeme mit mehreren Pflichtdateien pauschal wie alternative regionale BIOS-Versionen. Sobald eine Pflichtdatei vorhanden ist, liefert sie eine leere Fehlmenge. Für Intellivision sind laut Katalog und Projektdokumentation beide Dateien erforderlich. Die Vorprüfung gibt den Start trotzdem frei und verliert damit die konkrete Information, welche Datei importiert werden muss.

**Reproduktion:** Ausschließlich eine synthetische `exec.bin` anlegen, Status aktualisieren und Intellivision prüfen. `missingRequired` liefert **`[]`**, obwohl `grom.bin` fehlt. Dass die synthetische vorhandene Datei als unbekannte Version gilt, ändert den nachgewiesenen Fehler der Vollständigkeitsprüfung nicht.

**Lösungsvorschlag:** Gleichwertige Alternativen im Datenmodell explizit gruppieren. Unabhängige Pflichtdateien als UND-Bedingung behandeln; regionale Alternativen nur innerhalb ihrer Gruppe als ODER-Bedingung.

**Regressionstest:** Keine Datei, nur `exec.bin`, nur `grom.bin` und beide Dateien. Ergänzend die beabsichtigte Alternativenregel etwa für Sega-CD weiterhin prüfen.

### 11. [P2] Playlists mit Discs in Unterordnern erzeugen zusätzliche Spieleinträge

**Fundstellen:** [LibraryScanner.swift:52](<../Ursprung/Library/LibraryScanner.swift:52>), Zeilen 52–60; [LibraryScanner.swift:134](<../Ursprung/Library/LibraryScanner.swift:134>), Zeilen 134–135.

**Auslöser:** Ein Mehrdisc-Spiel verwendet zum Beispiel folgende Struktur:

```text
PSX/
  Game.m3u       # enthält: Disc1/Game.cue
  Disc1/
    Game.cue
    Game.bin
```

**Ursache und Auswirkung:** Referenzen werden nur innerhalb jeweils eines Verzeichnisses gesammelt und auf reine Dateinamen reduziert. Die Playlist im Elternordner kann deshalb die CUE im Kindordner nicht ausschließen. Beide werden als eigenständige Spiele angelegt, mit separaten Spielidentitäten und Metadaten. Bei ähnlich benannten Dateien im Playlist-Verzeichnis kann die Reduktion auf den Dateinamen zusätzlich die falsche Datei ausblenden.

**Reproduktion:** Die obige Struktur mit künstlichen Dateien anlegen. Der Scanner liefert **`["Game.cue", "Game.m3u"]`** statt nur der Playlist.

**Lösungsvorschlag:** Referenzen relativ zur jeweiligen Descriptor-Datei in vollständige normalisierte Zielpfade auflösen und verzeichnisübergreifend anwenden. Der Ausschluss muss die referenzierte Datei identifizieren, nicht lediglich ihren Namen.

**Regressionstest:** Playlists mit Unterordnern, `../`-Referenzen und gleichnamigen, aber nicht referenzierten Nachbardateien prüfen.

### 12. [P2] Fast Forward bleibt aktiv, wenn das Loslassen der Leertaste nicht beim Player ankommt

**Fundstellen:** [GameMetalView.swift:58](<../Ursprung/UI/Player/GameMetalView.swift:58>), Zeilen 58–72; [EmulationSession.swift:337](<../Ursprung/Emulation/EmulationSession.swift:337>), Zeilen 337–346.

**Auslöser:** Leertaste für Fast Forward halten, zu einer anderen App wechseln, dort loslassen und zu Ursprung zurückkehren. Auch ein Wechsel des Tastaturfokus zum Pausemenü kann das entsprechende `keyUp` vom Player fernhalten.

**Ursache und Auswirkung:** Fast Forward wird über `keyDown` eingeschaltet und ausschließlich über das passende `keyUp` bzw. vollständiges Session-Cleanup ausgeschaltet. Die Behandlung der App-Deaktivierung setzt nur den Pausezustand und die normalen Tastatureingaben zurück. `isFastForwarding` bleibt gesetzt; nach dem Fortsetzen läuft das Spiel weiter mit erhöhter Geschwindigkeit, bis die Leertaste erneut gedrückt und losgelassen wird.

**Nachweis:** Im isolierten Test Fast Forward einschalten und `NSApplication.didResignActiveNotification` auslösen. Die Prüfung, dass Fast Forward danach ausgeschaltet ist, schlägt fehl. Der vollständige manuelle App-Wechsel wurde nicht automatisiert nachgestellt.

**Lösungsvorschlag:** Temporäre Hotkey-Zustände bei Fokusverlust und Eintritt in das Pausemenü explizit lösen. Dies vom Wunsch unterscheiden, ein Spiel im Hintergrund weiterlaufen zu lassen.

**Regressionstest:** Fokusverlust bei gehaltener Leertaste, Loslassen außerhalb des Players und Rückkehr. Die Emulation muss anschließend mit normaler Geschwindigkeit laufen.

## Prüfverfahren und Belege

### Umfang

Geprüft wurden die zentralen Daten- und Kontrollflüsse in App-Initialisierung und SwiftData-Persistenz, Bibliotheksscans und Disc-Erkennung, BIOS-/Core-Verwaltung, ZIP-Parsing und Extraktion, Metadatenqueue und Netzwerkclient, Emulationsstart/-stopp, Saves, Audio-/Video-Bridge, Tastatur-/HID-/XInput-Routing sowie deren SwiftUI-Anbindung. Auch Build-Scripts, Signing-Konfiguration, vorhandene Tests und der bereits unversioniert vorliegende CI-Workflow wurden einbezogen.

Der Quellbestand umfasst **79 eigene Swift-/Objective-C-/C-/Headerdateien mit 12.944 Zeilen**, einschließlich Tests, Tools und Icon-Script; der mitgelieferte `libretro.h` ist dabei nicht mitgezählt. Diese Größe beschreibt den untersuchten Projektbestand, keine gemessene Code-Coverage oder Garantie einer vollständigen Fehlererfassung.

### Ausgeführte Prüfungen

| Prüfung | Ergebnis |
| --- | --- |
| Vorhandene Testsuite, Debug, macOS/arm64 | Erfolgreich: 110 Tests, 136 Testfälle inkl. Parametrisierung, 0 Fehler, 0 übersprungen |
| Release-Build des Anwendungstargets | Erfolgreich, Exit 0 |
| Sieben zusätzliche Swift-Tests in der temporären Kopie | Alle sieben decken die erwarteten Fehler auf; die 110 vorhandenen Tests bestehen weiterhin |
| Drei weitere gezielt ausgewählte Swift-Tests | Bestätigen ZIP-Integritätsfehler, Fast-Forward-Zustand und Metadatenqueue-Fehler |
| Separater Optionswert-Test mit AddressSanitizer | `heap-use-after-free`, Exit 134 |
| Separater Audio-Ring-Test mit zwei Threads | Rückwärtsbewegung des Leseindex nach Clear nachgewiesen |
| SHA-256-Abgleich der 123 vorab erfassten versionierten Dateien | Keine Änderungen |

Die temporären Swift-Tests formulieren das gewünschte korrekte Verhalten. Ihre Fehler sind die Reproduktionsbelege und dürfen nicht mit Fehlern der unveränderten bestehenden Testsuite verwechselt werden.

**Umgebung:** Xcode 27.0, Build `27A266a`, Apple Silicon, Ziel `platform=macOS,arch=arm64`. Die Result-Bundles melden macOS 27.0; eine zusätzliche Laufzeitprüfung auf der Mindestversion macOS 26 wurde nicht durchgeführt.

**Isolation:** Eine neue temporäre Kopie enthielt nur versionierte Projektdateien, keine `.env`, echten generierten Zugangsdaten, lokalen Signing-Einstellungen, ROMs oder BIOS-Dateien. Nur in dieser Kopie wurden die Application-Support-/Cache-Pfade auf temporäre Verzeichnisse und die Bundle-IDs auf einen separaten Test-Namensraum umgestellt. Die untersuchten Scanner-, Import-, Queue-, Cache-, ZIP- und Bridge-Implementierungen blieben unverändert. Zusätzliche Testdateien und Test-Cores liegen ausschließlich außerhalb des ursprünglichen Projekts.

Der erste reguläre Xcode-Testversuch scheiterte an Sandbox-Beschränkungen der Testdienste. Der anschließende freigegebene Testlauf außerhalb der Sandbox war erfolgreich. Ein späterer Testfilter ohne vollständige Swift-Testing-Funktionsnamen selektierte null Tests; dieser Lauf wurde nicht als Verifikation gewertet. Die drei betreffenden Tests wurden danach mit ihren korrekten Namen ausgeführt und die Ergebnisse aus den XCResult-Berichten ausgelesen.

Die temporären Arbeits- und Belegdateien liegen unter `/tmp/ursprung-review-20261002-unags_xe/`. Sie sind nicht Bestandteil des Repositorys und können vom System später entfernt werden. Dieser Bericht enthält deshalb die für die Bewertung erforderlichen Reproduktionsschritte und Resultate selbst.

### Abgleich mit dem älteren Review

Der Bericht vom 29.09.2026 ist historisch zu lesen. Insbesondere die damals nach der Nachprüfung noch offene Backup-Löschung ist heute korrigiert: Der Code legt ein eigenes freies Backup-Verzeichnis an und erhält Dateien bei einem fehlgeschlagenen Rollback. Die vorhandenen Tests für Namenskollision und Rollback-Fehler bestehen.

Auch die vorhandenen Regressionstests für getrennte Batteriespielstände, Pfadgrenzen bei Ordnerentfernung, ZIP64-Grenzprüfungen, gemeinsame Core-Installation, ZIP-Cache-Identität, verworfene veraltete Scan-Ergebnisse und HID-Lern-/Filterzustände bestehen. Der frühere Runner-Start-/Stopp-Test wurde in diesem Review nicht erneut mit einem blockierbaren ladenden Core ausgeführt; seine Korrektur wurde statisch nachvollzogen.

Die neuen Befunde 1 und 2 betreffen andere Scan-Fehlerpfade als die früher behobene Präfixprüfung. Befund 7 betrifft die in der Bibliothek gespeicherte Metadaten-CRC, nicht den bereits korrigierten Cache für extrahierte ROMs.

## Grenzen und empfohlene Reihenfolge

Keine praktischen Mehrspieler-/Controller-Hardwaretests, keine visuellen End-to-End-Tests der Fenster, keine realen ROM-/BIOS-Inhalte und keine Live-Anfragen an ScreenScraper oder den Core-Buildbot. Core-spezifische Speicherformate, OpenGL-Verhalten, hörbare Audiostörungen und das Verhalten aller angebotenen Systeme sind damit nicht vollständig verifiziert. Der AddressSanitizer-Nachweis zeigt den konkreten Speicherfehler unter kontrollierter Abfolge, keine gemessene Absturzhäufigkeit im Alltag.

Zuerst sollten die drei Datenverlustpfade in Scans und BIOS-Import sowie die Lebensdauer der Optionsstrings korrigiert werden. Danach bieten sich die Audio-Synchronisierung, der Neustart der Metadatenqueue und die Inhaltsinvalidierung für ROMs und Bilder an. Für jeden Befund ist oben ein gezielter Regressionstest beschrieben. Es wurden keine Korrekturen implementiert.
