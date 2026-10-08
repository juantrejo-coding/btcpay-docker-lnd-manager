# btcpay-docker-lnd-manager

[English](README.md) · [Español](README.es.md) · [Français](README.fr.md) · **Deutsch**

Backups für den Lightning-Node (LND) eines mit btcpayserver-docker installierten BTCPay Server,
dazu Werkzeuge zum Wiederherstellen der Wallet und, wenn Sie möchten, ein Watchtower auf einem
zweiten Server.

## So funktioniert es

Es gibt drei Teile:

- **Server A**: Ihr BTCPay-Server, auf dem LND läuft.
- **Das angehängte Volume**: eine zusätzliche Festplatte an Server A, nur für Backups.
- **Server B**: ein zweiter Server an einem anderen Ort.

Ein Backup-Dienst auf Server A überwacht das Kanal-Backup von LND. Nach jeder Änderung erstellt er
eine verschlüsselte, mit Ihrem GPG-Schlüssel signierte Kopie. Eine Kopie geht auf das angehängte
Volume, eine auf Server B.

Der Schlüssel von Server A kann auf Server B nur Backups ablegen, auflisten und abrufen. Er kann
sich dort nicht anmelden und nichts anderes ausführen, daher kann ein Einbruch auf Server A nicht
löschen, was Server B aufbewahrt.

## Bildschirmfotos

Das Backup-Dashboard auf Server A, `lnd-manager`:

![lnd-manager](docs/images/dashboard.svg)

Tippen Sie `/` für die Befehle; jeder erklärt, was er tut und was er stoppt, bevor er läuft:

![Die Befehlsliste](docs/images/commands.svg)

| | |
|---|---|
| ![Die Sprachfrage](docs/images/languages.svg) | ![Die Checkliste](docs/images/checklist.svg) |
| ![Die Wallet-Werkzeuge](docs/images/wallet.svg) | ![Das Dashboard auf Server B](docs/images/serverb-dashboard.svg) |

## Bevor Sie beginnen

- **Server A**: Ubuntu oder Debian, mit BTCPay auf dem üblichen Weg installiert (btcpayserver-docker)
  und Lightning (LND) in BTCPay eingerichtet. Sie brauchen ein Konto mit sudo.
- **Eine zusätzliche Festplatte an Server A**: ein Block-Volume Ihres Anbieters oder eine zweite
  Festplatte. Nicht die Systemfestplatte. Das Setup zeigt, wie Sie sie vorbereiten, wenn sie neu ist.
- **Server B**: ein beliebiger Ubuntu- oder Debian-Server, den Sie per SSH erreichen.
- **Ihr LND-Seed, aufgeschrieben.** In BTCPay: Server Settings → Services → LND Seed Backup.

## Installation auf Server A

1. Kopieren Sie diesen Ordner auf Server A, in Ihren Home-Ordner: `~/btcpay-docker-lnd-manager`.
2. Prüfen Sie, ob alles bereit ist. Dabei wird nichts geändert:

   ```
   cd ~/btcpay-docker-lnd-manager
   ./setup_script.sh --check
   ```

   Zeilen mit ❌ sagen, was Sie zuerst beheben müssen. Zeilen mit ⚠️ sind Dinge, die das Setup
   erledigt oder die warten können.
3. Starten Sie das Setup als Sie selbst (nicht mit sudo):

   ```
   ./setup_script.sh
   ```

   Es fragt zuerst nach der Sprache: Wählen Sie Deutsch. Dann führt es dieselbe Prüfung aus,
   fragt eine Sache nach der anderen und speichert Ihre Antworten in `config`. Es umfasst:
   - **Den Backup-Benutzer**, ein eigenes Konto, das die Backup-Arbeit erledigt. Das Setup legt
     es an.
   - **Das angehängte Volume**. Wählen Sie die Festplatte aus der Liste; das Setup hängt sie
     sicher ein.
   - **Server B**: seine Adresse, sein SSH-Port und der Benutzer, der die Backups aufbewahrt.
     Danach zeigt das Setup den Fingerabdruck von Server B. **Prüfen Sie ihn auf Server B selbst**
     (das Setup zeigt den Befehl), damit Sie wissen, dass Sie mit dem richtigen Server verbunden
     sind.
   - **Den SSH-Schlüssel**, mit dem Server A Server B erreicht. Das Setup erstellt ihn.
   - **Den GPG-Schlüssel**, der die Backups verschlüsselt. Fügen Sie einen vorhandenen ein, oder
     lassen Sie das Setup einen erstellen. **Bewahren Sie den privaten Schlüssel an einem sicheren
     Ort auf, getrennt von diesem Server: Ohne ihn kann niemand die Backups öffnen.**
   - Die Bestätigung, dass Ihr LND-Seed aufgeschrieben ist.
   - **Den Backup-Dienst**, die letzte Frage. Antworten Sie `y`.

   Die Wörter, die Sie zur Bestätigung eingeben (etwa `yes`, `STOP BTCPAY` oder
   `I WROTE IT DOWN`), sind in allen Sprachen gleich: Geben Sie sie genau so ein, wie sie
   angezeigt werden.
