# btcpay-docker-lnd-manager

[English](README.md) · [Español](README.es.md) · **Français** · [Deutsch](README.de.md)

Des sauvegardes pour le nœud Lightning (LND) d'un BTCPay Server installé avec
btcpayserver-docker, des outils pour restaurer le portefeuille et, en option, une watchtower sur un
second serveur.

## Fonctionnement

Il y a trois éléments :

- **Serveur A** : votre serveur BTCPay, où tourne LND.
- **Le volume attaché** : un disque supplémentaire sur le serveur A, réservé aux sauvegardes.
- **Serveur B** : un second serveur, situé ailleurs.

Un service de sauvegarde sur le serveur A surveille la sauvegarde des canaux de LND. Après chaque
changement, il en fait une copie chiffrée et signée avec votre clé GPG. Une copie va sur le volume
attaché et une autre sur le serveur B.

La clé du serveur A peut seulement stocker, lister et récupérer des sauvegardes sur le serveur B.
Elle ne peut ni s'y connecter ni y lancer quoi que ce soit d'autre : une intrusion sur le
serveur A ne peut donc pas supprimer ce que le serveur B conserve.

## Captures d'écran

Le tableau de bord des sauvegardes sur le serveur A, `lnd-manager` :

![lnd-manager](docs/images/dashboard.svg)

Tapez `/` pour voir les commandes ; chacune explique ce qu'elle fait, et ce qu'elle arrête, avant de s'exécuter :

![La liste des commandes](docs/images/commands.svg)

| | |
|---|---|
| ![La question de la langue](docs/images/languages.svg) | ![La liste des étapes](docs/images/checklist.svg) |
| ![Les outils du portefeuille](docs/images/wallet.svg) | ![Le tableau de bord du serveur B](docs/images/serverb-dashboard.svg) |

## Avant de commencer

- **Serveur A** : Ubuntu ou Debian, avec BTCPay installé de la manière habituelle
  (btcpayserver-docker) et Lightning (LND) configuré dans BTCPay. Il vous faut un compte avec sudo.
- **Un disque supplémentaire sur le serveur A** : un volume de stockage en bloc de votre
  hébergeur, ou un second disque. Pas le disque système. La configuration explique comment le
  préparer s'il est neuf.
- **Serveur B** : n'importe quel serveur Ubuntu ou Debian accessible par SSH.
- **Votre seed LND, notée par écrit.** Dans BTCPay : Server Settings → Services → LND Seed Backup.

## Installation sur le serveur A

1. Copiez ce dossier sur le serveur A, dans votre dossier personnel : `~/btcpay-docker-lnd-manager`.
2. Vérifiez que tout est prêt. Cette étape ne modifie rien :

   ```
   cd ~/btcpay-docker-lnd-manager
   ./setup_script.sh --check
   ```

   Les lignes ❌ indiquent ce qu'il faut corriger d'abord. Les lignes ⚠️ sont des points que la
   configuration prend en charge, ou qui peuvent attendre.
3. Lancez la configuration avec votre propre compte (pas avec sudo) :

   ```
   ./setup_script.sh
   ```

   Elle demande d'abord la langue : choisissez Français. Elle refait ensuite la même
   vérification, pose une question à la fois et enregistre vos réponses dans `config`. Elle
   couvre :
   - **L'utilisateur de sauvegarde**, un compte distinct qui effectue le travail de sauvegarde. La
     configuration le crée.
   - **Le volume attaché**. Choisissez le disque dans la liste ; la configuration le monte de
     façon sûre.
   - **Le serveur B** : son adresse, son port SSH et l'utilisateur qui conservera les sauvegardes.
     La configuration affiche ensuite l'empreinte du serveur B. **Vérifiez-la sur le serveur B
     lui-même** (la configuration affiche la commande), pour être sûr de parler au bon serveur.
   - **La clé SSH** que le serveur A utilise pour joindre le serveur B. La configuration la crée.
   - **La clé GPG** qui chiffre les sauvegardes. Collez une clé que vous avez déjà, ou laissez la
     configuration en créer une. **Conservez la clé privée en lieu sûr, hors de ce serveur : sans
     elle, personne ne peut ouvrir les sauvegardes.**
   - La confirmation que votre seed LND est notée par écrit.
   - **Le service de sauvegarde**, la dernière question. Répondez `y`.

   Les mots à taper pour confirmer (comme `yes`, `STOP BTCPAY` ou `I WROTE IT DOWN`) sont les
   mêmes dans toutes les langues : tapez-les exactement tels qu'ils s'affichent.
