<#
.SYNOPSIS
    Syncs GitHub Copilot CLI configuration (instructions, agents, skills, voice
    profiles, MCP servers, plugins) between machines via OneDrive.

.DESCRIPTION
    Run in -Link mode (the default) on any machine to point %USERPROFILE%\.copilot
    at the shared OneDrive copy:

      * agents, skills, my-writing-voice and copilot-instructions.md become
        symbolic links into OneDrive, so edits on any machine sync everywhere.
      * mcp-config.json is rendered from a template as a REAL file, because
        Copilot CLI rewrites it. Machine-specific paths are re-expanded.
      * Marketplaces and plugins listed in plugins.json are reinstalled.

    Run in -Export mode after adding an MCP server or plugin to capture the
    current state back into OneDrive.

    Safe to re-run. Existing local content is never deleted: it is either copied
    into OneDrive (when OneDrive has nothing yet) or set aside as a
    .backup-<timestamp> folder.

.EXAMPLE
    .\Sync-CopilotConfig.ps1
    Set up the current machine.

.EXAMPLE
    .\Sync-CopilotConfig.ps1 -WhatIf
    Show what would change without touching anything.

.EXAMPLE
    .\Sync-CopilotConfig.ps1 -Export
    Capture current MCP servers and plugins into OneDrive.
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Link')]
param(
    [Parameter(ParameterSetName = 'Export')]
    [switch] $Export,

    [Parameter(ParameterSetName = 'Link')]
    [switch] $SkipPlugins,

    [string] $ConfigRoot,

    [string] $CopilotHome = (Join-Path $env:USERPROFILE '.copilot')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Items linked live into OneDrive. mcp-config.json is deliberately absent:
# Copilot CLI rewrites it, and it holds machine-specific paths.
$LinkedDirectories = @('agents', 'skills', 'my-writing-voice')
$LinkedFiles       = @('copilot-instructions.md')

function Resolve-ConfigRoot {
    param([string] $Explicit)

    if ($Explicit) { return $Explicit }

    $oneDrive = $env:OneDriveCommercial
    if (-not $oneDrive) { $oneDrive = $env:OneDrive }
    if (-not $oneDrive) {
        throw 'Could not locate OneDrive. Sign in to OneDrive, or pass -ConfigRoot explicitly.'
    }

    Join-Path $oneDrive 'CopilotConfig'
}

function Test-IsLink {
    param([string] $Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return $false }
    [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
}

function Get-LinkTarget {
    param([string] $Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return $null }
    $item.Target | Select-Object -First 1
}

function Test-HasContent {
    param([string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    [bool](Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function New-Link {
    param(
        [string] $Path,
        [string] $Target,
        [switch] $Directory
    )

    try {
        New-Item -ItemType SymbolicLink -Path $Path -Target $Target -Force -ErrorAction Stop | Out-Null
        return 'symlink'
    }
    catch {
        if (-not $Directory) { throw }

        # Symbolic links need Developer Mode or elevation; junctions never do.
        New-Item -ItemType Junction -Path $Path -Target $Target -Force -ErrorAction Stop | Out-Null
        return 'junction'
    }
}

function Test-CanCreateFileSymlink {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        return $true
    }

    $developerMode = Get-ItemPropertyValue `
        -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' `
        -Name 'AllowDevelopmentWithoutDevLicense' `
        -ErrorAction SilentlyContinue
    [bool]$developerMode
}

function Sync-LinkedItem {
    param(
        [string] $Name,
        [string] $LocalPath,
        [string] $SharedPath,
        [switch] $Directory,
        [string] $Stamp
    )

    if (Test-IsLink $LocalPath) {
        $target = Get-LinkTarget $LocalPath
        if ($target -and ($target.TrimEnd('\') -ieq $SharedPath.TrimEnd('\'))) {
            Write-Host "  [ok]      $Name already linked" -ForegroundColor DarkGray
            return
        }

        Write-Host "  [relink]  $Name points at '$target'" -ForegroundColor Yellow
        if ($PSCmdlet.ShouldProcess($LocalPath, 'Remove stale link')) {
            # Remove-Item on a directory link would recurse into the target.
            (Get-Item -LiteralPath $LocalPath -Force).Delete()
        }
    }
    elseif (Test-Path -LiteralPath $LocalPath) {
        $sharedHasContent = if ($Directory) { Test-HasContent $SharedPath } else { Test-Path -LiteralPath $SharedPath }

        if (-not $sharedHasContent) {
            Write-Host "  [seed]    $Name -> OneDrive" -ForegroundColor Cyan
            if ($PSCmdlet.ShouldProcess($SharedPath, "Copy $Name into OneDrive")) {
                if ($Directory) {
                    New-Item -ItemType Directory -Path $SharedPath -Force | Out-Null
                    # -Path, not -LiteralPath: the trailing wildcard must expand.
                    Copy-Item -Path (Join-Path $LocalPath '*') -Destination $SharedPath -Recurse -Force

                    $copied = @(Get-ChildItem -LiteralPath $SharedPath -Recurse -File -Force)
                    $source = @(Get-ChildItem -LiteralPath $LocalPath -Recurse -File -Force)
                    if ($copied.Count -lt $source.Count) {
                        throw "Copy of '$Name' was incomplete ($($copied.Count) of $($source.Count) files). Local content left untouched."
                    }
                }
                else {
                    Copy-Item -LiteralPath $LocalPath -Destination $SharedPath -Force
                    if (-not (Test-Path -LiteralPath $SharedPath)) {
                        throw "Copy of '$Name' failed. Local content left untouched."
                    }
                }
            }
        }
        else {
            Write-Host "  [backup]  $Name (OneDrive copy wins)" -ForegroundColor Yellow
        }

        $backup = "$LocalPath.backup-$Stamp"
        if ($PSCmdlet.ShouldProcess($LocalPath, "Move aside to $backup")) {
            Move-Item -LiteralPath $LocalPath -Destination $backup -Force
        }
    }

    if ($Directory -and -not (Test-Path -LiteralPath $SharedPath)) {
        if ($PSCmdlet.ShouldProcess($SharedPath, 'Create empty shared folder')) {
            New-Item -ItemType Directory -Path $SharedPath -Force | Out-Null
        }
    }

    if (-not (Test-Path -LiteralPath $SharedPath)) {
        Write-Host "  [skip]    $Name has nothing to link" -ForegroundColor DarkGray
        return
    }

    if ($PSCmdlet.ShouldProcess($LocalPath, "Link to $SharedPath")) {
        $kind = New-Link -Path $LocalPath -Target $SharedPath -Directory:$Directory
        Write-Host "  [link]    $Name ($kind)" -ForegroundColor Green
    }
}

function ConvertTo-Template {
    param([string] $Text)

    $Text -replace [regex]::Escape(($CopilotHome -replace '\\', '\\')), '${COPILOT_HOME}' `
          -replace [regex]::Escape(($env:USERPROFILE -replace '\\', '\\')), '${USERPROFILE}'
}

function Expand-Template {
    param([string] $Text)

    $copilotHomeJson = ConvertTo-Json -InputObject $CopilotHome -Compress
    $userProfileJson = ConvertTo-Json -InputObject $env:USERPROFILE -Compress
    $copilotHomeEscaped = $copilotHomeJson.Substring(1, $copilotHomeJson.Length - 2)
    $userProfileEscaped = $userProfileJson.Substring(1, $userProfileJson.Length - 2)

    $Text = $Text.Replace('${COPILOT_HOME}', $copilotHomeEscaped)
    $Text.Replace('${USERPROFILE}', $userProfileEscaped)
}

function Get-InstalledPluginState {
    $marketplaces = @()
    $plugins      = @()

    if (-not (Get-Command copilot -ErrorAction SilentlyContinue)) {
        Write-Warning 'copilot CLI not on PATH; skipping plugin state.'
        return [pscustomobject]@{ marketplaces = @(); plugins = @(); available = $false }
    }

    $mktOutput = & copilot plugin marketplace list 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "copilot plugin marketplace list failed with exit code $LASTEXITCODE."
    }
    $mkt = $mktOutput -split "`r?`n"
    foreach ($line in $mkt) {
        # Matches: "  - windows-hivemind (URL: https://...)"
        # Local marketplaces are machine-specific paths and are never portable.
        if ($line -match '^\s*[\u2022\u25C6\*-]\s*(?<name>[\w.-]+)\s*\((?<kind>URL|GitHub):\s*(?<src>[^)]+)\)') {
            $marketplaces += [pscustomobject]@{
                name   = $Matches.name
                source = $Matches.src.Trim()
            }
        }
    }

    $listOutput = & copilot plugin list 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "copilot plugin list failed with exit code $LASTEXITCODE."
    }
    $lst = $listOutput -split "`r?`n"
    $inInstalled = $false
    foreach ($line in $lst) {
        if ($line -match '^\s*Installed plugins:') { $inInstalled = $true; continue }
        if ($line -match '^\s*(Built-in|Available) plugins:') { $inInstalled = $false; continue }
        if (-not $inInstalled) { continue }

        # Matches: "  - workiq@copilot-plugins (v1.0.0)"
        if ($line -match '^\s*[\u2022\u25C6\*-]\s*(?<id>[\w.-]+@[\w.-]+)') {
            if ($line -notmatch '\[disabled\]') { $plugins += $Matches.id }
        }
    }

    [pscustomobject]@{
        marketplaces = @($marketplaces)
        plugins      = @($plugins | Sort-Object -Unique)
        available    = $true
    }
}

# ---------------------------------------------------------------------------

$ConfigRoot = Resolve-ConfigRoot -Explicit $ConfigRoot
$mcpTemplatePath = Join-Path $ConfigRoot 'mcp-config.template.json'
$pluginsPath     = Join-Path $ConfigRoot 'plugins.json'
$mcpLocalPath    = Join-Path $CopilotHome 'mcp-config.json'

Write-Host ''
Write-Host 'Copilot config sync' -ForegroundColor White
Write-Host "  shared : $ConfigRoot"
Write-Host "  local  : $CopilotHome"
Write-Host ''

if (-not (Test-Path -LiteralPath $CopilotHome)) {
    # Copilot CLI creates this on first launch, but linking beforehand is fine
    # and lets a fresh machine be configured in a single pass.
    Write-Host "  note   : creating $CopilotHome (Copilot CLI has not run yet)" -ForegroundColor DarkGray
    if ($PSCmdlet.ShouldProcess($CopilotHome, 'Create Copilot home')) {
        New-Item -ItemType Directory -Path $CopilotHome -Force | Out-Null
    }
}

if (-not $Export -and $LinkedFiles.Count -gt 0 -and -not (Test-CanCreateFileSymlink)) {
    throw 'Creating copilot-instructions.md as a symbolic link requires Developer Mode or an elevated PowerShell session. Enable Developer Mode and re-run this script.'
}

if ($Export) {
    Write-Host 'Exporting MCP servers and plugins to OneDrive...' -ForegroundColor White

    if (-not (Test-Path -LiteralPath $ConfigRoot)) {
        if ($PSCmdlet.ShouldProcess($ConfigRoot, 'Create shared folder')) {
            New-Item -ItemType Directory -Path $ConfigRoot -Force | Out-Null
        }
    }

    if (Test-Path -LiteralPath $mcpLocalPath) {
        $templated = ConvertTo-Template (Get-Content -LiteralPath $mcpLocalPath -Raw)
        if ($PSCmdlet.ShouldProcess($mcpTemplatePath, 'Write MCP template')) {
            Set-Content -LiteralPath $mcpTemplatePath -Value $templated -Encoding UTF8
        }
        Write-Host '  [export]  mcp-config.template.json' -ForegroundColor Green
    }
    else {
        Write-Host '  [skip]    no local mcp-config.json' -ForegroundColor DarkGray
    }

    $state = Get-InstalledPluginState
    if (-not $state.available) {
        Write-Warning 'Plugin state is unavailable; preserving the existing plugins.json.'
    }
    else {
        if ($PSCmdlet.ShouldProcess($pluginsPath, 'Write plugins.json')) {
            $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $pluginsPath -Encoding UTF8
        }
        Write-Host "  [export]  plugins.json ($($state.plugins.Count) plugins, $($state.marketplaces.Count) marketplaces)" -ForegroundColor Green
    }

    Write-Host ''
    Write-Host 'Export complete.' -ForegroundColor Green
    return
}

# --- Link mode -------------------------------------------------------------

if (-not (Test-Path -LiteralPath $ConfigRoot)) {
    if ($PSCmdlet.ShouldProcess($ConfigRoot, 'Create shared folder')) {
        New-Item -ItemType Directory -Path $ConfigRoot -Force | Out-Null
    }
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

Write-Host 'Linking instructions, agents, skills and voice profiles...' -ForegroundColor White
foreach ($name in $LinkedDirectories) {
    Sync-LinkedItem -Name $name `
                    -LocalPath (Join-Path $CopilotHome $name) `
                    -SharedPath (Join-Path $ConfigRoot $name) `
                    -Directory -Stamp $stamp
}
foreach ($name in $LinkedFiles) {
    Sync-LinkedItem -Name $name `
                    -LocalPath (Join-Path $CopilotHome $name) `
                    -SharedPath (Join-Path $ConfigRoot $name) `
                    -Stamp $stamp
}

Write-Host ''
Write-Host 'Restoring MCP servers...' -ForegroundColor White
if (Test-Path -LiteralPath $mcpTemplatePath) {
    $rendered = Expand-Template (Get-Content -LiteralPath $mcpTemplatePath -Raw)

    if ((Test-Path -LiteralPath $mcpLocalPath) -and
        ((Get-Content -LiteralPath $mcpLocalPath -Raw) -ne $rendered)) {
        if ($PSCmdlet.ShouldProcess($mcpLocalPath, 'Back up existing mcp-config.json')) {
            Copy-Item -LiteralPath $mcpLocalPath -Destination "$mcpLocalPath.backup-$stamp" -Force
        }
    }

    if ($PSCmdlet.ShouldProcess($mcpLocalPath, 'Write mcp-config.json')) {
        Set-Content -LiteralPath $mcpLocalPath -Value $rendered -Encoding UTF8
    }
    Write-Host '  [write]   mcp-config.json' -ForegroundColor Green
}
else {
    Write-Host '  [skip]    no mcp-config.template.json yet (run -Export first)' -ForegroundColor DarkGray
}

if ($SkipPlugins) {
    Write-Host ''
    Write-Host 'Skipping plugins (-SkipPlugins).' -ForegroundColor DarkGray
}
elseif (Test-Path -LiteralPath $pluginsPath) {
    Write-Host ''
    Write-Host 'Restoring marketplaces and plugins...' -ForegroundColor White

    $desired = Get-Content -LiteralPath $pluginsPath -Raw | ConvertFrom-Json
    $current = Get-InstalledPluginState

    if (-not $current.available) {
        Write-Warning 'Skipping plugin restore: copilot CLI not found on PATH.'
        Write-Warning 'Open a new terminal after setup finishes and re-run this script.'
    }
    else {

    foreach ($m in $desired.marketplaces) {
        if ($current.marketplaces.name -contains $m.name) {
            Write-Host "  [ok]      marketplace $($m.name)" -ForegroundColor DarkGray
            continue
        }
        if ($PSCmdlet.ShouldProcess($m.name, 'Add marketplace')) {
            & copilot plugin marketplace add $m.source
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "  Could not add marketplace '$($m.name)' from $($m.source)"
                continue
            }
        }
        Write-Host "  [add]     marketplace $($m.name)" -ForegroundColor Green
    }

    foreach ($p in $desired.plugins) {
        if ($current.plugins -contains $p) {
            Write-Host "  [ok]      $p" -ForegroundColor DarkGray
            continue
        }
        if ($PSCmdlet.ShouldProcess($p, 'Install plugin')) {
            & copilot plugin install $p
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "  Could not install plugin '$p'"
                continue
            }
        }
        Write-Host "  [install] $p" -ForegroundColor Green
    }
    } # end if ($current.available)
}
else {
    Write-Host ''
    Write-Host 'No plugins.json yet (run -Export first).' -ForegroundColor DarkGray
}

Write-Host ''
Write-Host 'Done. Restart Copilot CLI to pick up the changes.' -ForegroundColor Green
Write-Host ''
