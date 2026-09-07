# Gyrus: Meta-Analyse vom 6. September 2026

**Bewertung:** Gyrus hat eine brauchbare Funktionsbasis, gute Schutzmaßnahmen für die lokale API und umfangreiche Regressionstests. Die wichtigsten verbliebenen Schwächen liegen an den Übergängen zwischen Funktionen: Was sich anlegen lässt, lässt sich nicht immer wiederherstellen; ein zurückgesetzter Datenspeicher bedeutet noch keinen zurückgesetzten App-Zustand; ein erreichbarer HTTP-Port bedeutet noch keinen verwendbaren eigenen Backend-Prozess. Vor einer weiteren Freigabe sollten insbesondere die beiden Befunde zur Wiederherstellung geschlossen werden.

Diese Runde ist eine systematische, risikoorientierte Gesamtprüfung des aktuellen Arbeitsstands einschließlich der bisherigen Korrekturen. Sie ist keine Garantie, dass jede mögliche Bedienfolge fehlerfrei ist. Es wurden **keine Produktfunktionen geändert und kein neuer Build installiert**. Destruktive Prüfungen liefen ausschließlich mit künstlichen Daten in temporären Verzeichnissen. Die produktive Oberfläche wurde für die Prüfung der Bibliothek sowie der Hinzufügen- und Exportdialoge bedient, ohne Daten anzulegen, zu löschen oder wiederherzustellen.

## Evidenz und Prüfumfang

| Bereich | Ergebnis und Grenze |
|---|---|
| Backend-Tests | **400 bestanden**, eine Deprecation-Warnung des Testclients. Der erste eingeschränkte Lauf hatte fünf durch verbotene lokale Test-Sockets verursachte Fehler; mit den erforderlichen Berechtigungen bestanden alle Tests. |
| Native Tests | **120 bestanden**, erneut ausgeführt mit dem aktuellen, unveränderten Testbuild und isolierten Benutzer-/Datenpfaden. |
| Zusätzliche Fehlerproben | Elf protokollierte Szenarien gegen echte Alembic-Migrationen und die produktive FastAPI-App mit ihren Middleware-Prüfungen. Hintergrund-Fetches wurden unterbunden. Ergebnisse unten. |
| Abhängigkeiten | Frischer PyPI-Audit: **50 Entwicklungspakete und 44 Pakete der installierten Laufzeit**, jeweils null gemeldete bekannte Schwachstellen und null übersprungene Pakete. Das ist keine Prüfung des Chromium-Binaries auf CVEs. |
| Geheimnisse | Gitleaks über 244 Dateien des aktuellen, nicht ignorierten Arbeitsstands: kein Fund; Bericht redigiert konfiguriert. Keine vollständige Git-Historienprüfung. |
| Installierte App | Version **1.5.0, Build 18**, Mindestversion laut Info.plist 14.0; vollständige Signaturprüfung erfolgreich. Der Release-Build aus der unmittelbar vorherigen Korrekturrunde war erfolgreich. |
| Projektgenerator | In einer temporären Kopie mit derselben Ordnerstruktur erzeugt er identische Projekt- und Scheme-Dateien. Ein zusätzlicher leerer lokaler Ordner verändert die generierten IDs; ein frischer Checkout kann deshalb unnötige Diffs erzeugen. |
| Formale Prüfungen | `git diff --check`, Shell-Syntax der Release-/Runtime-Skripte und JSON des Lokalisierungskatalogs ohne Befund. |
| UX | Bibliothek, Hinzufügen und Export in der installierten App; zusätzlich Quellprüfung von Start, Einstellungen, Navigation, Notizen, Chat, Lösch-/Undo-Abläufen und Fehlerrückmeldungen. Kein vollständiger VoiceOver-Durchlauf. |
| Leistung | Synthetische Backend-Messung mit 1.000 und 10.000 Lesezeichen; keine Messung von UI-Bildrate, Akku, Chromium-Auslastung oder echtem Ollama. |