4. Installez la clé du serveur A sur le serveur B. La configuration propose deux façons de faire :
   1. L'utilisateur du serveur B existe et vous connaissez son mot de passe : la configuration
      copie la clé elle-même.
   2. Sinon, la configuration crée `serverb-user-setup.sh`. Copiez-le vous-même sur le serveur B
      et lancez-le là-bas avec `sudo bash serverb-user-setup.sh`, puis relancez
      `./setup_script.sh` sur le serveur A.

   Dans les deux cas, la configuration restreint ensuite la clé pour qu'elle n'accède qu'aux
   sauvegardes (« la passerelle »).
5. Ouvrez le tableau de bord :

   ```
   lnd-manager
   ```

   Tant que tout n'est pas configuré, la ligne du haut indique la prochaine chose à faire. Tapez
   `/checklist` pour voir toutes les étapes.

## Utilisation au quotidien

`lnd-manager` indique si le service tourne, quand la dernière sauvegarde est arrivée à chaque
endroit, et les éventuels problèmes. Tapez `/` pour la liste des commandes. Chacune explique ce
qu'elle fait avant de s'exécuter.

Les sauvegardes ne sont faites que lorsque la sauvegarde des canaux de LND change (par exemple
quand un canal s'ouvre ou se ferme). Sur un nœud calme, il est normal de passer des jours sans
nouvelle sauvegarde.

## Si vous perdez le portefeuille

```
sudo lnd-wallet restore      # les fonds on-chain, depuis la seed
sudo lnd-wallet channels     # les fonds et les canaux
```

Ou utilisez `/wallet` dans le tableau de bord. Le script trouve la sauvegarde valide la plus
récente sur le volume attaché ou sur le serveur B, et conserve une sauvegarde de sécurité du
portefeuille actuel avant de modifier quoi que ce soit. Restaurer les canaux demande au pair de
chaque canal de fermer ce canal, et votre part revient on-chain.

## En option : une watchtower sur le serveur B

Une watchtower surveille vos canaux pendant que votre nœud est hors ligne.

1. Dans le tableau de bord : `/serverb scripts`. Cette commande crée les scripts du serveur B et
   liste les étapes dans l'ordre.
2. Copiez vous-même les scripts sur le serveur B, depuis un ordinateur de confiance, et lancez-les
   là-bas avec `sudo bash` : d'abord Bitcoin Core, puis la watchtower, puis le tableau de bord du
   serveur B.
3. Pour épargner au serveur B des jours de synchronisation, copiez-y la blockchain depuis le
   serveur A : `/chain copy` (d'abord `/chain prune`, si la blockchain de BTCPay n'est pas encore
   élaguée), puis `serverb-import-chain.sh` sur le serveur B.
4. De retour sur le serveur A : `/tower add`.

Sur le serveur B, connectez-vous avec le compte administrateur du tableau de bord et lancez
`serverb-dashboard`. Il a sa propre `/checklist`. Il signale aussi la sortie d'une nouvelle
version de Bitcoin Core ou de LND : `/update bitcoind` ou `/update tower` l'installe, après avoir
vérifié ses signatures de la même façon que la configuration. Rien ne se met à jour tout seul.

## À conserver en lieu sûr, hors ligne

- **Votre seed LND.** Elle permet de récupérer vos fonds.
- **La clé privée GPG.** Elle ouvre les sauvegardes.

## Modifier les réglages ou mettre à jour

Modifiez `config` dans votre dossier de travail, puis lancez-y `sudo ./install-scripts.sh`. Les
scripts qui tournent en root n'utilisent que les copies qu'il installe dans
`/usr/local/lib/btcpay-docker-lnd-manager`, pour que personne d'autre ne puisse les modifier.
Après une mise à jour des scripts, lancez aussi `/install` dans le tableau de bord pour mettre à
jour le service de sauvegarde.

La langue est `UI_LANGUAGE` dans `config` : `en` (anglais), ou le code de n'importe quelle
traduction présente dans `locale/` (`fr` pour le français).

## Licence

Voir `LICENSE`, ou `/support` dans le tableau de bord.
