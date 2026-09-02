# HyperVReplicaHealth-PRTG

Überwachung der **Hyper-V-Replikation** mit PRTG – als *Push*-Sensor.

Das Skript [`Push-HyperVReplicaHealth.ps1`](Push-HyperVReplicaHealth.ps1) läuft als geplante
Aufgabe auf dem Hyper-V-Host, liest den Replikationszustand aller VMs über CIM/WMI aus und
schickt das Ergebnis als PRTG-XML an einen Sensor vom Typ **HTTP Push Data Advanced**.

Vorteile gegenüber einem klassischen Pull-Sensor (EXE/Script Advanced):

* Die Probe braucht **keinen** Remote-Zugriff (kein WinRM/DCOM) auf den Hyper-V-Host.
* Funktioniert über Firewall-/NAT-Grenzen hinweg, solange der Host die Probe erreicht.
* Kein Hyper-V-PowerShell-Modul nötig – nur `root\virtualization\v2` (CIM/WMI).

---

## Inhalt

| Datei | Zweck |
|---|---|
| `Push-HyperVReplicaHealth.ps1` | Das Sensor-Skript (Push-Variante) |
| `README.md` | Diese Anleitung |
| `LICENSE` | MIT-Lizenz |

---

## Voraussetzungen

* **Windows Server 2012 R2 oder neuer** mit Hyper-V-Rolle
  (die Klasse `Msvm_ReplicationRelationship` existiert erst ab 2012 R2).
* **PowerShell 3.0 oder neuer** (`#Requires -Version 3.0`).
* Konto mit lokalen Administratorrechten bzw. Leserechten auf
  `root\virtualization\v2` – z. B. `SYSTEM` oder ein Mitglied von
  *Hyper-V Administrators*.
* Netzwerkzugriff vom Hyper-V-Host zur PRTG-Probe auf **TCP 5050** (HTTP)
  bzw. **5051** (HTTPS).
* Auf mindestens einer VM muss die Hyper-V-Replikation aktiviert sein –
  sonst meldet der Sensor bewusst einen Fehler.

---

## 1. Sensor in PRTG anlegen

1. Gerät auswählen (sinnvollerweise das Gerät, das den Hyper-V-Host repräsentiert)
   → **Sensor hinzufügen** → **HTTP Push Data Advanced**.
2. Einstellungen setzen:

   | Feld | Wert |
   |---|---|
   | **Port** | `5050` (Standard; `5051` bei HTTPS) |
   | **Identification Token** | frei wählbar, z. B. `hvrepl-host01` – wird gleich als `-Token` gebraucht |
   | **Request Method** | `ANY` (oder passend zu `-Method`: `GET` bzw. `POST`) |
   | **No Incoming Data** | *Switch to down status after x minutes* |
   | **Zeitspanne** | größer als das **doppelte** Aufrufintervall der geplanten Aufgabe |
   | **Scanning Interval** | egal – der Sensor wartet nur auf Daten |

   > **Beispiel:** Aufgabe alle 5 Minuten → „No Incoming Data" auf ≥ 15 Minuten.
   > So wird der Sensor rot, wenn der Host nicht mehr pusht, aber nicht bei einem
   > einzelnen verpassten Lauf.

3. Nach dem ersten erfolgreichen Push legt PRTG die Kanäle automatisch an.
   Erst danach lassen sich Limits im Sensor nachjustieren.

> **Hinweis:** Der Port des Push-Sensors muss auf der Probe erreichbar sein.
> Die Windows-Firewall der Probe öffnet ihn beim Anlegen des Sensors in der Regel
> selbst; bei Firewalls dazwischen muss die Freigabe manuell erfolgen.

---

## 2. Skript auf dem Hyper-V-Host ablegen

Beliebiger Pfad, z. B.:

```
C:\Scripts\Push-HyperVReplicaHealth.ps1
```

Die Datei sollte nur für Administratoren beschreibbar sein – sie läuft mit hohen Rechten.

Wenn die Datei aus dem Internet stammt, ggf. die Zone-Markierung entfernen:

```powershell
Unblock-File -Path C:\Scripts\Push-HyperVReplicaHealth.ps1
```

---

## 3. Trockenlauf (ohne Senden)

Zuerst prüfen, ob die Datenermittlung funktioniert. `-ShowXml` gibt nur das XML aus
und sendet nichts – `-ProbeHost` und `-Token` sind trotzdem Pflicht, Dummy-Werte genügen:

