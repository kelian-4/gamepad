# Détails techniques

## Structure

- `ios/` : app SwiftUI native, générée avec [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`project.yml` et sources dans `ios/Gamepad/`).
- `server/` : serveur Python (`gamepad_server.py`) qui reçoit les entrées par WebSocket et crée une manette virtuelle via `evdev`/`uinput`.
- `nixos/` : module NixOS qui prépare l'environnement (uinput, pare-feu, dépendances Python), sans service systemd.

## CI

`.github/workflows/ios-build.yml` build l'app sur un runner `macos-latest` : XcodeGen génère le `.xcodeproj`, `xcodebuild archive` compile sans signature, puis le `.app` est empaqueté en `.ipa` non signé. Le fichier est publié comme artifact du run, et dans une release GitHub à chaque build sur `main`.

## Serveur

Dépendances : `server/requirements.txt` (`websockets`, `evdev`, `zeroconf`, `qrcode` optionnel).

Diagnostic de l'environnement :

```fish
gamepad-server server/gamepad_server.py doctor
```

Il vérifie `/dev/uinput`, les permissions, la disponibilité de `zeroconf` et affiche l'IP locale.

### Diagnostic de latence (`--diag`)

Avec `--diag`, le serveur affiche chaque seconde où des messages arrivent une ligne :

```
diag: retard boucle moy 0.63 max 11.72 ms | 62 msg | écart max entre pings 151 ms | montée relative moy 0.4 max 2.1 ms | traitement max 0.03 ms | écho max 0.05 ms
```

- **retard boucle** : retard de la boucle asyncio du serveur par rapport à l'horloge. Un max élevé (plusieurs ms) indique que le processus n'a pas eu le CPU à temps.
- **écart max entre pings** : intervalle le plus long entre deux pings reçus de l'iPhone, envoyés toutes les 150 ms. Un écart bien au-dessus de 150 ms alors que le retard de boucle est faible indique un délai avant l'arrivée des données (envoi côté iPhone ou trajet réseau).
- **montée relative** : variation du délai iPhone vers PC seul. Le décalage constant entre les deux horloges est éliminé en retranchant le meilleur délai observé sur les 10 dernières secondes.
- **traitement max / écho max** : temps passé par le serveur à traiter un message et à renvoyer un ping.

## Robustesse

- **Deadman côté serveur** : sans message pendant 1,2 s, le serveur remet tous les boutons et axes au neutre. L'app envoie un ping toutes les 150 ms pour garder la connexion active.
- **Reconnexion côté app** : backoff exponentiel (0,5 s à 10 s) après une perte de connexion établie. Un échec de première connexion ne boucle pas.
- **Identité Xbox 360 émulée** : VID/PID `045e:028e`, reconnue nativement par Steam, Proton et SDL.
- **Handshake versionné** : le client annonce sa version de protocole et sa plateforme, le serveur répond avec les fonctionnalités supportées ou la raison du refus.
- **Multi-manettes** : jusqu'à 4 manettes virtuelles, une par appareil, chacune avec son propre device `uinput`.
- **Cycle de vie iOS** : écran toujours allumé pendant l'utilisation, gestes système différés sur les bords de l'écran.
