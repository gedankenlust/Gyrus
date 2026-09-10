# Schonmodus für die gemeinsame Tag-Analyse

Die gemeinsame Tag-Analyse kann ein lokales Modell über viele Minuten ohne
Unterbrechung beschäftigen. Kleine Pakete und begrenzte Parallelität allein
verhindern diese Dauerlast nicht.

In den AI-Brain-Einstellungen gibt es nun unter **Tag-Vergabe** den Schalter
**Schonmodus**. Er ist standardmäßig aktiviert, auch beim Laden älterer
Einstellungen. Die Wahl wird gespeichert und beim Start der nächsten Analyse
übertragen; laufende Analysen behalten ihre bisherige Konfiguration.

- Nach einem Embedding-Paket folgt eine Pause. Das gilt auch vor dem Wechsel
  vom Embedding-Modell zur Klassifikation.
- Zwischen neu berechneten Klassifikationspaketen folgt ungefähr eine Sekunde
  Pause pro Sekunde vorangegangener Anfragezeit, mindestens zwei Sekunden und
  höchstens drei Minuten. Das letzte Klassifikationspaket benötigt keine Pause.
- Die Fortschrittsanzeige zeigt die verbleibende Pause. Bereits erreichte
  Zähler bleiben erhalten. Stoppen unterbricht die Pause sofort.
- Klassifikationspakete werden vor der Pause zwischengespeichert. Ein Neustart
  mit derselben Auswahl kann sie auch nach einem Wechsel des Schonmodus
  wiederverwenden. Für wiederverwendete Pakete entstehen keine Pausen.

Der Modus reduziert die Dauerlast durch die gemeinsame Tag-Analyse und
verlängert deren Laufzeit. Er begrenzt weder die momentane CPU-/GPU-Auslastung
noch die Temperatur und beeinflusst keine Lüftereinstellungen. Andere
KI-Aufgaben und Anwendungen werden dadurch nicht gedrosselt.

Die Regressionstests simulieren die Zeit und Modellantworten: Mindest-/Maximal-
pause, Countdown, ausgeschalteter Modus, Abbruch, Reihenfolge der Embedding-
Anfragen und Wiederaufnahme nach einem Abbruch in der Pause. Native Tests
prüfen die Migration gespeicherter Einstellungen, die Übertragung beider
Schalterstellungen und die Fortschrittsdaten. Dafür werden keine privaten
Lesezeichen und keine echte Modellinferenz benötigt.

Validierung: 447 Backend-Tests und 139 native Tests erfolgreich. Deutsche
Übersetzungen sind im kompilierten App-Bundle enthalten. Ein Temperatur- oder
Leistungsvergleich mit echter Modellinferenz wurde nicht durchgeführt.
