<p align="center">
  <img src="docs/images/nerd_laptop.png" alt="Détente dans un hamac avec un ordinateur portable, pendant que les sauvegardes tournent" width="460">
</p>

<h1 align="center">btcpay-docker-lnd-manager</h1>

<p align="center">
  <b>Des sauvegardes sûres et automatiques du nœud Lightning de votre BTCPay Server, et les outils pour le récupérer.</b>
</p>

<p align="center">
  <a href="README.md">English</a> · <a href="README.es.md">Español</a> · <b>Français</b> · <a href="README.de.md">Deutsch</a>
</p>

---

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

La clé du serveur A peut seulement stocker, lister et récupérer des sauvegardes sur le serveur B, et lui transmettre ses réglages.
Elle ne peut ni s'y connecter ni y lancer quoi que ce soit d'autre : une intrusion sur le
serveur A ne peut donc pas supprimer ce que le serveur B conserve.

## Captures d'écran

Le tableau de bord des sauvegardes sur le serveur A, `lnd-manager` :

![lnd-manager](docs/images/dashboard.png)

Tapez `/` pour voir les commandes ; chacune explique ce qu'elle fait, et ce qu'elle arrête, avant de s'exécuter :

![La liste des commandes](docs/images/commands.png)


On choisit d'abord la langue :

![La question de la langue](docs/images/languages.png)

La liste des étapes montre ce qui est fait et ce qui reste à faire :

![La liste des étapes](docs/images/checklist.png)

Les outils du portefeuille :

![Les outils du portefeuille](docs/images/wallet.png)

Le tableau de bord du serveur B :

![Le tableau de bord du serveur B](docs/images/serverb-dashboard.png)

## Avant de commencer

- **Serveur A** : Ubuntu ou Debian, avec BTCPay installé de la manière habituelle
  (btcpayserver-docker) et Lightning (LND) configuré dans BTCPay. Il vous faut un compte avec sudo.
- **Un disque supplémentaire sur le serveur A** : un volume de stockage en bloc de votre
  hébergeur, ou un second disque. Pas le disque système. La configuration explique comment le
  préparer s'il est neuf.
- **Serveur B** : n'importe quel serveur Ubuntu ou Debian accessible par SSH.
- **Votre seed LND, notée par écrit.** Dans BTCPay : Server Settings → Services → LND Seed Backup.

## Installation sur le serveur A

