# NTRIP Scope Mobile

NTRIP Scope Mobile è il client diagnostico per Android e iOS. Le due app usano lo stesso codice Flutter e hanno tre schede per configurare la connessione, ispezionare i byte in diretta e consultare i messaggi RTCM3 ricevuti.

## Aggiornamento Android 0.4.2 — 12 novembre 2026

Corretto il primo caricamento della mappa mobile, che poteva richiedere un pan o uno zoom per completare la visualizzazione. L’inquadratura iniziale è ora dichiarata nelle opzioni della mappa; il callback onMapReady non sposta più la camera mentre lo strato delle tessere si inizializza. Le coordinate di stazione ricevute dopo l’apertura vengono gestite con un fit differito. Il viewport resta stabile durante i successivi aggiornamenti del rover.

I test della mappa usano tessere locali, senza contattare il servizio OSM, e verificano richieste e immagini decodificate su tutta l’area visibile: primo accesso con/senza rover, ridimensionamento, arrivo tardivo della posizione, transizione e riapertura della schermata. Nessun gesto è necessario per completare la copertura. La disponibilità delle tessere online continua a dipendere dalla connessione di rete.

## Aggiornamento Android 0.4.1 — 12 novembre 2026

Correzione della chiusura a schermo spento con Keep streaming disabilitato: la chiusura RFCOMM è serializzata e condivisa tra le richieste; la rimozione del riferimento al socket non viene più considerata una chiusura già completata. Prima di riaprire il ricevitore il client attende la fine del lettore e un breve intervallo di quiete. Durante la pulizia viene mantenuta temporaneamente attiva la CPU, al massimo 20 secondi, fino alla conclusione di ricevitore, file e chiusura del caster. La modalità Keep streaming attiva rimane distinta e conserva il servizio della 0.4.0.

In **Save configuration**:

1. Il campo **File name** ripropone l’ultimo nome usato o importato.
2. **Choose existing file** apre il selettore Android e richiama il nome del file scelto, senza modificarlo e senza caricarne le impostazioni.
3. Lasciando quel nome invariato, **Save changes** chiede **Replace existing configuration?**. Il file viene aperto in scrittura solo dopo **Replace**; Cancel lascia il file intatto e torna alla scelta del nome.
4. Modificando il nome, **Save as** crea una nuova copia attraverso il selettore di sistema. Il file originale resta invariato. Per sostituire un file esistente è necessario selezionarlo esplicitamente: il normale selettore Save as di Android può aggiungere un suffisso ai nomi già presenti, invece di sovrascrivere.
5. I file di sola lettura possono fornire un nome da modificare per salvare una copia; non vengono sovrascritti. Il nome del documento è verificato nuovamente prima della sostituzione.

Verifiche: analisi statica e **36 test Flutter superati**, inclusi flussi di conferma/annullamento/copia e standby. **13 test nativi superati** su servizio, barriera Bluetooth, documenti e mantenimento temporaneo della CPU; quest’ultimo è verificato con SDK34 e SDK36 (Android16) simulati. I test SDK36 richiedono JDK21. Non sono test del firmware Samsung/One UI né di una radio HC-06 fisica: la riconnessione sullo smartphone dell’utente resta da collaudare.

## Aggiornamento Android 0.4.0 — 12 novembre 2026

In **Connection**, prima di premere Connect, è disponibile la spunta **Keep streaming with screen off**, inizialmente disattivata. La scelta viene ricordata nelle impostazioni dell’app, separatamente dai file INI.

- Con spunta attiva, la sessione usa un servizio Android con notifica persistente. Lo schermo può spegnersi mentre proseguono NTRIP, GGA, Bluetooth, TCP, registrazione e decodifica. Alla riapertura vengono mostrati i dati aggiornati. Il servizio acquisisce le risorse CPU e Wi-Fi necessarie alla sessione e le rilascia quando termina.
- Alla prima attivazione Android può chiedere il permesso per le notifiche e di consentire l’attività senza ottimizzazione della batteria. Quest’ultima autorizzazione permette anche l’accesso alla rete durante Doze. Se viene negata, il servizio resta disponibile ma lo standby prolungato può essere limitato dal sistema. **Battery settings** apre le impostazioni dell’app per modificare questa scelta. Alcuni produttori prevedono ulteriori restrizioni energetiche.
- **Stop** nell’app termina la sessione e il servizio. **Stop** nella notifica termina anche il collegamento al ricevitore. La chiusura dal selettore delle app recenti termina la sessione. Nessuna sessione viene riavviata automaticamente dopo la terminazione del processo o il riavvio del telefono.
- Senza spunta, il passaggio in background o il blocco dello schermo chiudono NTRIP e tutte le uscite, compreso il Bluetooth. La riconnessione è consentita quando la pulizia è terminata. Il normale Stop in primo piano mantiene il riuso del Bluetooth sano, come nelle versioni precedenti.

