# MacRelay

MacRelay er en klassisk IRC-klient for macOS, med en native companion-app for iPhone og iPad, bygget i Swift og SwiftUI.

Målet er en enkel, rask og helt native Mac-opplevelse som gjenskaper følelsen av tradisjonelle IRC-klienter – uten et Discord-lignende grensesnitt eller tunge rammeverk.

MacRelay fokuserer på moderne IRCv3-støtte, sømløs ZNC-integrasjon og klienter som føles hjemme på både macOS og iOS.

**Versjon 1.1 · build 2**

[Last ned MacRelay som DMG](dist/MacRelay.dmg)

> **Testversjon**
>
> Den vedlagte appen er ikke notarized av Apple. macOS kan derfor be deg bekrefte åpning av appen. Last bare ned og åpne programmet dersom du stoler på denne kildekoden og utgiveren.

![MacRelay kanalvisning](docs/screenshots/main-chat.png)

---

# Hvorfor MacRelay?

MacRelay er laget for brukere som ønsker en moderne, native IRC-klient uten å gi slipp på den klassiske IRC-opplevelsen.

Fokus er på:

- Native SwiftUI-grensesnitt
- Moderne IRCv3-støtte
- Sømløs ZNC-integrasjon
- Lokal historikk og logging
- Rask oppstart
- Ingen Electron
- Ingen abonnement
- Native macOS-app og egen iOS companion-app

---

# Nøkkelfunksjoner

- IRC over vanlig TCP eller TLS
- Favorittservere og flere serverprofiler
- Automatisk tilkobling og kanal-join
- IRC PASS for ZNC og passordbeskyttede IRC-servere (lagret i macOS Keychain)
- Automatisk ZNC-gjenkjenning
- Automatisk IRCv3 capability-forhandling
- ZNC-playback med nøyaktig `server-time`
- Automatisk deduplisering av replayede meldinger
- Sømløs bruk av flere MacRelay-klienter mot samme ZNC-instans
- Robust reconnect etter macOS-dvale og midlertidige nettverksbrudd
- Automatisk Away basert på systemets inaktivitetstid
- Fast Away ved tilkobling (valgfritt)
- Alternativt nick
- Separat NickServ-passord lagret i macOS Keychain
- Kanal-topic
- Klassisk brukerstatus (`@`, `%`, `+`)
- Sortert brukerliste
- Private samtaler
- WHOIS
- Ignoreringsliste
- Diskré markering av uleste meldinger og omtaler
- Valgfri native menylinjemodus med tilkoblingsstatus og uleste samtaler
- Valgfritt skjult Dock-ikon, kjøring etter lukket hovedvindu og oppstart ved innlogging
- Native macOS-varsler
- Valgfri IRC-varsellyd
- Lokal UTF-8-logging av kanaler og private samtaler
- Lokal kanalhistorikk
- Diskrete markeringer for ny økt og reconnect
- Automatisk gjenoppretting av:
  - server
  - åpne kanaler
  - private samtaler
  - aktiv samtale
- Registrering av innkommende DCC SEND-tilbud

---

# Installere testversjonen

1. Last ned [`MacRelay.dmg`](dist/MacRelay.dmg)
2. Åpne DMG-filen.
3. Dra **MacRelay** til **Programmer / Applications**.
4. Start MacRelay fra Programmer-mappen.

Hvis Gatekeeper blokkerer første oppstart, kan du:

- høyreklikke på MacRelay og velge **Åpne**
- eller godkjenne appen under:

**Systeminnstillinger → Personvern og sikkerhet**

### SHA-256

```text
2204755680f729f50ff95e0416a12b3c1a4b78e02a56dfcb9468c646b3a0f4dd
```

---

# ZNC

MacRelay har innebygget støtte for ZNC.

Bruk feltet **IRC PASS (valgfritt)** med formatet:

```text
bruker/nettverk:passord
```

IRC PASS og NickServ-passord lagres separat i macOS Keychain.

