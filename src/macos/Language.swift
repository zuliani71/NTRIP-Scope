import Foundation

enum AppLanguage {
    static let key = "interfaceLanguage"

    static var english: Bool { UserDefaults.standard.string(forKey: key) != "it" }
}

func tr(_ italian: String) -> String {
    guard AppLanguage.english else { return italian }
    if let english = translations[italian] { return english }
    if italian.hasSuffix(" mountpoint disponibili") {
        return italian.replacingOccurrences(of: " mountpoint disponibili", with: " mountpoints available")
    }
    for (italianPrefix, englishPrefix) in translatedPrefixes where italian.hasPrefix(italianPrefix) {
        return englishPrefix + italian.dropFirst(italianPrefix.count)
    }
    return italian
}

private let translatedPrefixes = [
    ("Uscita TCP: ", "TCP output: "),
    ("Registrazione interrotta: ", "Recording stopped: "),
    ("Seriale: ", "Serial: "),
    ("Seriale ", "Serial "),
    ("Errore uscita seriale ", "Serial output error ")
]

private let translations: [String: String] = [
    "Carica configurazione…": "Load configuration…",
    "Configurazione caricata": "Configuration loaded",
    "Configurazione INI non valida": "Invalid INI configuration",
    "Sovrascrivere i file di uscita esistenti?": "Overwrite existing output files?",
    "Sovrascrivi": "Overwrite", "Annulla": "Cancel",

    "Mappa stradale": "Street map", "Mappa offline": "Offline map",
    "Scala mappa": "Map scale",
    "Posizione rover…": "Rover position…", "Posizione rover": "Rover position",
    "Invia posizione rover (GGA)": "Send rover position (GGA)",
    "Gradi": "Degrees", "Minuti": "Minutes", "Secondi": "Seconds", "Emisfero": "Hemisphere",
    "Quota ellissoidica (m)": "Ellipsoidal height (m)", "Separazione geoidica (m)": "Geoid separation (m)",
    "Separazione geoidica facoltativa. Se omessa, la GGA usa 0,000 m.": "Geoid separation is optional. If omitted, GGA uses 0.000 m.",
    "Completa latitudine, longitudine e quota ellissoidica.": "Enter latitude, longitude and ellipsoidal height.",

    "Gradi decimali": "Decimal degrees", "Gradi sessagesimali": "Degrees, minutes, seconds",
    "Latitudine": "Latitude", "Longitudine": "Longitude",
    "Quota ellissoidica": "Ellipsoidal height", "Non disponibile": "Unavailable",
    "Ingrandisci": "Zoom in", "Riduci": "Zoom out",

    "Mappa e cielo": "Map & sky", "Mappa": "Map", "Cielo GPS": "GPS sky", "O": "W",
    "Antenna dal flusso RTCM 1005/1006": "Antenna position from RTCM 1005/1006",
    "Posizione indicativa dalla sourcetable": "Approximate position from caster sourcetable",
    "Servono effemeridi GPS RTCM 1019 e un’epoca GPS MSM nel flusso.": "The stream must include GPS ephemerides (RTCM 1019) and a GPS MSM epoch.",
    "Scarica l’elenco e scegli un mountpoint, oppure connettiti a un flusso con RTCM 1005/1006.": "Fetch and select a mountpoint, or connect to a stream that includes RTCM 1005/1006.",
    "Nessuna traiettoria GPS sopra l’orizzonte con le effemeridi disponibili.": "No GPS tracks above the horizon from the available ephemerides.",
    "Traiettorie GPS nel cielo": "GPS satellite sky tracks",
    "GPS · ±30 min dall’ultima epoca del flusso. Il punto indica la posizione a quell’epoca.": "GPS · ±30 min around the latest stream epoch. A dot marks the position at that epoch.",

    "Pronto": "Ready", "Disconnesso": "Disconnected",
    "Controlla caster, porta e mountpoint": "Check the caster, port and mountpoint",
    "Inserisci una singola frase NMEA GGA": "Enter a single NMEA GGA sentence",
    "Connessione in corso…": "Connecting…",
    "Nessun dato ricevuto per 30 secondi": "No data received for 30 seconds",
    "Connessione chiusa dal caster": "Connection closed by caster",
    "Risposta del caster non valida": "Invalid caster response",
    "Il caster ha restituito l’elenco dei mountpoint": "The caster returned the mountpoint list",
    "Intestazione del caster troppo lunga": "Caster response header is too long",
    "Lettura mountpoint…": "Reading mountpoints…",
    "Connesso, in attesa di dati…": "Connected, waiting for data…",
    "Blocco NTRIP non valido": "Invalid NTRIP chunk",
    "Flusso terminato dal caster": "Stream ended by caster",
    "Elenco mountpoint troppo grande": "Mountpoint list is too large",
    "Ricezione in corso": "Receiving data",
    "Inserisci una porta TCP tra 1 e 65535": "Enter a TCP port between 1 and 65535",
    "Scegli una porta seriale": "Select a serial port",
    "Impossibile leggere le impostazioni seriali": "Unable to read serial settings",
    "Impossibile configurare la porta seriale": "Unable to configure the serial port",
    "Uscita seriale troppo lenta": "Serial output is too slow",
    "Nessun mountpoint trovato": "No mountpoints found",
    "mountpoint disponibili": "mountpoints available", "collegato": "connected", "in ascolto": "listening",
    "Client NTRIP · Decoder RTCM": "NTRIP client · RTCM decoder",
    "Flusso in diretta": "Live stream", "Opzioni…": "Options…",
    "Indirizzo caster": "Caster address", "caster.esempio.it": "caster.example.com",
    "Porta": "Port", "Scarica elenco": "Fetch mountpoints", "Utente": "Username",
    "Dati in arrivo": "Receiving data", "Nessun dato recente": "No recent data",
    "byte ricevuti": "bytes received", "Ferma": "Stop", "Connetti": "Connect",
    "Opzioni NTRIP": "NTRIP options", "Lingua": "Language", "Versione NTRIP": "NTRIP version",
    "Connessione TLS": "TLS connection", "Facoltativa, per caster VRS": "Optional, for VRS casters",
    "Salva RTCM su file": "Save RTCM to file", "Scegli file…": "Choose file…",
    "Inoltra su TCP": "Forward over TCP", "Indirizzo locale 127.0.0.1": "Local address 127.0.0.1",
    "Porta TCP": "TCP port", "Inoltra su seriale": "Forward over serial",
    "Scegli porta": "Select port", "Aggiorna": "Refresh", "Velocità": "Baud rate",
    "Fine": "Done", "Scegli il file RTCM nelle opzioni": "Choose an RTCM file in Options",
    "Vista": "View", "HEX e ASCII": "HEX and ASCII", "Decoder RTCM3": "RTCM3 decoder",
    "Ultimi 256 byte · I caratteri ASCII non stampabili appaiono come punti.": "Last 256 bytes · Dots represent non-printable ASCII characters.",
    "In attesa di dati…": "Waiting for data…", "Frame con CRC errato": "Frames with invalid CRC",
    "Segnali MSM osservati nella sessione": "MSM signals observed in this session",
    "In attesa di un messaggio RTCM3 valido…": "Waiting for a valid RTCM3 message…",
    "Tipo": "Type", "Messaggio": "Message", "N.": "Count", "Segnali / dettagli": "Signals / details",
    "Seleziona per il dettaglio": "Select for details", "Seleziona un tipo per consultare i singoli frame.": "Select a message type to inspect its frames.",
    "Ultimo ricevuto": "Latest frame", "Fino a 20 frame recenti per tipo": "Up to 20 recent frames per type",
    "byte": "bytes", "Misure per satellite e segnale": "Measurements by satellite and signal",
    "MSM compatto · Distanze modulo 1 ms, con ambiguità di millisecondi interi.": "Compact MSM · Ranges modulo 1 ms, with integer millisecond ambiguity.",
    "Segnale": "Signal", "Pseudodist. (m)": "Pseudorange (m)", "Fase (m)": "Phase range (m)",
    "Velocità (m/s)": "Range rate (m/s)",
    "— indica una misura assente o non valida. La fase è espressa come distanza equivalente.": "— marks missing or invalid measurements. Carrier phase is shown as equivalent range.",
    "Nessuna misura decodificabile in questo frame.": "No decodable measurements in this frame.",
    "Grafico C/N₀": "C/N₀ chart", "Tabella": "Table", "Slot satellite": "Satellite slot",
    "Nessun valore C/N₀ disponibile in questo frame.": "This frame contains no valid C/N₀ values.",
    "Ogni punto rappresenta un segnale ricevuto per lo slot indicato.": "Each point represents a signal received for that satellite slot.",
    "Osservazioni GPS L1": "GPS L1 observations", "Osservazioni GPS L1 estese": "Extended GPS L1 observations",
    "Osservazioni GPS L1/L2": "GPS L1/L2 observations", "Osservazioni GPS L1/L2 estese": "Extended GPS L1/L2 observations",
    "Coordinate stazione": "Station coordinates", "Coordinate e altezza antenna": "Antenna coordinates and height",
    "Descrittore antenna": "Antenna descriptor", "Descrittore e seriale antenna": "Antenna descriptor and serial",
    "Osservazioni GLONASS L1": "GLONASS L1 observations", "Osservazioni GLONASS L1 estese": "Extended GLONASS L1 observations",
    "Osservazioni GLONASS L1/L2": "GLONASS L1/L2 observations", "Osservazioni GLONASS L1/L2 estese": "Extended GLONASS L1/L2 observations",
    "Parametri di sistema": "System parameters", "Effemeridi GPS": "GPS ephemeris",
    "Effemeridi GLONASS": "GLONASS ephemeris", "Descrittori ricevitore e antenna": "Receiver and antenna descriptors",
    "Effemeridi NavIC": "NavIC ephemeris", "Effemeridi BeiDou": "BeiDou ephemeris",
    "Effemeridi SBAS": "SBAS ephemeris", "Effemeridi QZSS": "QZSS ephemeris",
    "Effemeridi Galileo F/NAV": "Galileo F/NAV ephemeris", "Effemeridi Galileo I/NAV": "Galileo I/NAV ephemeris",
    "Bias di codice GLONASS": "GLONASS code biases", "Messaggio RTCM3": "RTCM3 message",
    "Payload troppo corto per i campi del tipo": "Payload too short for message type",
    "Epoca GLONASS": "GLONASS epoch", "giorno": "day", "Epoca GNSS": "GNSS epoch",
    "Stazione": "Station", "Altri messaggi nella stessa epoca": "More messages in this epoch",
    "sì": "yes", "no": "no", "Satelliti nella maschera": "Satellites in mask", "nessuna cella attiva": "no active cells",
    "Indicatore ITRF": "ITRF indicator",
    "Coordinate ECEF del punto di riferimento antenna (ARP)": "Antenna reference point (ARP) ECEF coordinates",
    "Altezza antenna": "Antenna height", "ID configurazione antenna": "Antenna setup ID",
    "Seriale antenna": "Antenna serial", "Modello ricevitore": "Receiver model",
    "Firmware ricevitore": "Receiver firmware", "Seriale ricevitore": "Receiver serial",
    "Giorno giuliano modificato": "Modified Julian day", "Secondi del giorno UTC": "UTC seconds of day",
    "Messaggi annunciati": "Announced messages", "intervallo non dichiarato": "interval not specified",
    "sincronizzato": "synchronized", "Campi non decodificati per questo tipo.": "Fields for this type are not decoded.",
    "non trasmesso": "not transmitted"
]
