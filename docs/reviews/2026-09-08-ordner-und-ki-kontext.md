# Ordnerzustand und KI-Kontext

## Seitenleiste

Jede Aktualisierung der nativen Seitenleiste rief bisher eine rekursive Expansion sämtlicher Ordner auf. Daher öffnete bereits ein Auswahlwechsel oder ein aktualisierter Zähler zuvor zugeklappte Zweige erneut.

Die automatische Expansion betrifft jetzt ausschließlich die festen Abschnittsüberschriften. Der vorhandene Klappzustand der Ordner wird beim Neuladen beibehalten. Neben der Ordnerüberschrift stehen explizite Schaltflächen für „Alle Ordner aufklappen“ und „Alle Ordner zuklappen“, einschließlich deutscher Beschriftungen für Tooltips und Accessibility. Die Navigation bleibt beim Zuklappen eines ausgewählten Unterordners erhalten.

Zwei AppKit-Regressionstests prüfen Auswahlwechsel und Zähleraktualisierung bei geschlossenem Zweig sowie vollständiges Auf-/Zuklappen einschließlich ausgewählter Nachfahren.

## Bereits getaggte Lesezeichen abwählen

Im Menü „Organisieren“ der Auswahlleiste steht „Bereits getaggte abwählen“ an erster Stelle. Derselbe Befehl erscheint im Kontextmenü der aktuellen Auswahl. Er entfernt ausschließlich Lesezeichen mit vorhandenen Tags aus der Auswahl; Tags und Lesezeichen bleiben unverändert. Die Funktion benötigt keine KI-Freigabe und zeigt anschließend die Anzahl der abgewählten Einträge an. Während der Prüfung ist das Organisationsmenü gesperrt und eine Fortschrittsanzeige sichtbar.

Der lesende Endpunkt `POST /api/bookmarks/tagged-ids` prüft die vollständige übergebene Auswahl, unabhängig von geladenen Listenseiten. Die Datenbankabfrage läuft in Gruppen von 500 IDs, um SQLite-Parameterlimits einzuhalten; bis zu 100.000 IDs sind pro Anfrage zulässig. Manuelle und KI-Tags zählen gleichermaßen. Doppelte IDs werden zusammengefasst, Einträge außerhalb der Auswahl, unbekannte IDs und Papierkorbeinträge ausgeschlossen.

Auswahlwechsel, Navigation und Zurücksetzen der Bibliothek während einer Anfrage verwerfen deren Ergebnis. Bei Fehlern bleibt die Auswahl bestehen. Regressionstests prüfen unter anderem 4.094 synthetische Auswahl-IDs bei nur zwei geladenen Einträgen, ausschließlich getaggte bzw. ungetaggte Auswahlen sowie Fehler und verspätete Antworten.

Alle 136 nativen Tests bestehen in einer isolierten Benutzerumgebung, ebenso alle 427 Backend-Tests. Release-Build 22 enthält beide Verbesserungen, wurde erfolgreich erstellt und mit `codesign --verify --deep --strict` geprüft. Nach Abschluss der laufenden Metadaten-Aktualisierung wurde Build 22 unter `/Applications/Gyrus.app` installiert und erneut gestartet. Der vorherige Build wurde lokal gesichert. Die Bibliothek wird geladen und die neuen Ordner-Schaltflächen sind in der gestarteten App sichtbar.

## Bestehendes KI-Verhalten (Codeprüfung, unverändert)

- Die gemeinsame KI-Tag-Vergabe fordert in `taxonomy_service._stream_taxonomy` ein Kontextfenster von 32.768 Tokens und maximal 4.096 Antwort-Tokens an.
- Die Klassifikation verarbeitet jeweils 24 Lesezeichen mit gekürzten Titeln, URLs, Beschreibungen und Auszügen. Die gesamte Auswahl wird nicht in einen einzigen Klassifikationsprompt geschrieben.
- Die vorbereitende Embedding-Berechnung sendet dagegen derzeit alle Texte der Auswahl in einer Anfrage an Ollama, mit einem HTTP-Zeitlimit von 180 Sekunden. Das ist bei großen Importen ein möglicher Engpass, aber ohne konkrete Fehlermeldung kein nachgewiesener Grund für einen Abbruch beim Nutzer.
- Die Einstellung ist spezifisch für die gemeinsame Tag-Vergabe. Gyrus setzt nicht für sämtliche KI-Anfragen pauschal dieses Kontextfenster. Welche Größe das konkrete Modell tatsächlich unterstützt, wurde hier nicht durch einen Modellaufruf geprüft.

Es wurde keine KI-Vergabe auf den privaten Lesezeichen gestartet und die KI-Konfiguration nicht geändert.
