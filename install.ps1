<#
.SYNOPSIS
    zbx-install for Windows - installs the official Zabbix agent MSI,
    agent-only (the Windows analog of the bash installer's --agent-only /
    macOS flow; Zabbix ships no Windows server/proxy/frontend).

.DESCRIPTION
    Downloads the self-updating "latest" Zabbix agent MSI from
    cdn.zabbix.com (the same CDN pointer the macOS module uses), verifies
    its Authenticode signature is valid and issued to Zabbix, installs it
    silently as a Windows service pointed at your Zabbix server, and
    health-checks that the service is running and listening on port 10050.

    Run from an elevated PowerShell:

        irm https://github.com/momen-f/zbx-install/releases/latest/download/install.ps1 | iex

    or, to pass parameters (iex cannot forward them):

        & ([scriptblock]::Create((irm https://github.com/momen-f/zbx-install/releases/latest/download/install.ps1))) -Server 192.0.2.10 -Yes

.PARAMETER Server
    IP/DNS of the Zabbix server the agent reports to (Server + ServerActive).
    Default 127.0.0.1 - mirrors the bash installer's --server.

.PARAMETER ZbxVersion
    Zabbix major version: 7.0 (LTS, default - matches ZBX_DEFAULT_VERSION
    in the bash installer) or 7.4.

.PARAMETER Agent2
    Install Zabbix agent 2 (Go-based) instead of the classic zabbix_agentd
    that the bash installer sets up on Linux/macOS.

.PARAMETER Uninstall
    Remove a previously installed Zabbix agent (either variant) instead of
    installing. Mirrors --uninstall.

.PARAMETER Yes
    Skip the confirmation prompt. Mirrors --yes.

.PARAMETER DryRun
    Print the plan and every action without changing anything. Mirrors
    --dry-run.

.NOTES
    Exit codes match the bash installer's conventions:
      0 ok | 2 usage/confirmation declined | 3 unsupported platform |
      4 not elevated | 5 download/verify/install failed | 6 health check failed
#>
[CmdletBinding()]
param(
    [string]$Server = '127.0.0.1',
    [ValidateSet('7.0', '7.4')]
    [string]$ZbxVersion = '7.0',
    [switch]$Agent2,
    [switch]$Uninstall,
    [switch]$Yes,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ZbxCdn = 'https://cdn.zabbix.com/zabbix/binaries/stable'

# Get-ZbxArch - map the machine arch to the token Zabbix uses in MSI names.
# Pure; the Windows analog of _macos_arch. The CDN ships Windows MSIs for
# amd64 and i386 only (verified against the latest listing, 2026-07) - no
# arm64 MSI exists, so Windows-on-ARM gets the amd64 MSI and runs the agent
# under the OS's built-in x64 emulation. 32-bit Windows is not offered.
function Get-ZbxArch {
    param([string]$Machine = $env:PROCESSOR_ARCHITECTURE)
    switch ($Machine) {
        'AMD64' { 'amd64' }
        'ARM64' { 'amd64' }
        default { throw "Zabbix ships no Windows agent for architecture '$Machine'" }
    }
}

# Get-ZbxMsiUrl - pure: the self-updating "latest" MSI URL, same CDN pointer
# shape as the macOS module's zbx_macos_agent_url.
function Get-ZbxMsiUrl {
    param(
        [Parameter(Mandatory)][string]$Major,
        [Parameter(Mandatory)][string]$Arch,
        [switch]$IsAgent2
    )
    $product = if ($IsAgent2) { 'zabbix_agent2' } else { 'zabbix_agent' }
    "$ZbxCdn/$Major/latest/$product-$Major-latest-windows-$Arch-openssl.msi"
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Test-ZbxSignature - the MSI must carry a VALID Authenticode signature whose
# subject is Zabbix (mirrors the pkgutil --check-signature gate on macOS).
function Test-ZbxSignature {
    param([Parameter(Mandatory)][string]$Path)
    $sig = Get-AuthenticodeSignature -FilePath $Path
    if ($sig.Status -ne 'Valid') {
        Write-Warning "MSI signature status: $($sig.Status)"
        return $false
    }
    if ($sig.SignerCertificate.Subject -notmatch 'Zabbix') {
        Write-Warning "MSI is signed, but not by Zabbix: $($sig.SignerCertificate.Subject)"
        return $false
    }
    $true
}

# Find-ZbxProduct - registry Uninstall entries for an installed Zabbix agent
# (either variant, both registry views). Returns objects with DisplayName +
# the msiexec product code (PSChildName).
function Find-ZbxProduct {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    Get-ItemProperty $keys -ErrorAction SilentlyContinue |
        Where-Object { ($_.PSObject.Properties['DisplayName']) -and $_.DisplayName -like 'Zabbix Agent*' }
}

function Invoke-Step {
    # DryRun-aware runner: the analog of the bash installer's run().
    param([Parameter(Mandatory)][string]$What, [Parameter(Mandatory)][scriptblock]$Action)
    if ($DryRun) { Write-Host "  + $What"; return }
    Write-Verbose $What
    & $Action
}

function Install-ZbxAgent {
    $arch = Get-ZbxArch
    $url = Get-ZbxMsiUrl -Major $ZbxVersion -Arch $arch -IsAgent2:$Agent2
    $msi = Join-Path $env:TEMP 'zbx-agent.msi'
    $log = Join-Path $env:TEMP 'zbx-agent-msi.log'
    Write-Host "Downloading $url"
    Invoke-Step "Invoke-WebRequest $url -> $msi" {
        Invoke-WebRequest -Uri $url -OutFile $msi -UseBasicParsing
    }
    if (-not $DryRun) {
        if (-not (Test-ZbxSignature -Path $msi)) {
            Write-Error -ErrorAction Continue 'MSI failed Authenticode verification - refusing to install'
            exit 5
        }
        Write-Host 'Authenticode signature verified (Zabbix)'
    }
    # Public properties of the official Zabbix agent MSIs (shared by agentd
    # and agent2): SERVER, SERVERACTIVE, HOSTNAME, LISTENPORT, ...
    $msiArgs = @(
        '/i', $msi, '/qn', '/norestart', "/l*v", $log,
        "SERVER=$Server", "SERVERACTIVE=$Server", "HOSTNAME=$env:COMPUTERNAME"
    )
    Invoke-Step "msiexec $($msiArgs -join ' ')" {
        $p = Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -PassThru
        if ($p.ExitCode -notin 0, 3010) {
            Write-Host "--- msiexec log tail ($log) ---"
            Get-Content $log -Tail 40 -ErrorAction SilentlyContinue
            Write-Error -ErrorAction Continue "msiexec failed with exit code $($p.ExitCode) - full log: $log"
            exit 5
        }
    }
    if (-not $DryRun) { Remove-Item $msi -ErrorAction SilentlyContinue }
}

function Test-ZbxHealth {
    if ($DryRun) { Write-Host '  + health: service running + port 10050 listening'; return $true }
    for ($i = 1; $i -le 15; $i++) {
        $svc = Get-Service -Name 'Zabbix Agent*' -ErrorAction SilentlyContinue |
            Where-Object Status -eq 'Running'
        $port = Get-NetTCPConnection -LocalPort 10050 -State Listen -ErrorAction SilentlyContinue
        if ($svc -and $port) { return $true }
        Start-Sleep -Seconds 1
    }
    $false
}

function Uninstall-ZbxAgent {
    $products = @(Find-ZbxProduct)
    if (-not $products) {
        Write-Host 'No Zabbix agent is installed - nothing to do.'
        return
    }
    foreach ($p in $products) {
        Invoke-Step "msiexec /x $($p.PSChildName) /qn ($($p.DisplayName))" {
            $proc = Start-Process msiexec.exe -ArgumentList @('/x', $p.PSChildName, '/qn', '/norestart') -Wait -PassThru
            if ($proc.ExitCode -notin 0, 3010) {
                Write-Error -ErrorAction Continue "uninstall of $($p.DisplayName) failed with exit code $($proc.ExitCode)"
                exit 5
            }
        }
    }
    if (-not $DryRun) {
        $left = Get-Service -Name 'Zabbix Agent*' -ErrorAction SilentlyContinue
        if ($left) {
            Write-Error -ErrorAction Continue 'a Zabbix agent service is still present after uninstall'
            exit 5
        }
    }
    Write-Host 'Removed the Zabbix Windows agent.'
}

function Show-Plan {
    $agentName = if ($Agent2) { 'Zabbix agent 2' } else { 'zabbix_agentd (classic)' }
    $action = if ($Uninstall) { 'Uninstall' } else { 'Install' }
    Write-Host ''
    Write-Host "Plan (Windows agent)" -ForegroundColor White
    Write-Host "  OS:         Windows ($env:PROCESSOR_ARCHITECTURE)"
    if ($Uninstall) {
        Write-Host "  Action:     remove any installed Zabbix agent"
    }
    else {
        Write-Host "  Install:    $agentName $ZbxVersion (signed MSI)"
        Write-Host "  Reports to: $Server"
    }
    if ($DryRun) { Write-Host '  Mode:       dry-run (no changes made)' }
    Write-Host ''
    if ($Yes) { return $true }
    if (-not [Environment]::UserInteractive) {
        Write-Error -ErrorAction Continue 'No interactive session: re-run with -Yes'
        exit 2
    }
    (Read-Host "$action`? [y/N]") -match '^[Yy]'
}

function Invoke-ZbxMain {
    if (-not $DryRun -and -not (Test-Admin)) {
        Write-Error -ErrorAction Continue 'This installer must run from an elevated (Administrator) PowerShell.'
        exit 4
    }
    try { $null = Get-ZbxArch }
    catch { Write-Error -ErrorAction Continue $_.Exception.Message; exit 3 }
    if (-not (Show-Plan)) { Write-Host 'Aborted.'; exit 2 }
    if ($Uninstall) {
        Uninstall-ZbxAgent
        return
    }
    Install-ZbxAgent
    if (Test-ZbxHealth) {
        Write-Host 'All checks passed: agent service running, listening on port 10050.' -ForegroundColor Green
    }
    else {
        Write-Error -ErrorAction Continue "Agent installed but the health check failed (service not running or port 10050 not listening). See: Get-Service 'Zabbix Agent*'"
        exit 6
    }
}

# Only auto-run outside Pester (tests dot-source this file to unit-test the
# functions - the PowerShell equivalent of the bats mprobe/dprobe pattern).
if (-not $MyInvocation.MyCommand.Path -or $MyInvocation.InvocationName -ne '.') {
    Invoke-ZbxMain
}
