#Requires -Version 5.1

# dev2smb/dev2smb.ps1

$logo = @(
  "██████╗ ███████╗██╗   ██╗██████╗ ███████╗███╗   ███╗██████╗" ,
  "██╔══██╗██╔════╝██║   ██║╚════██╗██╔════╝████╗ ████║██╔══██╗",
  "██║  ██║█████╗  ██║   ██║ █████╔╝███████╗██╔████╔██║██████╔╝",
  "██║  ██║██╔══╝  ╚██╗ ██╔╝██╔═══╝ ╚════██║██║╚██╔╝██║██╔══██╗",
  "██████╔╝███████╗ ╚████╔╝ ███████╗███████║██║ ╚═╝ ██║██████╔╝",
  "╚═════╝ ╚══════╝  ╚═══╝  ╚══════╝╚══════╝╚═╝     ╚═╝╚═════╝ "
)
$colors = @("White", "White", "Gray", "Gray", "DarkGray", "DarkGray")
Write-Host ""
for ($i = 0; $i -lt $logo.Count; $i++) {
  Write-Host $logo[$i] -ForegroundColor $colors[$i]
}
Write-Host "             >> Automate SMB shares for your devices <<" -ForegroundColor DarkGray
Write-Host ""

$RootDir = $PSScriptRoot
$ScriptPath = $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $RootDir 'config.psd1'

# Ensure running as administrator
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Write-Host "`n[*] dev2smb requires Administrator" -ForegroundColor Yellow
  Write-Host "`n[>] Press [ENTER] to escalate ..." -ForegroundColor Yellow
  Read-Host
 
  if (Get-Command wt.exe -ErrorAction SilentlyContinue) {
    Start-Process wt.exe -ArgumentList "-p `"Windows PowerShell`" powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`"" -Verb RunAs
  }
  else {
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`"" -Verb RunAs
  }
  Exit
}

# function
function Read-Cfg {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$RootDir
  )
  if (-not (Test-Path $Path)) { throw "cfg not found: $Path" }
  try { $raw = Import-PowerShellDataFile -Path $Path -ErrorAction Stop }
  catch { throw "failed to parse cfg: $($_.Exception.Message)" }

  $prefix = ([string]$raw.prefix).Trim()
  if ([string]::IsNullOrWhiteSpace($raw.prefix)) { throw "cfg prefix is empty" }
  if ($prefix -notmatch '^[a-z0-9._-]{1,3}$') { throw "cfg prefix: ^[a-z0-9._-]{1,3}$" }

  $tag = ([string]$raw.tag).Trim()
  if ([string]::IsNullOrWhiteSpace($raw.tag)) { throw "cfg tag is empty" }
  if ($tag -notmatch '^\[[a-z0-9._-]+\]$') { throw "cfg tag: [lowercase], e.g. '[dev2smb]'" }

  $targets = @()
  $seenSuffixes = @{}
  if (-not $raw.devices -or @($raw.devices).Count -eq 0) { throw "cfg devices is empty" }
  foreach ($m in @($raw.devices)) {
    foreach ($k in @('suffix', 'ip', 'pw')) {
      if (-not $m.ContainsKey($k) -or [string]::IsNullOrWhiteSpace([string]$m[$k])) {
        throw "device entry empty '$k'"
      }
    }
    $suffix = [string]$m.suffix
    if ($suffix -notmatch '^[a-z0-9._-]{1,16}$') { throw "device suffix: ^[a-z0-9._-]{1,16}$" }
    if ($seenSuffixes.ContainsKey($suffix)) { throw "duplicate device suffix: '$suffix'" }
    $seenSuffixes[$suffix] = $true
    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse([string]$m.ip, [ref]$parsed)) {
      throw "device '$suffix' has invalid ip: '$($m.ip)'"
    }
    $targets += [PSCustomObject]@{
      Suffix = $suffix
      Id     = "$prefix-$suffix"
      Ip     = [string]$m.ip
      Pw     = [string]$m.pw
      Dir    = Join-Path $RootDir $suffix
    }
  }
  [PSCustomObject]@{ Prefix = $prefix; Tag = $tag; Targets = $targets }
}

Write-Host ("{0,-40}" -f "[~] loading config ...") -ForegroundColor DarkGray -NoNewline
try {
  $cfg = Read-Cfg -Path $ConfigPath -RootDir $RootDir
  $Prefix = $cfg.Prefix
  $Tag = $cfg.Tag
  $Targets = $cfg.Targets
  Write-Host " done" -ForegroundColor Green
}
catch {
  Write-Host " failed" -ForegroundColor Red
  Write-Host "`n[!] config error: $($_.Exception.Message)" -ForegroundColor Red
  Read-Host "[>] press [ENTER] to exit ..."; exit 1
}

