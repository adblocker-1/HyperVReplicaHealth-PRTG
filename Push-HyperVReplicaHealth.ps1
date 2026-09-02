#Requires -Version 3.0
<#
.SYNOPSIS
    Push-Variante: ermittelt den Zustand der Hyper-V-Replikation und schickt
    das Ergebnis per HTTP an einen PRTG-Sensor "HTTP Push Data Advanced".

.DESCRIPTION
    Laeuft als geplante Aufgabe direkt auf dem Hyper-V-Host (oder auf einem
    beliebigen Rechner mit -ComputerName) und pusht das PRTG-XML an:

        GET  http://<probe>:<port>/<token>?content=<urlencodiertes XML>
        POST http://<probe>:<port>/<token>          (Body = XML)

    Datenquelle wie bei der Pull-Variante: CIM/WMI aus root\virtualization\v2
    (Msvm_ComputerSystem + Msvm_ReplicationRelationship). Kein Hyper-V-Modul
    noetig.

    Schlaegt die Datenermittlung fehl, wird bewusst ein Fehler-XML gepusht,
    damit der Sensor rot wird statt still stehenzubleiben.

.PARAMETER ProbeHost
    IP oder DNS-Name des PRTG-Probe-Systems, auf dem der Sensor liegt.

.PARAMETER Token
    Identification Token aus den Sensoreinstellungen.

.PARAMETER Port
    Port des Push-Sensors. Standard 5050 (HTTP) bzw. 5051 bei -UseHttps.

.PARAMETER Method
    GET (Standard) oder POST.

.PARAMETER UseHttps
    Push ueber HTTPS (Sensor muss auf HTTPS konfiguriert sein).

.PARAMETER SkipCertificateCheck
    Zertifikatspruefung bei HTTPS abschalten (PRTG-Standardzertifikat).

.PARAMETER ComputerName
    Optionaler Remote-Hyper-V-Host. Leer = lokal.

.PARAMETER User / .PARAMETER Password
    Optionale Anmeldedaten fuer den Remote-Zugriff.

.PARAMETER Protocol
    DCOM (Standard) oder WSMan fuer die CIM-Session.

.PARAMETER WarnAgeMinutes / .PARAMETER ErrorAgeMinutes
    Schwellwerte fuer das Alter der letzten Replikation. Standard 30 / 60.

.PARAMETER ReplicationRole
    All (Standard) | Primary | Replica.

.PARAMETER ExcludeVM
    Komma-separierte Liste zu ignorierender VM-Namen.

.PARAMETER PerVM
    Zusaetzlich zwei Kanaele je VM.

.PARAMETER ShowXml
    Nur XML ausgeben, nichts senden (zum Testen).

.PARAMETER LogFile
    Optionale Logdatei fuer die geplante Aufgabe.

.EXAMPLE
    .\Push-HyperVReplicaHealth.ps1 -ProbeHost 10.0.0.5 -Token "ABC123" -WarnAgeMinutes 30 -ErrorAgeMinutes 60

.EXAMPLE
    Trockenlauf ohne Senden:
    .\Push-HyperVReplicaHealth.ps1 -ProbeHost x -Token x -ShowXml

.NOTES
    Sensor: HTTP Push Data Advanced
    Request Method im Sensor: ANY oder passend zu -Method
    "No Incoming Data" auf "Switch to down status after x minutes" stellen,
    Schwelle > doppeltes Aufrufintervall der geplanten Aufgabe.

    Exitcode 0 = gepusht, 1 = Push fehlgeschlagen.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProbeHost,

    [Parameter(Mandatory = $true)]
    [string]$Token,

    [int]$Port = 0,

    [ValidateSet('GET', 'POST')]
    [string]$Method = 'GET',

    [switch]$UseHttps,
    [switch]$SkipCertificateCheck,

    [string]$ComputerName = '',
    [string]$User = '',
    [string]$Password = '',

    [ValidateSet('DCOM', 'WSMan')]
    [string]$Protocol = 'DCOM',

    [int]$WarnAgeMinutes = 30,
    [int]$ErrorAgeMinutes = 60,

    [ValidateSet('All', 'Primary', 'Replica')]
    [string]$ReplicationRole = 'All',

    [string]$ExcludeVM = '',
    [switch]$PerVM,
    [switch]$ShowXml,
    [string]$LogFile = ''
)

