$dbFile = Join-Path $PSScriptRoot "servers.json"
$presetFile = Join-Path $PSScriptRoot "active_preset.txt"

if (Test-Path $presetFile) {
    $global:CurrentActiveBlocks = Get-Content $presetFile -Raw -Encoding utf8
} else {
    $global:CurrentActiveBlocks = "NONE (All servers are open)"
}

function Get-StalcraftPools {
    if (-not (Test-Path $dbFile)) {
        Write-Host "[ERROR] File 'servers.json' not found in script directory!" -ForegroundColor Red
        Pause; return $null
    }
    try {
        $jsonContent = Get-Content $dbFile -Raw -Encoding utf8
        return (ConvertFrom-Json $jsonContent).pools
    } catch {
        Write-Host "[ERROR] Failed to read or parse 'servers.json'!" -ForegroundColor Red
        Pause; return $null
    }
}

function Show-MainMenu {
    cls
    Write-Host "===================================================" -ForegroundColor Cyan
    Write-Host "       STALCRAFT AUTOMATIC PANEL TOOL" -ForegroundColor Cyan
    Write-Host "===================================================" -ForegroundColor Cyan
    Write-Host " Active servers left open: " -NoNewline -ForegroundColor White
    Write-Host "$global:CurrentActiveBlocks" -ForegroundColor Yellow
    Write-Host "---------------------------------------------------" -ForegroundColor Cyan
    Write-Host " 1] SELECT ALLOWED REGIONS TO KEEP OPEN" -ForegroundColor Green
    Write-Host " 2] CHECK PING TO ALL REGIONS (+TOP 5)" -ForegroundColor Green
    Write-Host " 3] RESET ALL FIREWALL BLOCKS" -ForegroundColor Yellow
    Write-Host " 4] EXIT" -ForegroundColor Red
    Write-Host "===================================================" -ForegroundColor Cyan
    Write-Host ""
    $choice = Read-Host "Select menu option (1-4)"
    if ($choice -eq "1") { Invoke-BlockMode }
    elseif ($choice -eq "2") { Invoke-PingMode }
    elseif ($choice -eq "3") { Invoke-ResetMode }
    elseif ($choice -eq "4") { exit }
    else { Show-MainMenu }
}

function Invoke-BlockMode {
    cls
    $pools = Get-StalcraftPools
    if (-not $pools) { Show-MainMenu; return }
    Write-Host "===================================================" -ForegroundColor Cyan
    Write-Host "         AVAILABLE REGIONS TO PLAY ON:" -ForegroundColor Cyan
    Write-Host "===================================================" -ForegroundColor Cyan
    $menuIndex = 1; $regionMap = @{}
    foreach ($pool in $pools) {
        if ($pool.name -notin $regionMap.Values) {
            Write-Host " [$menuIndex] Region: $($pool.name) ($($pool.tunnels.Count) proxies)" -ForegroundColor Green
            $regionMap[$menuIndex] = $pool.name; $menuIndex++
        }
    }
    Write-Host "===================================================" -ForegroundColor Cyan
    Write-Host "You can select MULTIPLE numbers separated by comma (e.g. 10,12)" -ForegroundColor Yellow
    Write-Host "Or just press ENTER without entering numbers to go back." -ForegroundColor Cyan
    Write-Host ""
    $choicesInput = Read-Host "Select region numbers to KEEP OPEN"
    
    if ([string]::IsNullOrWhiteSpace($choicesInput)) { Show-MainMenu; return }

    $selectedRegions = @()
    foreach ($c in $choicesInput.Split(',')) {
        $trimmed = $c.Trim()
        if ($trimmed -match '^\d+$' -and $regionMap.ContainsKey([int]$trimmed)) { $selectedRegions += $regionMap[[int]$trimmed] }
    }
    if ($selectedRegions.Count -eq 0) { Write-Host "No valid regions selected!" -ForegroundColor Red; Start-Sleep -Seconds 1; Invoke-BlockMode; return }
    $allowedStr = $selectedRegions -join ", "
    Write-Host "`nIsolating network. ALLOWED regions: $allowedStr" -ForegroundColor Yellow
    
    Remove-NetFirewallRule -DisplayName "Stalcraft_Dynamic_Block" -ErrorAction SilentlyContinue
    Remove-NetFirewallRule -DisplayName "Block_Stalcraft_Custom" -ErrorAction SilentlyContinue
    Remove-NetFirewallRule -DisplayName "Block_Stalcraft_Subnets" -ErrorAction SilentlyContinue

    $blockedIps = @()
    $allowedIps = @()
    foreach ($pool in $pools) {
        foreach ($tunnel in $pool.tunnels) {
            $rawAddr = $tunnel.address
            $ip = $rawAddr.Split(':')
            if ($pool.name -in $selectedRegions) { $allowedIps += $ip } else { $blockedIps += $ip }
        }
    }
    $successCount = 0
    foreach ($ip in $blockedIps) {
        if ($ip -notIn $allowedIps -and ![string]::IsNullOrWhiteSpace($ip)) {
            New-NetFirewallRule -DisplayName "Stalcraft_Dynamic_Block" -Direction Outbound -Action Block -Protocol UDP -RemoteAddress $ip -Enabled True | Out-Null
            $successCount++
        }
    }
    $hiddenSubnets = @("37.19.202.0/24", "91.231.235.0/24", "151.236.115.0/24", "46.42.187.0/24")
    foreach ($subnet in $hiddenSubnets) {
        New-NetFirewallRule -DisplayName "Stalcraft_Dynamic_Block" -Direction Outbound -Action Block -Protocol UDP -RemoteAddress $subnet -Enabled True | Out-Null
    }
    
    $global:CurrentActiveBlocks = "[ $allowedStr ]"
    $global:CurrentActiveBlocks | Out-File $presetFile -Encoding utf8 -Force

    Write-Host "===================================================" -ForegroundColor Cyan
    Write-Host "[SUCCESS] Windows Firewall configured!" -ForegroundColor Green
    Write-Host " Blocked official proxies: $successCount | Open regions: $allowedStr" -ForegroundColor Gray
    Write-Host "===================================================" -ForegroundColor Cyan
    Pause; Show-MainMenu
}

