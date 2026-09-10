# Suchindex: lange Texte überschreiten das Embedding-Limit

Der Suchindex verwendete noch `/api/embeddings` mit einem Limit von 8.000
Zeichen. Eine beobachtete Anfrage enthielt 2.268 Tokens; der lokale Runner
lehnte sie wegen seiner physischen Batch-Grenze von 2.048 Tokens ab. Der
Neuaufbau brach daraufhin ab und behielt den bisherigen Index.

Einzelne Such- und Indexierungsanfragen verwenden jetzt `/api/embed` mit
`input` und `truncate: true`. Das Zeichenlimit begrenzt weiterhin die
Anfragegröße. Die tatsächliche Tokenbegrenzung übernimmt Ollama anhand des
Modells. Lange Texte werden dafür gekürzt; die gespeicherten Reader-Texte
bleiben unverändert. Die Batch-Analyse für Tags verwendete diesen Endpunkt
bereits.

Die Antwort muss genau einen nichtleeren Vektor mit endlichen numerischen
Werten enthalten. Fehler erhalten maschinenlesbare Kategorien und deutsche
Erklärungen in den Einstellungen. Rohe Serverantworten, möglicherweise mit
übermittelten Texten, werden nicht an die Oberfläche weitergereicht.

Der neue Endpunkt liefert normalisierte Vektoren. Weil der Suchindex
euklidische Distanz verwendet, gehört die Embedding-Verarbeitung nun zum
Konfigurationsschlüssel. Ein alter Index muss neu aufgebaut werden und kann
nicht versehentlich mit den neuen Vektoren vermischt werden. Die bestehende
atomare Ersetzung bleibt erhalten: bei einem Fehler bleibt der alte Index
gespeichert.

Regressionen prüfen lange Unicode-Texte, das genaue Anfrageformat, ungültige
Vektoren, klassifizierte Serverfehler, die Index-Kompatibilität sowie den
erfolgreichen und fehlgeschlagenen vollständigen Neuaufbau. Ein einzelner
lokaler Test mit künstlichem langem Text und `embeddinggemma:latest` lieferte
HTTP 200, einen Vektor mit 768 Dimensionen und 2.048 verarbeitete Tokens.

Referenz: https://docs.ollama.com/api/embed

Validierung: 460 Backend-Tests und 140 native Tests erfolgreich.

Build 25 wurde lokal installiert und die Signatur geprüft. Der zuvor
fehlgeschlagene Neuaufbau wurde anschließend in der installierten App
vollständig erfolgreich abgeschlossen; die Bereitschaftswarnung verschwand.
