# Détails techniques

## Structure

- `ios/` : app SwiftUI native, générée avec [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`project.yml` et sources dans `ios/Gamepad/`).
- `server/` : serveur Python (`gamepad_server.py`) qui reçoit les entrées par WebSocket et crée une manette virtuelle via `evdev`/`uinput`.
- `server/screen_stream.py` : flux de l'écran du PC (voir « Flux de l'écran »), chargé seulement avec `--stream`.
- `nixos/` : module NixOS qui prépare l'environnement (uinput, pare-feu, dépendances Python, outils de capture), sans service systemd.

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

Avec `--diag`, le serveur écrit dans `gamepad-diag.log` (dossier courant, réécrit à chaque lancement, autre chemin avec `--diag-file`) chaque seconde où des messages arrivent une ligne :

```
diag: retard boucle moy 0.63 max 11.72 ms | 62 msg | écart max entre pings 151 ms | montée relative moy 0.4 max 2.1 ms | traitement max 0.03 ms | écho max 0.05 ms
```

- **retard boucle** : retard de la boucle asyncio du serveur par rapport à l'horloge. Un max élevé (plusieurs ms) indique que le processus n'a pas eu le CPU à temps.
- **écart max entre pings** : intervalle le plus long entre deux pings reçus de l'iPhone, envoyés toutes les 150 ms. Un écart bien au-dessus de 150 ms alors que le retard de boucle est faible indique un délai avant l'arrivée des données (envoi côté iPhone ou trajet réseau).
- **montée relative** : variation du délai iPhone vers PC seul. Le décalage constant entre les deux horloges est éliminé en retranchant le meilleur délai observé sur les 10 dernières secondes.
- **traitement max / écho max** : temps passé par le serveur à traiter un message et à renvoyer un ping.
- **machine bloquée cpu / mém / dsk** : millisecondes par seconde pendant lesquelles au moins une tâche de la machine attendait le processeur, la mémoire ou le disque (pression système du noyau, `/proc/pressure`). Si le retard de boucle monte en même temps qu'une de ces valeurs, la cause est la charge de la machine et non le réseau.
- **CPU serveur / préemptions** : part de processeur utilisée par le serveur et nombre de fois où le noyau l'a interrompu pour donner la place à un autre processus pendant la seconde.

## Robustesse

- **Deadman côté serveur** : sans message pendant 1,2 s, le serveur remet tous les boutons et axes au neutre. L'app envoie un ping toutes les 150 ms pour garder la connexion active.
- **Reconnexion côté app** : backoff exponentiel (0,5 s à 10 s) après une perte de connexion établie. Un échec de première connexion ne boucle pas.
- **Identité Xbox 360 émulée** : VID/PID `045e:028e`, reconnue nativement par Steam, Proton et SDL.
- **Handshake versionné** : le client annonce sa version de protocole et sa plateforme, le serveur répond avec les fonctionnalités supportées ou la raison du refus.
- **Multi-manettes** : jusqu'à 4 manettes virtuelles, une par appareil, chacune avec son propre device `uinput`.
- **Changement de réseau** : le serveur relève l'adresse IP de la route par défaut toutes les 1,5 s. Quand une nouvelle adresse est confirmée sur deux relevés, il arrête la capture, ferme tous les appareils de l'ancien réseau et se relance sur place (même processus, mêmes options) : nouvelle annonce mDNS, nouveau QR code, journal de `--diag` conservé. Le secret du flux d'écran est transmis au nouveau lancement par l'environnement du processus, sans être écrit sur disque, pour que l'app n'ait pas à rescanner le QR code. Pendant une perte totale de réseau le serveur attend, et se relance dès qu'une adresse réapparaît. Le WebSocket de contrôle ferme ses connexions en 1 s au plus.
- **Cycle de vie iOS** : écran toujours allumé pendant l'utilisation, gestes système différés sur les bords de l'écran.

## Flux de l'écran

Le fond de la manette peut afficher l'écran du PC en direct. La fonction est désactivée par défaut : elle n'existe que si le serveur est lancé avec `--stream`.

```fish
sudo gamepad-server server/gamepad_server.py --stream
```

Options : `--stream-port` (8766 par défaut), `--stream-encoder auto|vaapi|nvenc|x264`. Avec `--diag`, une ligne toutes les 5 s indique les images par seconde, le débit, l'écart maximal entre deux images, les abandons, le niveau de qualité, la chaîne de capture utilisée et le nombre d'images B, d'images répétées, d'images réellement envoyées à l'iPhone et d'images écartées parce que le client attend une image clé. À chaque démarrage de capture, une ligne décrit aussi le flux H.264 produit (profil, type de POC, codage CABAC ou CAVLC, images de référence). Le diagnostic `gamepad-server server/gamepad_server.py doctor --stream` liste les outils trouvés, la session graphique et les chaînes de capture possibles.

### Architecture

