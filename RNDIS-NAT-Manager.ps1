<#
.SYNOPSIS
    ICS / NAT менеджер для RNDIS-устройства (ККМ) — раздача интернета через WinNAT.

.DESCRIPTION
    Интерактивное меню. Все параметры задаются ИЗ ИНТЕРФЕЙСА (пункт «Настройки»)
    и сохраняются в C:\ProgramData\RNDIS-NAT-Manager\config.json — править код
    или перекомпилировать exe не нужно.

    Работает одинаково как .ps1 и как скомпилированный .exe (ps2exe):
    пути, самоповышение прав и задача автозапуска определяют режим автоматически.

    Механизм — WinNAT (New-NetNat), переживающий перезагрузку. WinNAT не раздаёт
    DHCP/DNS, поэтому на ККМ задаётся статика вручную:
        IP    : из подсети (напр. 192.168.137.100)
        Маска : 255.255.255.0
        Шлюз  : IP хоста (по умолчанию 192.168.137.1)
        DNS   : 1.1.1.1 / 8.8.8.8

.NOTES
    Компилировать БЕЗ -noConsole (нужна консоль для меню), желательно с -requireAdmin.
        Install-Module ps2exe
        Invoke-ps2exe .\RNDIS-NAT-Manager.ps1 .\RNDIS-NAT-Manager.exe -requireAdmin -title "RNDIS NAT Manager"
#>

param([switch]$Auto)   # -Auto: тихий режим для автозапуска (без меню)

#region ── Путь к себе (.ps1 или .exe) ────────────────────────────────
function Get-SelfPath {
    if ($PSCommandPath) { return $PSCommandPath }                 # запуск как .ps1
    try {
        $p = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ($p) { return $p }                                     # запуск как .exe (ps2exe)
    } catch {}
    return $MyInvocation.MyCommand.Definition
}
$Self  = Get-SelfPath
$IsExe = $Self -like '*.exe'
#endregion

#region ── Пути и лог (нужны ДО повышения прав, чтобы видеть и этот шаг) ──
$AppDir  = Join-Path $env:ProgramData 'RNDIS-NAT-Manager'
$LogPath = Join-Path $AppDir 'RNDIS-NAT.log'
try { if (-not (Test-Path $AppDir)) { New-Item -ItemType Directory -Path $AppDir -Force -ErrorAction Stop | Out-Null } } catch {}

$script:TraceToConsole = $false   # живой TRACE в консоли — переключается пунктом меню [V]

function Write-Log {
    param([string]$Message, [string]$Type = 'INFO')
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Type] $Message"
    try { $line | Out-File -FilePath $LogPath -Append -Encoding UTF8 } catch {}
    if ($Type -eq 'TRACE' -and -not $script:TraceToConsole) { return }   # TRACE всегда в файле, в консоли — по флагу
    $color = switch ($Type) { 'OK' {'Green'} 'WARN' {'Yellow'} 'ERROR' {'Red'} 'TRACE' {'DarkGray'} default {'Gray'} }
    Write-Host $line -ForegroundColor $color
}

# Оборачивает потенциально зависающий вызов (CIM/COM/сеть): пишет "->" до
# и "<- ...[N мс]" после. Если процесс зависнет внутри $Action, в логе
# останется одинокая "->" без пары — видно ровно, на каком вызове встало.
# Также ловит НЕтерминирующие ошибки (-ErrorAction SilentlyContinue их не
# выводит на экран, но они всё равно попадают в $Error) — иначе такие
# ошибки видны в консоли как голая строка без метки времени и источника.
function Invoke-Logged {
    param([string]$Name, [scriptblock]$Action)
    Write-Log ("-> {0}" -f $Name) 'TRACE'
    $errCountBefore = $Error.Count
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $result = & $Action
        if ($Error.Count -gt $errCountBefore) {
            $newCount = $Error.Count - $errCountBefore
            for ($i = 0; $i -lt $newCount; $i++) {
                Write-Log ("   (подавленная ошибка в {0}): {1}" -f $Name, $Error[$i].Exception.Message) 'WARN'
            }
        }
        Write-Log ("<- {0} [{1} мс]" -f $Name, $sw.ElapsedMilliseconds) 'TRACE'
        return $result
    } catch {
        Write-Log ("x  {0} [{1} мс]: {2}" -f $Name, $sw.ElapsedMilliseconds, $_.Exception.Message) 'ERROR'
        return $null
    }
}

Write-Log ("=== Запуск === Self=$Self IsExe=$IsExe Auto=$Auto PID=$PID") 'INFO'
#endregion

#region ── Самоповышение прав ─────────────────────────────────────────
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Log "Проверка прав администратора: isAdmin=$isAdmin" 'TRACE'