La chiusura è ora condivisa tra tutti i chiamanti, può passare da mantenimento Bluetooth a rilascio completo e interrompe anche connessioni TCP/TLS o operazioni di apertura/scrittura ancora in attesa. I controlli di generazione nativi impediscono alle vecchie operazioni di riaprire il collegamento o chiudere le risorse di una sessione successiva. I file di cattura vengono finalizzati prima di rendere disponibile la nuova connessione.

Analisi statica, 32 test Flutter e 4 test Android nativi superati; APK release compilato. I test comprendono un caster locale per chiusura durante handshake o stream, riconnessione immediata e simulazione dei cicli blocco/sblocco con entrambe le scelte. I test Android nativi verificano servizio, notifica Stop, annullamento dell’avvio e rilascio delle risorse. L’APK mantiene la firma delle versioni dalla 0.1.5. Nessun telefono fisico era collegato durante la verifica: lo standby prolungato con il ricevitore deve essere collaudato sul dispositivo.

Questa opzione riguarda Android. iOS conserva la chiusura quando l’app passa in background.

## Aggiornamento 0.3.1 — 12 novembre 2026

Il pannello principale mostra **Receiver fix** ricavato dalla GGA originale del ricevitore, con sorgente e secondi dall’ultima ricezione. RTK FIXED è verde, NO FIX rosso; GNSS, DGNSS, RTK FLOAT ed ESTIMATED sono ambra. I valori di qualità non etichettati restano indicati numericamente. Dopo oltre cinque secondi visualizzati senza una nuova GGA valida compare STALE in grigio; dopo Stop compare PAUSED. Lo stato riporta quanto dichiarato dal ricevitore e non costituisce una verifica indipendente dell’accuratezza.

La GGA con qualità 0 viene riconosciuta anche con coordinate vuote: aggiorna lo stato NO FIX, ma non la posizione del rover e non viene inoltrata al caster. Il checksum deve essere valido. Le frasi di Bluetooth e TCP sono ricomposte separatamente; l’indicatore mostra l’ultima sorgente che ha fornito uno stato valido. Le coordinate manuali non generano un falso stato RTK: quando attive, una nota distingue la GGA inviata al caster dal fix osservato del ricevitore. Lo stato viene azzerato alla nuova sessione.

Analisi statica e 23 test automatici superati; APK Android compilato con la firma delle versioni precedenti dalla 0.1.5. Le modifiche condivise sono incluse anche nei sorgenti iOS.

## Aggiornamento 0.3.0 — 12 novembre 2026

Il dettaglio RTCM3 contiene le schede **Fields** e **Measurements**. Fields mostra i campi decodificati del tipo selezionato; il payload HEX/ASCII rimane disponibile. I tipi non supportati sono indicati esplicitamente. Measurements mantiene tabella e grafico **C/N₀**, aggiornati sul frame più recente oppure fermi sul frame storico selezionato. Il grafico distingue i segnali e scorre orizzontalmente quando i satelliti sono numerosi. L’elenco dei tipi e il dettaglio hanno una barra di scorrimento verticale visibile quando necessaria; su telefono sono schermate separate a tutta altezza, senza divisore desktop.

**Map & sky → GPS sky** mostra azimut, elevazione e traiettorie GPS ±30 minuti intorno all’ultima epoca del flusso, con anelli 0°/30°/60° e zenit al centro. Il punto indica la posizione a quell’epoca. Si può scegliere come osservatore Mountpoint oppure Rover. Il calcolo usa effemeridi GPS sane RTCM 1019, fresche entro due ore, e un’epoca GPS MSM 1071–1077. Se questi messaggi o la posizione dell’osservatore mancano, viene mostrata un’indicazione; nessun satellite è inventato. Le altre costellazioni non sono ancora tracciate nello sky plot. Le coordinate non provengono dal GNSS interno del telefono.

Analisi statica e 21 test automatici superati, inclusi confronto delle posizioni orbitali con il modello desktop, controllo CRC, effemeridi non sane/scadute, selezione Fields persistente, geometria dello sky plot e layout su schermo da 390 pixel. APK release Android firmato con la stessa chiave delle versioni 0.1.5, 0.1.6 e 0.2.0. Il collaudo radio reale richiede il telefono e il ricevitore.

## Aggiornamento 0.2.0 — 11 novembre 2026

