# Große Bibliotheken: Metadaten und KI-Tag-Vergabe

## Befunde

- Die Metadaten-Aktualisierung startete für jeden Eintrag eine Task und sammelte alle Ergebnisse bis zu einer einzigen abschließenden Transaktion. Einzelne Seiten konnten durch Redirects, langsame Datenübertragung und mehrere Favicon-Fallbacks die ganze Sammlung lange aufhalten. Die angezeigten Fortschritte waren bis zum Ende noch nicht in der Datenbank gespeichert.
- Die gemeinsame Tag-Vergabe lud zunächst fehlende Reader-Texte sämtlicher ausgewählter Seiten nach. Damit musste die KI-Vorbereitung auf Tausende externe Websites warten, obwohl gespeicherte Titel und Beschreibungen bereits verwertbare Eingaben waren.
- Alle Bookmark- und Kategorietexte gingen anschließend in eine einzelne Embedding-Anfrage mit 180 Sekunden Zeitlimit. Es gab währenddessen keinen Fortschrittszähler.
- Die Klassifikation verwendete 32.768 Kontext-Tokens und 24 Bookmarks pro Anfrage. Ein Transportfehler warf alle bisherigen Zuordnungen dieses Durchlaufs weg; gezählt wurden hauptsächlich Tokens der aktuellen Anfrage.
- Beim alternativen Antwortformat als Zeilenliste wurden nur Schlüssel mit genau drei Ziffern erkannt. Ab `B1000` konnten Klassifikationen deshalb verloren gehen. Das betraf nicht das erwartete JSON-Objektformat.
- Der konkrete historische KI-Abbruch ist im vorhandenen Log nicht dokumentiert. Netzwerk-Timeouts sind vorhanden. Die Diagnose unterscheidet daher reproduzierbare Codefehler von einem nicht belegten einzelnen Abbruchgrund.

## Änderungen in Build 23

- Metadaten: acht feste Worker, nur aktive Lesezeichen, 25 Sekunden Gesamtbudget in der Fetch-Funktion und 30 Sekunden äußere Absicherung. Bereits ermittelte Felder werden bei Ablauf des inneren Budgets zurückgegeben. Ergebnisse werden laufend in kurzen, serialisierten Transaktionen gespeichert; ein Stop wartet auf eine bereits laufende Transaktion. Der Zähler und bereits gespeicherte Ergebnisse bleiben erhalten.
- Die Seitenleiste erhält einen direkten Stop-Button. Nicht erreichbare Seiten und Speicherfehler werden beim Abschluss sichtbar, statt einen erfolgreichen Gesamtlauf vorzutäuschen.
- KI-Vorbereitung: gespeicherte Titel, Beschreibungen und kurze Reader-Auszüge; kein erneuter Vollabruf aller Websites. Datenbankabfragen verwenden 500 IDs pro Paket und laden nur die benötigten Felder. Umfangreiche Ähnlichkeitsberechnungen laufen außerhalb des Event-Loops, damit Statusabfragen bedient werden können.
- Embeddings: maximal 32 Texte pro Anfrage, geordnete Zusammenführung, Prüfung der Anzahl und Dimensionen sowie Fortschritt je Paket. Das Modell bleibt zwischen Paketen geladen und wird vor der Klassifikation freigegeben. Ein Wechsel oder Abschalten der KI stoppt weitere Pakete.
- Klassifikation: 12 Einträge bei angeforderten 16.384 Kontext- und maximal 2.048 Antwort-Tokens. Eine Anfrage einschließlich möglicher JSON-Reparatur hat ein Gesamtbudget von 180 Sekunden; bei Transportfehlern oder Zeitüberschreitung gibt es einen erneuten Versuch für diesen Block.
- Fertige Zuordnungsblöcke eines unterbrochenen Laufs werden lokal zwischengespeichert. Bei erneuter Auswahl derselben unveränderten Daten und Konfiguration werden diese Blöcke wiederverwendet. Embeddings werden dabei neu berechnet. Änderungen an Daten, Modell, Sprache oder Kandidaten erzeugen einen anderen Fingerabdruck. Fertige Analysen löschen ihren Checkpoint; abgebrochene Checkpoints werden auf drei Dateien und sieben Tage begrenzt, mit Dateirechten `0600`. Bibliothekslöschung und Werksreset entfernen sie ebenfalls. Es werden keine Tags ohne die bestehende Entwurfsfreigabe gespeichert.
- Die Oberfläche zeigt erledigte Embeddings und Klassifikationen statt nur einer wechselnden Tokenzahl. Ollama-Fehler innerhalb eines Streams werden als Fehler weitergegeben. Fehlende Antwortschlüssel lösen eine Reparatur aus; IDs mit vier oder mehr Ziffern werden unterstützt.

## Prüfung und Grenzen

- Vollständiger Backend-Lauf: 438 Tests erfolgreich. Anschließend wurden zwei weitere Fälle für echte Klassifikations-Timeouts und Ollama-Streamfehler ergänzt; alle 13 neuen Großbibliotheks-Tests bestehen. Insgesamt sind damit 440 Backend-Testfälle abgedeckt.
- Alle 137 nativen Tests erfolgreich, einschließlich kompatibler Decodierung der neuen Fortschrittsfelder.
- Synthetische Tests decken 4.000 Metadaten-Einträge, 4.094 Embedding-Texte, Stop während eines Datenbank-Commits, langsame Seiten, teilweise erhaltene Metadaten, Wiederaufnahme nach Fehlern und Schlüssel ab `B1000` ab.
- Kleiner lokaler Modelltest mit ausschließlich künstlichen Daten: 32 Texte mit `embeddinggemma:latest` in rund 1,7 Sekunden; zwölf gültige Klassifikationen mit `gemma4:e4b-mlx`, zusammen rund 11,4 Sekunden. Dieser kurze Test ist keine Laufzeitgarantie für eine echte Sammlung mit längeren und uneindeutigen Inhalten.
- Die eigentliche KI-Klassifikation bleibt modell- und hardwareabhängig. Mehrere Tausend Bookmarks benötigen weiterhin viele lokale Modellaufrufe. Es wurde keine vollständige KI-Vergabe auf privaten Bookmarks gestartet.

## Installation

Release-Build 23 wurde unter `/Applications/Gyrus.app` installiert, mit `codesign --verify --deep --strict` geprüft und neu gestartet. Die Bibliothek wird wieder geladen. Der zuvor hängende Metadaten-Durchlauf wurde über die vorhandene Stop-Funktion beendet, damit dessen fertig abgerufene Ergebnisse noch gespeichert werden konnten. Der vorherige App-Build wurde lokal gesichert. Es wurde kein Commit, Push oder öffentliches Release ausgelöst.
