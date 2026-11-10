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

### iOS

Configurare [l'ambiente iOS di Flutter](https://docs.flutter.dev/platform-integration/ios/setup) con Xcode completo. Per compilare senza firma per il simulatore:

```sh
BYPASS_PERMISSION_LOCATION_ALWAYS=1 flutter build ios --simulator
```

Per installare su iPhone, selezionare il proprio team di firma per il target Runner in Xcode e usare `BYPASS_PERMISSION_LOCATION_ALWAYS=1 flutter run -d <device>`.

## Licenza

Il codice è distribuito con [licenza MIT](LICENSE).