Android è la piattaforma mobile prioritaria. Le modifiche condivise sono compilate anche per iPhone/iPad; il Bluetooth iOS resta BLE e richiede un ricevitore compatibile. L’HC-06 usa Bluetooth Classic SPP su Android.

- Live stream separa RTCM del caster e byte del ricevitore, con HEX, ASCII e contatori indipendenti.
- Il decoder segue gli ultimi frame senza essere disturbato dal traffico Bluetooth; i frame storici restano selezionabili. Le misure MSM sono disponibili come tabella e grafico C/N₀.
- **Map** mostra master, rover, linea e distanza, scala in chilometri e coordinate decimali/DMS. Il rover proviene dalla GGA o dalla posizione manuale prioritaria. La quota ellissoidica è H + separazione geoidica quando entrambi sono disponibili.
- Lo zoom resta invariato durante gli spostamenti; **Show both** inquadra entrambe le posizioni. Sono disponibili mappa stradale e cartografia offline semplificata. Dalla 0.3.0 è disponibile anche GPS sky, descritto sopra.
- Le coordinate manuali si convertono automaticamente tra gradi decimali (6 cifre) e DMS (4 cifre sui secondi); quote a 3 cifre.
- Stop congela posizione, contatori e viste, conserva la master e mantiene il collegamento SPP Android sano aperto. Connect lo riutilizza o riapre se non è più valido. Nessun dato in arrivo durante la pausa aggiorna la vista.
- La barra verde avanza a tacche durante la ricezione. Versione e informazioni sull’autore restano visibili. L’app ricorda le impostazioni non segrete e il ricevitore selezionato; non salva automaticamente la password.

Analisi statica e 17 test automatici superati; APK Android e build iOS simulatore/dispositivo senza firma compilati. Nessun telefono Android era collegato durante questa verifica: la prova radio con HC-06 deve essere eseguita sul telefono.

### Collaudo consigliato su Android

1. Installare l’APK, consentire i dispositivi nelle vicinanze, selezionare l’HC-06 già abbinato e connettere il caster.
2. Controllare i due pannelli Live stream, le GGA del ricevitore e l’aggiornamento delle misure RTCM3 in Latest frame.
3. Aprire Map, cambiare zoom e verificare che resti fermo al movimento del rover; provare Show both.
4. Premere Stop: coordinate e contatori devono fermarsi e la master deve restare. Premere Connect e verificare la ripresa senza riabbinare il ricevitore.
5. Verificare la priorità della posizione manuale e usare Disconnect receiver quando si desidera rilasciare il collegamento Bluetooth.

## Uso sul campo

**Save configuration** salva un file INI riutilizzabile da desktop e CLI. Include caster, utente e posizione rover. La password si reinserisce dopo il caricamento. Le uscite desktop presenti in un file importato vengono conservate nel file esportato.

1. Inserire l'indirizzo del caster e la porta, scegliere NTRIP 1.0 o 2.0 e attivare TLS se il caster lo supporta. Per caricare i parametri esistenti, usare **Load configuration** e selezionare il file INI del desktop o di `ntripscope --config`.
2. Usare **Fetch mountpoints** e selezionare un mountpoint dall'elenco, oppure scriverlo direttamente.
3. Per una stazione VRS, attivare **Send rover GGA**. Inserire latitudine, longitudine, quota ellissoidica e separazione geoidica. Il pulsante **Use phone latitude and longitude** chiede accesso alla posizione e compila solo latitudine e longitudine. Verificare i valori di quota prima della connessione. L'app invia la GGA iniziale e la ripete ogni dieci secondi.
4. Premere **Connect** e passare a **Live stream** o **RTCM3**. Il decoder conta i frame validi per tipo, segnala i CRC errati e conserva fino a 20 frame recenti per tipo. **Latest frame** segue il flusso in diretta. Selezionando un frame precedente, i valori restano fissi per consentirne l’ispezione. Mostra il dettaglio dei tipi 1005, 1006, 1007, 1008, 1013 e 1033 e le misure MSM1–7 per slot e segnale. I tipi senza campi decodificati restano consultabili in HEX e ASCII.
5. Per registrare i byte RTCM, attivare **Record RTCM** prima di connettersi. Dopo la chiusura della sessione, **Export capture** apre la condivisione di sistema per salvare il file temporaneo `.rtcm`.

L'importazione carica le sezioni `[caster]` e `[rover]`. Il file può contenere anche `[outputs]` e `list`, usati dagli altri client. Sul telefono la registrazione si attiva dalla schermata di connessione. L'app opera in primo piano e interrompe la sessione quando passa in background. Le credenziali inserite restano nella sessione dell'app. Il file INI originale può contenere credenziali in chiaro.