4. Bringen Sie den Schlüssel von Server A auf Server B. Das Setup bietet zwei Wege:
   1. Der Benutzer auf Server B existiert und Sie kennen sein Passwort: Das Setup kopiert den
      Schlüssel selbst.
   2. Andernfalls erstellt das Setup `serverb-user-setup.sh`. Kopieren Sie es selbst auf Server B,
      führen Sie es dort mit `sudo bash serverb-user-setup.sh` aus und starten Sie danach
      `./setup_script.sh` auf Server A erneut.

   In beiden Fällen beschränkt das Setup den Schlüssel danach so, dass er nur die Backups erreicht
   („das Gate“).
5. Öffnen Sie das Dashboard:

   ```
   lnd-manager
   ```

   Solange nicht alles eingerichtet ist, sagt die oberste Zeile, was als Nächstes zu tun ist.
   Geben Sie `/checklist` ein, um alle Schritte zu sehen.

## Im Alltag

`lnd-manager` zeigt, ob der Dienst läuft, wann das letzte Backup an jedem Ort angekommen ist, und
etwaige Probleme. Geben Sie `/` ein, um die Liste der Befehle zu sehen. Jeder Befehl erklärt, was
er tut, bevor er ausgeführt wird.

Backups werden nur erstellt, wenn sich das Kanal-Backup von LND ändert (zum Beispiel, wenn ein
Kanal geöffnet oder geschlossen wird). Tage ohne neues Backup sind bei einem ruhigen Node normal.

## Wenn Sie die Wallet verlieren

```
sudo lnd-wallet restore      # das On-Chain-Guthaben, aus dem Seed
sudo lnd-wallet channels     # das Guthaben und die Kanäle
```

Oder verwenden Sie `/wallet` im Dashboard. Das Skript sucht das neueste gültige Backup auf dem
angehängten Volume oder auf Server B und legt eine Sicherheitskopie der aktuellen Wallet an, bevor
es etwas ändert. Beim Wiederherstellen der Kanäle wird jeder Peer gebeten, seinen Kanal zu
schließen, und Ihr Anteil kommt on-chain zurück.

## Optional: ein Watchtower auf Server B

Ein Watchtower behält Ihre Kanäle im Auge, während Ihr Node offline ist.

1. Im Dashboard: `/serverb scripts`. Es erstellt die Skripte für Server B und listet die Schritte
   der Reihe nach auf.
2. Kopieren Sie die Skripte selbst auf Server B, von einem Computer, dem Sie vertrauen, und führen
   Sie sie dort mit `sudo bash` aus: zuerst Bitcoin Core, dann den Watchtower, dann das Dashboard
   von Server B.
3. Um Server B tagelanges Synchronisieren zu ersparen, kopieren Sie die Blockchain von Server A:
   `/chain copy` (vorher `/chain prune`, falls die Blockchain von BTCPay noch nicht gepruned ist),
   danach `serverb-import-chain.sh` auf Server B.
4. Wieder auf Server A: `/tower add`.

Melden Sie sich auf Server B mit dem Admin-Konto des Dashboards an und starten Sie
`serverb-dashboard`. Es hat eine eigene `/checklist`. Es meldet auch, wenn eine neue Version von
Bitcoin Core oder LND erschienen ist: `/update bitcoind` oder `/update tower` installiert sie,
nachdem die Signaturen auf dieselbe Weise geprüft wurden wie im Setup. Nichts wird von selbst
aktualisiert.

## Sicher und offline aufbewahren

- **Ihren LND-Seed.** Er bringt Ihr Guthaben zurück.
- **Den privaten GPG-Schlüssel.** Er öffnet die Backups.

## Einstellungen ändern oder aktualisieren

Bearbeiten Sie `config` in Ihrem Arbeitsordner und führen Sie dann dort `sudo ./install-scripts.sh`
aus. Die Skripte, die als root laufen, verwenden nur die Kopien, die es in
`/usr/local/lib/btcpay-docker-lnd-manager` installiert, sodass niemand sonst sie ändern kann. Führen
Sie nach dem Aktualisieren der Skripte auch `/install` im Dashboard aus, um den Backup-Dienst zu
aktualisieren.

Die Sprache ist `UI_LANGUAGE` in `config`: `en` (Englisch) oder der Code einer beliebigen
Übersetzung in `locale/` (`de` für Deutsch).

## Lizenz

Siehe `LICENSE` oder `/support` im Dashboard.