Die [Stabilisierungsrunde](/Users/sky/Developer/Gyrus/docs/reviews/2026-09-05-stabilisierung.md) und die [Fensterkorrektur](/Users/sky/Developer/Gyrus/docs/reviews/2026-09-06-autostart-fenster.md) bleiben gültige Berichte über ihre jeweiligen Prüfungen. Die hier gefundenen Gegenbeispiele zeigen zusätzliche Grenzen ihrer Aussagen.

## Priorisierte Befunde

P1 bedeutet hier: vor der nächsten Freigabe beheben, weil eine normale Datenoperation einen unerwarteten Verlust oder eine unbrauchbare Sicherung verursachen kann. P2 bezeichnet relevante Funktionsfehler oder konkrete Absicherungs-/Testlücken. „Reproduziert“ bezieht sich auf die isolierten Proben; reine Codebefunde werden ausdrücklich so bezeichnet.

### F01 · P1 · Fremde JSON-Datei wird als leeres Backup angenommen

**Reproduziert:** Eine Bibliothek mit einem künstlichen Lesezeichen wurde durch `POST /api/data/restore` mit `{"unrelated":"configuration"}` geleert. Antwort: HTTP 200. Alle Tabellenlisten und sogar die Versionsangabe haben Standardwerte; unbekannte Felder verhindern die Annahme nicht. Der Dateidialog akzeptiert beliebige JSON-Dateien. Bestätigt ein Nutzer versehentlich die falsche Datei, wird daraus eine erfolgreiche leere Wiederherstellung.

**Änderung:** Vor dem Ersetzen ein eindeutig erkennbares Backup-Format mit erforderlicher Versions-/Strukturinformation verlangen; bekannte ältere Formate gezielt unterstützen. Vor der Bestätigung Dateiname, Exportdatum und tatsächlich gelesene Objektzahlen anzeigen. Eine gültige leere Sicherung muss weiterhin ausdrücklich erkennbar sein. Eine Sicherung des bestehenden Zustands unmittelbar vor dem Austausch würde eine weitere Rückfallebene bieten.

**Abnahme:** `{}`, fremdes JSON und unvollständige Backup-Strukturen liefern 422 und verändern keine Daten; eine ausdrücklich gültige leere Sicherung bleibt importierbar.

Quelle: [RestoreData](/Users/sky/Developer/Gyrus/backend/routers/data.py:186), [Restore-Dialog](/Users/sky/Developer/Gyrus/Gyrus/Views/Settings/SettingsView.swift:296).

### F02 · P1 · Erlaubte Ordner erzeugen nicht wiederherstellbare Backups

**Reproduziert:** Ein leerer Ordnername und ein Name mit 256 Zeichen wurden jeweils mit HTTP 201 angelegt. Das unmittelbar danach erzeugte eigene Backup wurde mit HTTP 422 abgewiesen. Dasselbe gilt für eine über die API angelegte Hierarchie mit 65 Ebenen. Die Wiederherstellung erzwingt Grenzen, die Anlegen, Bearbeiten und teilweise Import nicht gemeinsam durchsetzen.

**Änderung:** Einheitliche Regeln für Namen und Baumtiefe in Anlegen, Bearbeiten, Verschieben, Import und Restore. Bereits vorhandene Daten außerhalb neuer Grenzen benötigen eine verlustfreie Kompatibilitäts- oder Reparaturstrategie; einfach strengere Backup-Ablehnung wäre keine Lösung.

**Abnahme:** Jede erfolgreich gespeicherte Bibliothek besteht den Durchlauf „Backup → Restore → gleiche Nutzdaten“, einschließlich Randfällen und älteren Datenständen.

Quelle: [Collection-Schemas](/Users/sky/Developer/Gyrus/backend/schemas/collection.py:5), [Restore-Regeln](/Users/sky/Developer/Gyrus/backend/routers/data.py:241), [Import](/Users/sky/Developer/Gyrus/backend/services/import_service.py:23).

### F03 · P2 · Werkseinstellungen setzen den laufenden Zustand nicht vollständig zurück

**Teilweise reproduziert:** Nach `factory-reset` antwortete das Backend mit 200, der zuvor aktivierte KI-Hauptschalter war intern weiterhin aktiv. Im Swift-Code wird die gespeicherte UserDefaults-Domain entfernt, die bereits geladenen Eigenschaften von `AppSettings.shared` werden aber nicht zurückgesetzt. Chat-Zwischenspeicher, Notizentwürfe und ausstehende UI-Aktionen werden hier ebenfalls nicht so bereinigt wie bei der Backup-Wiederherstellung.

