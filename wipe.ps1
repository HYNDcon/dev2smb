# wipe.ps1
# 强制清除系统中所有带有 config.psd1 中指定 tag 的资源

$RootDir = $PSScriptRoot
$ConfigPath = Join-Path $RootDir 'config.psd1'

# 1. 提权检查
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Write-Host "[!] dev2smb wipe script requires Administrator" -ForegroundColor Red
  Read-Host "[>] press [ENTER] to exit ..."; exit 1
}

# 2. 读取配置（只取 tag 和 prefix，不关心 devices）
if (-not (Test-Path $ConfigPath)) {
  Write-Host "[!] config.psd1 not found at $ConfigPath" -ForegroundColor Red
  Read-Host "[>] press [ENTER] to exit ..."; exit 1
}

try {
  $raw = Import-PowerShellDataFile -Path $ConfigPath -ErrorAction Stop
  $Tag = ([string]$raw.tag).Trim()
  $Prefix = ([string]$raw.prefix).Trim()
  if ([string]::IsNullOrWhiteSpace($Tag)) { throw "tag is empty" }
}
catch {
  Write-Host "[!] failed to read config: $($_.Exception.Message)" -ForegroundColor Red
  Read-Host "[>] press [ENTER] to exit ..."; exit 1
}

Write-Host "[~] scaning for resources tagged $Tag ..." -ForegroundColor DarkGray -NoNewline
$escapedTag = [regex]::Escape($Tag)
$TaggedAcc = @(Get-LocalUser      | Where-Object { $_.Description -match $escapedTag })
$TaggedSmb = @(Get-SmbShare       | Where-Object { $_.Description -match $escapedTag })
$TaggedFw = @(Get-NetFirewallRule | Where-Object { $_.Description -match $escapedTag })
Write-Host " done" -ForegroundColor Green

# 3. 汇总要删除的 ID
$AllIds = @{}
foreach ($a in $TaggedAcc) { $AllIds[$a.Name] = $true }
foreach ($s in $TaggedSmb) { $AllIds[$s.Name] = $true }
foreach ($f in $TaggedFw) { $AllIds[$f.Name] = $true }

if ($AllIds.Count -eq 0) {
  Write-Host "`n[+] no tagged resources found. system is clean." -ForegroundColor Green
  Read-Host "[>] press [ENTER] to exit ..."; exit 0
}

$AccById = @{}
foreach ($a in $TaggedAcc) { $AccById[$a.Name] = $a }
$SmbById = @{}
foreach ($s in $TaggedSmb) { $SmbById[$s.Name] = $s }
$FwById = @{}
foreach ($f in $TaggedFw) { $FwById[$f.Name] = $f }

foreach ($id in ($AllIds.Keys | Sort-Object)) {
  Write-Host "`n  $id" -ForegroundColor White
  if ($AccById.ContainsKey($id)) {
    $a = $AccById[$id]
    Write-Host ("    [-] acc {0}" -f $a.Description) -ForegroundColor DarkGray
  }
  if ($SmbById.ContainsKey($id)) {
    $s = $SmbById[$id]
    Write-Host ("    [-] smb {0} {1}" -f $s.Description, $s.Path) -ForegroundColor DarkGray
  }
  if ($FwById.ContainsKey($id)) {
    $f = $FwById[$id]
    $addr = (Get-NetFirewallRule -Name $f.Name -ErrorAction SilentlyContinue | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue).RemoteAddress
    Write-Host ("    [-] fw  {0} {1}" -f $f.Description, $addr) -ForegroundColor DarkGray
  }
}

# 4. 危险警告与确认
Write-Host "`n[!] DESTRUCTIVE: found $($AllIds.Count) tagged entries." -ForegroundColor Yellow
Write-Host "    ALL resources with tag '$Tag' will be WIPED (namespace: $Prefix-*)." -ForegroundColor blue
Write-Host "[>] type 'WIPE' to confirm: " -ForegroundColor Yellow -NoNewline
$Action = Read-Host

if ($Action.Trim().ToUpper() -ne "WIPE") {
  Write-Host "`n[x] aborted. no changes made." -ForegroundColor White
  Read-Host "[>] press [ENTER] to exit ..."; exit 1
}

# 5. 执行清理
Write-Host "`n[#] wiping tagged entries ..." -ForegroundColor Cyan
foreach ($id in ($AllIds.Keys | Sort-Object)) {
  Write-Host "`n  $id" -ForegroundColor White

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
    $addr = (Get-NetFirewallRule -Name $f.Name -ErrorAction SilentlyContinue | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue).RemoteAddress
    Remove-NetFirewallRule -Name $f.Name -ErrorAction SilentlyContinue
    Write-Host ("    [-] fw {0} {1}" -f $f.Description, $addr) -ForegroundColor DarkGray
  }
}

Write-Host "`n[v] all tagged resources wiped." -ForegroundColor Green
Read-Host "[>] press [ENTER] to exit ..."