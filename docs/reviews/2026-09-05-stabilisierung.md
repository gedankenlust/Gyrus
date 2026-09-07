**Gyrus: Stabilisierungsrunde vom 5. September 2026**

Die 17 priorisierten Befunde der vorherigen Analyse wurden im lokalen Arbeitsstand bearbeitet. Schwerpunkt sind Datenintegrität, vollständige Kernabläufe und verständliche Rückmeldungen bei Fehlern. Die bereits vorhandenen Änderungen am kopierbaren Designbericht einschließlich ihrer Tests und Übersetzungen wurden beibehalten. Dieser Bericht beschreibt die zusätzliche Stabilisierungsarbeit; er bewertet keine veröffentlichte DMG.

**Änderungen zu den 17 Befunden**

| Befund | Umsetzung | Zentrale Dateien |
|---|---|---|
| 1 – Fremde Brain-Dateien | Vollständige Bookmark-ID als Herkunftsmarker. Bereinigung und Verschieben nur für identifizierte Gyrus-Dateien. Fremde Indexdateien bleiben erhalten; ein freier Indexname wird gewählt. Pfade dürfen den gewählten Ordner nicht verlassen. | `backend/services/brain_sync_service.py` |
| 2 – Gültige Backups mit gleichen Unterordnernamen | Eltern werden vor Kindern mit ihren endgültigen Elternbeziehungen eingesetzt. Gleichnamige Unterordner unter unterschiedlichen Eltern sind zulässig. | `backend/routers/data.py` |
| 3 – Erweiterungsberechtigung | Separater zufälliger Extension-Token, ausschließlich für `POST /api/bookmarks`. Diese Einschränkung gilt auch ohne Origin-Header. Der native App-Token wird nicht mehr beim Pairing ausgegeben. | `backend/security.py`, `backend/main.py` |
| 4 – HTML-Exportumfang | Ein Ordnerexport umfasst den gewählten Ordner und seine Unterordner. Papierkorb und andere Ordner werden ausgeschlossen. HTML und die anderen Formate verwenden denselben Umfang. | `backend/routers/export_.py`, `APIClient+Data.swift`, `ExportSheet.swift` |
| 5 – Verlorene Notizentwürfe | Entwürfe bleiben während der Sitzung pro Bookmark im Store erhalten. Leeren erst nach erfolgreichem Speichern und nur, wenn der Text zwischenzeitlich unverändert blieb. Speicherzustand und Fehler sind sichtbar; erneutes Speichern ist möglich. Auch Löschfehler werden angezeigt. | `BookmarkStore.swift`, `PreviewPanelView.swift` |
| 6 – Exportlimit und verschwiegene Fehler | Exportseiten mit maximal 200 Einträgen; weitere Seiten werden vollständig geladen. Netzwerk- und Dateifehler erscheinen im Dialog. Atomisches Schreiben; der Dialog schließt erst nach erfolgreichem Speichern. Abbruch im Dateidialog lässt die Exportauswahl erhalten. | `APIClient+Data.swift`, `ExportSheet.swift` |
| 7 – URL per Drag-and-drop | Der Host dient als gültiger Anfangstitel. Ein Drop in der Rasteransicht übernimmt den ausgewählten Zielordner. | `BookmarkStore.swift`, `BookmarkGridView.swift` |
| 8 – KI-Hauptschalter | Neues Backend-Feld `ai_enabled`, standardmäßig aus. Markdown-Spiegel nur bei aktivem Haupt- und Spiegelschalter. KI-Endpunkte und automatische Embeddings prüfen die Freigabe. Nach einer Abschaltung werden verspätete Modellergebnisse verworfen; auch Kompatibilitätswiederholungen starten keine neue Anfrage. | `ai_policy.py`, `embedding_service.py`, `llm_service.py`, KI-Router, `APIClient+Brain.swift` |
| 9 – Suchseiten mit Papierkorbtreffern | Aktive Treffer werden vor der Seiteneinteilung ausgewählt. Die Prüfung läuft gegen echte FTS-Tabellen und Migrationen. | `backend/services/search_service.py` |
| 10 – Veraltete Analyse nach URL-Wechsel | Reader-Inhalt, Metadatenstatus, Vektoren und Design-/Struktur-Caches werden zurückgesetzt; neue Analyse wird eingeplant. URL-Normalisierung und Duplikatprüfung erfolgen auch beim Bearbeiten. Der Chat verwendet einen Markdown-Scrape nur für dessen ausdrücklich vermerkte Quell-URL. Alte Markdown-Inhalte werden nach Möglichkeit separat erhalten. | `bookmark_service.py`, `routers/brain.py`, `schemas/bookmark.py` |
| 11 – Ungültige Backups und Zyklen | Prüfung vor dem Ersetzen: ID-Form, Typen, Datumswerte, doppelte IDs/URLs/Namen, Verweise, Tag-Verknüpfungen, Zyklen und maximale Baumtiefe. Fehler liefern 422 und lassen die Bibliothek erhalten. Historische Version-1-Backups mit sicheren Standardwerten bleiben unterstützt. | `backend/routers/data.py` |
| 12 – Restore mit alten Jobs/Indizes/Caches | Laufende Anfragen und Hintergrundjobs werden erfasst. Restore und URL-Wechsel werden bei konkurrierender Arbeit mit einer verständlichen 409-Meldung abgelehnt. Restore verwirft alte Vektoren und Caches; vorhandener Reader-Text wird bei aktiver KI neu indexiert. Lokale Chats, Auswahl, Filter und Entwürfe werden nach erfolgreichem Restore zurückgesetzt. Noch ausstehende Lösch-/Undo-Aktionen werden vorher beendet. | `maintenance.py`, `background.py`, `background_job.py`, `routers/data.py`, `AppStore.swift`, `SettingsView.swift`, `BrainChatStore.swift` |
| 13 – Falscher semantischer Status | Verwendet den aktiven Ollama-Server und das aktive Embedding-Modell einschließlich Modell-Tag. Bei ausgeschalteter KI erfolgt keine Modellabfrage. | `embedding_service.py`, `routers/search.py` |
| 14 – Unvollständiger Such-Fallback | Der tatsächlich verwendete Suchmodus bleibt im Ladekontext über alle Seiten stabil. „Alles auswählen“ berücksichtigt den Suchmodus; die Stichwort-ID-Suche umfasst auch Notizen, Chats und Tags. Papierkorb-Auswahl lädt bei Bedarf weitere Seiten. | `BookmarkStore.swift`, `routers/bookmarks.py` |
| 15 – Brain-Links und veraltete Metadaten | Einheitliche Dateinamen mit ID-Anhang für Schreiben und Index. Erzeugte Abschnitte werden nur bei unverändertem Inhalts-Hash ersetzt; angehängte Texte bleiben erhalten. Notizänderungen aktualisieren den Spiegel. Rasche Umbenennungen hinterlassen keinen dauerhaft alten Index. Import erzeugt die tatsächlich verlinkten Dateien. | `brain_sync_service.py`, `bookmark_service.py`, `import_service.py` |
| 16 – Abweichende Testdatenbank | Der eindeutige Ordnerindex referenziert die tatsächliche Spalte `parent_id`. Neue Integrationstests verwenden eine vollständig migrierte dateibasierte SQLite-Datenbank samt FTS-Triggern. Alembic unterstützt dafür eine übergebene Testverbindung. | `models/collection.py`, `alembic/env.py`, `test_stabilization.py` |
| 17 – Unvollständige Tag-Zuweisung | Neue Tags und Tag-Umschaltungen verwenden den Batch-Endpunkt mit sämtlichen ausgewählten IDs. Nicht geladene Zeilen werden nicht übersprungen. „Tag überall vorhanden“ wird nur für die gesamte Auswahl angezeigt. | `TagStore.swift` |