**Änderung:** Reset als gemeinsamen Ablauf für Datenspeicher, aktive Konfiguration, laufende Aufgaben und UI-Zustand implementieren. Die Anzeige muss erst nach erfolgreicher Backend-Operation zurückgesetzt werden; danach Standardkonfiguration auch im Backend aktiv anwenden. Betriebssystem-Einstellungen wie Autostart gesondert behandeln und den zugesagten Umfang klar benennen.

**Abnahme:** Nach Reset sind KI und Spiegel gemäß Standard aus, alte lokale Inhalte verschwunden und laufende Ansichten konsistent; ein anschließender Neustart ändert diesen Zustand nicht nochmals überraschend.

Quelle: [Backend-Reset](/Users/sky/Developer/Gyrus/backend/routers/data.py:106), [AppStore.handleReset](/Users/sky/Developer/Gyrus/Gyrus/Services/AppStore.swift:604).

### F04 · P2 · Übliche Eingabekonflikte enden als Serverfehler

**Reproduziert:** Doppelter Ordnername unter demselben Elternordner, unbekannte Eltern-ID, explizit null gesetzter Ordnername und Umbenennen eines Tags auf einen schon vorhandenen Namen lieferten jeweils HTTP 500. Die Datenbank schützt ihre Constraints, aber der API-Vertrag übersetzt diese Fälle nicht in brauchbare Eingabefehler.

**Änderung:** Vorprüfung und abgefangene `IntegrityError` mit Rollback; 409 für Namenskonflikte, 404/422 für ungültige Verweise und Pflichtwerte. Dialoge offen lassen und den betreffenden Namen direkt markieren. Die Datenbank-Constraints als letzte Sicherung beibehalten.

**Abnahme:** Die vier Gegenbeispiele liefern spezifische Antworten; nach jedem Fehler funktionieren weitere Schreiboperationen und die bestehende Struktur bleibt erhalten.

Quelle: [Ordner anlegen](/Users/sky/Developer/Gyrus/backend/routers/collections.py:94), [Tag bearbeiten](/Users/sky/Developer/Gyrus/backend/routers/tags.py:225).

### F05 · P2 · Fensterkorrektur ersetzt noch keine vollständige Prozesssteuerung

**Codebefund mit Beobachtung aus der vorherigen Installation:** `willTerminateNotification` plant das Beenden des Backends in einem neuen asynchronen Task. Beim unmittelbar vorherigen regulären Beenden blieb der Python-Prozess tatsächlich bestehen und musste vor dem App-Austausch separat beendet werden. Außerdem genügt für den Startstatus irgendeine Antwort `{"status":"ok"}` auf dem festen Port: Weder der erfolgreiche Weiterbetrieb des gestarteten Prozesses noch ein authentifizierter Zugriff mit dessen Token werden geprüft. Nach einem Portkonflikt oder einem noch auslaufenden alten Backend kann die App deshalb Bereitschaft melden, obwohl die eigentliche API nicht verwendbar ist. Dieser Portkonflikt wurde nicht an der persönlichen Installation provoziert.

**Änderung:** Backend-Abschluss in einen zuverlässigen Delegate-Lebenszyklus übernehmen, tatsächliches Prozessende begrenzt abwarten und Port-/Prozessfehler sichtbar behandeln. Bereitschaft zusätzlich anhand eines authentifizierten Zugriffs prüfen. Fenster-, Backend- und Bibliothekszustand voneinander unterscheiden.

**Abnahme:** Reguläres Beenden lässt keinen eigenen Backend-Prozess zurück; sofortiges Wiederöffnen, belegter Port und ein absichtlich vorzeitig beendeter Kindprozess führen zu korrekter Bereitschaft oder einer verständlichen Fehlermeldung.

