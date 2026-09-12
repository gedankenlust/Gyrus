# Nachladen beim Scrollen

Die lokale Diagnose zeigte erschöpfte Datenbankverbindungen mit einem
30-Sekunden-Timeout. Beim Anzeigen von Karten und Tabellenzeilen mit fehlendem
Favicon wurden viele Metadatenanfragen gestartet. Der asynchrone Endpunkt lud
nach dem Commit erneut das ORM-Objekt, um dessen URL auszulesen, und hielt so
eine neue Datenbanktransaktion während des Webseitenabrufs offen. Andere
Anfragen, darunter die nächste Lesezeichenseite, mussten auf eine Verbindung
warten. Die App teilte zudem denselben HTTP-Verbindungspool für Metadaten und
Nachladen.

## Korrekturen in Build 26

- URL vor dem Commit kopieren und die Datenbanksitzung vor dem Netzwerkabruf
  schließen. Anschließend den aktuellen Datensatz erneut laden; gelöschte
  oder zwischenzeitlich geänderte URLs erhalten keine veralteten Ergebnisse.
- Höchstens drei Metadatenabrufe gleichzeitig im Endpunkt; wartende Anfragen
  belegen keine Datenbankverbindung. Abbruch gibt den Platz frei und markiert
  die Metadaten als erneut versuchbar.
- Eigene HTTP-Sitzung für langsame Metadaten, begrenzt auf zwei Verbindungen.
  Listen- und Favicon-Dateianfragen teilen diesen Pool nicht. Auch in der
  Tabellenansicht gehören Metadatenaufgaben jetzt zum Lebenszyklus der Zeile.
- Die normale Seitenabfrage lädt Reader-Text und Notizen nicht mehr mit. Tags
  und die angezeigten Analysezustände bleiben enthalten.
- Jede angezeigte Karte bzw. Zeile innerhalb der letzten 40 geladenen Einträge
  kann vorladen. Schnelles Scrollen darf den Auslöser überspringen; bisher war
  genau eine bestimmte Zeile 24 Einträge vor Schluss zuständig.
- Ladefehler werden sichtbar mit „Erneut laden“. Seitenoffset und bestehende
  Einträge bleiben erhalten. Automatisches Vorladen versucht einen bekannten
  Fehler nicht fortwährend erneut. Beim Wechsel der Ansicht kann keine Seite
  der alten Ansicht an die neue angehängt werden.

## Prüfung

Der zentrale Regressionstest simuliert zwölf Metadatenanfragen, davon drei
hängende Webseitenabrufe, bei nur einer verfügbaren Datenbankverbindung.
Währenddessen funktioniert die vollständige Serialisierung einer weiteren
Lesezeichenseite; während der Netzwerkwartezeit sind keine Verbindungen
ausgeliehen. Weitere Tests prüfen ausgelassene große Textfelder, URL-Änderung,
Abbruch, getrennte HTTP-Sitzungen, übersprungene Vorladeschwellen und erneutes
Laden nach Fehlern. Alle Testdaten sind künstlich.

463 Backend-Tests bestanden im vollständigen Lauf, danach zusätzlich der neue
Abbruchfall; alle vier Scroll-Regressionen bestehen. 143 native Tests bestanden.

Build 26 wurde unter Programme installiert und die Signatur geprüft. Ein
Scrolltest über mehrere Seitengrenzen in der Rasteransicht lud weitere Karten
nach, ohne einen neuen Pool-Timeout auszulösen. Dies ist ein Funktionstest,
keine Garantie für jede Scrollgeschwindigkeit oder Systemlast.
