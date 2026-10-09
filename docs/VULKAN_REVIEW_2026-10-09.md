<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# Code-Review: Vulkan-Implementierung

**Datum:** 09.10.2026  
**Branch / Stand:** `main`, `46c8e137ad1c48c7c159b6a78224b261d8564ba4`  
**Vergleich:** `bf00425..46c8e13`, insbesondere `06f18e6` und `b9e58eb`  
**Grundlage:** [VULKAN_PLAN.md](</Users/ben/Projekte/Ursprung - Retro Games Library for Mac/docs/VULKAN_PLAN.md>)

Geprüft wurden Vulkan-Kontext und libretro-Integration, Pixelkonvertierung, Renderer-Auswahl, Save-State-Metadaten, Dependency-/Build-Einbindung, Smoke-Tool und Tests. Anwendungscode und Repository-Tests wurden nicht geändert.

## Ergebnis

**Fünf konkrete Findings: zwei P1, drei P2.** Die bestehenden Tests bestehen einschließlich der Vulkan-Tests. Die gefundenen Fehler betreffen zusätzliche, vom API-Vertrag erlaubte Übergabeformen und Fehlerpfade. Vor einer Freigabe sollten insbesondere die beiden P1-Probleme behoben werden.

P1 bedeutet hier: kann die Emulation blockieren oder die sichere Lebensdauer von GPU-Ressourcen verletzen. P2 bedeutet: bedingter Funktions- oder Kompatibilitätsfehler. Die Priorität sagt nichts darüber aus, wie häufig ein bestimmter derzeit verwendeter Core den Auslöser nutzt.

| ID | Priorität | Finding | Nachweis |
|---|---|---|---|
| F1 | P1 | Weiterbetrieb nach GPU-Timeout verwendet potenziell laufende Ressourcen erneut | Fehler injiziert, Kontrollfluss reproduziert |
| F2 | P1 | Command-Buffer-Modus wartet auf Semaphoren, die ignoriert werden müssen | Tatsächliche Submit-Parameter abgefangen |
| F3 | P2 | Duplizierte Frames verbrauchen ihr Signal-Semaphor nicht im Callback | Callback-Folge und verlorenes Signal reproduziert |
| F4 | P2 | Queue-Familien-Wechsel kombiniert inkompatible Ownership- und Layout-Übergänge | Aufgezeichnete Barrieren geprüft; bedingt durch mehrere Queue-Familien |
| F5 | P2 | Image-View-Kanalzuordnung geht beim Readback verloren | Mit echtem MoltenVK-Readback reproduziert |

## F1 · P1 – Nach einem GPU-Timeout werden noch verwendete Ressourcen wieder freigegeben

**Stellen:** [URVulkanContext.m:701](</Users/ben/Projekte/Ursprung - Retro Games Library for Mac/Ursprung/Bridge/URVulkanContext.m:701>), [beginFrame:519](</Users/ben/Projekte/Ursprung - Retro Games Library for Mac/Ursprung/Bridge/URVulkanContext.m:519>), [wait_sync_index:834](</Users/ben/Projekte/Ursprung - Retro Games Library for Mac/Ursprung/Bridge/URVulkanContext.m:834>).

`vkWaitForFences` wartet höchstens fünf Sekunden. Bei `VK_TIMEOUT` wird lediglich geloggt und `NO` zurückgegeben. Der Core läuft anschließend weiter: `beginFrame` schaltet den Sync-Index weiter, `wait_sync_index` kehrt ohne Prüfung zurück, der nächste Submit setzt dieselbe Fence zurück und ein weiterer Readback beginnt denselben Command Buffer erneut. Bei einer Vergrößerung kann sogar der noch verwendete Readback-Puffer zerstört werden.

