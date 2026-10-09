# Gamepad

Transforme un smartphone en manette virtuelle pour un PC Linux (NixOS), via WebSocket + `uinput`.

## Structure

- `ios/` — app SwiftUI native (iOS), générée via [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`project.yml` + sources dans `ios/Gamepad/`)
- `server/` — serveur Python (`gamepad_server.py`) qui tourne sur la machine Linux cible : reçoit les inputs via WebSocket et crée une manette virtuelle via `evdev`/`uinput`

## CI

`.github/workflows/ios-build.yml` build l'app iOS sur un runner `macos-latest` (pas besoin de Mac local) :
XcodeGen génère le `.xcodeproj`, `xcodebuild archive` compile sans signature (`CODE_SIGNING_ALLOWED=NO`), puis le `.app` est empaqueté en `.ipa` non signé, publié comme artifact du run.

Pour installer sur un iPhone : télécharger le `.ipa` depuis les artifacts du run GitHub Actions, puis le signer avec **Sideloadly** (ou AltStore) en utilisant un Apple ID gratuit. Limite : l'app expire au bout de 7 jours et doit être re-signée.

## Utilisation

1. Sur la machine Linux : `python3 server/gamepad_server.py` (dépendances : voir `server/requirements.txt`). **Sur NixOS avec le module (`nixos/`) activé, utilise `gamepad-server server/gamepad_server.py` à la place** — le `python3` du système n'a pas les dépendances (`evdev`/`websockets`/`zeroconf`), c'est `gamepad-server` qui les fournit sans entrer en conflit avec le `python3` système.
2. Sur le téléphone : ouvrir l'app, puis soit toucher « Scanner un QR code » et viser le QR code affiché par le serveur dans le terminal (connexion automatique), soit toucher « Rechercher automatiquement » (découverte mDNS sur le réseau local), soit entrer l'IP + le port (8765 par défaut) à la main, puis se connecter.

Le QR code (`gamepad://ip:port`) s'affiche au démarrage du serveur quand il tourne dans un terminal interactif et que le module Python `qrcode` est installé (inclus dans `server/requirements.txt` et dans le module NixOS) ; sinon seule l'adresse est loggée.

Diagnostic de l'environnement serveur : `python3 server/gamepad_server.py doctor` (ou `gamepad-server server/gamepad_server.py doctor` sur NixOS).

### Latence sous forte charge CPU (jeu lourd)

Si la latence augmente fortement en jeu (centaines de ms, voire plusieurs secondes), le serveur se fait probablement déclasser par le scheduler Linux par défaut (`SCHED_OTHER`), qui privilégie l'équité entre processus plutôt que la latence d'un processus I/O-bound comme celui-ci. Lancer le serveur avec une priorité temps réel modérée règle ça :

```fish
sudo chrt -r 10 python3 server/gamepad_server.py
```

`chrt` nécessite root ou la capacité `CAP_SYS_NICE`. Confirmé en conditions réelles (jeu lourd) : sans `chrt`, latence de 400 à 2000 ms ; avec `chrt -r 10`, jeu fluide. Le traitement d'un message par le serveur lui-même ne dépassait jamais 1 ms pendant ces tests, la cause était donc bien le scheduling du processus sous charge CPU, pas le code du serveur.

### Diagnostic de latence (`--diag`)

Pour savoir d'où vient une latence ou un ping irrégulier, lancer le serveur avec `--diag` (par exemple `sudo chrt -r 10 gamepad-server server/gamepad_server.py --diag`). Chaque seconde où des messages arrivent, il affiche une ligne :

```
diag: retard boucle moy 0.63 max 11.72 ms | 62 msg | écart max entre pings 151 ms | montée relative moy 0.4 max 2.1 ms | traitement max 0.03 ms | écho max 0.05 ms
```

- **retard boucle** : retard de la boucle asyncio du serveur par rapport à l'horloge. Un max élevé (plusieurs ms) indique que le processus n'a pas eu le CPU à temps (scheduling, `chrt` absent, charge).
- **écart max entre pings** : intervalle le plus long entre deux pings reçus de l'iPhone, envoyés toutes les 150 ms. Un écart bien au-dessus de 150 ms alors que le retard de boucle est faible indique un délai avant l'arrivée des données (envoi côté iPhone ou trajet réseau).
- **montée relative** : variation du délai iPhone → PC seul. Chaque ping contient l'heure d'envoi de l'iPhone, comparée à l'heure d'arrivée au serveur ; le décalage constant entre les deux horloges est éliminé en retranchant le meilleur délai observé sur les 10 dernières secondes. Une montée max proche des variations du ping affiché dans l'app (par exemple 30 à 40 ms) indique que la variation se produit entre l'envoi iPhone et l'arrivée au PC ; une montée stable alors que le ping varie indique le retour vers l'iPhone ou la réception côté app.
- **traitement max / écho max** : temps passé par le serveur à traiter un message et à renvoyer un ping.

Sans `--diag`, aucune de ces lignes n'est affichée.

### Robustesse

- **Deadman côté serveur** : si aucun message n'arrive pendant 1,2 s (Wi-Fi coupé, app en arrière-plan, téléphone verrouillé), le serveur remet tous les boutons/axes au neutre pour éviter un stick ou un bouton bloqué. L'app envoie un ping toutes les 150 ms pour garder la connexion active même quand rien ne change (bouton maintenu, stick immobile), avec une large marge sous le seuil du deadman.
- **Reconnexion côté app** : backoff exponentiel (0.5s à 10s max) après une perte de connexion établie, avec un indicateur discret "Reconnexion… (n)" à l'écran plutôt qu'un retour à l'écran de connexion. Un échec de première connexion (mauvaise IP/port, serveur éteint) n'affiche jamais l'interface de la manette et ne boucle pas indéfiniment.
- **Identité Xbox 360 émulée** : la manette virtuelle s'annonce avec le VID/PID `045e:028e` (Xbox 360), reconnue nativement par Steam/Proton/SDL.
- **Cycle de vie iOS** : écran toujours allumé pendant l'utilisation (`isIdleTimerDisabled`), gestes système (Centre de contrôle, Dock) différés sur les bords de l'écran pour éviter de les déclencher accidentellement en jeu.
- **Handshake versionné** : le client annonce sa version de protocole et sa plateforme à la connexion ; le serveur répond avec les fonctionnalités supportées.
- **Multi-manettes** : jusqu'à 4 manettes virtuelles simultanées (une par appareil connecté), chacune avec son propre device `uinput`.
- **Diagnostic (`doctor`)** : `python3 server/gamepad_server.py doctor` vérifie `/dev/uinput`, les permissions, la disponibilité de `zeroconf`, et affiche l'IP locale.

### Qualité de vie

- **Découverte automatique (mDNS/Bonjour)** : le serveur s'annonce sur le réseau local (`_gamepad._tcp`), l'app peut le détecter automatiquement sans saisir l'IP.
- **Module NixOS** : voir `nixos/module.nix` et `nixos/README.md` — prépare l'environnement (uinput, pare-feu, dépendances Python) sans service systemd.
- **Import/export de disposition** : dans Réglages → Disposition, exporte la disposition actuelle en JSON (partage système) ou importe un fichier JSON existant.

### Gameplay

- **LT/RT** : gâchettes supplémentaires (simple appui, comme LB/RB).
- **L3/R3 (clic de stick)** : double-tap rapide sur un stick pour déclencher le clic du stick correspondant.
- **Haptique différenciée** : tap léger sur les boutons normaux, clic plus sec sur les gâchettes analogiques et les clics de stick, cran discret quand un stick atteint le bord de sa course.