$ErrorActionPreference = 'Stop'

if ($Port -le 0) { if ($UseHttps) { $Port = 5051 } else { $Port = 5050 } }

# ---------------------------------------------------------------- Helfer ----

function Write-Log {
    param([string]$Message)
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Output $line
    if ($LogFile -ne '') {
        try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch { }
    }
}

function ConvertTo-PrtgText {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $t = $Text -replace '&', '&amp;'
    $t = $t -replace '<', '&lt;'
    $t = $t -replace '>', '&gt;'
    $t = $t -replace '"', '&quot;'
    $t = $t -replace "'", '&apos;'
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $t.ToCharArray()) {
        $code = [int][char]$c
        if ($code -ge 32 -and $code -le 126) { [void]$sb.Append($c) }
        else { [void]$sb.Append('_') }
    }
    return $sb.ToString()
}

# Kompaktes XML ohne Zeilenumbrueche - haelt die GET-URL kurz
function New-PrtgChannel {
    param(
        [string]$Name,
        [long]$Value,
        [string]$CustomUnit = '',
        [string]$WarnMax = '',
        [string]$ErrMax = '',
        [string]$ErrMsg = '',
        [int]$ShowChart = 1
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<result>')
    [void]$sb.Append('<channel>' + (ConvertTo-PrtgText $Name) + '</channel>')
    [void]$sb.Append('<value>' + $Value.ToString([System.Globalization.CultureInfo]::InvariantCulture) + '</value>')
    if ($CustomUnit -ne '') {
        [void]$sb.Append('<unit>Custom</unit>')
        [void]$sb.Append('<customunit>' + (ConvertTo-PrtgText $CustomUnit) + '</customunit>')
    }
    else {
        [void]$sb.Append('<unit>Count</unit>')
    }
    [void]$sb.Append('<float>0</float>')
    [void]$sb.Append('<mode>Absolute</mode>')
    [void]$sb.Append('<showchart>' + $ShowChart + '</showchart>')
    [void]$sb.Append('<showtable>1</showtable>')
    if ($WarnMax -ne '' -or $ErrMax -ne '') {
        [void]$sb.Append('<limitmode>1</limitmode>')
        if ($WarnMax -ne '') { [void]$sb.Append('<limitmaxwarning>' + $WarnMax + '</limitmaxwarning>') }
        if ($ErrMax -ne '') { [void]$sb.Append('<limitmaxerror>' + $ErrMax + '</limitmaxerror>') }
        if ($ErrMsg -ne '') { [void]$sb.Append('<limiterrormsg>' + (ConvertTo-PrtgText $ErrMsg) + '</limiterrormsg>') }
    }
    [void]$sb.Append('</result>')
    return $sb.ToString()
}

function New-PrtgErrorXml {
    param([string]$Message)
    return '<prtg><error>1</error><text>' + (ConvertTo-PrtgText $Message) + '</text></prtg>'
}

function Send-PrtgPush {
    param([string]$Xml)

    if ($UseHttps) { $scheme = 'https' } else { $scheme = 'http' }
    $baseUrl = '{0}://{1}:{2}/{3}' -f $scheme, $ProbeHost, $Port, $Token

    if ($UseHttps) {
        try {
            [Net.ServicePointManager]::SecurityProtocol = `
                [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        }
        catch { }
        if ($SkipCertificateCheck) {
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        }
    }

    $lastError = ''
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            if ($Method -eq 'GET') {
                $url = $baseUrl + '?content=' + [System.Uri]::EscapeDataString($Xml)
                if ($url.Length -gt 7500) {
                    throw ("GET-URL zu lang ({0} Zeichen). -Method POST verwenden oder -PerVM weglassen." -f $url.Length)
                }
                $response = Invoke-WebRequest -Uri $url -Method Get -UseBasicParsing -TimeoutSec 30
            }
            else {
                $response = Invoke-WebRequest -Uri $baseUrl -Method Post -Body $Xml `
                    -ContentType 'application/xml' -UseBasicParsing -TimeoutSec 30
            }

            if ($response.StatusCode -eq 200) {
                return @{ Ok = $true; Info = "HTTP 200 (Versuch $attempt)" }
            }
            $lastError = 'HTTP ' + $response.StatusCode
        }
        catch {
            $lastError = $_.Exception.Message
        }
        if ($attempt -lt 3) { Start-Sleep -Seconds 3 }
    }
    return @{ Ok = $false; Info = $lastError }
}

