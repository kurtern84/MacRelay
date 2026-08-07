# MacRelay

MacRelay er en klassisk IRC-klient for macOS, bygget i Swift og SwiftUI. Målet er en enkel, native Mac-opplevelse med følelsen fra tradisjonelle IRC-klienter – uten et Discord-lignende grensesnitt.

[Last ned MacRelay som DMG](dist/MacRelay.dmg)

> **Testversjon:** Den vedlagte appen er ikke notarized av Apple. macOS kan derfor be deg bekrefte åpning av appen. Last bare ned og åpne programmet dersom du stoler på denne kildekoden og utgiveren.

![MacRelay kanalvisning](docs/screenshots/main-chat.png)

## Funksjoner

- IRC over vanlig TCP eller TLS
- Favorittservere og flere serverprofiler
- Automatisk tilkobling og kanal-join
- Robust reconnect etter macOS-dvale og midlertidige nettverksbrudd
- Automatisk away basert på systemets inaktivitetstid
- Alternativt nick og NickServ-passord lagret i macOS Keychain
- Kanal-topic, klassisk brukerstatus (`@` og `+`) og sortert brukerliste
- Private samtaler, WHOIS og ignoreringsliste
- Diskré markering av uleste meldinger og omtaler
- Native macOS-varsler og valgfri IRC-varsellyd
- Lokal UTF-8-logging av kanaler og private samtaler
- Lokal kanalhistorikk med diskrete markeringer for ny økt og reconnect
- Automatisk gjenoppretting av åpne kanaler, private samtaler og aktiv samtale
- Registrering av innkommende DCC SEND-tilbud

## Installere testversjonen

1. Last ned [`MacRelay.dmg`](dist/MacRelay.dmg).
2. Åpne DMG-filen.
3. Dra **MacRelay** til **Programmer / Applications**.
4. Start MacRelay fra Programmer-mappen.

Dersom Gatekeeper blokkerer første oppstart, kan du høyreklikke på MacRelay og velge **Åpne**, eller godkjenne appen under **Systeminnstillinger → Personvern og sikkerhet**.

DMG SHA-256:

```text
6703ba175449bacc7012fd2fa51b801c49f4663c22edb4d29e3932bb28c03526
```

## Skjermbilder

### Native IRC-meny

![MacRelay IRC-meny](docs/screenshots/irc-menu.png)

### Server og identitet

| Serverinnstillinger | Identitetsinnstillinger |
| --- | --- |
| ![Serverinnstillinger](docs/screenshots/server-settings.png) | ![Identitetsinnstillinger](docs/screenshots/identity-settings.png) |

### Logging og varsling

![Logging og varsling](docs/screenshots/logging-settings.png)

## Bygge fra kildekode

1. Klon repoet.
2. Åpne `MacRelay.xcodeproj` i Xcode.
3. Velg `MacRelay`-scheme og **My Mac**.
4. Bygg og kjør med `⌘R`.

Prosjektets deployment target er macOS 14.0. Appen bygges som Universal Binary for Apple Silicon og Intel når begge arkitekturer er valgt i Xcode.

## IRC-kommandoer

MacRelay støtter blant annet:

```text
/join #kanal
/part [melding]
/msg nick melding
/query nick
/me handling
/nick nyttnick
/whois nick
/ignore nick
/unignore nick
/quote RAW IRC-LINJE
/quit [melding]
```

## Logger

Logger lagres lokalt under:

```text
~/Library/Application Support/MacRelay/Logs/
```

## Kjente begrensninger

- DCC SEND-tilbud oppdages og vises, men direkte filoverføring er ikke implementert ennå.
- MacRelay bruker én aktiv IRC-servertilkobling om gangen.
- Distribusjonsbygget i `dist/` er ment for testing og er ikke notarized av Apple.