if (-not $isAdmin) {
    Write-Log 'Прав администратора нет — запрашиваю повышение (UAC)' 'WARN'
    Write-Host 'Требуются права администратора. Перезапуск...' -ForegroundColor Yellow
    try {
        if ($IsExe) {
            if ($Auto) { Start-Process -FilePath $Self -ArgumentList '-Auto' -Verb RunAs }
            else       { Start-Process -FilePath $Self -Verb RunAs }
        } else {
            $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$Self`"")
            if ($Auto) { $argList += '-Auto' }
            Start-Process powershell.exe -ArgumentList $argList -Verb RunAs
        }
        Write-Log 'Повышенный процесс запущен, текущий процесс завершается' 'OK'
    } catch {
        Write-Log ("UAC отклонён пользователем или повышение не удалось: {0}" -f $_.Exception.Message) 'ERROR'
    }
    exit
}
Write-Log 'Права администратора подтверждены' 'OK'

try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
#endregion

#region ── Конфиг ──────────────────────────────────────────────────────
$ConfigPath = Join-Path $AppDir 'config.json'

$DefaultConfig = [ordered]@{
    NatName      = 'RndisNat'
    HostIP       = '192.168.137.1'
    Prefix       = 24
    KkmIP        = '192.168.137.100'
    AdapterMatch = 'RNDIS|Remote NDIS|Gadget'
    TaskName     = 'RNDIS NAT'
}

function Load-Config {
    $c = [ordered]@{}
    foreach ($k in $DefaultConfig.Keys) { $c[$k] = $DefaultConfig[$k] }
    if (Test-Path $ConfigPath) {
        try {
            $json = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in $DefaultConfig.Keys) {
                if ($null -ne $json.$k -and "$($json.$k)" -ne '') { $c[$k] = $json.$k }
            }
        } catch { }
    }
    return $c
}

function Save-Config {
    try {
        ($script:Config | ConvertTo-Json) | Out-File -FilePath $ConfigPath -Encoding UTF8
        Write-Log "Настройки сохранены: $ConfigPath" 'OK'
    } catch {
        Write-Log ("Не удалось сохранить настройки: {0}" -f $_.Exception.Message) 'ERROR'
    }
}

$script:Config = Load-Config
Write-Log ("Конфиг: NatName=$($Config.NatName) HostIP=$($Config.HostIP)/$($Config.Prefix) KkmIP=$($Config.KkmIP) AdapterMatch='$($Config.AdapterMatch)' TaskName='$($Config.TaskName)'") 'TRACE'

# Подсеть выводится из IP хоста и префикса — чтобы не было рассинхрона
function Get-SubnetPrefix {
    param([string]$IP, [int]$Prefix)
    $ip  = [System.Net.IPAddress]::Parse($IP).GetAddressBytes()   # big-endian, 4 байта
    $net = New-Object byte[] 4
    for ($i = 0; $i -lt 4; $i++) {
        $bits = [Math]::Min(8, [Math]::Max(0, $Prefix - ($i * 8)))
        $mask = if ($bits -eq 0) { 0 } else { (0xFF -shl (8 - $bits)) -band 0xFF }
        $net[$i] = [byte]($ip[$i] -band $mask)
    }
    return ('{0}.{1}.{2}.{3}/{4}' -f $net[0], $net[1], $net[2], $net[3], $Prefix)
}
#endregion

#region ── Поиск адаптера ─────────────────────────────────────────────
$script:ManualAdapterIndex = $null

function Get-RndisAdapter {
    if ($script:ManualAdapterIndex) {
        return Invoke-Logged "Get-NetAdapter(ifIndex=$($script:ManualAdapterIndex))" {
            Get-NetAdapter -InterfaceIndex $script:ManualAdapterIndex -ErrorAction SilentlyContinue
        }
    }
    Invoke-Logged 'Get-NetAdapter(все)' {
        Get-NetAdapter -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceDescription -match $Config.AdapterMatch -and $_.Status -ne 'Disabled' } |
            Select-Object -First 1
    }
}

function Wait-RndisAdapter {
    param([int]$TimeoutSec = 30)
    Write-Log "Wait-RndisAdapter: ожидание адаптера до ${TimeoutSec}с" 'TRACE'
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $attempt = 0
    do {
        $attempt++
        $a = Get-RndisAdapter
        if ($a) { Write-Log "Wait-RndisAdapter: найден на попытке $attempt" 'TRACE'; return $a }
        Write-Log "Wait-RndisAdapter: попытка $attempt — не найден, жду 2с" 'TRACE'
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    Write-Log "Wait-RndisAdapter: не найден за ${TimeoutSec}с ($attempt попыток)" 'WARN'
    return $null
}
#endregion

#region ── Действия ───────────────────────────────────────────────────

function Show-Status {
    Write-Host ''
    Write-Host '── Состояние ──────────────────────────────────' -ForegroundColor Cyan
    Write-Log 'Show-Status: старт' 'TRACE'

    $a = Get-RndisAdapter
    if ($a) {
        Write-Host ("RNDIS-адаптер : {0}  [{1}]" -f $a.Name, $a.InterfaceDescription) -ForegroundColor Green
        Write-Host ("  Статус      : {0}" -f $a.Status)
        $ips = Invoke-Logged "Get-NetIPAddress(ifIndex=$($a.ifIndex))" {
            Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        }
        if ($ips) { $ips | ForEach-Object { Write-Host ("  IP          : {0}/{1}" -f $_.IPAddress, $_.PrefixLength) } }
        else      { Write-Host '  IP          : не назначен' -ForegroundColor Yellow }
    } else {
        Write-Host 'RNDIS-адаптер : НЕ НАЙДЕН (проверь USB / выбери вручную [5])' -ForegroundColor Red
    }

    $nat = Invoke-Logged "Get-NetNat($($Config.NatName))" { Get-NetNat -Name $Config.NatName -ErrorAction SilentlyContinue }
    if ($nat) {
        Write-Host ("NAT '{0}'  : активен на {1}" -f $Config.NatName, $nat.InternalIPInterfaceAddressPrefix) -ForegroundColor Green
    } else {
        Write-Host ("NAT '{0}'  : не создан" -f $Config.NatName) -ForegroundColor Yellow
    }

    $task = Invoke-Logged "Get-ScheduledTask($($Config.TaskName))" { Get-ScheduledTask -TaskName $Config.TaskName -ErrorAction SilentlyContinue }
    Write-Host ("Автозапуск    : {0}" -f $(if ($task) { 'установлен' } else { 'нет' }))
    Write-Host ("Шлюз / ККМ    : {0}  ->  {1}" -f $Config.HostIP, $Config.KkmIP)
    Write-Host '────────────────────────────────────────────────' -ForegroundColor Cyan
    Write-Log 'Show-Status: конец' 'TRACE'
}

function Enable-Nat {
    Write-Log '=== Enable-Nat: старт ===' 'TRACE'
    $a = Wait-RndisAdapter
    if (-not $a) { Write-Log 'RNDIS-адаптер не найден за 30с' 'ERROR'; return }
    Write-Log ("Адаптер: {0} / {1}" -f $a.Name, $a.InterfaceDescription)

    $existingIPs = Invoke-Logged "Get-NetIPAddress(ifIndex=$($a.ifIndex))" {
        Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    }
    $hasIP = $existingIPs | Where-Object IPAddress -eq $Config.HostIP
    if (-not $hasIP) {
        Invoke-Logged 'Remove-NetIPAddress(старые)' {
            $existingIPs | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        } | Out-Null
        Invoke-Logged "New-NetIPAddress($($Config.HostIP)/$($Config.Prefix))" {
            New-NetIPAddress -InterfaceIndex $a.ifIndex -IPAddress $Config.HostIP -PrefixLength $Config.Prefix
        } | Out-Null
        Write-Log ("Назначен IP {0}/{1}" -f $Config.HostIP, $Config.Prefix) 'OK'
    } else {
        Write-Log ("IP {0} уже на адаптере" -f $Config.HostIP)
    }

    $subnet = Get-SubnetPrefix -IP $Config.HostIP -Prefix $Config.Prefix
    $existingNat = Invoke-Logged "Get-NetNat($($Config.NatName))" { Get-NetNat -Name $Config.NatName -ErrorAction SilentlyContinue }

    # NAT с таким именем уже есть, но привязан к ДРУГОЙ подсети (например,
    # HostIP поменяли в настройках после того, как NAT был создан под старый
    # IP) — раздача выглядит "включённой", а трафик с ККМ реально никуда не
    # транслируется. Пересоздаём под актуальную подсеть.
    if ($existingNat -and $existingNat.InternalIPInterfaceAddressPrefix -ne $subnet) {
        Write-Log ("NAT '{0}' существует на ДРУГОЙ подсети ({1} вместо {2}) — пересоздаю" -f `
            $Config.NatName, $existingNat.InternalIPInterfaceAddressPrefix, $subnet) 'WARN'
        Invoke-Logged "Remove-NetNat($($Config.NatName))" { Remove-NetNat -Name $Config.NatName -Confirm:$false } | Out-Null
        $existingNat = $null
    }

    if (-not $existingNat) {
        try {
            Write-Log ("-> New-NetNat($($Config.NatName), $subnet)") 'TRACE'
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            New-NetNat -Name $Config.NatName -InternalIPInterfaceAddressPrefix $subnet | Out-Null
            Write-Log ("<- New-NetNat [{0} мс]" -f $sw.ElapsedMilliseconds) 'TRACE'
            Write-Log ("Создан NAT '{0}' на {1}" -f $Config.NatName, $subnet) 'OK'
        } catch {
            Write-Log ("Не удалось создать NAT: {0}" -f $_.Exception.Message) 'ERROR'; return
        }
    } else {
        Write-Log ("NAT '{0}' уже существует на {1}" -f $Config.NatName, $subnet)
    }
    Write-Log 'Раздача интернета включена' 'OK'
}