Quelle: [Beenden](/Users/sky/Developer/Gyrus/Gyrus/GyrusApp.swift:33), [Backend-Start](/Users/sky/Developer/Gyrus/Gyrus/Services/BackendLauncher.swift:187), [Health-Prüfung](/Users/sky/Developer/Gyrus/Gyrus/Services/APIClient.swift:121).

### F06 · P2 · KI-Einstellung kann vom aktiven Backend abweichen

**Codebefund:** Eine Änderung wird sofort lokal gespeichert und über einen unabhängigen Task übertragen. Fehler werden nur protokolliert. Schlägt das Abschalten etwa während einer Wartung oder einer Verbindungslücke fehl, kann die Oberfläche „aus“ anzeigen, während das laufende Backend seine bisherige Freigabe behält. Ein gesunder `/health`-Status führt in der Wiederverbindung nicht grundsätzlich zum erneuten Abgleich. Schnelle Änderungen werden zudem nicht über eine einzige geordnete Übertragung zusammengeführt.

**Änderung:** Gewünschten und bestätigten Zustand unterscheiden, Konfigurationsübertragung serialisieren, neueste Konfiguration bei Wiederverbindung erneut übertragen und eine fehlgeschlagene Abschaltung sichtbar machen. Ein deaktivierter UI-Schalter allein ist kein Beleg für den Backend-Zustand.

**Abnahme:** Unterbrochene Übertragung und schnelle Ein-/Aus-Folge enden in exakt der zuletzt gewählten Konfiguration; Übertragungsfehler verschwinden nicht nur im Log.

Quelle: [Konfigurationsübertragung](/Users/sky/Developer/Gyrus/Gyrus/Services/AppSettings.swift:246), [Wiederverbindung](/Users/sky/Developer/Gyrus/Gyrus/Services/AppStore.swift:269).

### F07 · P2 · Mehrere Bedienabläufe verschweigen weiterhin Fehler

**Codebefund:** Das erste Laden nutzt für Bibliothek, Ordner, Tags und Zähler jeweils `try?`. Der Dialog „neuer Tag für Auswahl“ schließt sofort und unterdrückt Fehler der asynchronen Zuweisung. „Chat leeren“ leert die lokale Anzeige vorab und verwirft Fehler beim serverseitigen Löschen; beim späteren Laden kann die angeblich gelöschte Unterhaltung wieder erscheinen. In der Erweiterung wird jede 409-Antwort weiterhin als „bereits gespeichert“ übersetzt, obwohl Wartung ebenfalls 409 liefert.

**Änderung:** Erstladen mit erkennbarem Fehler-/Wiederholungszustand; Tagdialog bis zum Erfolg offen halten; Chat-Löschen bestätigen oder bei Fehler zurückrollen; strukturierte Fehlercodes zwischen Backend, nativer App und Erweiterung vereinheitlichen.

**Abnahme:** Gezielt erzeugte Netzwerkfehler, 409 und 500 führen in jedem dieser Abläufe zu einer sichtbaren und passenden Rückmeldung ohne verlorene Eingabe oder falsche Erfolgsaussage.

Quelle: [Erstladen](/Users/sky/Developer/Gyrus/Gyrus/Services/AppStore.swift:35), [Tagdialog](/Users/sky/Developer/Gyrus/Gyrus/ContentView.swift:67), [Chat löschen](/Users/sky/Developer/Gyrus/Gyrus/Services/BrainChatStore.swift:112), [Erweiterung](/Users/sky/Developer/Gyrus/extension/popup.js:58).

### F08 · P2 · Fehlgeschlagener Vektoraustausch entfernt den bisherigen Indexeintrag

**Reproduziert:** Ein gültiger Vektor wurde gespeichert; ein Ersatz mit falscher Dimension scheiterte. Danach waren null Vektoren vorhanden. `upsert` löscht zuerst und fügt anschließend ohne gemeinsame Transaktion ein. Ein Fehler beim Einfügen verliert deshalb bereits brauchbare Suchdaten. Ein Modellwechsel ist ein relevanter Auslöser für Dimensionsunterschiede.

**Änderung:** Dimension prüfen und Austausch atomar durchführen; Modellidentität und Dimension zum Indexzustand speichern. Beim Modellwechsel den neuen Index kontrolliert aufbauen, statt verschiedene Embeddings still zu mischen. Auch Restore löscht Vektoren über eine getrennte Verbindung vor dem Datenbank-Commit; dessen Fehlerpfad sollte den Wiederaufbau klar behandeln.

