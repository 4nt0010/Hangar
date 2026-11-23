# Hangar

Tutti i tuoi dischi esterni in un posto solo: spazio libero, navigazione nei file anche a disco staccato, ricerca, duplicati da eliminare e progetti.

- **App per Mac** (`mac/`): si compila da sola su GitHub e la scarichi come `Hangar.dmg`. Rileva i dischi che colleghi, li indicizza e fa le azioni sui file (Mostra nel Finder, Sposta nel Cestino, sempre con conferma).
- **Sito** (`docs/`): la stessa interfaccia, pubblicata su GitHub Pages. Dentro l'app viene caricata da lì, quindi ogni modifica al sito arriva anche nell'app senza reinstallare nulla.
- **Firebase** (`firebase/`): facoltativo. Se accedi con il tuo account nell'app, i dischi e gli indici si vedono anche dal sito, da qualsiasi dispositivo.

## Prima installazione (una volta sola, tutto dal browser)

1. **Crea il repository** su github.com → *New repository* → nome `hangar` → *Create*.
2. **Carica i file**: *uploading an existing file* → trascina tutto il contenuto della cartella `Hangar-repo` (cartelle `mac`, `docs`, `firebase` e `README.md`) → *Commit changes*.
3. **Crea il file di compilazione** (il Finder nasconde le cartelle che iniziano con il punto, quindi va creato a mano):
   *Add file → Create new file* → come nome scrivi `.github/workflows/build.yml` → incolla il contenuto del file `DA-COPIARE-build.yml` → *Commit changes*.
4. **Attiva il sito**: *Settings → Pages* → *Source: Deploy from a branch* → branch `main`, cartella `/docs` → *Save*. Dopo un minuto il sito è su `https://<tuo-utente>.github.io/hangar/`.
5. **Aspetta la compilazione**: scheda *Actions* → “Compila Hangar per Mac” (circa 3 minuti). Se non è partita da sola premi *Run workflow*.
6. **Scarica l'app**: nella pagina del repository, a destra, *Releases* → ultima versione → `Hangar.dmg`.
7. **Installa**: apri il DMG e trascina Hangar su *Applicazioni*.
8. **Primo avvio**: macOS dirà che non può verificare lo sviluppatore (l'app non è firmata con un account Apple a pagamento). Vai su *Impostazioni di Sistema → Privacy e sicurezza*, scorri in basso e premi **Apri comunque**. Serve solo la prima volta.
9. Quando colleghi un disco, macOS chiede se Hangar può accedere ai volumi rimovibili: rispondi **Consenti**.

## Aggiornamenti

- **Interfaccia** (`docs/index.html`): modifichi il file su GitHub e salvi. L'app scarica la nuova versione a ogni avvio (o con ⌘R).
- **App** (`mac/`): ogni modifica crea da sola una nuova Release. Hangar controlla ogni 6 ore e propone *“È disponibile Hangar 1.0.x — Aggiorna e riavvia”*: un clic e si sostituisce da sola in Applicazioni. Puoi anche usare *Cerca aggiornamenti…* dal menu.
- Dopo un aggiornamento dell'app macOS potrebbe richiedere di nuovo il permesso per i dischi esterni.

## Come si usa

- L'icona del disco nella barra dei menu mostra lo spazio libero dei dischi collegati. Chiudere la finestra non chiude Hangar, che continua a seguire i dischi.
- Un disco appena collegato viene indicizzato in automatico (si può disattivare dal menu). Il pulsante ↻ nella testata del disco rifà l'indice quando vuoi.
- *Libera spazio* trova duplicati, proxy, render, cache, `node_modules` e simili. Quello che scegli finisce nel Raccoglitore; lo svuoti con una conferma sul Mac e i file vanno nel Cestino, da cui si possono ancora recuperare.
- In basso nella barra laterale il pulsante account collega Firebase: da lì in poi il sito mostra gli stessi dischi, e da sito puoi chiedere al Mac di aprire un file nel Finder o di spostare elementi nel Cestino (il Mac chiede sempre conferma).

## Firebase (solo se vuoi il sito sincronizzato)

Il progetto `hangar-4f2a1` è già configurato nel sito. Le regole da incollare in console sono in `firebase/firestore.rules` e `firebase/storage.rules`; `firebase/cors.json` è già stato applicato al bucket.

## Struttura

```
mac/Sources/      codice dell'app (Swift, senza Xcode: compila GitHub)
mac/Info.plist    dati dell'app; versione e indirizzi li scrive la compilazione
mac/make-icon.swift  disegna l'icona
docs/index.html   interfaccia (sito + app)
firebase/         regole di sicurezza
.github/workflows/build.yml  compilazione automatica, DMG e Release
```