function Disable-Nat {
    Write-Log '=== Disable-Nat: старт ===' 'TRACE'
    if (Invoke-Logged "Get-NetNat($($Config.NatName))" { Get-NetNat -Name $Config.NatName -ErrorAction SilentlyContinue }) {
        Invoke-Logged "Remove-NetNat($($Config.NatName))" { Remove-NetNat -Name $Config.NatName -Confirm:$false } | Out-Null
        Write-Log ("NAT '{0}' удалён" -f $Config.NatName) 'OK'
    } else {
        Write-Log ("NAT '{0}' не найден" -f $Config.NatName) 'WARN'
    }
}

function Reset-Nat {
    Write-Log '=== Сброс (пересоздание) NAT ==='
    Disable-Nat
    Start-Sleep -Seconds 1
    Enable-Nat
}

function Test-Kkm {
    Write-Host ("Пинг ККМ {0} ..." -f $Config.KkmIP) -ForegroundColor Cyan
    $ok = Invoke-Logged "Test-Connection($($Config.KkmIP))" {
        Test-Connection -ComputerName $Config.KkmIP -Count 3 -Quiet -ErrorAction SilentlyContinue
    }
    if ($ok) {
        Write-Log ("ККМ {0} отвечает" -f $Config.KkmIP) 'OK'
    } else {
        $subnet = Get-SubnetPrefix -IP $Config.HostIP -Prefix $Config.Prefix
        Write-Log ("ККМ {0} не отвечает" -f $Config.KkmIP) 'ERROR'
        Write-Host ("  На ККМ: IP из {0}, шлюз {1}, DNS 1.1.1.1" -f $subnet, $Config.HostIP) -ForegroundColor Yellow
    }
}