Un [INI VRS di esempio](assets/ntripscope-vrs.example.ini) è incluso nel progetto. Sostituire il caster e il mountpoint prima dell'uso.

Il pulsante **ⓘ** nella barra superiore mostra autore, versione, licenza e collegamento al repository GitHub.

## Uscite RTCM su Android

In **Connection → Stream outputs** si possono attivare più destinazioni prima di premere **Connect**.

- **Write RTCM to file** apre il selettore Android. Durante la sessione scrive i byte nel documento scelto. Una nuova connessione con la stessa destinazione riparte dall’inizio del file.
- **TCP server** ascolta sulla porta impostata, inizialmente 5000, per un client alla volta. Di default accetta collegamenti dal telefono su `127.0.0.1`. Per un computer sulla stessa rete, attiva **Allow clients on the local network** e usa l’indirizzo IP del telefono. L’uscita TCP è in chiaro e senza autenticazione. Il ricevitore riceve i byte che arrivano dopo il suo collegamento.
- **Bluetooth Classic (SPP)** invia RTCM a un ricevitore abbinato in Android. Il ricevitore deve accettare dati sul profilo seriale SPP. Se Android lo richiede, consenti l’accesso ai dispositivi nelle vicinanze.

La cattura temporanea **Record RTCM** e il decoder rimangono disponibili. Stop chiude file e TCP, congela le viste e mantiene il collegamento Bluetooth Android sano aperto, scartando i byte durante la pausa. **Disconnect receiver** lo chiude esplicitamente; il passaggio in background rilascia anche il Bluetooth se Keep streaming with screen off non è attivo. Su iOS Stop chiude il collegamento BLE. USB-seriale è previsto per una versione futura.

## GGA dal ricevitore e Bluetooth su iPhone e iPad

Il client riceve frasi GGA dal ricevitore e le inoltra al caster mentre invia le correzioni RTCM nella direzione opposta. Su Android si usa Bluetooth Classic SPP. Su iOS si usa un servizio BLE con una caratteristica per scrivere RTCM e una con notifiche per ricevere GGA.

Su iPhone e iPad aprire **Bluetooth LE receiver**, impostare gli UUID secondo le specifiche del produttore e selezionare il ricevitore dopo la scansione. I valori iniziali corrispondono al Nordic UART Service. Questo profilo è una scelta iniziale configurabile e deve corrispondere al dispositivo utilizzato.

Quando **Send manual rover GGA** è attivo, le coordinate inserite manualmente hanno priorità. Disattivandolo, il client usa le nuove GGA valide ricevute via Bluetooth. Il controllo comprende checksum, posizione e indicatore di fix. Una GGA esterna può essere inviata al massimo una volta al secondo e viene scartata se ha più di cinque secondi.

Le prove automatiche verificano entrambe le priorità con un caster simulato. Il collaudo radio SPP e BLE richiede un ricevitore fisico.

## Compilazione e prove

Il progetto contiene entrambi i target. È stato generato con Flutter 3.47.9.

```sh
flutter pub get
flutter analyze
flutter test
# Android native service tests (from android/):
# ./gradlew :app:testDebugUnitTest
```

### Android

Configurare [l'ambiente Android di Flutter](https://docs.flutter.dev/platform-integration/android/setup), poi eseguire:

```sh
flutter build apk --release
```

L'APK di prova si trova in `build/app/outputs/flutter-apk/app-release.apk`. Per uno store occorre configurare la firma di distribuzione.

### iOS

Configurare [l'ambiente iOS di Flutter](https://docs.flutter.dev/platform-integration/ios/setup) con Xcode completo. Per compilare senza firma per il simulatore:

```sh
BYPASS_PERMISSION_LOCATION_ALWAYS=1 flutter build ios --simulator
```

Per installare su iPhone, selezionare il proprio team di firma per il target Runner in Xcode e usare `BYPASS_PERMISSION_LOCATION_ALWAYS=1 flutter run -d <device>`.

## Licenza

Il codice è distribuito con [licenza MIT](LICENSE).


## Firma e aggiornamento Android

La chiave temporanea usata dalle prime build di prova non è più disponibile. Le build 0.1.5, 0.1.6 e 0.2.0 usano la stessa nuova firma di sviluppo: dalla 0.1.5/0.1.6 è possibile aggiornare direttamente. Prima di rimuovere l’app precedente, esportare le configurazioni INI e le catture RTCM che si vogliono conservare. Dopo la rimozione, installare il nuovo APK. Le chiavi di firma locali sono escluse dai sorgenti distribuiti.