**Zusätzliche UX- und Qualitätsverbesserungen**

- Exportumfang direkt im Dialog: gesamte Bibliothek oder Ordner einschließlich Unterordnern, jeweils ohne Papierkorb.
- Notiz-Speicherknopf mit Fortschrittsanzeige, zugänglicher Bezeichnung und Hilfetext; unabhängige Entwürfe beim Wechsel zwischen Bookmarks.
- Sichtbarer Hinweis, wenn die Stichwortsuche die semantische Suche ersetzt.
- Serverhinweise zu laufender Arbeit werden nicht mehr irrtümlich als „Bookmark bereits vorhanden“ ausgegeben.
- Neue UI-Hinweise sind deutsch lokalisiert. Bestehende Übersetzungen blieben erhalten.
- „Brain-Index öffnen“ fragt den tatsächlich gewählten Dateipfad ab, statt `_Index.md` vorauszusetzen.
- Dokumentation korrigiert: Notizen werden ausdrücklich gespeichert; bisher versprochenes Auto-save und Bearbeiten vorhandener Einträge sind nicht implementiert.
- APIClient unterstützt eine austauschbare URLSession und Basis-URL; BookmarkStore und TagStore lassen sich mit einer Test-API aufrufen. Dadurch können echte Fehlerantworten und Seiteneinteilungen ohne produktiven Server geprüft werden.
- Der Swift-Testhost startet keinen regulären Backend-Prozess. Testläufe verwenden zusätzlich isolierte Benutzer- und Datenverzeichnisse.
- `setuptools` wurde in der Entwicklungsumgebung von 65.5.0 auf 83.0.0 aktualisiert und in `backend/requirements.txt` gebunden. Die bereits gebündelte Laufzeit verwendet ebenfalls 83.0.0.