$healthNames = @('Not applicable', 'Ok', 'Warning', 'Critical')
$stateNames = @(
    'Disabled', 'Ready for replication', 'Waiting to complete initial replication',
    'Replicating', 'Synced replication complete', 'Recovered', 'Committed',
    'Suspended', 'Critical', 'Waiting to start resynchronization', 'Resynchronizing',
    'Resynchronization suspended', 'Failover in progress', 'Failback in progress',
    'Failback complete', 'Disk update in progress', 'Disk update critical', 'Unknown',
    'Repurpose replication in progress', 'Prepared for sync replication',
    'Prepared for group reverse replication', 'Firedrill in progress'
)
$stateOk = @(3, 4)

# ------------------------------------------------------ Daten ermitteln ----

$xmlPayload = $null
$session = $null
$summary = ''

try {
    $cimArgs = @{
        Namespace   = 'root\virtualization\v2'
        ErrorAction = 'Stop'
    }

    $target = $ComputerName.Trim()
    $localAliases = @('', '.', 'localhost', '127.0.0.1', '::1', $env:COMPUTERNAME)

    if ($localAliases -notcontains $target) {
        if ($Protocol -eq 'DCOM') { $sessionOption = New-CimSessionOption -Protocol Dcom }
        else { $sessionOption = New-CimSessionOption -Protocol Wsman }

        $sessionArgs = @{
            ComputerName  = $target
            SessionOption = $sessionOption
            ErrorAction   = 'Stop'
        }
        if ($User.Trim() -ne '') {
            if ($Password -eq '') { throw 'Parameter -User angegeben, aber -Password ist leer.' }
            $securePw = ConvertTo-SecureString $Password -AsPlainText -Force
            $sessionArgs['Credential'] = New-Object System.Management.Automation.PSCredential($User, $securePw)
        }
        $session = New-CimSession @sessionArgs
        $cimArgs['CimSession'] = $session
    }

    $guidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

    $vms = @(Get-CimInstance @cimArgs -ClassName Msvm_ComputerSystem |
        Where-Object { $_.Name -match $guidPattern })

    $relations = @()
    try { $relations = @(Get-CimInstance @cimArgs -ClassName Msvm_ReplicationRelationship) }
    catch { $relations = @() }

    $relByVm = @{}
    foreach ($rel in $relations) {
        $id = [string]$rel.InstanceID
        if ($id -match '^Microsoft:([0-9a-fA-F\-]{36})\\HVR\\(\d+)') {
            $vmId = $Matches[1].ToLower()
            $relIndex = [int]$Matches[2]
            if ($relIndex -eq 0 -or -not $relByVm.ContainsKey($vmId)) { $relByVm[$vmId] = $rel }
        }
        elseif ($id -match '^Microsoft:([0-9a-fA-F\-]{36})\\HVR') {
            $vmId = $Matches[1].ToLower()
            if (-not $relByVm.ContainsKey($vmId)) { $relByVm[$vmId] = $rel }
        }
    }

    $excluded = @()
    if ($ExcludeVM.Trim() -ne '') {
        $excluded = @($ExcludeVM.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    }

    $now = Get-Date
    $items = @()

    foreach ($vm in $vms) {
        $mode = 0
        if ($null -ne $vm.ReplicationMode) { $mode = [int]$vm.ReplicationMode }
        if ($mode -eq 0) { continue }

        if ($ReplicationRole -eq 'Primary' -and $mode -ne 1) { continue }
        if ($ReplicationRole -eq 'Replica' -and @(2, 4) -notcontains $mode) { continue }

        $vmName = [string]$vm.ElementName
        if ($excluded -contains $vmName) { continue }

        $vmId = ([string]$vm.Name).ToLower()
        $rel = $null
        if ($relByVm.ContainsKey($vmId)) { $rel = $relByVm[$vmId] }

        if ($null -ne $rel) {
            $health = [int]$rel.ReplicationHealth
            $state = [int]$rel.ReplicationState
            $lastRepl = $rel.LastReplicationTime
        }
        else {
            $health = 0
            $state = 0
            if ($null -ne $vm.ReplicationHealth) { $health = [int]$vm.ReplicationHealth }
            if ($null -ne $vm.ReplicationState) { $state = [int]$vm.ReplicationState }
            $lastRepl = $null
        }

        $ageMinutes = $null
        if ($lastRepl -is [datetime] -and $lastRepl.Year -gt 1900) {
            $ageMinutes = [int][math]::Round(($now - $lastRepl).TotalMinutes)
            if ($ageMinutes -lt 0) { $ageMinutes = 0 }
        }

        $healthText = 'Unknown'
        if ($health -ge 0 -and $health -lt $healthNames.Count) { $healthText = $healthNames[$health] }
        $stateText = "State $state"
        if ($state -ge 0 -and $state -lt $stateNames.Count) { $stateText = $stateNames[$state] }

        $items += New-Object PSObject -Property @{
            Name       = $vmName
            Mode       = $mode
            Health     = $health
            HealthText = $healthText
            State      = $state
            StateText  = $stateText
            AgeMinutes = $ageMinutes
        }
    }

    if ($items.Count -eq 0) {
        throw 'Keine VM mit aktivierter Hyper-V-Replikation gefunden (Rollenfilter/Ausschlussliste pruefen).'
    }
    if ($relations.Count -eq 0) {
        throw 'Klasse Msvm_ReplicationRelationship lieferte keine Instanzen. Windows Server 2012 R2 oder neuer erforderlich.'
    }

    $countTotal = $items.Count
    $countOk = @($items | Where-Object { $_.Health -eq 1 }).Count
    $countWarn = @($items | Where-Object { $_.Health -eq 2 }).Count
    $countCrit = @($items | Where-Object { $_.Health -eq 3 }).Count
    $countNa = @($items | Where-Object { $_.Health -eq 0 }).Count
    $countBadState = @($items | Where-Object { $stateOk -notcontains $_.State }).Count
    $withAge = @($items | Where-Object { $null -ne $_.AgeMinutes })
    $countNever = $countTotal - $withAge.Count

    $maxAge = 0
    if ($withAge.Count -gt 0) {
        $maxAge = [int](($withAge | Measure-Object -Property AgeMinutes -Maximum).Maximum)
    }
    $countWarnTotal = $countWarn + $countNa

    $problems = @()
    foreach ($i in ($items | Sort-Object Name)) {
        $isBad = ($i.Health -ne 1) -or ($stateOk -notcontains $i.State)
        if ($null -eq $i.AgeMinutes) { $isBad = $true }
        elseif ($i.AgeMinutes -gt $WarnAgeMinutes) { $isBad = $true }
        if (-not $isBad) { continue }

        if ($null -eq $i.AgeMinutes) { $ageText = 'nie' } else { $ageText = "$($i.AgeMinutes) min" }
        $problems += ('{0}: {1}/{2}, letzte Replikation {3}' -f $i.Name, $i.HealthText, $i.StateText, $ageText)
    }

    if ($problems.Count -gt 0) { $text = $problems -join ' | ' }
    else { $text = '{0} Replikation(en) OK, aelteste vor {1} min' -f $countTotal, $maxAge }
    if ($text.Length -gt 900) { $text = $text.Substring(0, 897) + '...' }
    $summary = $text

    $xml = New-Object System.Text.StringBuilder
    [void]$xml.Append('<prtg>')

    [void]$xml.Append((New-PrtgChannel -Name 'Alter letzte Replikation' -Value $maxAge -CustomUnit 'min' `
                -WarnMax ([string]$WarnAgeMinutes) -ErrMax ([string]$ErrorAgeMinutes) `
                -ErrMsg 'Letzte erfolgreiche Replikation liegt zu lange zurueck'))
    [void]$xml.Append((New-PrtgChannel -Name 'Replizierte VMs' -Value $countTotal -ShowChart 0))
    [void]$xml.Append((New-PrtgChannel -Name 'Health OK' -Value $countOk))
    [void]$xml.Append((New-PrtgChannel -Name 'Health Warning' -Value $countWarnTotal -WarnMax '0'))
    [void]$xml.Append((New-PrtgChannel -Name 'Health Critical' -Value $countCrit -ErrMax '0' `
                -ErrMsg 'Replikation im Zustand Critical'))
    [void]$xml.Append((New-PrtgChannel -Name 'State nicht OK' -Value $countBadState -ErrMax '0' `
                -ErrMsg 'Mindestens eine VM repliziert nicht (angehalten/kritisch)'))
    [void]$xml.Append((New-PrtgChannel -Name 'Nie repliziert' -Value $countNever -ErrMax '0' `
                -ErrMsg 'Mindestens eine VM hat noch keine erfolgreiche Replikation'))

    if ($PerVM) {
        foreach ($i in ($items | Sort-Object Name)) {
            if ($null -eq $i.AgeMinutes) { $vmAge = 0 } else { $vmAge = [int]$i.AgeMinutes }
            [void]$xml.Append((New-PrtgChannel -Name ($i.Name + ' Alter') -Value $vmAge -CustomUnit 'min' `
                        -WarnMax ([string]$WarnAgeMinutes) -ErrMax ([string]$ErrorAgeMinutes) `
                        -ErrMsg ('Replikation von ' + $i.Name + ' ist zu alt')))
            switch ($i.Health) {
                1 { $healthValue = 0 }
                2 { $healthValue = 1 }
                3 { $healthValue = 2 }
                default { $healthValue = 3 }
            }
            [void]$xml.Append((New-PrtgChannel -Name ($i.Name + ' Health') -Value $healthValue `
                        -WarnMax '0' -ErrMax '1' -ShowChart 0 `
                        -ErrMsg ('Replikations-Health von ' + $i.Name + ' ist nicht OK')))
        }
    }

    [void]$xml.Append('<text>' + (ConvertTo-PrtgText $text) + '</text>')
    [void]$xml.Append('</prtg>')

    $xmlPayload = $xml.ToString()
}
catch {
    $summary = 'FEHLER: ' + $_.Exception.Message
    $xmlPayload = New-PrtgErrorXml $summary
}
finally {
    if ($null -ne $session) {
        Remove-CimSession -CimSession $session -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------------------- Senden ----

if ($ShowXml) {
    Write-Output $xmlPayload
    Write-Log ('XML-Laenge: {0} Zeichen, GET-URL waere {1} Zeichen' -f `
            $xmlPayload.Length, ([System.Uri]::EscapeDataString($xmlPayload).Length + $ProbeHost.Length + $Token.Length + 20))
    exit 0
}

$result = Send-PrtgPush -Xml $xmlPayload

if ($result.Ok) {
    Write-Log ('Push OK ({0}) - {1}' -f $result.Info, $summary)
    exit 0
}
else {
    Write-Log ('Push FEHLGESCHLAGEN: {0} - Daten waeren gewesen: {1}' -f $result.Info, $summary)
    exit 1
}