Write-Host ("{0,-40}" -f "[~] checking namespace conflicts ...") -ForegroundColor DarkGray -NoNewline
$Conflicts = @()
$prefixLike = "$Prefix-*"
$escapedTag = [regex]::Escape($Tag)
foreach ($a in Get-LocalUser) {
  if ($a.Name -like $prefixLike -and $a.Description -notmatch $escapedTag) {
    $Conflicts += [PSCustomObject]@{ Type = 'acc'; Name = $a.Name }
  }
}
foreach ($s in Get-SmbShare) {
  if ($s.Name -like $prefixLike -and $s.Description -notmatch $escapedTag) {
    $Conflicts += [PSCustomObject]@{ Type = 'smb'; Name = $s.Name }
  }
}
foreach ($f in Get-NetFirewallRule) {
  if ($f.Name -like $prefixLike -and $f.Description -notmatch $escapedTag) {
    $Conflicts += [PSCustomObject]@{ Type = 'fw'; Name = $f.Name }
  }
}
Write-Host " done" -ForegroundColor Green

Write-Host ("{0,-40}" -f "[~] scanning system tagged entries ...") -ForegroundColor DarkGray -NoNewline
$TaggedAcc = @(Get-LocalUser      | Where-Object { $_.Description -match [regex]::Escape($Tag) })
$TaggedSmb = @(Get-SmbShare       | Where-Object { $_.Description -match [regex]::Escape($Tag) })
$TaggedFw = @(Get-NetFirewallRule | Where-Object { $_.Description -match [regex]::Escape($Tag) })
$AccById = @{}
foreach ($a in $TaggedAcc) { $AccById[$a.Name] = $a }
$SmbById = @{}
foreach ($s in $TaggedSmb) { $SmbById[$s.Name] = $s }
$FwById = @{}
foreach ($f in $TaggedFw) { $FwById[$f.Name] = $f }
$AllIds = @{}
foreach ($id in $AccById.Keys) { $AllIds[$id] = $true }
foreach ($id in $SmbById.Keys) { $AllIds[$id] = $true }
foreach ($id in $FwById.Keys) { $AllIds[$id] = $true }
Write-Host " done" -ForegroundColor Green

# cfg - detail
Write-Host "`n[#] cfg - detail" -ForegroundColor White
if ($Targets.Count -eq 0) {
  Write-Host "  (none)" -ForegroundColor DarkCyan
}
else {
  foreach ($t in $Targets) {
    Write-Host "`n  $($t.Id)" -ForegroundColor Cyan
    Write-Host ("    acc {0}" -f $Tag) -ForegroundColor DarkCyan
    Write-Host ("    smb {0} {1}" -f $Tag, $t.Dir) -ForegroundColor DarkCyan
    Write-Host ("    fw  {0} {1}" -f $Tag, $t.Ip) -ForegroundColor DarkCyan
  }
  Write-Host ""
}

