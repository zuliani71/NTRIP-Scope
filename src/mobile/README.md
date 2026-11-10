# NTRIP Scope Mobile

NTRIP Scope Mobile è il client diagnostico per Android e iOS. Le due app usano lo stesso codice Flutter e hanno tre schede per configurare la connessione, ispezionare i byte in diretta e consultare i messaggi RTCM3 ricevuti.

## Uso sul campo

**Save configuration** salva un file INI riutilizzabile da desktop e CLI. Include caster, utente e posizione rover. La password si reinserisce dopo il caricamento. Le uscite desktop presenti in un file importato vengono conservate nel file esportato.

1. Inserire l'indirizzo del caster e la porta, scegliere NTRIP 1.0 o 2.0 e attivare TLS se il caster lo supporta. Per caricare i parametri esistenti, usare **Load configuration** e selezionare il file INI del desktop o di `ntripscope --config`.
2. Usare **Fetch mountpoints** e selezionare un mountpoint dall'elenco, oppure scriverlo direttamente.
3. Per una stazione VRS, attivare **Send rover GGA**. Inserire latitudine, longitudine, quota ellissoidica e separazione geoidica. Il pulsante **Use phone latitude and longitude** chiede accesso alla posizione e compila solo latitudine e longitudine. Verificare i valori di quota prima della connessione. L'app invia la GGA iniziale e la ripete ogni dieci secondi.
4. Premere **Connect** e passare a **Live stream** o **RTCM3**. Il decoder conta i frame validi per tipo, segnala i CRC errati e conserva fino a 20 frame recenti per tipo. **Latest frame** segue il flusso in diretta. Selezionando un frame precedente, i valori restano fissi per consentirne l’ispezione. Mostra il dettaglio dei tipi 1005, 1006, 1007, 1008, 1013 e 1033 e le misure MSM1–7 per slot e segnale. I tipi senza campi decodificati restano consultabili in HEX e ASCII.
5. Per registrare i byte RTCM, attivare **Record RTCM** prima di connettersi. Dopo la chiusura della sessione, **Export capture** apre la condivisione di sistema per salvare il file temporaneo `.rtcm`.

L'importazione carica le sezioni `[caster]` e `[rover]`. Il file può contenere anche `[outputs]` e `list`, usati dagli altri client. Sul telefono la registrazione si attiva dalla schermata di connessione. L'app opera in primo piano e interrompe la sessione quando passa in background. Le credenziali inserite restano nella sessione dell'app. Il file INI originale può contenere credenziali in chiaro.

Un [INI VRS di esempio](assets/ntripscope-vrs.example.ini) è incluso nel progetto. Sostituire il caster e il mountpoint prima dell'uso.

## Compilazione e prove

Il progetto contiene entrambi i target. È stato generato con Flutter 3.47.9.

```sh
flutter pub get
flutter analyze
flutter test
```

### Android

Configurare [l'ambiente Android di Flutter](https://docs.flutter.dev/platform-integration/android/setup), poi eseguire:

```sh
flutter build apk --debug
```

L'APK di prova si trova in `build/app/outputs/flutter-apk/app-debug.apk`. Per uno store occorre configurare la firma di distribuzione.

### iPhone e iPad

NTRIP Scope richiede iOS o iPadOS 15 o successivo. La versione di sviluppo si installa dal Mac con Xcode. Per provare l’app sul proprio dispositivo si può usare un normale account Apple e scegliere **Personal Team** in Xcode.

1. Installa Flutter e Xcode completo. Apri Xcode e scarica il componente iOS da **Xcode → Settings → Components**. In **Settings → Locations → Command Line Tools**, seleziona Xcode. [Configurazione Flutter per iOS](https://docs.flutter.dev/platform-integration/ios/setup)
2. Clona il repository e prepara le dipendenze dalla cartella del progetto mobile.

   ```sh
   git clone https://github.com/zuliani71/NTRIP-Scope.git
   cd NTRIP-Scope/src/mobile
   flutter pub get
   flutter build ios --config-only
   open ios/Runner.xcworkspace
   ```

3. Collega il dispositivo al Mac con un cavo dati, sbloccalo e conferma **Autorizza questo computer?** se richiesto. Controlla che compaia nel Finder sotto **Posizioni** e in Xcode sotto **Window → Devices and Simulators**.
4. In **Xcode → Settings → Accounts** aggiungi il tuo account Apple. Nel progetto **Runner**, seleziona **TARGETS → Runner → Signing & Capabilities**, attiva **Automatically manage signing** e scegli il tuo **Personal Team**. Se Xcode segnala che l’identificativo dell’app è già in uso, modifica **Bundle Identifier** con un identificativo univoco per la tua build.
5. Scegli l’iPhone o l’iPad come destinazione. Se Xcode richiede la **Modalità sviluppatore**, sul dispositivo vai in **Impostazioni → Privacy e sicurezza → Modalità sviluppatore**, attivala, riavvia e conferma dopo il riavvio. [Guida Apple alla modalità sviluppatore](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)
6. Premi **Run ▶**. Se il Portachiavi del Mac chiede a `codesign` di usare la chiave **Apple Development**, autorizza la richiesta nella finestra di sistema. A installazione completata, apri **NTRIP Scope**.
7. Se il dispositivo segnala **Sviluppatore non autorizzato**, vai in **Impostazioni → Generali → VPN e gestione dispositivo**. Se compare la sezione **App sviluppatore**, seleziona il profilo del tuo account e autorizzalo seguendo le indicazioni di iOS. Riapri l’app.

Per provare l’app sul simulatore senza configurare la firma, installa il runtime iOS da Xcode e usa:

```sh
BYPASS_PERMISSION_LOCATION_ALWAYS=1 flutter build ios --simulator
```

#### Risoluzione dei problemi

| Sintomo | Controllo |
|---|---|
| Il dispositivo è collegato ma non compare in Xcode | Verifica prima il Finder. Sblocca il dispositivo, prova una porta diretta del Mac e usa un cavo dati. Dopo un riavvio, se necessario scollega e ricollega il cavo. [Guida Apple](https://support.apple.com/it-it/108643) |
| `PhaseScriptExecution failed` | Apri il log della build e leggi la prima riga di errore. Se cita `objective_c`, `sdkPath` o `Bad state: No element`, verifica che in **Settings → Locations** sia selezionato Xcode completo e che il componente iOS sia installato. Esegui di nuovo `flutter pub get` se Xcode non trova i plugin Flutter. |
| `invalid reuse after initialization failure` | Chiudi e riapri il workspace, poi usa **Product → Clean Build Folder** e riprova. Una compilazione con una cartella di build nuova ha superato questo errore durante la prova. |
| `errSecInternalComponent` durante la firma | Verifica il **Team** e controlla se il Portachiavi attende il consenso per **Apple Development**. |
| L’app si installa ma iOS ne blocca l’apertura | Se iOS indica uno sviluppatore non autorizzato, controlla il profilo come al punto 7. Se il profilo manca o l’errore persiste, verifica certificato, firma e profilo in Xcode. |

## Licenza

Il codice è distribuito con [licenza MIT](LICENSE).