- **Canal séparé.** Un second WebSocket (port 8766) ne transporte que la vidéo. Les entrées, les pings et le deadman restent sur le port 8765 et ne partagent aucune file avec la vidéo.
- **Capture lancée en tant qu'utilisateur.** Le serveur tourne en root sous `sudo`, mais la capture dépend de la session de l'utilisateur. Il retrouve celui-ci par `SUDO_UID` (ou l'unique session `/run/user/<uid>`), puis lance l'outil de capture avec ce compte et l'environnement de sa session (`XDG_RUNTIME_DIR`, `WAYLAND_DISPLAY`, `HYPRLAND_INSTANCE_SIGNATURE`, `DISPLAY`). Lancé sans `sudo`, le serveur utilise sa propre session. Le processus de capture repasse en ordonnancement normal même si le serveur tourne en temps réel (`chrt -r`).
- **Outils et encodeurs.** Wayland : `wl-screenrec` (VAAPI) puis `wf-recorder` (VAAPI, NVENC ou x264). X11 : `ffmpeg` (`x11grab`). Choix automatique : NVENC si `/dev/nvidiactl` existe, sinon VAAPI si `/dev/dri/renderD128` existe, sinon x264. En mode `auto`, si une chaîne échoue trop vite, la suivante est essayée, avec x264 en dernier recours. La taille de l'écran est lue avec `hyprctl` ou `wlr-randr` quand elle est connue.
- **Aucun coût au repos.** La capture ne démarre que lorsqu'un appareil regarde le flux et s'arrête quand le dernier part.
- **Dépendances.** Aucune dépendance Python en plus. Les outils manquants ne bloquent pas le serveur : il démarre sans flux et indique ce qui manque. Le module NixOS installe `wl-screenrec`, `wf-recorder` et `ffmpeg` (option `programs.gamepadServer.screenStream`) et ouvre le port `streamPort`.

### Sécurité

- Le flux est désactivé sans `--stream`.
- À chaque lancement, le serveur génère un secret aléatoire placé dans le QR code d'appairage (`gamepad://ip:port?s=<secret>`). L'app l'envoie dans le premier message du canal vidéo ; sans le bon secret, aucune image n'est envoyée. Sans terminal ni module `qrcode`, l'adresse complète est écrite dans les journaux du serveur.
- Le secret est comparé en temps constant, et un refus attend une seconde avant de fermer. Il circule en clair sur le réseau local, comme le reste du protocole : n'active le flux que sur un réseau de confiance.
- Deux flux simultanés au maximum.

### Protocole

Capacité facultative annoncée dans le `hello_ack` du port 8765, seulement si la capture est possible :

```json
{"type":"hello_ack","ok":true,"features":["deadman","...","screen_stream"],"streamPort":8766,"streamCodec":"h264","streamProtocol":1}
```

Les anciennes versions de l'app ignorent ces champs, et une app récente face à un serveur sans flux n'affiche pas l'option.

Sur le port du flux, l'app ouvre un WebSocket et envoie en texte :

```json
{"type":"stream_hello","secret":"<secret du QR>","quality":"auto"}
```

`quality` vaut `auto`, `high`, `medium` ou `low` et peut être changé ensuite avec `{"type":"quality","quality":"low"}`. Le serveur répond `{"type":"stream_ack","ok":true,...}` ou `ok:false` avec une `reason`, puis envoie :

- des messages texte `{"type":"stream_status","state":"waiting|active|unavailable|idle","level":"medium","reason":"..."}` ;
- des messages binaires, un par image, dans un format prêt pour VideoToolbox (NAL en AVCC, préfixe de 4 octets) : 1 octet de drapeaux (bit 0 : image clé, bit 1 : paramètres présents), puis si le bit 1 est posé `u16 taille SPS`, SPS, `u16 taille PPS`, PPS, puis les NAL (`u32 taille`, données). Chaque image clé embarque ses paramètres, ce qui permet de démarrer ou reprendre sur n'importe laquelle.

### Latence et réseau

- Chaque appareil a une file de 40 images (environ 0,7 s à 60 images par seconde), qui absorbe les à-coups du réseau. Au-delà, la file est vidée et les images suivantes sont ignorées jusqu'à la prochaine image clé. L'encodeur compte ses images et non le temps : quand l'écran bouge peu, une image clé peut mettre plusieurs secondes à venir, d'où l'intérêt de ne pas déborder pour rien. Si un appareil attend une image clé depuis plus de 3 s, la capture est relancée (au plus une fois toutes les 15 s), ce qui en produit une tout de suite. Un client qui n'absorbe plus rien pendant 2 s est déconnecté du canal vidéo.
- Les tampons d'envoi de la socket vidéo sont réduits (16 Ko côté système, 8 Ko côté programme) : tout octet en attente dans un tampon est du retard que l'abandon d'images ne voit pas. Avec `--diag`, la ligne `diag flux` indique la file d'envoi maximale (octets non partis, programme et système) et la durée d'envoi maximale d'une image.
- L'image est affichée dès son arrivée (`DisplayImmediately`) et décodée par le matériel via `AVSampleBufferDisplayLayer`. Le flux H.264 n'indique pas où une image se termine : le serveur la ferme au début de la suivante, ou après 6 ms sans nouvelle donnée de la capture. Sans ce second cas, une capture qui n'encode que quand l'écran change (`wl-screenrec`) retenait chaque image jusqu'au changement suivant.

### Plancher de 30 images par seconde

Une capture n'émet rien quand l'écran ne change pas (`wl-screenrec` comme `wf-recorder`, quel que soit le compositeur). Pour que le flux ne passe jamais sous 30 images par seconde, le serveur intercale une image de répétition quand 28 ms se sont écoulées sans image réelle, à condition que tous les appareils aient vidé leur file et ne soient pas en attente d'une image clé (sinon la répétition ne ferait qu'alourdir un envoi déjà en retard). C'est une image P où tous les macroblocs sont `P_Skip` (copie exacte de l'image précédente, quelques dizaines d'octets) : elle est produite par `server/h264_repeat.py` à partir de l'en-tête SPS/PPS du flux, en CABAC comme en CAVLC. Le flux reste libre de monter à 60 images par seconde quand l'écran bouge, les images de répétition n'apparaissent que dans les trous.

