# Gamepad

Transforme un smartphone en manette virtuelle pour un PC Linux (NixOS), via WebSocket + `uinput`.

## Structure

- `ios/` — app SwiftUI native (iOS), générée via [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`project.yml` + sources dans `ios/Gamepad/`)
- `server/` — serveur Python (`gamepad_server.py`) qui tourne sur la machine Linux cible : reçoit les inputs via WebSocket et crée une manette virtuelle via `evdev`/`uinput`
- `android/` — app Kotlin native (à venir)

## CI

`.github/workflows/ios-build.yml` build l'app iOS sur un runner `macos-latest` (pas besoin de Mac local) :
XcodeGen génère le `.xcodeproj`, `xcodebuild archive` compile sans signature (`CODE_SIGNING_ALLOWED=NO`), puis le `.app` est empaqueté en `.ipa` non signé, publié comme artifact du run.

Pour installer sur un iPhone : télécharger le `.ipa` depuis les artifacts du run GitHub Actions, puis le signer avec **Sideloadly** (ou AltStore) en utilisant un Apple ID gratuit. Limite : l'app expire au bout de 7 jours et doit être re-signée.

## Utilisation

1. Sur la machine Linux (NixOS) : `python3 server/gamepad_server.py` (dépendances : voir `server/requirements.txt`, ou le module NixOS dans `nixos/`)
2. Le serveur affiche un token d'appairage au démarrage (généré une fois, stocké dans `server/.pairing_token`).
3. Sur le téléphone : ouvrir l'app, soit toucher « Rechercher automatiquement » (découverte mDNS sur le réseau local), soit entrer l'IP + le port (8765 par défaut) à la main, puis coller le token affiché par le serveur, et se connecter.

Diagnostic de l'environnement serveur : `python3 server/gamepad_server.py doctor`.

### Latence sous forte charge CPU (jeu lourd)

Si la latence augmente fortement en jeu (centaines de ms, voire plusieurs secondes), le serveur se fait probablement déclasser par le scheduler Linux par défaut (`SCHED_OTHER`), qui privilégie l'équité entre processus plutôt que la latence d'un processus I/O-bound comme celui-ci. Lancer le serveur avec une priorité temps réel modérée règle ça :

```fish
sudo chrt -r 10 python3 server/gamepad_server.py
```

`chrt` nécessite root ou la capacité `CAP_SYS_NICE`. Confirmé en conditions réelles (jeu lourd) : sans `chrt`, latence de 400 à 2000 ms ; avec `chrt -r 10`, jeu fluide. Le traitement d'un message par le serveur lui-même ne dépassait jamais 1 ms pendant ces tests, la cause était donc bien le scheduling du processus sous charge CPU, pas le code du serveur.

### Robustesse

- **Deadman côté serveur** : si aucun message n'arrive pendant 400 ms (Wi-Fi coupé, app en arrière-plan, téléphone verrouillé), le serveur remet tous les boutons/axes au neutre pour éviter un stick ou un bouton bloqué.
- **Reconnexion côté app** : backoff exponentiel (0.5s à 10s max) après une perte de connexion établie, avec un indicateur discret "Reconnexion… (n)" à l'écran plutôt qu'un retour à l'écran de connexion. Un échec de première connexion (mauvaise IP/port/token) n'affiche jamais l'interface de la manette et ne boucle pas indéfiniment.
- **Identité Xbox 360 émulée** : la manette virtuelle s'annonce avec le VID/PID `045e:028e` (Xbox 360), reconnue nativement par Steam/Proton/SDL.
- **Cycle de vie iOS** : écran toujours allumé pendant l'utilisation (`isIdleTimerDisabled`), gestes système (Centre de contrôle, Dock) différés sur les bords de l'écran pour éviter de les déclencher accidentellement en jeu.
- **Token d'appairage** : le serveur génère un token au premier démarrage (`server/.pairing_token`) ; le client doit le fournir lors du handshake, sinon la connexion est refusée.
- **Handshake versionné** : le client annonce sa version de protocole et sa plateforme à la connexion ; le serveur répond avec les fonctionnalités supportées.
- **Multi-manettes** : jusqu'à 4 manettes virtuelles simultanées (une par appareil connecté), chacune avec son propre device `uinput`.
- **Diagnostic (`doctor`)** : `python3 server/gamepad_server.py doctor` vérifie `/dev/uinput`, les permissions, la disponibilité de `zeroconf`, et affiche l'IP locale et le chemin du token.

### Qualité de vie

- **Découverte automatique (mDNS/Bonjour)** : le serveur s'annonce sur le réseau local (`_gamepad._tcp`), l'app peut le détecter automatiquement sans saisir l'IP.
- **Module NixOS** : voir `nixos/module.nix` et `nixos/README.md` — prépare l'environnement (uinput, pare-feu, dépendances Python) sans service systemd.
- **Import/export de disposition** : dans Réglages → Disposition, exporte la disposition actuelle en JSON (partage système) ou importe un fichier JSON existant.

### Gameplay

- **LT/RT analogiques** : gâchettes glissantes (haut = appuyé à fond, bas = relâché) en plus de LB/RB.
- **L3/R3 (clic de stick)** : double-tap rapide sur un stick pour déclencher le clic du stick correspondant.
- **Haptique différenciée** : tap léger sur les boutons normaux, clic plus sec sur les gâchettes analogiques et les clics de stick, cran discret quand un stick atteint le bord de sa course.
