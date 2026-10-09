<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# Re-Review: Vulkan-Fixes

**Datum:** 09.10.2026  
**Stand:** uncommittete Änderungen im Working Tree auf `main`, Basis `46c8e137ad1c48c7c159b6a78224b261d8564ba4`  
**Vorheriges Review:** [VULKAN_REVIEW_2026-10-09.md](VULKAN_REVIEW_2026-10-09.md)

Geprüft wurden die Fixes für F1–F5, die zusätzlichen Regressionstests, Speicherfehlerbehandlung, Smoke-Renderer-Prüfung und die neue `libvulkan.1.dylib`-Einbindung. Die vorhandenen Änderungen und der erste Review-Bericht wurden nicht bearbeitet.

## Ergebnis

**F2–F5 sind für die beanstandeten Fälle behoben. F1 ist nur teilweise behoben; ein P1-Blocker bleibt im Timeout-Lebenszyklus bestehen.** Die neue Fehler-Markierung verhindert den nächsten `retro_run`, schützt aber weder den bereits laufenden Core-Aufruf vollständig noch den anschließenden Core-Abbau.

| Ursprünglicher Punkt | Ergebnis des Re-Reviews | Nachweis |
|---|---|---|
| F1: Ressourcen-Reuse nach Timeout | **Teilweise behoben, P1 offen** | Nächster `retro_run` unterbleibt; bei anhaltendem Timeout laufen die Core-Abbau-Callbacks dennoch. `wait_sync_index` kehrt im aktuellen `retro_run` trotz ausstehender Arbeit zurück. |
| F2: Semaphore-Waits mit Command Buffern | Behoben | Instrumentierter Submit enthält null Waits; GPU-Regressionstest mit nie signalisiertem Semaphore besteht. |
| F3: Signalverlust bei duplizierten Frames | Behoben | NULL-Callback reicht Signal A sofort ein, nächster Callback Signal B; Regressionstests bestehen in beiden Übergabemodi. |
| F4: Ownership-/Layout-Übergaben | Für den beanstandeten Übergang behoben | Vier getrennte Barrieren beim Readback, zwei ohne Kopie; Acquire und Release jeweils im unveränderten Image-Layout. Kein echter Multi-Queue-GPU-Test. |
| F5: Image-View-Kanalzuordnung | Behoben | GPU-Test liefert den erwarteten R/B-Tausch; Konvertierungstests für Identität, Konstanten und weitere Kanäle bestehen. |

## R1 · P1 – Ein anhaltender Timeout erlaubt weiterhin Zugriff und Freigabe laufender Core-Ressourcen