```powershell
.\Push-HyperVReplicaHealth.ps1 -ProbeHost dummy -Token dummy -ShowXml
```

Erwartete Ausgabe: eine XML-Zeile mit `<prtg>…</prtg>` plus eine Info-Zeile mit der
Länge der (potenziellen) GET-URL.

Danach ein echter Push zum Test:

```powershell
.\Push-HyperVReplicaHealth.ps1 -ProbeHost 10.0.0.5 -Token "hvrepl-host01"
```

Ausgabe bei Erfolg:

```
2026-09-02 10:15:00 Push OK (HTTP 200 (Versuch 1)) - 4 Replikation(en) OK, aelteste vor 6 min
```

---

## 4. Geplante Aufgabe einrichten

### Variante A: per PowerShell (empfohlen)

Als Administrator auf dem Hyper-V-Host ausführen – Werte anpassen:

```powershell
$script  = 'C:\Scripts\Push-HyperVReplicaHealth.ps1'
$probe   = '10.0.0.5'
$token   = 'hvrepl-host01'

$argList = '-NoProfile -ExecutionPolicy Bypass -File "{0}" ' -f $script
$argList += '-ProbeHost {0} -Token "{1}" ' -f $probe, $token
$argList += '-WarnAgeMinutes 30 -ErrorAgeMinutes 60 '
$argList += '-LogFile "C:\Scripts\hvrepl-push.log"'

$action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argList
$trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date) `
                -RepetitionInterval (New-TimeSpan -Minutes 5)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount `
                -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
                -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
                -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName 'PRTG Hyper-V Replica Push' `
    -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
    -Description 'Pusht den Hyper-V-Replikationszustand an PRTG'
```

Testlauf und Ergebnis prüfen:

```powershell
Start-ScheduledTask -TaskName 'PRTG Hyper-V Replica Push'
Get-ScheduledTaskInfo -TaskName 'PRTG Hyper-V Replica Push' |
    Select-Object LastRunTime, LastTaskResult
```

`LastTaskResult` = `0` → Push erfolgreich, `1` → Push fehlgeschlagen (siehe Logdatei).

### Variante B: per Aufgabenplanung (GUI)

* **Allgemein:** „Unabhängig von der Benutzeranmeldung ausführen", „Mit höchsten
  Privilegien ausführen", Konto `SYSTEM` oder ein Hyper-V-Admin.
* **Trigger:** täglich, „Aufgabe alle 5 Minuten wiederholen" für „Unbegrenzt".
* **Aktion:** Programm `powershell.exe`, Argumente:

  ```
  -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Push-HyperVReplicaHealth.ps1" -ProbeHost 10.0.0.5 -Token "hvrepl-host01" -WarnAgeMinutes 30 -ErrorAgeMinutes 60 -LogFile "C:\Scripts\hvrepl-push.log"
  ```

* **Einstellungen:** „Keine neue Instanz starten", Ausführungszeit begrenzen.

---

## Parameter

| Parameter | Typ | Standard | Beschreibung |
|---|---|---|---|
| `-ProbeHost` | string, **Pflicht** | – | IP oder DNS-Name des PRTG-Probe-Systems |
| `-Token` | string, **Pflicht** | – | Identification Token aus den Sensoreinstellungen |
| `-Port` | int | `5050` / `5051` bei `-UseHttps` | Port des Push-Sensors |
| `-Method` | `GET` \| `POST` | `GET` | HTTP-Methode des Push |
| `-UseHttps` | switch | aus | Push über HTTPS (Sensor muss auf HTTPS stehen) |
| `-SkipCertificateCheck` | switch | aus | Zertifikatsprüfung abschalten (PRTG-Standardzertifikat) |
| `-ComputerName` | string | leer = lokal | Remote-Hyper-V-Host |
| `-User` | string | leer | Benutzer für den Remote-Zugriff |
| `-Password` | string | leer | Passwort für den Remote-Zugriff (Klartext – siehe Sicherheit) |
| `-Protocol` | `DCOM` \| `WSMan` | `DCOM` | Protokoll der CIM-Session bei Remote-Zugriff |
| `-WarnAgeMinutes` | int | `30` | Warnschwelle für das Alter der letzten Replikation |
| `-ErrorAgeMinutes` | int | `60` | Fehlerschwelle für das Alter der letzten Replikation |
| `-ReplicationRole` | `All` \| `Primary` \| `Replica` | `All` | Filter auf die Replikationsrolle der VMs |
| `-ExcludeVM` | string | leer | Komma-separierte Liste zu ignorierender VM-Namen |
| `-PerVM` | switch | aus | Zusätzlich zwei Kanäle je VM (Alter + Health) |
| `-ShowXml` | switch | aus | Nur XML ausgeben, nichts senden (Test) |
| `-LogFile` | string | leer | Logdatei, an die jede Statuszeile angehängt wird |

### Beispiele

```powershell
# Standard: lokaler Host, GET-Push
.\Push-HyperVReplicaHealth.ps1 -ProbeHost 10.0.0.5 -Token "ABC123" `
    -WarnAgeMinutes 30 -ErrorAgeMinutes 60

# Nur VMs, die auf diesem Host primär repliziert werden, zwei VMs ausnehmen
.\Push-HyperVReplicaHealth.ps1 -ProbeHost prtg.firma.local -Token "ABC123" `
    -ReplicationRole Primary -ExcludeVM "TESTVM01,LAB-DC02"

