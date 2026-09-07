# Autostart: laufende App ohne Hauptfenster

Am 6. September 2026 meldete der Nutzer, dass Gyrus nach dem Rechnerneustart im Dock als laufend erschien, ein Klick jedoch kein Hauptfenster öffnete. Bei der Untersuchung liefen App und Backend; erreichbar war nur das Einstellungsfenster „Allgemein“.

## Ursache und Änderungen

- Der bisherige SwiftUI-Öffnungsbefehl wurde erst im `onAppear` des Hauptfensters eingerichtet. Fehlte dieses Fenster beim Start, fehlte damit auch der Befehl zum Erzeugen der Szene. Der Dock-Handler unterdrückte trotzdem die native Wiederöffnung.
- Die Registrierung verwendete außerdem das gerade aktive `NSApp.keyWindow`. Dadurch konnte das Einstellungsfenster oder ein anderes Hilfsfenster als Hauptfenster gespeichert werden.
- `MainWindowCommands` stellt den Szenenöffner jetzt unabhängig vom Erscheinen des Hauptfensters bereit. Frühe Öffnungsanforderungen werden vorgemerkt und nach Einrichtung des Öffners ausgeführt.
- `MainWindowRegistration` registriert über eine eingebettete AppKit-Ansicht ausschließlich das tatsächlich zugehörige Hauptfenster. Einstellungen und Hilfsfenster ersetzen diese Zuordnung nicht mehr.
- Dock-Wiederöffnung, Aktivierung und Einblenden stellen ein vorhandenes Hauptfenster wieder her. Beim Schließen wird es ausgeblendet und kann erneut geöffnet werden.
- Als zusätzlicher sichtbarer Zugang wurde „Fenster → Gyrus öffnen“ ergänzt; die vorhandene deutsche Übersetzung wird verwendet.
- Die Fenstersteuerung liegt in `Gyrus/Services/MainWindowLifecycle.swift`; das Xcode-Projekt wurde mit dem Projektgenerator aktualisiert.

## Prüfung und Installation

- Vollständige Swift-Testsuite: **120 Tests, 0 Fehler** in einer isolierten Testumgebung.
- Sechs neue Regressionstests prüfen den Szenenöffner ohne vorhandenes Fenster, ein frühes Dock-Ereignis, sichtbare Einstellungen, die tatsächliche Fensterzuordnung, Schließen/Wiederöffnen und Aktivierung eines ausgeblendeten Hauptfensters.
- Release-Build erfolgreich. Lokal signiert und mit `codesign --verify --deep --strict` geprüft.
- Neuer Build in `/Applications/Gyrus.app` installiert. Vorherige App gesichert unter `/tmp/gyrus-login-fix/Previous-Gyrus.app` (temporäre Sicherung).
- Installierte Programmdatei per SHA-256 mit dem neuen Release-Build abgeglichen; identisch. Lokales Backend meldet nach dem Start `{"status":"ok","version":"1.5.0"}`. `git diff --check` ohne Befund.
- An der installierten App geprüft: Start mit sichtbarer Bibliothek, Schließen des Hauptfensters und erneutes Öffnen sowie „Gyrus öffnen“ aus dem Einstellungsfenster. Autostart blieb aktiviert.
- Ein vollständiger macOS-Neustart wurde während dieser Prüfung nicht ausgeführt. Das tatsächliche Anmelden nach einem Rechnerneustart bleibt daher als abschließender Praxistest offen.

Testprotokoll: `/tmp/gyrus-login-tests.log`; Testresultat: `/tmp/gyrus-login-tests.xcresult`; Release-Protokoll: `/tmp/gyrus-login-release.log`. Diese temporären Dateien können beim Neustart entfernt werden.