**Validierung**

| Prüfung | Ergebnis |
|---|---|
| Backend-Gesamtsuite im finalen Stand | 400 bestanden; keine fehlgeschlagenen Tests. Darunter 32 neue Regressionstests. |
| Swift-App und Testbundle | Build erfolgreich. |
| Swift-Gesamtsuite im finalen Swift-Stand | 114 bestanden; keine Fehler. Darunter neun neue Regressionstests. |
| Gebündelte Python-Laufzeit | Start und vollständige Migration einer leeren Testdatenbank, Authentifizierung, KI-aus-Status, Export und leerer Restore erfolgreich. |
| PyPI-Audit der aktualisierten Entwicklungsumgebung | 50 Pakete; keine bekannten Schwachstellen gemeldet. |
| PyPI-Audit der unveränderten gebündelten Python-Pakete aus der Analyse | 44 Pakete; keine bekannten Schwachstellen gemeldet. |
| Diff und Lokalisierung | Keine Whitespace-Fehler; Lokalisierungskatalog gültiges JSON. |

Die Backend-Suite meldet weiterhin eine Deprecation-Warnung des FastAPI/Starlette-Testclients zur Nutzung von httpx. Sie ist kein Testfehler. Die Tests prüfen synthetische Daten in temporären Verzeichnissen; die persönliche Bibliothek wurde nicht für Restore- oder Löschversuche verwendet.

**Kompatibilität und bewusste Grenzen**

Nach Übernahme der Änderungen Gyrus einschließlich Backend neu starten, damit die aktualisierte Konfiguration und die getrennten Tokens gelten. Die Erweiterung holt beim Speichern ihren Token erneut ab. Es wurden keine Änderungen veröffentlicht oder committed.

Bereits vorhandene Markdown-Dateien ohne Herkunftsmarker werden weder automatisch übernommen noch gelöscht. Nach Aktivierung des Spiegels können deshalb neue eindeutig gekennzeichnete Dateien neben alten Dateien entstehen. Extern veränderte erzeugte Abschnitte werden erhalten und anschließend nicht automatisch überschrieben. Das verhindert Datenverlust, bedeutet aber auch, dass solche Dateien manuell abgeglichen werden müssen. Bei einem URL-Wechsel erhaltene Archivdateien werden nicht als aktive Gyrus-Spiegeldateien behandelt.

Ein Restore wartet nicht automatisch auf umfangreiche laufende Analysen: er meldet den Konflikt vor dem Ersetzen. Die Arbeit kann beendet oder abgebrochen und der Restore anschließend erneut gestartet werden. Bereits an Ollama gesendete Anfragen können beim Abschalten noch auslaufen; neue Anfragen werden verhindert und verspätete Ergebnisse verworfen. Ungespeicherte Notizentwürfe überstehen den Wechsel zwischen Bookmarks und Speicherfehler innerhalb der laufenden Sitzung, aber keinen App-Neustart.

Die Stabilisierungsrunde ersetzt keinen vollständigen manuellen Bedien-, VoiceOver- oder Release-Test. Noch sinnvoll sind Lastmessungen mit großen Bibliotheken, ein kompletter Tastatur-/Fokusdurchlauf, eine frische Installation des Distributionspakets, echte Ollama-Abläufe und zusätzliche Website-Kompatibilitätstests. Weiterführende Strukturarbeiten wie das Aufteilen des großen Design-Inspektors oder ein vollständiger Abhängigkeits-Lock wurden nicht in diese Fehlerkorrektur aufgenommen.