**Abnahme:** Ein abgelehnter Ersatz erhält den alten Eintrag; Modellwechsel und abgebrochener Neuaufbau liefern einen nachvollziehbaren Status.

Quelle: [vector_store.upsert](/Users/sky/Developer/Gyrus/backend/services/vector_store.py:61), [Restore](/Users/sky/Developer/Gyrus/backend/routers/data.py:303).

### F09 · P2 · Request-Größenlimit prüft nur den Header

**Reproduziert im verkleinerten Testmaßstab:** Bei auf 128 Byte gesetztem Limit wurde dieselbe 351-Byte-Nutzlast mit `Content-Length` abgewiesen (413), ohne diesen Header als Chunked-Request jedoch gespeichert (201). Es wurde keine große Last erzeugt. Die vorhandene 100-MB-Konstante ist damit keine verlässliche Grenze für eingelesene Daten.

**Änderung:** Tatsächlich empfangene Bytes im ASGI-Receive-Pfad zählen und bei Überschreitung abbrechen; zusätzliche zweckbezogene Feld-/Uploadgrenzen beibehalten. Authentifizierung und Origin-Schutz bleiben wirksam — dieser Befund ist kein Beleg für unberechtigten Fernzugriff.

**Abnahme:** Identische Begrenzung mit, ohne und bei unzutreffendem Längenheader, einschließlich gestreamter Uploads.

Quelle: [Request-Middleware](/Users/sky/Developer/Gyrus/backend/main.py:93).

### F10 · P2 · Getestete und ausgelieferte Python-Umgebung sind nicht identisch

**Gemessen:** Fünf gemeinsame Pakete unterscheiden sich zwischen Entwicklungsumgebung und installierter Laufzeit:

| Paket | Entwicklung | Installierte Laufzeit |
|---|---|---|
| pip | 26.2.1 | 26.2 |
| lxml | 6.1.1 | 6.1.2 |
| python-dotenv | 1.2.2 | 1.2.3 |
| chardet | 7.5.1 | 7.6.0 |
| idna | 3.18 | 3.19 |

Beide Umgebungen bestanden den aktuellen Schwachstellen-Audit. Der Befund betrifft Reproduzierbarkeit: Die direkten Anforderungen sind gebunden, transitive Auflösungen bleiben veränderlich. `release.sh` testet die Entwicklungsumgebung und übernimmt die vorhandene gebündelte Laufzeit; es erzwingt keinen Neuaufbau beziehungsweise vollständigen Abgleich dieser Laufzeit mit den aktuellen Anforderungen. CI enthält bereits einen separaten Runtime-Smoke-Test und Audit — diese gute Prüfung sollte verbindlich mit dem tatsächlich verteilten Artefakt verbunden sein.

**Änderung:** Vollständige, plattformgerechte Abhängigkeitsbindung und ein Runtime-Manifest mit Eingabe-Hash; vor Packaging Übereinstimmung prüfen. Kritische HTTP-/Migrations-/Backup-Tests zusätzlich gegen genau die zu verteilende Laufzeit ausführen.

**Abnahme:** Gleiche freigegebene Eingaben ergeben gleiche Paketversionen; eine veraltete lokale Laufzeit kann nicht unbemerkt verpackt werden.

Quelle: [Runtime-Build](/Users/sky/Developer/Gyrus/backend/build_python_runtime.sh:60), [Release-Prüfungen](/Users/sky/Developer/Gyrus/release.sh:157), [CI](/Users/sky/Developer/Gyrus/.github/workflows/ci.yml).

## UX-Verbesserungen

