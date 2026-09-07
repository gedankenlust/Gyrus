# Design-Inspektor: Übersicht und gezielte Details

Die rechte Design-Spalte wurde für System, Komponenten und Webseite neu gegliedert. Ziel ist eine verständliche Einstiegsebene mit kurzen Ergebnislisten; genaue Werte bleiben gezielt erreichbar. Der Bereich Probleme behält seine bisherige Darstellung.

## Relevante Änderungen

- **System:** Startübersicht mit einer kompakten Farbpalette, Schriftzusammenfassung und erkannter Technik. Eigene Unteransichten für Farben, Schrift, Layout und CSS.
- **Farben:** Sortierung nach relativer sRGB-Helligkeit von dunkel nach hell, auch über Ergebnis-Seiten hinweg. Gleiche normalisierte RGB/HEX-Werte werden zusammengefasst; sämtliche zugehörigen Variablennamen sind in einem Popover abrufbar. Zwölf Farben je Seite, Suche nach HEX oder Quellenname und Auswahl zwischen Design-Tokens, tatsächlich verwendeten Farben und Screenshot-Palette. Die Übersicht verteilt ihre zwölf Muster über den gesamten Helligkeitsbereich. Die frühere Begrenzung auf 24 Tokens gilt für diese Ansicht nicht mehr.
- **Schrift und Layout:** Fünf Schriftstile pro Seite, zusätzliche Font-Stacks auf Wunsch. Abstände, Rundungen und Display-Muster stehen in einem eigenen Bereich. Die Schriftvorschau weist darauf hin, dass die Systemschrift verwendet wird; kopierte CSS-Werte bleiben erhalten.
- **CSS:** Suchfeld, Gruppenauswahl und acht Variablen pro Seite. Farbwerte erscheinen ebenfalls nach Helligkeit sortiert. Rohwerte bleiben einschließlich Transparenz kopierbar.
- **Komponenten:** Direkt sichtbare Vorschaukarten in zwei Spalten statt verschachtelter Akkordeons. Vier Muster pro Seite, Kategorieauswahl und Suche. Name, Häufigkeit und Maße stehen untereinander. Eine Karte öffnet eine größere Vorschau mit Selektor und gemessenen Eigenschaften; CSS und weitere Texte sind gezielt aufklappbar. Alle erfassten Varianten sind erreichbar, nicht nur die früheren zwölf je Kategorie.
- **Webseite:** Getrennte Bereiche Inhalt, Seiten & Menüs und Dateien. Titel, Suchbeschreibung, Sprache und Überschriften werden verständlich benannt. Social-Media-/JSON-LD-Daten sowie Erkennungsdetails sind nachgeordnet. Seiten und Dateien haben Suche und kurze Ergebnis-Seiten. Dateien behalten ihre erweiterten Attribute in aufklappbaren Details.
- **Dateireferenzen:** Mehrere erfasste Elemente mit derselben URL und demselben Selektor bekommen für die Liste eine eigene Identität; SwiftUI lässt dadurch keine zweite Zeile wegen doppelter IDs verschwinden. Leere Dateinamen erhalten den Hostnamen als Ersatz; bedeutungslose Maße 0 × 0 werden nicht als Größe angezeigt.
- **Navigation und Sprache:** Unterbereichsauswahl bleibt oberhalb des Inhalts. Suche/Seitenauswahl setzen sich bei passenden Datenwechseln zurück. Deutsche Texte, Singular/Plural und zugängliche Bezeichnungen für Blättern und Kopieren ergänzt.
- **Darstellungssicherheit:** Neue Bildausschnitte werden bei einem Wechsel der Screenshot-Datei neu geladen. Ungültige Hex-Zeichen werden verworfen.

## Prüfung

- Native Tests: 131 bestanden, darunter vier neue Regressionstests für Helligkeitsreihenfolge, Zusammenfassung von Farbquellen, die Übersichtspalette und vollständige Token-Datensätze.
- Debug-Testbuild und universeller Release-Build erfolgreich; Signatur einschließlich gebündelter Laufzeit geprüft.
- Manuelle Prüfung in der App mit der vorhandenen YouTube-Untersuchung vom 7. September: Systemübersicht, zwölf Farbkarten ohne Scrollen bei der vorhandenen Spaltenbreite, Weiterblättern, HEX-Suche und Zurücksetzen auf die erste Ergebnisseite, Quellen-Popover, Schrift/CSS, Komponentenkarten und größere Detailansicht sowie Inhalt, Seiten und Dateien.
- Backend und Datenbankschema sind in dieser Runde unverändert. Die vorhandene Untersuchung wurde verwendet; keine neue Online-Untersuchung ausgelöst.

## Installation

Version 1.5.0, Build 20 wurde unter `/Applications/Gyrus.app` installiert und nach dem Austausch erneut gestartet. Die abschließende Prüfung bestätigte das Raster mit zwei Spalten sowie beide separaten Dateireferenzen. Die 131 nativen Tests bestanden auch mit dem endgültigen Stand erneut. Die App bleibt auf der neuen Systemübersicht geöffnet. Die vorherige installierte App liegt als Rückfallkopie unter `/tmp/gyrus-design-ux/Previous-Gyrus.app`.

## Grenzen

Die Farbfolge basiert auf normalisiertem RGB und relativer Helligkeit. Unterschiedliche Transparenzen derselben RGB-Farbe teilen eine Farbkarte; ihre exakten Originalwerte bleiben unter CSS erhalten. Komponentenbilder sind Ausschnitte einer vorhandenen Aufnahme und können bei starker Vergrößerung unscharf sein. Die Erfassung kann unvollständig sein; die Oberfläche benennt bekannte Untersuchungslimits. Die manuelle Prüfung ist kein vollständiger VoiceOver- oder Mehrschirm-Test.

## Nachtrag: Reiterreihenfolge (Build 21)

Auf Nutzerwunsch steht Probleme jetzt am Ende: Vorschau → System → Komponenten → Webseite → Probleme. Release-Build und vollständige Signaturprüfung erfolgreich; Build 21 unter Programme installiert. Für diese reine Umordnung wurden keine zusätzlichen Unit-Tests angelegt.
