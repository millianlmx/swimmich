[English](PRIVACY.md) · [Français](PRIVACY.fr.md) · [Deutsch](PRIVACY.de.md) · [Español](PRIVACY.es.md) · [Italiano](PRIVACY.it.md)

# Swimmich — Datenschutzerklärung

Zuletzt aktualisiert: 16. Oktober 2026

Swimmich ist ein iOS-Client von Drittanbietern für selbst gehostete Immich-Server. Er steht in keiner Verbindung zum Immich-Projekt. Der Server, mit dem du dich verbindest, gehört dir oder seinem Administrator, nicht dem Entwickler von Swimmich.

## Keine Erhebung durch den Entwickler

Der Entwickler von Swimmich erhebt, empfängt, speichert und verkauft keinerlei Daten. Er betreibt keinen Server und hat keinen Zugriff auf deine Fotos oder dein Konto.

## Kein Tracking, keine Analysen

Swimmich enthält kein Tracking, keine Analysen, keine Absturzberichte, keine Werbung und keine Drittanbieter-SDKs dieser Art. Die App liest nie den Standort deines Geräts.

## Daten, die an deinen Immich-Server gesendet werden, und nur an ihn

Die folgenden Daten verlassen dein Gerät in Richtung des von dir gewählten Immich-Servers und gehen an niemanden sonst:

- die Serveradresse;
- deine E-Mail-Adresse und dein Passwort bei der Anmeldung oder die Anmeldung per Single Sign-on (SSO) beim Anbieter, den dein Server dafür konfiguriert hat;
- das Sitzungstoken, das jeder Anfrage beigefügt wird;
- die Fotos und Videos, die du sicherst oder hochlädst, mit ihren Datumsangaben und Metadaten, sowie Änderungen an Metadaten, die du vornimmst;
- eine zufällige Geräte-ID, die von der App erzeugt wird (weder eine Hardware-Kennung noch eine Werbe-ID);
- die Echtzeit-Aktualisierungen, die mit demselben Server ausgetauscht werden.

Was der Server mit diesen Daten macht, liegt in der Verantwortung seines Administrators und unterliegt dessen eigener Richtlinie.

## Apple-Dienste

Karten und die Anzeige von Orten senden die Koordinaten deiner Fotos und die angezeigten Bereiche an Apple: Kartenkacheln, Ortsnamen und Routen. AirPlay läuft über iOS. Diese Dienste unterliegen der Datenschutzerklärung von Apple. Nichts läuft über den Entwickler.

## Auf deinem Gerät gespeicherte Daten

- **Schlüsselbund (nur dieses Gerät):** das Sitzungstoken jedes Kontos, die optionale PIN des gesperrten Ordners und die mit dem Widget und der Teilen-Erweiterung geteilte Sitzung (Serveradresse, Token und Geräte-ID). Dein Passwort wird nie gespeichert.
- **Einstellungen und gespeicherte Konten:** die Serveradresse, die gespeicherten Konten (Adresse, E-Mail-Adresse und Name), deine Benutzer-ID und dein Administratorstatus, die Geräte-ID, die freigegebenen Server und deine Einstellungen (Sicherung und gewählte Alben, Bereinigung, Sprache, Sperre, Darstellung).
- **Caches und Dateien:** ein Bild-Cache auf dem Datenträger, die Originale, die du offline behältst, das Sicherungsprotokoll, Bearbeitungszustände, ein Cache mit Kartenmarkierungen (Koordinaten), Downloads und temporäre Dateien.
- **App-Protokoll:** wird nur im Arbeitsspeicher gehalten und nur exportiert, wenn du es selbst tust.

Diese Daten bleiben auf deinem Gerät, außer dem, was wie oben beschrieben an deinen Server gesendet wird.

Berechtigungen:

- **Fotos (Lesen und Schreiben):** um deine Mediathek zu sichern, Fotos zu speichern und Speicherplatz freizugeben.
- **Kamera:** nur zum Scannen des QR-Codes, der den Server konfiguriert.
- **Face ID:** um die App zu sperren. Das übernimmt iOS; die App erhält keine biometrischen Daten.

## Kontolöschung

Swimmich legt kein Konto an. Dein Konto gehört zu deinem Immich-Server. Um es zu löschen, wende dich an den Administrator dieses Servers.

## Kontakt

Fragen und Support: https://github.com/millianlmx/swimmich/issues