# Kanäle je VM – dabei POST verwenden, sonst wird die GET-URL zu lang
.\Push-HyperVReplicaHealth.ps1 -ProbeHost 10.0.0.5 -Token "ABC123" -PerVM -Method POST

# HTTPS mit PRTG-Standardzertifikat
.\Push-HyperVReplicaHealth.ps1 -ProbeHost 10.0.0.5 -Token "ABC123" `
    -UseHttps -SkipCertificateCheck

# Remote-Host abfragen (Skript läuft z. B. auf einem Management-Server)
.\Push-HyperVReplicaHealth.ps1 -ProbeHost 10.0.0.5 -Token "ABC123" `
    -ComputerName HV-HOST01 -Protocol WSMan
```

---

## Kanäle des Sensors

Die Aggregatkanäle sind immer vorhanden:

| Kanal | Einheit | Bedeutung | Limits |
|---|---|---|---|
| **Alter letzte Replikation** | min | Ältester Wert über alle VMs (Maximum) | Warnung > `-WarnAgeMinutes`, Fehler > `-ErrorAgeMinutes` |
| **Replizierte VMs** | Anzahl | VMs mit aktivierter Replikation (nach Filtern) | – |
| **Health OK** | Anzahl | VMs mit Health `Ok` | – |
| **Health Warning** | Anzahl | VMs mit Health `Warning` **oder** `Not applicable` | Warnung > 0 |
| **Health Critical** | Anzahl | VMs mit Health `Critical` | Fehler > 0 |
| **State nicht OK** | Anzahl | VMs, deren State weder `Replicating` noch `Synced replication complete` ist | Fehler > 0 |
| **Nie repliziert** | Anzahl | VMs ohne bisherige erfolgreiche Replikation | Fehler > 0 |

Mit `-PerVM` kommen je VM zwei weitere Kanäle dazu:

| Kanal | Einheit | Bedeutung | Limits |
|---|---|---|---|
| `<VM> Alter` | min | Alter der letzten Replikation dieser VM (nie repliziert → `0`) | wie oben |
| `<VM> Health` | Anzahl | `0` = Ok, `1` = Warning, `2` = Critical, `3` = unbekannt/n. a. | Warnung > 0, Fehler > 1 |

Der Sensortext (`<text>`) enthält entweder eine Zusammenfassung
(`4 Replikation(en) OK, aelteste vor 6 min`) oder die Liste der auffälligen VMs
(`VM01: Warning/Resynchronizing, letzte Replikation 42 min | …`, gekürzt auf 900 Zeichen).

### Wertetabellen aus WMI

**ReplicationHealth** (`Msvm_ReplicationRelationship.ReplicationHealth`)

| Wert | Bedeutung |
|---|---|
| 0 | Not applicable |
| 1 | Ok |
| 2 | Warning |
| 3 | Critical |

**ReplicationMode** – bestimmt den Filter `-ReplicationRole`

| Wert | Bedeutung | `-ReplicationRole` |
|---|---|---|
| 0 | keine Replikation | wird immer übersprungen |
| 1 | Primary | `Primary`, `All` |
| 2 | Replica | `Replica`, `All` |
| 3 | Test Replica | nur `All` |
| 4 | Extended Replica | `Replica`, `All` |

**ReplicationState** – als „OK" gelten nur `3` (*Replicating*) und
`4` (*Synced replication complete*). Alle anderen Zustände (u. a. `7` *Suspended*,
`8` *Critical*, `10` *Resynchronizing*) zählen in den Kanal **State nicht OK**.

---

## GET oder POST?

* **GET** (Standard) hängt das XML URL-kodiert an die Push-URL. Das Skript bricht ab,
  wenn die URL länger als 7500 Zeichen wird – bei vielen VMs mit `-PerVM` passiert das
  schnell.
* **POST** schickt das XML im Body und kennt diese Grenze nicht.
  Bei `-PerVM` oder mehr als ca. 20 VMs also `-Method POST` verwenden und im Sensor
  *Request Method* auf `ANY` oder `POST` stellen.

Die tatsächliche URL-Länge zeigt der Trockenlauf:

```powershell
.\Push-HyperVReplicaHealth.ps1 -ProbeHost dummy -Token dummy -PerVM -ShowXml
```

---

## Verhalten bei Fehlern

* Schlägt die **Datenermittlung** fehl (kein Zugriff, keine replizierten VMs,
  zu altes Betriebssystem), pusht das Skript bewusst ein Fehler-XML
  (`<prtg><error>1</error><text>…</text></prtg>`). Der Sensor wird rot und zeigt
  die Ursache an, statt still auf alten Daten stehenzubleiben.
* Der **Push** selbst wird bis zu **3-mal** versucht (3 s Pause, 30 s Timeout je Versuch).
* Exitcodes: `0` = gepusht (oder `-ShowXml`), `1` = Push endgültig fehlgeschlagen.
  Die Aufgabenplanung zeigt das als `LastTaskResult`.

---

## Troubleshooting

| Symptom | Ursache / Lösung |
|---|---|
| Sensor bleibt auf „No incoming data" | Token oder Port stimmen nicht; Firewall zwischen Host und Probe; geplante Aufgabe läuft nicht (`LastRunTime` prüfen). |
| `Keine VM mit aktivierter Hyper-V-Replikation gefunden` | Auf dem Host ist keine Replikation aktiv, oder `-ReplicationRole` / `-ExcludeVM` filtert alles weg. |
| `Klasse Msvm_ReplicationRelationship lieferte keine Instanzen` | Betriebssystem älter als Windows Server 2012 R2. |
| `GET-URL zu lang (… Zeichen)` | `-Method POST` verwenden oder `-PerVM` weglassen. |
| HTTP-Fehler bei HTTPS | Sensor läuft nicht auf HTTPS, falscher Port (`5051`), oder Zertifikat nicht vertrauenswürdig → `-SkipCertificateCheck`. |
| Aufgabe läuft, Logdatei bleibt leer | Konto darf nicht in den Log-Pfad schreiben; anderen Pfad wählen. |
| Remote-Abfrage schlägt fehl | DCOM (RPC, Port 135 + dynamisch) oder WinRM freigeben, `-Protocol WSMan` testen, Rechte des Kontos prüfen. |
| Umlaute in VM-Namen erscheinen als `_` | Beabsichtigt: `ConvertTo-PrtgText` ersetzt alle Zeichen außerhalb ASCII 32–126, damit die Push-URL sauber bleibt. |

Logdatei live mitlesen:

```powershell
Get-Content C:\Scripts\hvrepl-push.log -Tail 20 -Wait
```

---

## Sicherheitshinweise

* `-Password` wird im Klartext übergeben und landet damit in der Kommandozeile der
  geplanten Aufgabe. Besser: das Skript unter einem Konto laufen lassen, das ohnehin
  Zugriff auf den Ziel-Host hat, und `-User`/`-Password` weglassen.
* Der **Token** ist das einzige Geheimnis des Push-Sensors – wer ihn kennt, kann
  beliebige Werte in den Sensor schreiben. Token entsprechend lang wählen und das
  Skript nur für Administratoren lesbar machen.
* `-SkipCertificateCheck` deaktiviert die Zertifikatsprüfung für den gesamten
  PowerShell-Prozess. Nur im vertrauenswürdigen Netz bzw. für das
  PRTG-Standardzertifikat verwenden.

---

## Lizenz

[MIT](LICENSE)