# system tagged - detail
Write-Host "`n[#] system tagged - detail" -ForegroundColor White
if ($AllIds.Count -eq 0) {
  Write-Host "  (none)" -ForegroundColor DarkGray
}
else {
  foreach ($id in ($AllIds.Keys | Sort-Object)) {
    $a = $AccById[$id]
    $s = $SmbById[$id]
    $f = $FwById[$id]

    Write-Host "`n  $id" -ForegroundColor Gray
    if ($a) { Write-Host ("    acc {0}" -f $a.Description) -ForegroundColor DarkGray }
    else { Write-Host "    acc -" -ForegroundColor DarkGray }
    if ($s) { Write-Host ("    smb {0} {1}" -f $s.Description, $s.Path) -ForegroundColor DarkGray }
    else { Write-Host "    smb -" -ForegroundColor DarkGray }
    if ($f) {
      $addr = ($f | Get-NetFirewallAddressFilter).RemoteAddress
      Write-Host ("    fw  {0} {1}" -f $f.Description, $addr) -ForegroundColor DarkGray
    }
    else { Write-Host "    fw  -" -ForegroundColor DarkGray }
  }
  Write-Host ""
}

# system tagged - brief
Write-Host "`n[#] system tagged — brief" -ForegroundColor White
if ($AllIds.Count -eq 0) {
  Write-Host "  (none)" -ForegroundColor DarkGray
}
else {
  foreach ($id in ($AllIds.Keys | Sort-Object)) {
    $acc = if ($AccById.ContainsKey($id)) { 'acc' } else { '-' }
    $smb = if ($SmbById.ContainsKey($id)) { 'smb' } else { '-' }
    $fw = if ($FwById.ContainsKey($id)) { 'fw' } else { '-' }
    Write-Host ("  {0,-20} {1,-4} {2,-4} {3,-4}" -f $id, $acc, $smb, $fw) -ForegroundColor DarkGray
  }
}

# system tagged - psd1
Write-Host "`n[#] system tagged — psd1" -ForegroundColor Cyan
if ($AllIds.Count -eq 0) {
  Write-Host "  devices = @()" -ForegroundColor White
}
else {
  $exportLines = @()
  $exportLines += "@{"
  $exportLines += "  prefix  = '$Prefix'"
  $exportLines += "  tag     = '$Tag'"
  $exportLines += "  devices = @("
  foreach ($id in ($AllIds.Keys | Sort-Object)) {
    $f = $FwById[$id]
    if ($id.StartsWith("$Prefix-")) { $suffix = $id.Substring($Prefix.Length + 1) } else { $suffix = $id }
    $ip = if ($f) { ($f | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue).RemoteAddress } else { '?' }
    $exportLines += "    @{ suffix = '$suffix'; ip = '$ip'; pw = 'CHANGE_ME' }"
  }
  $exportLines += "  )"
  $exportLines += "}"

  foreach ($line in $exportLines) {
    Write-Host "  $line" -ForegroundColor White
  }
  Write-Host "  [h] pw is not recoverable — replace 'CHANGE_ME' manually" -ForegroundColor Blue

  $backupFile = Join-Path $RootDir ("config.psd1.{0:yyyyMMdd-HHmmss}.snapshot" -f (Get-Date))
  $exportLines | Out-File -FilePath $backupFile -Encoding utf8
  Write-Host "  [+] saved to: $backupFile" -ForegroundColor Green
}

# conflicts
if ($Conflicts.Count -gt 0) {
  Write-Host "`n[!] coincidence: external conflict(s) in namespace '$Prefix-*'" -ForegroundColor Red
  Write-Host "[#] exist in system, NOT tagged '$Tag':" -ForegroundColor Red
  foreach ($c in $Conflicts) {
    Write-Host ("    {0,-20} {1,-4}" -f $c.Name, $c.Type) -ForegroundColor DarkRed
  }
  Write-Host "    [h] change 'prefix' in cfg to avoid collision" -ForegroundColor Blue
  Read-Host "[>] press [ENTER] to exit ..."; exit 1
}

if ($AllIds.Count -eq 0) {
  Write-Host "`n[+] system is clean. will create all entries from cfg." -ForegroundColor Green
}
else {
  Write-Host "`n[*] DESTRUCTIVE: ALL system tagged $Tag will be WIPED and rebuild" -ForegroundColor Yellow
  Write-Host "[h] check 'system tagged — detail' and confirm every entry carries '$Tag'" -ForegroundColor Blue
}
Write-Host "[>] type 'COMMIT' to commit: " -ForegroundColor Yellow -NoNewline
$Action = Read-Host
if ($Action.Trim().ToUpper() -ne "COMMIT") {
  Write-Host "[x] aborted. no changes made" -ForegroundColor White
  Read-Host "[>] press [ENTER] to exit ..."; exit 1
}