function Select-Adapter {
    $list = Invoke-Logged 'Get-NetAdapter(все, для выбора)' { Get-NetAdapter -ErrorAction SilentlyContinue | Sort-Object ifIndex }
    if (-not $list) { Write-Host 'Адаптеры не найдены' -ForegroundColor Red; return }
    Write-Host ''
    $map = @{}; $i = 0
    foreach ($n in $list) {
        $i++; $map[$i] = $n.ifIndex
        Write-Host ("  [{0}] {1,-24} {2,-12} {3}" -f $i, $n.Name, $n.Status, $n.InterfaceDescription)
    }
    $sel = Read-Host 'Номер адаптера (Enter — отмена)'
    if ($sel -and ($sel -as [int]) -and $map.ContainsKey([int]$sel)) {
        $script:ManualAdapterIndex = $map[[int]$sel]
        Write-Log ("Выбран адаптер ifIndex={0}" -f $script:ManualAdapterIndex) 'OK'
    } else {
        Write-Host 'Отмена' -ForegroundColor Yellow
    }
}

function Install-Task {
    Write-Log '=== Install-Task: старт ===' 'TRACE'
    if ($IsExe) {
        $action = New-ScheduledTaskAction -Execute $Self -Argument '-Auto'
    } else {
        $arg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Self`" -Auto"
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    }
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Invoke-Logged "Register-ScheduledTask($($Config.TaskName))" {
        Register-ScheduledTask -TaskName $Config.TaskName -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings -Force
    } | Out-Null
    Write-Log ("Задача автозапуска '{0}' установлена" -f $Config.TaskName) 'OK'
}

function Remove-Task {
    Write-Log '=== Remove-Task: старт ===' 'TRACE'
    if (Invoke-Logged "Get-ScheduledTask($($Config.TaskName))" { Get-ScheduledTask -TaskName $Config.TaskName -ErrorAction SilentlyContinue }) {
        Invoke-Logged "Unregister-ScheduledTask($($Config.TaskName))" {
            Unregister-ScheduledTask -TaskName $Config.TaskName -Confirm:$false
        } | Out-Null
        Write-Log 'Задача автозапуска удалена' 'OK'
    } else {
        Write-Log 'Задача автозапуска не найдена' 'WARN'
    }
}

function Reset-ICS {
    Write-Log '=== Сброс классического ICS ==='
    try {
        Write-Log '-> New-Object HNetCfg.HNetShare' 'TRACE'
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $share = New-Object -ComObject HNetCfg.HNetShare
        Write-Log ("<- New-Object HNetCfg.HNetShare [{0} мс]" -f $sw.ElapsedMilliseconds) 'TRACE'
        $saved = @()
        foreach ($conn in $share.EnumEveryConnection) {
            $cfg = $share.INetSharingConfigurationForINetConnection($conn)
            if ($cfg.SharingEnabled) {
                $type = $cfg.SharingConnectionType
                $saved += [pscustomobject]@{ Cfg = $cfg; Type = $type }
                $cfg.DisableSharing()
                Write-Log ("Отключён общий доступ (type={0})" -f $type)
            }
        }
        Write-Log ("<- EnumEveryConnection [{0} мс], найдено активных: {1}" -f $sw.ElapsedMilliseconds, $saved.Count) 'TRACE'
        if ($saved.Count -eq 0) { Write-Log 'Активных ICS-подключений нет' 'WARN'; return }
        Start-Sleep -Seconds 1
        foreach ($s in ($saved | Sort-Object Type)) {   # сначала Public (0), потом Private (1)
            $s.Cfg.EnableSharing($s.Type)
            Write-Log ("Восстановлен общий доступ (type={0})" -f $s.Type) 'OK'
        }
        Write-Log 'ICS сброшен' 'OK'
    } catch {
        Write-Log ("Ошибка ICS: {0}" -f $_.Exception.Message) 'ERROR'
    }
}

function Read-Field {
    param([string]$Label, [string]$Current)
    $in = Read-Host ("  {0} [{1}]" -f $Label, $Current)
    if ([string]::IsNullOrWhiteSpace($in)) { return $Current } else { return $in.Trim() }
}

function Edit-Settings {
    Write-Host ''
    Write-Host '── Настройки (Enter — оставить текущее) ─────────' -ForegroundColor Cyan
    $script:Config.HostIP       = Read-Field 'IP хоста (шлюз для ККМ)'        $Config.HostIP
    $prefixIn = Read-Field 'Префикс подсети (бит)' $Config.Prefix
    $script:Config.Prefix      = if ($prefixIn -as [int]) { [int]$prefixIn } else { $Config.Prefix }
    $script:Config.KkmIP        = Read-Field 'IP ККМ (для ping)'             $Config.KkmIP
    $script:Config.AdapterMatch = Read-Field 'Шаблон RNDIS-адаптера (regex)' $Config.AdapterMatch
    $script:Config.NatName      = Read-Field 'Имя NAT'                       $Config.NatName
    $derived = Get-SubnetPrefix -IP $Config.HostIP -Prefix $Config.Prefix
    Write-Host ("  Подсеть будет: {0}" -f $derived) -ForegroundColor Green
    Save-Config
}

function Show-Log {
    if (Test-Path $LogPath) {
        Write-Host ("── Последние записи ($LogPath) ──") -ForegroundColor Cyan
        Get-Content $LogPath -Tail 60 | ForEach-Object {
            $color = if ($_ -match '\[ERROR\]') { 'Red' } elseif ($_ -match '\[WARN\]') { 'Yellow' } elseif ($_ -match '\[TRACE\]') { 'DarkGray' } else { 'Gray' }
            Write-Host $_ -ForegroundColor $color
        }
        Write-Host ("Полный лог: {0}" -f $LogPath) -ForegroundColor DarkGray
    } else {
        Write-Host 'Лог пуст' -ForegroundColor Yellow
    }
}
#endregion

#region ── Диагностика и устранение отвалов ──────────────────────────

# Активная схема электропитания (GUID) — для чтения USB selective suspend
function Get-ActiveScheme {
    try {
        $out = powercfg /getactivescheme
        if ("$out" -match '([0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12})') { return $Matches[1] }
    } catch {}
    return $null
}

function Test-Diag {
    Write-Host ''
    Write-Host '── Диагностика ─────────────────────────────────' -ForegroundColor Cyan
    Write-Log '=== Test-Diag: старт ===' 'TRACE'
    $script:DiagHints = @()

    function Add-Row {
        param([string]$Label, [bool]$Ok, [string]$Detail, [string]$Hint)
        $mark = if ($Ok) { ' OK ' } else { 'ПРОБ' }
        $col  = if ($Ok) { 'Green' } else { 'Red' }
        Write-Host ('  [{0}] {1,-30} {2}' -f $mark, $Label, $Detail) -ForegroundColor $col
        Write-Log ("Диагностика: [{0}] {1} — {2}" -f $(if ($Ok) {'OK'} else {'ПРОБЛЕМА'}), $Label, $Detail) 'TRACE'
        if (-not $Ok -and $Hint) { $script:DiagHints += $Hint }
    }

    # Служба WinNat
    $winnat = Invoke-Logged 'Get-Service(WinNat)' { Get-Service WinNat -ErrorAction SilentlyContinue }
    Add-Row 'Служба WinNat работает' ($winnat -and $winnat.Status -eq 'Running') `
        $(if ($winnat) { "$($winnat.Status) / $($winnat.StartType)" } else { 'нет' }) 'H'

    # Быстрый запуск (Fast Startup) — главный виновник отвалов после «Завершение работы»
    $hb = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
            -Name HiberbootEnabled -ErrorAction SilentlyContinue).HiberbootEnabled
    Add-Row 'Быстрый запуск отключён' ($hb -eq 0) `
        $(if ($hb -eq 0) { 'отключён' } else { 'ВКЛЮЧЁН (усыпляет USB)' }) 'H'

    # USB selective suspend
    $suspOk = $false; $suspTxt = 'неизвестно'
    $scheme = Get-ActiveScheme
    if ($scheme) {
        $p = "HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\$scheme\2a737441-1930-4402-8d77-b2bebba308a3\48e6b7a6-50f5-4782-a5d4-53bb8f07e226"
        $ac = (Get-ItemProperty $p -Name ACSettingIndex -ErrorAction SilentlyContinue).ACSettingIndex
        $suspOk = ($ac -eq 0)
        $suspTxt = if ($ac -eq 0) { 'отключён' } else { 'ВКЛЮЧЁН' }
    }
    Add-Row 'USB selective suspend откл.' $suspOk $suspTxt 'H'

    # RNDIS-адаптер
    $a = Get-RndisAdapter
    Add-Row 'RNDIS-адаптер найден' ($null -ne $a) `
        $(if ($a) { "$($a.Name) [$($a.Status)]" } else { 'НЕ НАЙДЕН' }) $null

    if ($a) {
        $hasIP = Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                 Where-Object IPAddress -eq $Config.HostIP
        Add-Row 'IP хоста на адаптере' ($null -ne $hasIP) `
            $(if ($hasIP) { $Config.HostIP } else { 'нет / другой' }) 'E'

        $ifc = Get-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        Add-Row 'IP статический (DHCP off)' ($ifc.Dhcp -eq 'Disabled') "$($ifc.Dhcp)" 'H'
        Add-Row 'Forwarding на адаптере' ($ifc.Forwarding -eq 'Enabled') "$($ifc.Forwarding)" 'H'

        Write-Log "-> Get-NetAdapterPowerManagement($($a.Name))" 'TRACE'
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $pm = Get-NetAdapterPowerManagement -Name $a.Name -ErrorAction Stop
            Write-Log ("<- Get-NetAdapterPowerManagement [{0} мс]" -f $sw.ElapsedMilliseconds) 'TRACE'
            Add-Row 'Питание адаптера откл.' ($pm.AllowComputerToTurnOffDevice -ne 'Enabled') `
                "$($pm.AllowComputerToTurnOffDevice)" 'H'
        } catch {
            Write-Log ("<- Get-NetAdapterPowerManagement [{0} мс]: не поддерживается адаптером (ожидаемо)" -f $sw.ElapsedMilliseconds) 'TRACE'
            Add-Row 'Питание адаптера' $true 'адаптер не поддерживает управление (ок)' $null
        }
    }

    # NAT
    $nat = Invoke-Logged "Get-NetNat($($Config.NatName))" { Get-NetNat -Name $Config.NatName -ErrorAction SilentlyContinue }
    Add-Row 'NAT создан' ($null -ne $nat) `
        $(if ($nat) { $nat.InternalIPInterfaceAddressPrefix } else { 'нет' }) 'E'

    # Автозапуск
    $task = Invoke-Logged "Get-ScheduledTask($($Config.TaskName))" { Get-ScheduledTask -TaskName $Config.TaskName -ErrorAction SilentlyContinue }
    Add-Row 'Задача автозапуска' ($null -ne $task) $(if ($task) { 'есть' } else { 'нет' }) 'T'

    # Конфликт с ICS
    $icsOn = Invoke-Logged 'HNetCfg.HNetShare(проверка ICS)' {
        $on = $false
        $sh = New-Object -ComObject HNetCfg.HNetShare
        foreach ($c in $sh.EnumEveryConnection) {
            if ($sh.INetSharingConfigurationForINetConnection($c).SharingEnabled) { $on = $true }
        }
        $on
    }
    Add-Row 'Нет конфликта с ICS' (-not $icsOn) `
        $(if ($icsOn) { 'ICS ВКЛЮЧЁН — конфликтует с WinNAT' } else { 'чисто' }) 'I'

    # Интернет на хосте и связь с ККМ
    $inet = Invoke-Logged 'Test-Connection(1.1.1.1)' { Test-Connection 1.1.1.1 -Count 2 -Quiet -ErrorAction SilentlyContinue }
    Add-Row 'Интернет на хосте' $inet $(if ($inet) { 'есть' } else { 'НЕТ' }) $null
    $kkm = Invoke-Logged "Test-Connection($($Config.KkmIP))" { Test-Connection $Config.KkmIP -Count 2 -Quiet -ErrorAction SilentlyContinue }
    Add-Row 'ККМ отвечает' $kkm $(if ($kkm) { $Config.KkmIP } else { "$($Config.KkmIP) молчит" }) $null

    Write-Host '────────────────────────────────────────────────' -ForegroundColor Cyan
    if ($script:DiagHints -contains 'H') { Write-Host '  -> Запусти [H] — устранить причины отвалов.' -ForegroundColor Yellow }
    if ($script:DiagHints -contains 'E') { Write-Host '  -> Запусти [1] — включить раздачу.' -ForegroundColor Yellow }
    if ($script:DiagHints -contains 'I') { Write-Host '  -> Отключи ICS: пункт [8].' -ForegroundColor Yellow }
    if ($script:DiagHints -contains 'T') { Write-Host '  -> Поставь автозапуск: пункт [6].' -ForegroundColor Yellow }
    if ($script:DiagHints.Count -eq 0)   { Write-Host '  Всё в порядке.' -ForegroundColor Green }
    Write-Log '=== Test-Diag: конец ===' 'TRACE'
}