1. Récupérez le projet sur le serveur A, dans votre dossier personnel :

   ```
   git clone https://github.com/juantrejo-coding/btcpay-docker-lnd-manager.git ~/btcpay-docker-lnd-manager
   ```

   Vérifiez ensuite sa signature (voir [Vérifier ce que vous téléchargez](#vérifier-ce-que-vous-téléchargez)) :
   ces scripts sont lancés en root.
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

      Ou, si vous clonez aussi le projet sur le serveur B : lancez `lnd-manager` → `/serverb send`,
      qui ne peut pas encore joindre le serveur B et affiche donc `serverb.conf` à la place. Sur le
      serveur B, dans le clone, lancez `sudo ./serverb-setup.sh --paste`, collez-le, et répondez
      `yes` à l'étape 1 seulement.

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
portefeuille actuel avant de modifier quoi que ce soit. Le serveur B garde jusqu'à 20 sauvegardes de
sécurité (50 Go) ; quand il est plein, supprimez-y les anciennes. Restaurer les canaux demande au pair de
chaque canal de fermer ce canal, et votre part revient on-chain.

## En option : une watchtower sur le serveur B

Une watchtower surveille vos canaux pendant que votre nœud est hors ligne.

1. Dans le tableau de bord : `/serverb send`. Cette commande envoie ses réglages au serveur B
   (`serverb.conf`) par la passerelle de sauvegarde, dans `~/serverb-setup` de l'utilisateur de
   sauvegarde. Rien n'y est lancé tout seul. Choisissez comment le serveur B obtient les scripts :
   1. **git clone (recommandé).** Seuls les réglages viennent du serveur A. Sur le serveur B, avec
      votre compte administrateur :

      ```
      git clone https://github.com/juantrejo-coding/btcpay-docker-lnd-manager.git
      cd btcpay-docker-lnd-manager
      ```

      Vérifiez la signature ([Vérifier ce que vous téléchargez](#vérifier-ce-que-vous-téléchargez)),
      puis :

      ```
      sudo ./serverb-setup.sh <backup user>
      ```

      Il lit `serverb.conf` comme de simples données (sans jamais le lancer), affiche chaque
      valeur et crée les scripts à partir du clone que vous avez vérifié. Root sur le serveur B ne
      lance alors que du code que vous avez vérifié, même si le serveur A a subi une intrusion.
   2. **Les scripts du serveur A.** Pour un serveur B qui ne peut pas joindre GitHub. Le serveur A
      envoie aussi `serverb-install.sh`, tous les scripts dans un seul fichier. Sur le serveur B,
      copiez-le d'abord hors du dossier de l'utilisateur de sauvegarde (root ne le lancera pas
      depuis là), et comparez son sha256 avec celui qu'a affiché `/serverb send` :

      ```
      sudo -u <backup user> cat ~<backup user>/serverb-setup/serverb-install.sh > serverb-install.sh
      sha256sum serverb-install.sh
      sudo bash serverb-install.sh
      ```

      C'est aussi sûr que de copier les scripts vous-même, et pas plus : root sur le serveur B
      lance ce que le serveur A a créé. Si le serveur A a subi une intrusion, le sha256 qu'il
      affiche peut lui aussi être falsifié.

   Dans les deux cas, le script suit les étapes dans l'ordre et demande avant chacune :
   l'utilisateur de sauvegarde et la passerelle, Bitcoin Core, l'import de la blockchain, la
   watchtower, le tableau de bord. Les scripts lancés restent dans
   `/var/lib/serverb-setup/scripts`. Une passerelle de sauvegarde plus ancienne que
   `/serverb send` refuse les réglages : utilisez alors la façon 1 avec `--paste` (elle affiche
   les réglages à coller), et l'étape 1 met la passerelle à jour.
2. Pour épargner au serveur B des jours de synchronisation, copiez-y la blockchain depuis le
   serveur A : `/chain copy` (d'abord `/chain prune`, si la blockchain de BTCPay n'est pas encore
   élaguée). Elle demande où la blockchain est élaguée à la taille du serveur B : sur le serveur A,
   dans une copie à côté de celle de BTCPay (la blockchain de BTCPay ne change pas, et environ moitié
   moins est envoyé : le chainstate, quelque 12 Go, ne peut pas être élagué), ou sur le serveur B
   après l'import. Elle vérifie d'abord que les deux serveurs ont la place. Les étapes s'arrêtent après Bitcoin Core tant que la copie n'est pas terminée ;
   relancez ensuite la même commande sur le serveur B pour continuer.
3. De retour sur le serveur A : `/tower add`, avec l'adresse de la watchtower affichée par
   l'étape de la watchtower.

`/serverb scripts` crée toujours les scripts un par un, pour que vous les copiiez vous-même sur
le serveur B.

Sur le serveur B, connectez-vous avec le compte administrateur du tableau de bord et lancez
`serverb-dashboard`. Il a sa propre `/checklist`, et signale la sortie d'une nouvelle version
de Bitcoin Core, de LND ou de ces scripts (voir [Mettre à jour](#mettre-à-jour)).

## À conserver en lieu sûr, hors ligne

- **Votre seed LND.** Elle permet de récupérer vos fonds.
- **La clé privée GPG.** Elle ouvre les sauvegardes.

## Vérifier ce que vous téléchargez

Chaque commit et chaque tag de version est signé avec cette clé GPG :

```
Juan Trejo <juantrejo_coding@proton.me>
93F4 433D CE56 353B D7E6  9D42 CBFE 4123 CF41 21FA
```

Une empreinte affichée à côté du code ne prouve rien à elle seule : quiconque pourrait modifier
le code pourrait aussi modifier cette page. Récupérez donc la clé à deux endroits et vérifiez que
les deux affichent l'empreinte ci-dessus :

```
curl -fsSL https://github.com/juantrejo-coding.gpg | gpg --show-keys
gpg --keyserver hkps://keys.openpgp.org --recv-keys 93F4433DCE56353BD7E69D42CBFE4123CF4121FA
gpg --fingerprint 93F4433DCE56353BD7E69D42CBFE4123CF4121FA
```

Ensuite, dans le clone :

```
git tag -l                           # the releases
git verify-tag <newest tag>          # "Good signature from Juan Trejo", with the fingerprint above
git checkout <newest tag>
git log --show-signature -3          # each commit: "Good signature", the same fingerprint
```

S'il n'y a pas encore de tag de version, vérifiez plutôt le commit le plus récent :
`git verify-commit HEAD`. gpg peut ajouter "This key is not certified with a trusted signature"
(cette clé n'est pas certifiée par une signature de confiance) : c'est normal pour une clé que
vous n'avez pas signée vous-même. Ce qui compte, c'est "Good signature" (signature valide) et
l'empreinte. Dans tout autre cas (une signature BAD, une autre empreinte, aucune signature) : ne
le lancez pas.

Vous ne faites cela à la main que la première fois. Ensuite, les commandes de mise à jour
ci-dessous vérifient chaque nouvelle version de la même façon, avec la clé installée avec les
scripts.

## Mettre à jour

Rien ne se met à jour tout seul. Les deux tableaux de bord signalent la sortie d'une nouvelle
version ; vous lancez la mise à jour et tapez `UPDATE`. Chaque mise à jour télécharge d'abord la
version et vérifie sa signature, puis ne l'installe que lorsque cela peut se faire sans risque.
Sinon, elle attend en arrière-plan et vérifie toutes les 5 minutes, pendant 24 heures au plus ;
passé ce délai, la mise à jour est installée au démarrage suivant, avant que les services qu'elle
concerne ne démarrent. Le tableau de bord affiche une mise à jour en attente.

**Serveur A** (`/update` dans `lnd-manager`, ou `sudo lnd-update`) : ces scripts, à partir du tag
de version signé le plus récent. Sans risque veut dire ici qu'aucune sauvegarde, aucune opération
sur le portefeuille et aucune opération `/chain` ou `/tower` n'est en cours. Le service de
sauvegarde est réinstallé ; LND et BTCPay continuent de tourner (BTCPay les met à jour lui-même,
avec `btcpay-update.sh`). Votre dossier de travail passe à la même version, et votre `config` est
conservé. Si vous y avez modifié d'autres fichiers, il est laissé tel quel et la mise à jour le
signale ; `install-scripts.sh` refuse alors de remettre l'ancienne version.

**Serveur B** (`serverb-dashboard`) :
- `/update scripts` : ces scripts, à partir de la version signée la plus récente, créés avec les
  réglages enregistrés par `serverb-setup.sh`. La passerelle de sauvegarde et le tableau de bord
  sont mis à jour ; bitcoind et la watchtower continuent de tourner. Il faut un serveur B qui peut
  joindre GitHub (la façon 1 ci-dessus) ; sinon, utilisez de nouveau `/serverb send`.
- `/update bitcoind` et `/update tower` : la version la plus récente de Bitcoin Core ou de LND,
  vérifiée de la même façon que lors de la configuration. La mise à jour redémarre la watchtower,
  elle n'a donc lieu que lorsque le nœud du serveur A peut surveiller lui-même ses canaux : le
  serveur A envoie son état toutes les 5 minutes par la passerelle (uniquement des données), et la
  mise à jour attend que cet état date de moins de 10 minutes, que LND y tourne, qu'aucun paiement
  ne soit en cours et qu'aucun canal ne soit en cours d'ouverture ou de fermeture. Un serveur A
  éteint compte comme un cas à risque : c'est justement là que la watchtower est nécessaire.

Plus tard, ces scripts pourront aussi être fournis sous forme de paquet depuis un dépôt APT ; les
mêmes commandes utiliseront alors apt, qui vérifie la signature du paquet.

## Modifier les réglages

Modifiez `config` dans votre dossier de travail, puis lancez-y `sudo ./install-scripts.sh`. Les
scripts qui tournent en root n'utilisent que les copies qu'il installe dans
`/usr/local/lib/btcpay-docker-lnd-manager`, pour que personne d'autre ne puisse les modifier.
Après avoir modifié des réglages qu'utilise le service de sauvegarde, lancez aussi `/install`
dans le tableau de bord.

La langue est `UI_LANGUAGE` dans `config` : `en` (anglais), ou le code de n'importe quelle
traduction présente dans `locale/` (`fr` pour le français).

## Soutien

S'il protège votre nœud, merci de soutenir son développement. Bitcoin :

```
bc1qevxw36e4htzvlke3y0kqqz3qs0nfmreqhxkt73
```

C'est aussi l'adresse de don à laquelle vont les paiements prévus par la licence (voir [LICENSE](LICENSE), section 5).

## Licence

Voir `LICENSE`, ou `/support` dans le tableau de bord.