| Priorität | Beobachtung | Konkrete Verbesserung |
|---|---|---|
| Hoch | Restore-Bestätigung beschreibt pauschal das Ersetzen, prüft und erklärt die gewählte Sicherung aber erst danach. | Vorschau mit Exportdatum, Dateiname, Ordner-/Lesezeichen-/Notizanzahl; ungültige Sicherungen bereits vor dem destruktiven Knopf ablehnen. |
| Hoch | Löschdialog behauptet „permanently deletes“, der zugehörige Backend-Ablauf verschiebt in den 30-Tage-Papierkorb. Undo wird nur bei mehr als zehn Einträgen angeboten. | „In den Papierkorb verschieben“ von endgültigem Löschen unterscheiden; konsistentes Undo und präzise Erklärung der Einstellung „Vor dem Löschen nachfragen“. |
| Hoch | Verbindungs-, Lade- und Speicherschwierigkeiten werden je nach Funktion unterschiedlich oder gar nicht dargestellt. | Einheitliche sichtbare Zustände mit „Erneut versuchen“, erhaltener Eingabe und verständlicher Ursache; besonders F05–F07. |
| Mittel | Im Accessibility-Baum heißen einzelne Symbolknöpfe `gearshape`, `checklist` oder „Funken“; Tooltip erklärt teilweise mehr als die eigentliche Bezeichnung. | Explizite Labels „Einstellungen“, „Alle auswählen“, „Semantische Suche“ sowie ein zugänglicher Ein-/Aus-Zustand. Anschließend mit VoiceOver und Tastatur prüfen. |
| Mittel | Export erklärt Umfang, Papierkorb-Ausschluss und Format bereits gut. „Plain Text“ bleibt im deutschen Dialog Englisch. Während des Exports ist Abbrechen deaktiviert. | Letzte Formate vollständig lokalisieren; lange Exporte mit Fortschritt und tatsächlichem Abbruch unterstützen. |
| Mittel | Notizentwürfe bleiben bei Bookmark-Wechsel erhalten, überstehen aber keinen App-Neustart. | Lokale Entwurfsablage oder verlässlicher Hinweis beim Beenden; gespeicherte und ungespeicherte Inhalte eindeutig kennzeichnen. |
| Mittel | Erststart bietet sofort KI-/Markdown-Einrichtung; die Kernfunktion ist ein Lesezeichen- und Recherchewerkzeug. | Zuerst „Importieren“ oder „Lesezeichen hinzufügen“ anbieten; KI als spätere optionale Einrichtung zugänglich halten. Das ist eine Produktentscheidung, kein nachgewiesener Funktionsfehler. |
| Mittel | Drei Mindestspalten benötigen zusammen bereits ungefähr 1.020 Punkte, ohne weitere Fensterabstände. | Kompakten Modus auf kleinen Displays und bei großer Schrift prüfen; Detailansicht bei Bedarf separat öffnen. Keine pauschale Aussage zur Bedienbarkeit aller Bildschirmgrößen aus diesem Durchgang. |

Der Hinzufügen-Dialog setzt den Fokus sinnvoll ins URL-Feld und deaktiviert Speichern ohne Eingabe. Die Exportauswahl kommuniziert Format und Umfang verständlich. Diese funktionierenden Muster sollten für die übrigen Dialoge übernommen werden.

## Architektur, Sicherheit und noch offene Prüfpunkte

**Tragfähige Grundlagen:** Die lokale API verlangt Tokens, unterscheidet den eingeschränkten Erweiterungs-Token und blockiert fremde Web-Origins. Ausgehende Backend-Fetches und Chromium nutzen die gemeinsame Egress-Prüfung statt unabhängiger Sonderlösungen. SQL-Parameter, Datenbank-Constraints, Alembic-Migrationen, Papierkorb und SQLite-Backups sind sinnvolle Schutzschichten. KI-Inhalte werden als untrusted Referenzdaten getrennt von den Systemanweisungen aufgebaut. Diese Grundlagen sind durch die vorhandenen Tests wesentlich besser abgesichert als die vollständigen UI-Abläufe.