function Invoke-Harden {
    Write-Log '=== Устранение причин отвалов (разово): старт ===' 'TRACE'

    # 1. Быстрый запуск off — иначе USB-драйверы не переинициализируются после выключения
    try {
        Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
            -Name HiberbootEnabled -Value 0 -Type DWord
        Write-Log 'Быстрый запуск (Fast Startup) отключён' 'OK'
    } catch { Write-Log ("Fast Startup: {0}" -f $_.Exception.Message) 'ERROR' }

    # 2. USB selective suspend off (сеть и от батареи)
    try {
        $sub = '2a737441-1930-4402-8d77-b2bebba308a3'
        $set = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
        powercfg /SETACVALUEINDEX SCHEME_CURRENT $sub $set 0 | Out-Null
        powercfg /SETDCVALUEINDEX SCHEME_CURRENT $sub $set 0 | Out-Null
        powercfg /SETACTIVE SCHEME_CURRENT | Out-Null
        Write-Log 'USB selective suspend отключён' 'OK'
    } catch { Write-Log ("USB suspend: {0}" -f $_.Exception.Message) 'ERROR' }

    # 3. Службы в Automatic
    foreach ($svc in 'WinNat', 'iphlpsvc') {
        try {
            Set-Service -Name $svc -StartupType Automatic -ErrorAction Stop
            Write-Log ("Служба {0}: Automatic" -f $svc) 'OK'
        } catch { Write-Log ("Служба {0}: {1}" -f $svc, $_.Exception.Message) 'WARN' }
    }
    try { Start-Service WinNat -ErrorAction SilentlyContinue } catch {}

    # 4. Адаптер: forwarding + отключение питания USB
    $a = Get-RndisAdapter
    if ($a) {
        try {
            Set-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -Forwarding Enabled -ErrorAction Stop
            Write-Log 'Forwarding на RNDIS-адаптере включён' 'OK'
        } catch { Write-Log ("Forwarding: {0}" -f $_.Exception.Message) 'WARN' }

        # Попытка через cmdlet
        try {
            $pm = Get-NetAdapterPowerManagement -Name $a.Name -ErrorAction Stop
            $pm.AllowComputerToTurnOffDevice = 'Disabled'
            $pm | Set-NetAdapterPowerManagement -ErrorAction Stop
            Write-Log 'Питание адаптера отключено (cmdlet)' 'OK'
        } catch {}

        # Надёжный способ: PnPCapabilities=24 в реестре класса сетевых адаптеров
        try {
            $guid = $a.InterfaceGuid
            $base = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'
            $key = Invoke-Logged 'Поиск ключа адаптера в реестре класса' {
                Get-ChildItem $base -ErrorAction SilentlyContinue | Where-Object {
                    (Get-ItemProperty $_.PSPath -Name NetCfgInstanceId -ErrorAction SilentlyContinue).NetCfgInstanceId -eq $guid
                } | Select-Object -First 1
            }
            if ($key) {
                Set-ItemProperty $key.PSPath -Name PnPCapabilities -Value 24 -Type DWord
                Write-Log 'PnPCapabilities=24 (авто-усыпление USB запрещено)' 'OK'
                Invoke-Logged "Disable-NetAdapter($($a.Name))" { Disable-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction SilentlyContinue } | Out-Null
                Start-Sleep -Seconds 2
                Invoke-Logged "Enable-NetAdapter($($a.Name))" { Enable-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction SilentlyContinue } | Out-Null
                Start-Sleep -Seconds 3
                Write-Log 'Адаптер перезапущен для применения настроек' 'OK'
            } else {
                Write-Log 'Ключ адаптера в реестре не найден — PnPCapabilities пропущен' 'WARN'
            }
        } catch { Write-Log ("PnPCapabilities: {0}" -f $_.Exception.Message) 'WARN' }
    } else {
        Write-Log 'RNDIS-адаптер не найден — питание/forwarding пропущены' 'WARN'
    }

    # 5. Заново поднять IP + NAT (после сброса адаптера IP слетает)
    Enable-Nat

    Write-Log 'Харденинг завершён. Fast Startup и USB suspend вступят в силу после перезагрузки.' 'OK'
}