**Stellen:** [URLibretroCore.m:452](../Ursprung/Bridge/URLibretroCore.m#L452), [URVulkanContext.m:815](../Ursprung/Bridge/URVulkanContext.m#L815), [wait_sync_index:959](../Ursprung/Bridge/URVulkanContext.m#L959).

### Der Core-Abbau ignoriert den gescheiterten Abschluss

`settleUnfinishedFrame` setzt nach einem zweiten Timeout `_abandoned = YES` und liefert `NO`. `waitIdle` kehrt daraufhin zurück, ohne nachgewiesen zu haben, dass die GPU fertig ist. Da `waitIdle` keinen Status zurückgibt, fährt `unloadGame` unmittelbar mit `context_destroy`, `retro_unload_game` und `retro_deinit` fort.

Diese Core-Callbacks können genau die Images, Semaphoren, Speicherbereiche und Command Pools freigeben, welche die noch laufende Submission verwendet. Dass `URVulkanContext.destroy` später das eigene Device und die Instanz absichtlich bestehen lässt, schützt die vorher freigegebenen Core-Ressourcen nicht. Wartet ein Core in seinem Destructor selbst mit `vkDeviceWaitIdle`, kann stattdessen der gesamte Shutdown hängen bleiben. Der mitgelieferte Test-Core tut das in [TestDestroyResources:188](../Tools/ursprung-test-core/test_core.c#L188).

**Reproduziert:** Frame-Wait und nachfolgender Teardown-Wait wurden im Originalcode beide mit `VK_TIMEOUT` beantwortet. Trotzdem liefen sämtliche drei Core-Abbau-Callbacks:

```text
F1 before unload: runs=1 failed=1 unfinished=1
context_destroy: unfinished=1 abandoned=1
F1 after persistent timeout: context_destroy=1 unload=1 deinit=1 abandoned=1
```

### Auch der bereits laufende Core-Aufruf ist noch nicht abgesichert

Die neue Schranke in `runFrame` verhindert erst den nächsten Aufruf. Der aktuelle `retro_run` läuft nach der Rückkehr aus dem fehlgeschlagenen Video-Callback weiter. Ruft der Core dort `wait_sync_index` auf, kehrt dieser weiterhin sofort zurück. Damit erhält er die vertragliche Freigabe zur Wiederverwendung seiner Frame-Ressourcen, obwohl `_fenceUnfinished` gesetzt ist. Der [libretro-Vertrag:476](../Ursprung/Bridge/libretro_vulkan.h#L476) verlangt an dieser Stelle den Abschluss der GPU-Arbeit für den aktuellen Index.

**Reproduziert:** Eine temporäre Core-Run-Funktion ruft nach dem Video-Callback `wait_sync_index` auf. Die Kontrolle kehrt mit `failed=1 unfinished=1` zum Core zurück. Ein anschließend angeforderter zweiter `retro_run` unterbleibt dagegen korrekt.

**Auswirkung:** F1 ist im normalen Folgetakt entschärft, aber bei einem tatsächlich nicht abgeschlossenen Frame weiterhin ein möglicher GPU-/Prozessabsturz oder Shutdown-Hänger. Die vorhandene Testsimulation lässt nur den ersten Wait fehlschlagen; beim Abbau kann die echte, kurze GPU-Arbeit bereits beendet sein. Deshalb erkennen die grünen Tests diesen Fall nicht.

**Verbesserungsvorschlag:**

1. Den Zustand „fehlgeschlagen“ von „Ressourcen dürfen freigegeben werden“ unterscheiden. Der Abschluss muss an `URLibretroCore` zurückgemeldet und vor jedem zerstörenden Core-Callback geprüft werden.
2. Solange Arbeit lediglich aussteht, weder `wait_sync_index` erfolgreich zurückkehren lassen noch `context_destroy`/`unload_game`/`deinit` oder andere ressourcenverändernde Core-Aufrufe zulassen. Ein Frame-Timeout ist kein Nachweis, dass Device-Loss eingetreten ist oder die Submission beendet wurde.
3. Die Strategie für einen dauerhaft blockierten In-Process-Core ausdrücklich festlegen. Nur das Vulkan-Device zu behalten reicht nicht. Bei Quarantäne müssen auch Core-Objekt, Interface und geladene Bibliothek gültig bleiben; ein weiterer Core darf den globalen Callback-Zustand nicht übernehmen. Eine harte, zeitlich begrenzte Beendigung eines beliebigen blockierten Cores erfordert eine geeignete Prozessgrenze. Ungeprüftes Fortsetzen des normalen Unloads ist keine sichere Abkürzung.

**Benötigte Regressionstests:**

- Zwei aufeinanderfolgende `VK_TIMEOUT`-Ergebnisse, einschließlich des Abbaus: keine zerstörenden Core-Callbacks, keine Freigabe der Interface-/Bibliotheks-Lebensdauer.
- Timeout, danach `wait_sync_index` innerhalb desselben `retro_run`: keine Freigabe ausstehender Frame-Ressourcen.
- Timeout, später tatsächlicher Abschluss: Abbau erfolgt genau einmal und erst nach dem Abschluss.

Die Reproduktion instrumentiert Rückgabewerte und Callback-Aufrufe. Sie provoziert keinen echten GPU-Hänger und behauptet keinen neu reproduzierten Spielabsturz.

## Prüfung der übrigen Fixes

**F2:** Die Entscheidung über `waitCount` erfolgt vor dem Verbrauch der Core-Command-Buffer. Der direkte Prüflauf meldet `waits=0 commands=1`. Der neue Test `commandBuffersIgnoreTheImageSemaphores` prüft den relevanten Fall auf der GPU. Für den ursprünglichen Befund kein weiterer Änderungsbedarf.

**F3:** Die Vulkan-Behandlung liegt jetzt vor dem allgemeinen NULL-Return. In der instrumentierten Callback-Folge wird zuerst Semaphore 21 und anschließend Semaphore 22 eingereicht. `everyRefreshSignalsItsSemaphore` bestätigt das Verhalten mit echten Semaphoren für beide Übergabemodi. Das Beibehalten der Image-Waits für eine spätere tatsächliche Präsentation ist vom sofortigen Signal des aktuellen Duplikat-Callbacks getrennt.

**F4:** Ownership-Wechsel und lokale Layoutwechsel sind getrennt. Die aufgezeichneten Acquire-/Release-Barrieren verwenden jeweils `SHADER_READ_ONLY_OPTIMAL → SHADER_READ_ONLY_OPTIMAL`, auch ohne Bildkopie. Die Referenz verwendet für Ownership ebenfalls das unveränderte Image-Layout: [RetroArch Vulkan-Treiber](https://raw.githubusercontent.com/libretro/RetroArch/master/gfx/drivers/vulkan.c). Mangels zweiter Queue-Familie wurde die GPU-Ausführung dieses Falls nicht geprüft. Die Barrieren lassen sich dennoch GPU-unabhängig automatisiert prüfen; ein solcher Repository-Test fehlt weiterhin.

**F5:** `create_info.components` wird übernommen; der neue Konvertierungspfad berücksichtigt die Zuordnung einschließlich Alpha als Quelle für Farbkanäle. Der schnelle Identitätspfad bleibt erhalten. `theImageViewsChannelMappingApplies` besteht mit dem erwarteten CPU-Pixel `0xFF804001`.

**V2 / V3:** Die Smoke-API-Prüfung und die Absicherung der Übergabe-Array-Allokationen sind umgesetzt. Beim neuen Speicherfehlerzustand gilt allerdings dieselbe Anforderung wie bei R1: Ein Flag allein sichert Core-Abbau und laufende Core-Aufrufe nicht ab.

**Dolphin-Bibliotheksalias:** Der erzeugte Debug-App-Bundle enthält `Contents/Frameworks/libvulkan.1.dylib → libMoltenVK.dylib`. Die Prüfung mit `codesign --verify --deep --strict` besteht. Das bestätigt die lokale Ad-hoc-Signierung, ersetzt aber keinen Developer-ID-/Notarisierungs-Test.

## Validierung

Die vollständige aktualisierte Testsuite wurde erneut ausgeführt:

```sh
xcodebuild -project Ursprung.xcodeproj \
  -derivedDataPath build/DerivedData \
  -destination 'platform=macOS,arch=arm64' \
  -scheme Ursprung test -quiet \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
```

**Ergebnis:** 423 Testfälle insgesamt, davon **421 bestanden, 2 übersprungen, 0 fehlgeschlagen**. Mit Parameterfällen ergeben sich **464 erfolgreiche Ausführungen**. Alle zehn Vulkan-Testfälle einschließlich ihrer Parameterfälle liefen erfolgreich. Übersprungen wurden nur `everyPackPresetRoundTrips()` und `realPackUnpacksAndIndexes()` aus dem Shader-Bereich.

Zusätzlich wurde unter `/tmp/ursprung-vulkan-rereview/` ein temporäres Prüfprogramm gegen die aktuellen Original-Implementierungen gebaut. Es bestätigt die Submit-/Callback-/Barrier-Korrekturen für F2–F4 und reproduziert R1 mit abgefangenen Vulkan-Submissions und simuliert anhaltenden Timeouts. Anwendungscode und Repository-Tests wurden dabei nicht verändert.

Die im Plan nachgetragenen manuellen MGS-/Disc-Wechsel-Prüfungen wurden in diesem Re-Review nicht wiederholt. Vulkan bei 2× N64-Auflösung in der App, Langzeitverhalten und notarisierten Distributionsbuild habe ich ebenfalls nicht erneut geprüft. Der verbleibende Fallback-Neustart aus V1 bleibt eine dokumentierte Produktentscheidung.

## Behebung (09.10.2026)

| ID | Status | Umsetzung | Test |
|---|---|---|---|
| R1 | behoben | „Fehlgeschlagen“ und „ausstehend“ sind getrennt: Nach einem Timeout bleibt der Kontext `busy`, bis die Fence signalisiert oder das Device verloren ist (andere Fehler gelten nicht als Abschluss). `wait_sync_index` blockiert bis dahin und kehrt nie mit ausstehender Arbeit zurück. `waitIdle` meldet das Ergebnis; ist der Frame beim Entladen noch nicht fertig, ruft `unloadGame` weder `context_destroy` noch `retro_unload_game` oder `retro_deinit` auf. Strategie für einen dauerhaft blockierten Core: Quarantäne im Prozess. Core-Objekt, `dlopen`-Handle, Vulkan-Kontext samt Interface und `gActiveCore` bleiben gültig (`gUnfinishedCore`). Der nächste Spielstart prüft ohne Warten, ob der Frame fertig ist: dann wird der alte Core genau einmal abgebaut, sonst verweigert der Start mit Fehler 7 und dem Hinweis, Ursprung neu zu öffnen. Nach einem Fehler nimmt der Core außerdem kein Reset, keine States (auch kein Autosave), keine Cheats und keinen Discwechsel mehr an. | `waitingForTheSyncIndexWaitsForAnUnfinishedFrame` (Timeout, `wait_sync_index` im selben `retro_run`), `anUnfinishedFrameDefersTheTeardown` (zwei Timeouts samt Abbau: keine Abbau-Callbacks, Core-Objekt bleibt; weiterer Timeout blockiert den nächsten Start; danach Abbau genau einmal vor dem neuen Spiel), `aFailedFrameStopsTheGame` (Timeout mit späterem Abschluss: Abbau genau einmal, keine States) |
| V2/V3 | behoben | Der Speicherfehlerzustand setzt `failed`; dieselben Sperren gelten. Ausstehende GPU-Arbeit entsteht dabei nicht, der Abbau läuft normal. | – |

Simulierte Fence-Ergebnisse stehen jetzt in einer Warteschlange (`simulateFenceWaitResult:`), damit Frame-Wait, `wait_sync_index` und Abbau einzeln ausfallen können. Der Test-Core zählt `retro_unload_game` und `retro_deinit` und kann nach dem Frame `wait_sync_index` aufrufen (`waitsAfterFrame`).

Validierung: `xcodebuild … test` mit 442 Tests grün, 2 übersprungen (Shader-Pack); `make smoke RENDERER=vulkan` mit Mupen64Plus-Next (paraLLEl-RDP, Ocarina of Time, 300 Frames, State und Entladen).