function Invoke-PingMode {
    cls
    $pools = Get-StalcraftPools
    if (-not $pools) { Show-MainMenu; return }
    Write-Host "===================================================" -ForegroundColor Cyan
    Write-Host "      DIAGNOSTIC MODE: PING TEST TO ALL POOLS" -ForegroundColor Cyan
    Write-Host "===================================================" -ForegroundColor Cyan
    Write-Host "Pinging regional hubs, please wait..." -ForegroundColor Yellow
    Write-Host ""
    
    $pingResults = @()
    foreach ($pool in $pools) {
        $firstTunnel = $pool.tunnels | Select-Object -First 1
        if (-not $firstTunnel) { continue }
        
        $rawAddr = $firstTunnel.address
        $testIp = $rawAddr.Split(':')
        
        if ([string]::IsNullOrWhiteSpace($testIp)) { continue }

        $pingCmd = Test-Connection -ComputerName $testIp -Count 1 -ErrorAction SilentlyContinue
        if ($pingCmd) {
            $rtt = $pingCmd.ResponseTime
            Write-Host " Hub: $($pool.name.PadRight(20)) -> Ping: $rtt ms" -ForegroundColor Green
            $pingResults += [PSCustomObject]@{Name=$pool.name; Ping=$rtt}
        } else { 
            Write-Host " Hub: $($pool.name.PadRight(20)) -> [TIMEOUT / BLOCKED]" -ForegroundColor Red 
        }
    }
    Write-Host "`n===================================================" -ForegroundColor Cyan
    Write-Host "             TOP 5 BEST REGIONS BY PING:" -ForegroundColor Cyan
    Write-Host "===================================================" -ForegroundColor Cyan
    if ($pingResults.Count -gt 0) {
        $sorted = $pingResults | Sort-Object Ping
        $topCount = [System.Math]::Min(5, $sorted.Count)
        for ($i = 0; $i -lt $topCount; $i++) { Write-Host " $($i+1). Ping: $($sorted[$i].Ping) ms - $($sorted[$i].Name)" -ForegroundColor Green }
    } else { 
        Write-Host "[!] No data available." -ForegroundColor Red 
    }
    Write-Host "===================================================" -ForegroundColor Cyan
    Write-Host "Press any key to return to Main Menu..." -ForegroundColor Cyan
    Pause; Show-MainMenu
}

function Invoke-ResetMode {
    cls
    Write-Host "Cleaning up Windows Firewall..." -ForegroundColor Yellow
    
    Remove-NetFirewallRule -DisplayName "Stalcraft_Dynamic_Block" -ErrorAction SilentlyContinue
    Remove-NetFirewallRule -DisplayName "Block_Stalcraft_Custom" -ErrorAction SilentlyContinue
    Remove-NetFirewallRule -DisplayName "Block_Stalcraft_Subnets" -ErrorAction SilentlyContinue
    
    # Исправлено: вызываем удаление маршрутов через cmd.exe, чтобы скрыть лишний вывод без ошибок
    cmd.exe /c "route delete 37.19.202.0 >nul 2>&1"
    cmd.exe /c "route delete 91.231.235.0 >nul 2>&1"
    cmd.exe /c "route delete 151.236.115.0 >nul 2>&1"
    cmd.exe /c "route delete 146.185.199.0 >nul 2>&1"
    
    if (Test-Path $presetFile) { Remove-Item $presetFile -Force }
    $global:CurrentActiveBlocks = "NONE (All servers are open)"
    
    Write-Host "[SUCCESS] All blocks completely removed. All Stalcraft servers are open." -ForegroundColor Green
    Pause; Show-MainMenu
}

Show-MainMenu