#endregion

#region ── Тихий режим (автозапуск) ───────────────────────────────────
if ($Auto) {
    Write-Log '=== Автозапуск: настройка NAT ===' 'INFO'
    Invoke-Logged 'Enable-Nat(авто)' { Enable-Nat } | Out-Null
    Write-Log '=== Автозапуск: завершение ===' 'INFO'
    exit 0
}
#endregion

#region ── Меню ───────────────────────────────────────────────────────
function Show-Menu {
    Clear-Host
    Write-Host '╔════════════════════════════════════════════════╗' -ForegroundColor Cyan
    Write-Host '║      ICS / NAT менеджер для RNDIS-ККМ           ║' -ForegroundColor Cyan
    Write-Host '╚════════════════════════════════════════════════╝' -ForegroundColor Cyan
    Show-Status
    Write-Host ''
    Write-Host '  [1] Включить раздачу (NAT)'
    Write-Host '  [2] Выключить раздачу (NAT)'
    Write-Host '  [3] Сбросить / перезапустить раздачу'
    Write-Host '  [4] Проверить связь с ККМ (ping)'
    Write-Host '  [5] Выбрать сетевой адаптер вручную'
    Write-Host '  [6] Установить автозапуск при загрузке'
    Write-Host '  [7] Убрать автозапуск'
    Write-Host '  [8] Сбросить классический ICS (старый способ)' -ForegroundColor DarkGray
    Write-Host '  [9] Показать лог'
    Write-Host '  [D] Диагностика подключений' -ForegroundColor Cyan
    Write-Host '  [H] Устранить причины отвалов (разово)' -ForegroundColor Cyan
    Write-Host ("  [V] Подробный лог в консоли: {0}" -f $(if ($script:TraceToConsole) { 'ВКЛ' } else { 'выкл' })) -ForegroundColor DarkGray
    Write-Host '  [C] Настройки'
    Write-Host '  [0] Выход'
    Write-Host ''
}