**Live-Webansicht gesondert prüfen:** `WebPreviewSecurityPolicy` prüft Host-Schreibweisen in Navigationsentscheidungen; sie nutzt nicht den Backend-Egress-Proxy und löst Hosts nicht auf validierte Zieladressen auf. Das ist eine andere Schutzstufe als die Chromium-Inspektion. Apple beschreibt `WKNavigationDelegate` als Steuerung von Navigation und `WKWebsiteDataStore.nonPersistent()` als nicht persistente Datenhaltung; daraus folgt kein umfassender Filter sämtlicher Netzwerkanfragen. Ein gezielter Integrationstest mit kontrollierten Navigationen, Subressourcen und DNS-Zielen fehlt hier noch. In dieser Runde wurde **kein tatsächlicher Zugriff auf private Dienste über WebKit demonstriert**. Quelle: [lokale Policy](/Users/sky/Developer/Gyrus/Gyrus/Views/PreviewPanel/WebPreviewView.swift:5), [Apple: WKNavigationDelegate](https://developer.apple.com/documentation/webkit/wknavigationdelegate?changes=_2_3&language=objc), [Apple: WKWebsiteDataStore](https://developer.apple.com/documentation/webkit/wkwebsitedatastore?changes=lat_3_5).

**Chat-Abbruch und Wiederbeginn:** `load` berücksichtigt eine Generation, die Streaming-Callbacks in `send` dagegen verändern Nachrichten anhand eines gespeicherten Array-Indexes. „Leeren → sofort neue Nachricht“ beziehungsweise Reset während eines auslaufenden Tasks verdienen einen kontrollierten Test auf verspätete Schreibzugriffe und falsche `sending`-Zustände. Das ist hier ein Codehinweis, kein reproduzierter UI-Fehler. Quelle: [BrainChatStore](/Users/sky/Developer/Gyrus/Gyrus/Services/BrainChatStore.swift:80).

**Backup-Betrieb:** Tägliche Snapshots werden beim Backend-Start angestoßen. Eine tagelang durchlaufende App erzeugt dadurch nicht automatisch alle 24 Stunden ein neues Backup. Fehlgeschlagene Sicherungen werden protokolliert; die Oberfläche zeigt keinen klaren letzten erfolgreichen Sicherungsstand. Für Autostart-/Dauerbetrieb sind ein Zeitplan im Prozess und ein sichtbarer Status sinnvoll. Quelle: [Backup-Service](/Users/sky/Developer/Gyrus/backend/services/backup_service.py:30), [Startup](/Users/sky/Developer/Gyrus/backend/main.py:55).

**Wartbarkeit:** Der visuelle Snapshot-Service umfasst 1.559 Zeilen, der Design-Helfer 1.310, die Preview-Ansicht 981. Diese Größen allein beweisen keinen Fehler, erhöhen aber den Aufwand für die Prüfung von Seiteneffekten. Nach den Daten-/Zustandskorrekturen sollten Datenextraktion, Persistenz, Berichtserzeugung und UI-Darstellung klarer getrennt werden. Vorab Regressionstests für bestehende Berichtsausgaben und Cache-/Versionswechsel sichern.

## Leistungsmessung

Median aus drei Requests pro Fall, lokale In-Process-HTTP-Prüfung gegen eine migrierte temporäre SQLite-Datenbank. Jeder Datensatz enthält Titel, URL, Beschreibung und ungefähr 1.100 Zeichen Reader-Text; keine realen Websites, Tags, Chats oder KI-Berechnungen. Die Zahlen sind eine Stichprobe auf diesem Mac, keine zugesagte Nutzerlatenz.

| Operation | 1.000 Lesezeichen | 10.000 Lesezeichen |
|---|---:|---:|
| Erste Seite, 100 Einträge | 8,7 ms | 33,4 ms |
| Zähler | 2,3 ms | 7,0 ms |
| Stichwortsuche, erste 100 Treffer | 18,9 ms | 48,4 ms |
| Vollständiges JSON-Backup | 21,1 ms | 227,2 ms |

Das Backup mit 10.000 Einträgen umfasst rund 17 MB. Für größere Bibliotheken bleiben relevant: vollständiges Laden aller Treffer-IDs bei der Suche, Reader-Text im geladenen ORM-Modell, Volltextscans für Notizen/Chats, speicherbasierter JSON-Export und fünfsekündiges Polling auch im Hintergrund. Die hier gemessenen Standardfälle zeigen keinen akuten Leistungsengpass; Belastung mit großen Reader-Inhalten, vielen Chats und parallelen Design-Jobs ist damit noch nicht abgedeckt.

## Warum die vorhandenen Tests die Fehler nicht fanden

Die bisherigen Tests prüfen viele einzelne Funktionen und bekannte Regressionen gut. Der Großteil der Backend-Fixtures nutzt jedoch eine kleine In-Memory-Datenbank mit `create_all`; nur ein Teil prüft die echte Migrations-/Middleware-Kombination. Native Tests decken vor allem Modelle, Zustandslogik und einzelne API-Antworten ab. Ein vollständiger Ablauf über Betriebssystem, SwiftUI, Kindprozess, HTTP, SQLite und Dateisystem wird dadurch nicht ersetzt.

Die neu belegten Fehler verlangen insbesondere **Eigenschaftstests und Ablaufprüfungen**:

1. Was sich gültig anlegen oder importieren lässt, muss sich verlustfrei sichern und wiederherstellen lassen.
2. Eine abgewiesene Operation muss die vorherigen Daten und zugehörigen Indizes erhalten.
3. Ein angezeigter Erfolg muss dem bestätigten Zustand im Backend entsprechen.
4. Reset und Abbruch müssen auch auslaufende Tasks, lokale Zwischenspeicher und erneutes Öffnen berücksichtigen.
5. Der als bereit gemeldete Backend-Prozess muss der eigenen gestarteten und authentifizierten Instanz entsprechen.
6. Die geprüfte Laufzeit muss der tatsächlich verteilten Laufzeit entsprechen.

## Empfohlene Reihenfolge und Abschlusskriterien

1. **Daten schützen:** F01/F02 zuerst; Gegenbeispiele als dauerhafte Regressionstests, anschließend vollständige Backup-Rundläufe mit gültigen Altformaten. F03 gemeinsam mit der Bereinigung ausstehender Aufgaben umsetzen.
2. **Zustände verlässlich machen:** F05/F06, danach F07 und gezielte Chat-/Undo-Abbruchtests. Start, reguläres Beenden, sofortiger Neustart und ein vollständiger Login-/Wake-Durchlauf prüfen.
3. **Grenzen vereinheitlichen:** F04/F08/F09, kontrollierter WebKit-Netzwerktest und klare Aussagen zur Live-Webansicht.
4. **Freigabe absichern:** F10, Installation des tatsächlichen Distributionsartefakts auf der ältesten unterstützten macOS-Version, Runtime-/Chromium-Smoke-Test, echte Ollama-Abläufe sowie Tastatur-/VoiceOver-Prüfung.

Ein Rechnerneustart, Intel-Hardware, ein frisches macOS-Benutzerkonto, tatsächliches macOS 14, reale Ollama-Inferenz und ein neuer DMG-Installationsdurchlauf wurden in dieser Runde nicht getestet. Die bestehende Autostart-Fensterkorrektur hat weiterhin ihre automatisierten und manuellen Wiederöffnungsprüfungen bestanden; der vollständige Login-Praxistest bleibt offen.

## Artefakte und Wiederholung

Alle zehn aufbewahrten Prüfdateien liegen unter [Meta-Analyse-Artefakte](/Users/sky/Developer/Gyrus/docs/reviews/2026-09-06-meta-analyse). Enthalten sind Fehlerproben und Resultate, Benchmark und Messwerte, beide Testsuiten-Protokolle, beide Abhängigkeits-Audits sowie der Secret-Scan. Die Proben erzeugen bei jedem Lauf neue temporäre Datenverzeichnisse und greifen nicht auf die persönliche Bibliothek zu.

```sh
cd /Users/sky/Developer/Gyrus/backend
venv/bin/python ../docs/reviews/2026-09-06-meta-analyse/probes.py
venv/bin/python ../docs/reviews/2026-09-06-meta-analyse/benchmark.py
```

Die Skripte schreiben ihre neuen Ergebnisdateien nach `/tmp/gyrus-meta-review/`; dieses Verzeichnis bei einer späteren Wiederholung vorher anlegen. Die aufbewahrten JSON-Dateien dokumentieren den in dieser Runde geprüften Stand. Die native Ergebnisdatei liegt zusätzlich temporär unter `/tmp/gyrus-meta-review/SwiftTests.xcresult`.