# wiping tagged entries
Write-Host "`n[#] wiping tagged entries ..." -ForegroundColor White
foreach ($id in ($AllIds.Keys | Sort-Object)) {
  Write-Host "`n  $id" -ForegroundColor Gray
  if ($AccById.ContainsKey($id)) {
    $a = $AccById[$id]
    Remove-LocalUser -Name $a.Name -ErrorAction SilentlyContinue
    Write-Host ("    [-] acc {0}" -f $a.Description) -ForegroundColor DarkGray
  }
  if ($SmbById.ContainsKey($id)) {
    $s = $SmbById[$id]
    Remove-SmbShare -Name $s.Name -Force -ErrorAction SilentlyContinue
    Write-Host ("    [-] smb {0} {1}" -f $s.Description, $s.Path) -ForegroundColor DarkGray
  }
  if ($FwById.ContainsKey($id)) {
    $f = $FwById[$id]
    $addr = ($f | Get-NetFirewallAddressFilter).RemoteAddress
    Remove-NetFirewallRule -Name $f.Name -ErrorAction SilentlyContinue
    Write-Host ("    [-] fw {0} {1}" -f $f.Description, $addr) -ForegroundColor DarkGray
  }
}

# rebuild from cfg
Write-Host "`n[#] rebuilding from cfg ..." -ForegroundColor White
foreach ($t in $Targets) {
  try {
    Write-Host "`n  $($t.Id)" -ForegroundColor Cyan

    # dir
    if (-not (Test-Path $t.Dir)) {
      New-Item -ItemType Directory -Path $t.Dir -Force | Out-Null
      Write-Host ("    [+] dir  {0}" -f $t.Dir) -ForegroundColor DarkCyan
    }

    # acc
    $SecurePw = ConvertTo-SecureString $t.Pw -AsPlainText -Force
    New-LocalUser -Name $t.Id -Password $SecurePw -Description $Tag -PasswordNeverExpires -ErrorAction Stop | Out-Null
    Write-Host ("    [+] acc  {0}" -f $Tag) -ForegroundColor DarkCyan

    # ntfs
    $Acl = Get-Acl -Path $t.Dir
    $Rule = New-Object System.Security.AccessControl.FileSystemAccessRule($t.Id, "Modify", "ContainerInherit,ObjectInherit", "None", "Allow")
    $Acl.SetAccessRule($Rule) | Out-Null
    $Acl | Set-Acl -Path $t.Dir
    Write-Host ("    [+] ntfs {0} -> {1}" -f $Tag, $t.Id) -ForegroundColor DarkCyan

    # smb
    New-SmbShare -Name $t.Id -Path $t.Dir -ChangeAccess $t.Id -Description $Tag -ErrorAction Stop | Out-Null
    Write-Host ("    [+] smb  {0} {1}" -f $Tag, $t.Dir) -ForegroundColor DarkCyan

    # fw
    New-NetFirewallRule -Name $t.Id -DisplayName $t.Id -Description $Tag `
      -Direction Inbound -Protocol TCP -LocalPort 445 -RemoteAddress $t.Ip `
      -Action Allow -Profile Private, Domain -ErrorAction Stop | Out-Null
    Write-Host ("    [+] fw   {0} {1}" -f $Tag, $t.Ip) -ForegroundColor DarkCyan
  }
  catch {
    Write-Host "`n[!] FAILED to deploy [$($t.Id)]: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "[h] system may be in partial state; rerun script to converge" -ForegroundColor Blue
    Read-Host "[>] press [ENTER] to exit ..."; exit 1
  }
}

Write-Host "`n[#] dev2smb rebuild complete" -ForegroundColor Green
Read-Host "[>] press [ENTER] to exit ..."