MacRelay oppdager ZNC automatisk gjennom dokumenterte IRCv3-capabilities.

Ingen egen «ZNC-modus» trenger å aktiveres.

Når ZNC tilbyr relevante capabilities aktiveres automatisk:

- `server-time`
- `echo-message`
- `znc.in/self-message`

Dette gir:

- korrekte tidsstempler på playback
- deduplisering av meldinger
- egne meldinger sendt fra andre MacRelay-klienter
- sømløs bruk av flere Mac-er

For å bruke flere MacRelay-installasjoner samtidig må ZNC-brukeren ha **MultiClients** aktivert.

Da kan flere Mac-er dele den samme IRC-tilkoblingen uten å ende opp med alternativt nick.

MacRelay kobler kun klientvinduet fra. Selve IRC-økten holdes levende av ZNC.

---

# Skjermbilder

## Kanalvisning

![MacRelay kanalvisning](docs/screenshots/main-chat.png)

## Native IRC-meny

![MacRelay IRC-meny](docs/screenshots/irc-menu.png)

## Server og identitet

| Server | Identitet |
| --- | --- |
| ![Server](docs/screenshots/server-settings.png) | ![Identitet](docs/screenshots/identity-settings.png) |

## Logging og varsling

![Logging](docs/screenshots/logging-settings.png)

## Menylinjestatus

![MacRelay menylinjestatus](docs/screenshots/menu-bar-status.png)

## iPhone og iPad

| Samtaleliste | Kanalvisning |
| --- | --- |
| ![MacRelay på iPhone](docs/screenshots/ios-overview-blurred.png) | ![Kanalvisning på iPhone](docs/screenshots/ios-channel-blurred.png) |

Samtaleinnholdet i iOS-skjermbildene er anonymisert.

---

# Installere iOS companion-appen

iOS-appen distribueres foreløpig ikke som en vanlig nedlastbar appfil.

Du kan bruke den på én av disse måtene:

- Be om tilgang til MacRelay via TestFlight når en testversjon er tilgjengelig.
- Klon repoet og kompiler `MacRelayiOS` selv i Xcode med ditt eget Apple Developer-team.

Ved egen kompilering åpner du `MacRelay.xcodeproj`, velger **MacRelayiOS**, velger en iPhone, iPad eller simulator og kjører med `⌘R`.

`MacRelayCore` bygges automatisk som en avhengighet og skal ikke startes separat.

---

# Bygge fra kildekode

1. Klon repoet.
2. Åpne `MacRelay.xcodeproj` i Xcode.
3. Velg **MacRelay** for macOS eller **MacRelayiOS** for iPhone/iPad.
4. Velg riktig Mac, simulator eller fysisk iOS-enhet.
5. Bygg og kjør med:

```text
⌘R
```

`MacRelayCore` er det delte kodebiblioteket og bygges automatisk. Det skal ikke startes som en egen app.

Krever macOS 14 eller nyere for Mac-appen og iOS/iPadOS 17 eller nyere for companion-appen.

Prosjektet bygger som Universal Binary når både Apple Silicon og Intel er valgt i Xcode.

---

# IRC-kommandoer

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

---

# Logger

Logger lagres lokalt under:

```text
~/Library/Application Support/MacRelay/Logs/
```

---

# Kjente begrensninger

- DCC SEND-tilbud oppdages og vises, men direkte filoverføring er foreløpig ikke implementert.
- Én aktiv IRC-server om gangen. Flere serverprofiler støttes, men bare én servertilkobling kan være aktiv samtidig.
- Distribusjonsbygget i `dist/` er ment for testing og er ikke notarized av Apple.
- DMG-filen inneholder bare macOS-appen. iOS companion-appen fås via TestFlight etter forespørsel eller kompileres fra kildekoden i Xcode.

---

# Lisens

Dette prosjektet er publisert som åpen kildekode. Se prosjektets lisensfil for detaljer.