Ein Timeout bedeutet nicht, dass die eingereichte GPU-Arbeit abgeschlossen oder abgebrochen ist. Die zentrale Voraussetzung der vereinfachten Architektur mit nur einer Fence und einem Command Buffer ist damit nicht mehr erfüllt. Vulkan verbietet sowohl das Zurücksetzen einer noch verwendeten Fence als auch die erneute Aufzeichnung eines noch laufenden Command Buffers. Siehe [vkResetFences, VUID 01123](https://docs.vulkan.org/refpages/latest/refpages/source/vkResetFences.html) und [vkBeginCommandBuffer, VUID 00049](https://docs.vulkan.org/refpages/latest/refpages/source/vkBeginCommandBuffer.html).

**Auslöser / Folge:** Eine GPU-Verzögerung oder ein blockierender Semaphore-Wait überschreitet fünf Sekunden. Danach sind ungültige Vulkan-Aufrufe, vorzeitige Wiederverwendung von Core-Bildern und weitere Hänger möglich. Auch `VK_ERROR_DEVICE_LOST` führt derzeit zu keinem dauerhaften Fehlerzustand.

**Nachweis:** Im Original-Kontrollfluss wurde `VK_TIMEOUT` am Fence-Wait injiziert. Danach wechselte der Sync-Index und ein weiterer Submit erfolgte, ohne zunächst die alte Arbeit nachweislich abzuschließen. Ein echter GPU-Absturz wurde nicht provoziert.

**Vorschlag:** Ausstehende Arbeit und einen dauerhaften Fehlerzustand explizit führen. Nach Timeout entweder dieselbe Fence weiter kontrolliert abwarten oder die Emulation über einen Fehlerkanal stoppen; weder `retro_run` noch Ressourcen-Reuse dürfen einfach weiterlaufen. Device-Loss separat behandeln. Fehler von `vkBeginCommandBuffer`, `vkEndCommandBuffer` und `vkResetFences` ebenfalls auswerten. Der Abbau darf einen verlorenen Kontext nicht unbegrenzt als intakten Kontext behandeln.

**Regressionstest:** Fence-Wait liefert zunächst `VK_TIMEOUT`; bis zum Abschluss oder kontrollierten Abbruch dürfen keine neue Aufzeichnung, Fence-Resets, Readback-Reallokationen oder freigegebenen Sync-Indizes folgen. Separater Test für Device-Loss.

## F2 · P1 – Im Command-Buffer-Modus werden verbotene Semaphore-Waits eingereicht

**Stelle:** [URVulkanContext.m:672](</Users/ben/Projekte/Ursprung - Retro Games Library for Mac/Ursprung/Bridge/URVulkanContext.m:672>), insbesondere die unveränderte Übernahme von `_waitSemaphoreCount` in `VkSubmitInfo` ab Zeile 684.

Wenn ein Core `set_command_buffers` verwendet, muss das Frontend die Semaphoren aus `set_image` ignorieren. Das ist ausdrücklich im mitgelieferten [libretro-Vertrag:453](</Users/ben/Projekte/Ursprung - Retro Games Library for Mac/Ursprung/Bridge/libretro_vulkan.h:453>) festgelegt. Der Code hängt zwar die Core-Command-Buffer vor den eigenen Readback, übernimmt aber gleichzeitig sämtliche Image-Semaphoren als Waits.

**Auslöser / Folge:** Ein konformer Core übergibt Command Buffer und außerdem ein nicht signalisiertes Image-Semaphor, dessen Ignorieren er in diesem Modus voraussetzen darf. Ursprung wartet darauf und blockiert die Submission. Nach fünf Sekunden tritt zusätzlich F1 ein. Die Ownership-Entscheidung wird ebenfalls aus der falschen Wait-Annahme abgeleitet.

**Nachweis:** `set_command_buffers(1, …)` und `set_image(…, 1, …)` ergeben im abgefangenen Original-Submit `commandBufferCount = 1`, `waitSemaphoreCount = 1`; erwartet ist `waitSemaphoreCount = 0`. Die vorhandenen Tests übergeben in diesem Modus immer null Semaphoren und erkennen den Fehler deshalb nicht.

**Vorschlag:** Den Übergabemodus vor der Submission bestimmen. Bei übergebenen Core-Command-Buffern Image-Semaphoren für diese Übergabe ignorieren und anschließend verwerfen. Auch Ownership-Wechsel nur aus den tatsächlich verwendeten Waits ableiten. Das vom Frontend zu signalisierende Semaphore bleibt davon unabhängig.

**Regressionstest:** Ein gültiger Command Buffer plus ein absichtlich unsignalisiertes Image-Semaphor muss ohne Wait darauf ausgeführt werden und das erwartete Bild liefern.

## F3 · P2 – Bei duplizierten Frames können Signal-Semaphoren verloren gehen

**Stellen:** [URLibretroCore.m:1370](</Users/ben/Projekte/Ursprung - Retro Games Library for Mac/Ursprung/Bridge/URLibretroCore.m:1370>), [nachträglicher Submit:430](</Users/ben/Projekte/Ursprung - Retro Games Library for Mac/Ursprung/Bridge/URLibretroCore.m:430>).

`URCoreVideoRefresh` kehrt bei `data == NULL` sofort zurück. Ausstehende Vulkan-Arbeit wird erst nach der Rückkehr aus `retro_run` eingereicht. Der Vertrag von [set_signal_semaphore:493](</Users/ben/Projekte/Ursprung - Retro Games Library for Mac/Ursprung/Bridge/libretro_vulkan.h:493>) bindet das Signal jedoch an den nächsten Video-Callback, ausdrücklich auch an ein dupliziertes Frame.

**Auslöser / Folge:** Ein Core setzt Signal A, ruft `video_refresh(NULL, …)` auf und setzt anschließend Signal B vor einem weiteren Video-Callback innerhalb desselben `retro_run`. A wird überschrieben und niemals signalisiert. Wartet der Core bereits innerhalb von `retro_run` auf den Abschluss der von A abhängigen Arbeit, erreicht das Frontend seinen nachträglichen Submit gar nicht. Der entsprechende Duping-Vertrag verlangt außerdem, Image-Wait-Semaphoren nicht abzuwarten; der pauschale Submit nach `retro_run` unterscheidet diesen Fall nicht.

**Nachweis:** Original-Callbacks im Prüfprogramm: nach dem NULL-Callback null Submissions und A noch ausstehend; nach Setzen von B und einem weiteren Callback wird nur B eingereicht.

**Vorschlag:** Vulkan-Synchronisation im Video-Callback vor dem allgemeinen NULL-Return bearbeiten. Duping benötigt einen eigenen Modus: gegebenenfalls Core-Command-Buffer ausführen, das zugehörige Signal einmal einreichen, Image-Waits entsprechend dem Vertrag ignorieren und das vorhandene CPU-Bild beibehalten. Nachträgliches Aufräumen nach `retro_run` ersetzt diese Callback-Semantik nicht.

**Regressionstest:** Zwei Video-Callbacks innerhalb desselben `retro_run`, der erste mit NULL-Daten und eigenem Signal; beide Signale müssen genau einmal der passenden Submission zugeordnet sein. Zusätzlich NULL-Callback mit Image-Waits testen.

## F4 · P2 – Ownership-Transfer und Readback-Layoutwechsel passen nicht zusammen

**Stellen:** [URVulkanContext.m:602](</Users/ben/Projekte/Ursprung - Retro Games Library for Mac/Ursprung/Bridge/URVulkanContext.m:602>), [Release-Barriere:627](</Users/ben/Projekte/Ursprung - Retro Games Library for Mac/Ursprung/Bridge/URVulkanContext.m:627>), [bedingte Aufzeichnung:675](</Users/ben/Projekte/Ursprung - Retro Games Library for Mac/Ursprung/Bridge/URVulkanContext.m:675>).

Bei einer Übergabe aus einer anderen Queue-Familie kombiniert die Acquire-Barriere den Ownership-Wechsel direkt mit `SHADER_READ_ONLY_OPTIMAL → TRANSFER_SRC_OPTIMAL`. Die Release-Barriere kombiniert die Rückgabe mit dem umgekehrten Layoutwechsel. Der Core kennt nur das im Interface vereinbarte Image-Layout, nicht das intern für Ursprung gewählte Transfer-Layout.

Ein zulässiger Core kann vor der Übergabe einen Ownership-Release mit `SHADER_READ_ONLY_OPTIMAL → SHADER_READ_ONLY_OPTIMAL` aufzeichnen. Ursprungs Acquire stimmt dann nicht mit diesem Release überein. Die beiden Seiten eines Ownership-Transfers müssen dieselben alten und neuen Layouts angeben; siehe die [Khronos-Synchronisationsbeispiele](https://docs.vulkan.org/guide/latest/synchronization_examples.html).

**Auslöser / Folge:** Ein Core übergibt ein exklusives Image aus einer anderen Queue-Familie. Die Barrieren verletzen dann den Vulkan-Vertrag. Zusätzlich werden bei ausgeblendeten Frames oder nicht unterstütztem Pixelformat überhaupt keine Ownership-Barrieren aufgezeichnet, weil `copy == NO`; der erforderliche Hin- und Rücktransfer entfällt trotzdem nicht automatisch.

**Nachweis:** Die instrumentierte Aufzeichnung ergibt beim Acquire Layout `5 → 6`, beim Release `6 → 5`, obwohl der beschriebene Core-Transfer `5 → 5` verwendet. Das ist ein bedingter Vertragsfehler; ein betroffenes reales Spiel mit mehreren Queue-Familien wurde in diesem Review nicht reproduziert. Bei derselben Queue-Familie greift dieser Fehler nicht.

**Vorschlag:** Ownership separat im vereinbarten Image-Layout erwerben und zurückgeben. Dazwischen die lokalen Layoutwechsel für den Readback mit `VK_QUEUE_FAMILY_IGNORED` durchführen. Auch der Pfad ohne Bildkopie muss erforderliche Ownership-Übergaben abschließen, bevor die Wiederverwendung freigegeben wird.

**Regressionstest:** Release/Acquire-Paare anhand aufgezeichneter Barrieren prüfen, einschließlich verborgenem Frame und nicht unterstütztem Format; auf geeigneter Hardware zusätzlich mit zwei Queue-Familien und Vulkan-Validation testen.

## F5 · P2 – Der Readback ignoriert die Kanalzuordnung des Image Views

**Stellen:** [URVulkanContext.m:780](</Users/ben/Projekte/Ursprung - Retro Games Library for Mac/Ursprung/Bridge/URVulkanContext.m:780>), [Pixelkonvertierung:713](</Users/ben/Projekte/Ursprung - Retro Games Library for Mac/Ursprung/Bridge/URVulkanContext.m:713>).

`set_image` übernimmt Image, Format und Subresource, aber nicht `create_info.components`. Anschließend kopiert `vkCmdCopyImageToBuffer` die rohen Bilddaten. Die CPU-Konvertierung kennt nur das Format und rekonstruiert deshalb die im Image View festgelegte Farbkanal-Zuordnung nicht. Diese Zuordnung bestimmt die ausgegebenen Komponenten; siehe [VkComponentMapping](https://docs.vulkan.org/refpages/latest/refpages/source/VkComponentMapping.html).

**Auslöser / Folge:** Ein Core verwendet einen gültigen Image View mit vertauschtem Rot/Blau oder einer anderen nicht identischen Zuordnung. Ursprung zeigt falsche Farben; Screenshots, Shader-Eingabe und Save-State-Thumbnails übernehmen sie ebenfalls.

**Nachweis mit echtem GPU-Readback:** Zwei temporäre Kopien des vorhandenen Test-Cores rendern dasselbe RGBA-Bild. Die zweite Variante ändert ausschließlich die Image-View-Zuordnung auf `{B, G, R, A}`. Beide liefern mit unverändertem Anwendungscode `0xff014080`. Für die zweite Variante wäre nach der Zuordnung `0xff804001` korrekt. MoltenVK, Command-Buffer-Ausführung und Readback liefen bei diesem Test tatsächlich auf der GPU, ohne abgefangene Submissions.

**Vorschlag:** `VkComponentMapping` zusammen mit dem Image speichern und bei der Konvertierung berücksichtigen. Identitätszuordnung als schnellen Standardpfad behalten; `ZERO`, `ONE` und die einzelnen Komponenten korrekt abbilden. Alternativ das übergebene Image View in ein kanonisches Zwischenbild samplen, falls später ohnehin eine GPU-Konvertierung entsteht.

**Regressionstest:** Identität, R/B-Tausch und konstante Kanäle testen. Mindestens ein Test muss vom tatsächlichen Image View bis zum veröffentlichten CPU-Frame reichen.

## Weitere Verbesserungsmöglichkeiten

### V1 – Fallback-Anforderung und aktuelle Umsetzung vereinheitlichen

Die ursprüngliche Entscheidungstabelle verspricht OpenGL-/Software-Fallback bei Device-Erstellungsfehlern. Tatsächlich prüft `isAvailable` nur Instanz und physisches Gerät. Scheitert der ausgehandelte Kontext später, bricht [loadGame:385](</Users/ben/Projekte/Ursprung - Retro Games Library for Mac/Ursprung/Bridge/URLibretroCore.m:385>) den Start ab. Der Abschnitt „As built“ dokumentiert diese Abweichung bereits; sie ist deshalb hier eine offene Produktentscheidung und kein neu entdeckter, versteckter Fehler.

**Vorschlag:** Entweder einen einmaligen vollständigen Neustart des Core-Ladevorgangs mit OpenGL-/Software-Defaults umsetzen oder die ursprüngliche Fallback-Zusage überall auf den tatsächlich unterstützten Fall beschränken. Ein Retry muss Renderer-Optionen neu auflösen, einen frischen Core verwenden und vor erfolgreichem Start weiterhin kein vorhandenes Save-RAM überschreiben. Meldungen sollten die tatsächlich verwendete API nennen; der derzeitige Text behauptet auch beim N64-Software-Fallback „OpenGL“.

### V2 – Smoke-Tests müssen den tatsächlich getesteten Renderer absichern

[Tools/ursprung-smoke/main.m:105](</Users/ben/Projekte/Ursprung - Retro Games Library for Mac/Tools/ursprung-smoke/main.m:105>) setzt mit `URSMOKE_RENDERER` lediglich die bevorzugte API. Die nötigen Plugin-/Renderer-Optionen kommen separat über `URSMOKE_OPTIONS`. Das ist im Code dokumentiert, kann aber bei dem im Plan empfohlenen kurzen Aufruf `make smoke … RENDERER=vulkan` zu einem erfolgreichen Test des falschen Renderer-Pfads führen.

**Vorschlag:** Einen optionalen „erwartete tatsächliche API“-Parameter ergänzen, der bei abweichendem `core.graphicsAPI` mit Fehler endet. Für die Akzeptanz-Cores vollständige Smoke-Rezepte inklusive Optionen bereitstellen oder Defaults aus einer gemeinsam nutzbaren Datenquelle beziehen. Die separate Prüfung des Fallbacks darf eine API-Abweichung ausdrücklich erlauben.

### V3 – Speicherfehler dürfen Synchronisation nicht stillschweigend entfernen

In [URVulkanContext.m:680](</Users/ben/Projekte/Ursprung - Retro Games Library for Mac/Ursprung/Bridge/URVulkanContext.m:680>) wird das Ergebnis der dynamischen Command-Buffer-Array-Allokation vor `memcpy` nicht geprüft. Fehler beim Vergrößern der Semaphore- oder Command-Buffer-Arrays setzen außerdem nur deren Anzahl auf null. Damit können erforderliche Waits oder Core-Arbeiten verschwinden, während das Frame weiterverarbeitet wird.

**Vorschlag:** Allokationen vollständig prüfen und Änderungen erst nach erfolgreicher Vorbereitung übernehmen. Bei einem Fehler den gesamten Übergabevorgang kontrolliert abbrechen und den Fehler weiterreichen. Speicherfehler-Injektion kann diese seltenen Pfade ohne realen Speichermangel testen.

### V4 – Abnahme und Tests gezielt vervollständigen

Der Plan enthält weiterhin offene Abnahmen: paraLLEl-RDP 2× in der App, erste spielbare MGS-Szene, Disc-2-Wechsel und signierter/notarisierter Distributionsbuild. Phase 5 wurde bewusst vertagt; Phase 6 ist durch fehlendes geeignetes Testmaterial blockiert. Diese Punkte sind keine durch dieses Review nachgewiesenen Programmfehler, sollten aber nicht als erledigte Gesamt-Abnahme geführt werden.

**Vorschlag:** Die fünf oben beschriebenen Regressionstests ergänzen. Zusätzlich Negotiation v1 automatisiert prüfen – die bestehenden Vulkan-Test-Core-Modi verwenden v2 –, Größenwechsel, asymmetrische Testbilder/Orientierung und `GENERAL`-Layout abdecken. Für die reine Protokolllogik eine GPU-unabhängige Testschicht vorsehen, damit sie auch auf CI ohne GPU läuft. Die noch offenen manuellen Abnahmen separat protokollieren; `experimental` für Dolphin bis dahin beibehalten.

## Durchgeführte Validierung und Grenzen

Die vollständige bestehende Xcode-Testsuite wurde auf diesem Mac mit Ad-hoc-Signierung ausgeführt:

```sh
xcodebuild -project Ursprung.xcodeproj \
  -derivedDataPath build/DerivedData \
  -destination 'platform=macOS,arch=arm64' \
  -scheme Ursprung test -quiet \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
```

**Ergebnis:** 416 Testfälle bestanden, 2 übersprungen, 0 fehlgeschlagen. Durch parametrisierte Tests ergeben sich 457 erfolgreiche Ausführungen. Die beiden übersprungenen Tests sind `everyPackPresetRoundTrips()` und `realPackUnpacksAndIndexes()` aus dem Shader-Bereich. Sämtliche sechs Vulkan-Testfälle einschließlich ihrer Parameterfälle liefen erfolgreich.

Zusätzlich wurden ausschließlich unter `/tmp/ursprung-vulkan-review/` zwei Prüfprogramme und Test-Core-Varianten erstellt:

- **Protokollprüfung F1–F4:** Original-Implementierungen direkt eingebunden; Submit, Fence-Wait und Copy-/Barrier-Aufrufe gezielt abgefangen. Damit wurden die tatsächlichen Parameter und der Kontrollfluss geprüft. Die daraus möglichen GPU-Hänger oder Abstürze wurden nicht als reale Spielabstürze reproduziert.
- **Pixelprüfung F5:** Original-Bridge mit echtem MoltenVK-Kontext; vorhandener Test-Core einmal mit Identitätszuordnung und einmal mit R/B-Tausch. Tatsächlichen CPU-Frame nach einem gerenderten Frame verglichen.

Die erste Xcode-Ausführung innerhalb der Sandbox scheiterte vor den Tests am Zugriff auf das konfigurierte Entwicklungszertifikat. Der anschließende Lauf mit Ad-hoc-Signierung und erforderlichem Zugriff auf die lokalen Testdienste war erfolgreich. Die Protokoll- und Pixelprüfungen benötigten ebenfalls GPU-Zugriff außerhalb der Sandbox.

Reale Spiele, Langzeit-Performance, Disc-Wechsel und notarisierten Release habe ich in diesem Review nicht erneut getestet. Die entsprechenden Spike-Ergebnisse im Plan stammen aus der Implementierungsphase. Ein erfolgreicher Testlauf hebt die hier reproduzierten, bisher ungetesteten Sonderfälle nicht auf.

## Behebung (09.10.2026)

Alle fünf Findings wurden gegen `libretro_vulkan.h` und RetroArchs `gfx/drivers/vulkan.c` geprüft und bestätigt; RetroArch wartet ebenfalls nur bei einem echten Frame ohne Command Buffer auf Image-Semaphoren und überträgt Ownership im unveränderten Image-Layout.

| ID | Status | Umsetzung | Test |
|---|---|---|---|
| F1 | behoben | Timeout (jetzt 10 s), Device-Loss oder fehlgeschlagener Reset/Record/Submit setzen einen dauerhaften Fehlerzustand (`URVulkanContext.failed`). Danach kein Submit, kein Fence-Reset, keine Readback-Reallokation; `runFrame` ruft kein `retro_run` mehr auf, `shutdownRequested` beendet das Spiel. Beim Abbau wird ein nach Timeout noch laufender Frame erneut abgewartet; endet er nicht, bleiben Device und Instanz bewusst bestehen. | `aFailedFrameStopsTheGame` (VK_TIMEOUT und VK_ERROR_DEVICE_LOST simuliert) |
| F2 | behoben | Mit Core-Command-Buffern werden Image-Semaphoren ignoriert und verworfen; Ownership-Wechsel nur bei tatsächlich gewarteten Semaphoren. | `commandBuffersIgnoreTheImageSemaphores` (nie signalisiertes Semaphor) |
| F3 | behoben | Vulkan-Synchronisation läuft im Video-Callback vor dem NULL-Return: Duplikat-Frames führen Command Buffer aus und signalisieren ihr Semaphor, warten aber auf keine Image-Semaphoren und behalten das CPU-Bild. | `everyRefreshSignalsItsSemaphore` (Duplikat + echter Frame je `retro_run`, beide Modi) |
| F4 | behoben | Acquire/Release im vereinbarten Layout (`old == new`) über alle Mips/Layer; Layoutwechsel für die Kopie als getrennte Barrieren mit `VK_QUEUE_FAMILY_IGNORED`; Ownership-Rundreise auch ohne Kopie (verborgener Frame, nicht unterstütztes Format). | Kein automatischer Test: MoltenVK bietet nur eine Queue-Familie. |
| F5 | behoben | `create_info.components` wird gespeichert und bei der Konvertierung angewandt (`URComponentMapping`, Identität bleibt schneller Pfad). | `channelMappingsApply` (Identität, R/B-Tausch, Konstanten, Alpha) und `theImageViewsChannelMappingApplies` (echter MoltenVK-Readback) |
| V2 | umgesetzt | `make smoke RENDERER=vulkan` scheitert, wenn das Spiel mit einer anderen API rendert; `ALLOW_FALLBACK=1` erlaubt das, `OPTIONS=` reicht Core-Optionen durch. | Manuell: Mupen64Plus-Next ohne Optionen → Fehler |
| V3 | umgesetzt | Kein Allokieren mehr pro Frame (Platz für den eigenen Command Buffer wird in `set_command_buffers` reserviert); Allokationsfehler in `set_image`/`set_command_buffers` setzen den Fehlerzustand statt still Synchronisation zu verlieren. | – |
| V1, V4 | offen | Fallback-Neustart ist weiterhin eine Produktentscheidung; die manuelle Abnahme (paraLLEl-RDP 2×) steht aus, Dolphin bleibt `experimental`. | – |

Validierung: `xcodebuild … test` mit 423 Tests grün; `make smoke` mit Mupen64Plus-Next (paraLLEl-RDP), SwanStation (Vulkan) und Dolphin (MGS: Hauptmenü nach 3600 Frames) sowie je zwölf Lade-/Entladerunden für Mupen64Plus-Next und Dolphin.