do {
    Show-Menu
    $choice = (Read-Host 'Выбор').ToUpper()
    Write-Log "Выбор пункта меню: '$choice'" 'TRACE'
    switch ($choice) {
        '1' { Invoke-Logged 'Меню[1] Enable-Nat'     { Enable-Nat }     | Out-Null }
        '2' { Invoke-Logged 'Меню[2] Disable-Nat'    { Disable-Nat }    | Out-Null }
        '3' { Invoke-Logged 'Меню[3] Reset-Nat'      { Reset-Nat }      | Out-Null }
        '4' { Invoke-Logged 'Меню[4] Test-Kkm'       { Test-Kkm }       | Out-Null }
        '5' { Invoke-Logged 'Меню[5] Select-Adapter' { Select-Adapter } | Out-Null }
        '6' { Invoke-Logged 'Меню[6] Install-Task'   { Install-Task }   | Out-Null }
        '7' { Invoke-Logged 'Меню[7] Remove-Task'    { Remove-Task }    | Out-Null }
        '8' { Invoke-Logged 'Меню[8] Reset-ICS'      { Reset-ICS }      | Out-Null }
        '9' { Show-Log }
        'D' { Invoke-Logged 'Меню[D] Test-Diag'      { Test-Diag }      | Out-Null }
        'H' { Invoke-Logged 'Меню[H] Invoke-Harden'  { Invoke-Harden }  | Out-Null }
        'C' { Edit-Settings }
        'V' {
            $script:TraceToConsole = -not $script:TraceToConsole
            Write-Log ("Подробный лог в консоли: {0}" -f $(if ($script:TraceToConsole) { 'включён' } else { 'выключен' })) 'INFO'
        }
        '0' { Write-Host 'Выход.' -ForegroundColor Cyan }
        default { Write-Host 'Неверный выбор' -ForegroundColor Yellow }
    }
    if ($choice -ne '0') {
        Write-Host ''
        Read-Host 'Нажми Enter для продолжения' | Out-Null
    }
} while ($choice -ne '0')
#endregion