Conditions : POC de type 2, une seule image de référence, une seule tranche par image, pas de prédiction pondérée ni d'entrelacement (c'est ce que produisent `wl-screenrec`, `wf-recorder` et `ffmpeg` avec les réglages du serveur). Sinon la fonction est désactivée et le serveur l'écrit dans son journal. Comme l'image de répétition est une image de référence, le numéro `frame_num` des images réelles suivantes est décalé du nombre d'images insérées depuis la dernière image clé. Avec `--diag`, la ligne `diag flux` indique le nombre d'images répétées.

### Latence du serveur et du ping

Mesures faites avec la chaîne complète (capture à 60 images par seconde, WebSocket réelle, 6 Mbit/s) : le retard de la boucle du serveur reste sous 10 ms (99 % sous 2 ms). Les pics de 100 à 300 ms vus dans `--diag` quand l'écran bouge viennent donc de la charge de la machine ou du réseau, pas du code. Le serveur agit sur ce qu'il contrôle :

- la boucle du serveur passe en ordonnancement temps réel (`SCHED_RR`, priorité 10, comme les threads de capture et d'envoi de Sunshine ou Steam) : elle reprend la main dès qu'un message arrive, même quand un jeu et l'encodeur saturent le processeur (le diagnostic `machine bloquée cpu` montrait jusqu'à 1100 ms/s d'attente). Garde-fous : les processus lancés par le serveur (capture, `iw`) redeviennent normaux, et une limite de 2 s de processeur sans pause fait arrêter le serveur au lieu de geler la machine. Sans `sudo`, le serveur retombe sur `nice -10` (et sur le groupe de session du noyau, sans quoi le `nice` ne compte que face aux processus du même terminal) ;
- le canal de contrôle (touches, pings) est marqué `DSCP EF` (priorité voix du Wi-Fi WMM), le flux vidéo reste en priorité normale ;
- la compression WebSocket est désactivée sur les deux canaux (elle coûtait environ 30 % de CPU sur de la vidéo déjà compressée) ;
- sur une liaison Wi-Fi, l'économie d'énergie de la carte (qui retient les paquets jusqu'à 100 ms) est coupée pendant la session avec `iw`, puis rétablie à l'arrêt ou au changement de réseau ; sans `sudo`, sans `iw` ou en Ethernet, rien n'est modifié ;
- une image qui attend plus de 0,25 s dans la file d'envoi compte comme un signe de réseau saturé pour l'adaptation automatique de la qualité ; au-delà de 0,5 s la file est vidée pour ne pas laisser le retard grandir. `--diag` affiche `attente max en file`.

### Qualité

| Niveau | Hauteur | Images/s | Débit visé |
|---|---|---|---|
| `high` | 720 | 60 | 6 Mbit/s |
| `medium` | 540 | 30 | 3 Mbit/s |
| `low` | 360 | 24 | 1,2 Mbit/s |

En `auto`, le flux démarre en `medium`. Deux abandons d'images en 6 s font baisser d'un niveau (la capture redémarre, une brève coupure) ; 45 s sans abandon font remonter d'un niveau. Un niveau choisi à la main n'est jamais modifié automatiquement ; si plusieurs appareils regardent, le niveau le plus bas demandé s'applique.

### Côté app

`ScreenStreamClient` gère le canal vidéo (connexion, reprise automatique toutes les 3 s, retour à « en attente » après 3 s sans image). Le réglage est dans Réglages > Fond > Écran du PC ; le fond précédent est conservé et réutilisé tant que le flux n'est pas actif. Le flux s'arrête quand l'app quitte l'avant-plan.
