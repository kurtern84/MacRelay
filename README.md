# MacRelay

MacRelay er en klassisk IRC-klient for macOS, bygget i Swift og SwiftUI. Målet er en enkel, native Mac-opplevelse med følelsen fra tradisjonelle IRC-klienter – uten et Discord-lignende grensesnitt.

[Last ned MacRelay som DMG](dist/MacRelay.dmg)

> **Testversjon:** Den vedlagte appen er ikke notarized av Apple. macOS kan derfor be deg bekrefte åpning av appen. Last bare ned og åpne programmet dersom du stoler på denne kildekoden og utgiveren.

![MacRelay kanalvisning](docs/screenshots/main-chat.png)

## Funksjoner

- IRC over vanlig TCP eller TLS
- Favorittservere og flere serverprofiler
- Automatisk tilkobling og kanal-join
- IRC PASS for ZNC og passordbeskyttede IRC-servere, lagret i macOS Keychain
- Automatisk ZNC-gjenkjenning og optimal IRCv3-forhandling
- ZNC-playback med nøyaktig `server-time`, deduplisering og støtte for flere MacRelay-klienter
- Robust reconnect etter macOS-dvale og midlertidige nettverksbrudd
- Automatisk away basert på systemets inaktivitetstid, eller fast away ved tilkobling
- Alternativt nick og separat NickServ-passord lagret i macOS Keychain
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
b5ee5ead00fdd43740929e88dbaf8d6ccbc50a63414d1d502e518f6242ca58c6
```

## ZNC

Bruk feltet **IRC PASS (valgfritt)** for ZNC-passordet, for eksempel `bruker/nettverk:passord`. IRC PASS og NickServ-passord er separate og lagres i hver sin oppføring i macOS Keychain.

MacRelay oppdager ZNC automatisk gjennom dokumenterte IRCv3-capabilities. Når ZNC tilbyr dem, aktiveres `server-time`, `echo-message` og `znc.in/self-message`. Dermed beholdes riktige tidsstempler og egne meldinger sendt fra en annen MacRelay-klient vises uten lokale duplikater.

For samtidige klienter må **MultiClients** være tillatt på ZNC-serveren. MacRelay kobler bare klientvinduet fra og avslutter ikke IRC-økten som ZNC holder åpen mot nettverket.

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
