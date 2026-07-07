#!/usr/bin/env pwsh
# LLaMesa — Windows PowerShell Client
# local inference control plane · v0.2
# License: MIT

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Colors ────────────────────────────────────────────────────────────────
$teal   = "`e[38;2;93;202;165m"    # #5DCAA5 — LL, M, section headers, online dot
$amber  = "`e[38;2;239;159;39m"   # #EF9F27 — a, esa, tok/s highlight
$purple = "`e[38;2;127;119;221m"  # #7F77DD — RAM bar
$blue   = "`e[38;2;55;138;221m"   # #378ADD — VRAM bar
$red    = "`e[38;2;226;75;74m"    # #E24B4A — health warnings
$gray   = "`e[38;2;68;68;65m"     # #444441 — hints
$dim    = "`e[38;2;42;42;42m"     # dim separators
$white  = "`e[38;2;224;224;224m"  # #E0E0E0 — primary text
$cyan   = "`e[38;2;55;200;221m"   # accent
$green  = "`e[38;2;93;202;165m"   # alias for teal
$reset  = "`e[0m"

# ── Config ────────────────────────────────────────────────────────────────
$Script:LLAMESA_DIR    = Join-Path $env:USERPROFILE ".llamesa"
$Script:CONFIG_FILE    = Join-Path $Script:LLAMESA_DIR "config.json"
$Script:Config         = $null
$Script:ActiveServer   = $null
$Script:CurrentView        = "menu"  # menu, chat, logs
$Script:ChatHistory        = @()
$Script:RefreshTimer       = $null
$Script:LastTokS           = $null   # updated after each /chat response; shown in header badge
$Script:LastStatusRefresh  = $null   # tracks when stat cards were last fetched
$Script:GpuStatus         = $null   # parsed GPU status array from --gpu all

# ── JSON Helpers ──────────────────────────────────────────────────────────

function ConvertFrom-InlineJson {
    param([string]$text)
    try {
        return $text | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Warning "Failed to parse JSON: $_"
        return $null
    }
}

# ── Config Functions ──────────────────────────────────────────────────────

function Read-Config {
    if (-not (Test-Path $Script:CONFIG_FILE)) {
        Run-SetupWizard
    }

    try {
        $Script:Config = Get-Content $Script:CONFIG_FILE -Raw | ConvertFrom-Json
        $serverName = $Script:Config.active_server
        if ($serverName -and $Script:Config.servers -and $Script:Config.servers.PSObject.Properties[$serverName]) {
            $Script:ActiveServer = $Script:Config.servers.$serverName
            $Script:ActiveServerName = $serverName
        }
    } catch {
        Write-Error "Failed to read config: $_"
        exit 1
    }
}

function Save-Config {
    if (-not (Test-Path $Script:LLAMESA_DIR)) {
        New-Item -ItemType Directory -Force -Path $Script:LLAMESA_DIR | Out-Null
    }
    $Script:Config | ConvertTo-Json -Depth 5 | Set-Content $Script:CONFIG_FILE
}

# ── Setup Wizard ──────────────────────────────────────────────────────────

function Run-SetupWizard {
    Write-Host ""
    Write-Host ("{0}LLaMesa Windows Setup{1}" -f $teal, $reset)
    Write-Host ("{0}===================={1}" -f $dim, $reset)
    Write-Host ""

    # Ensure directory exists
    if (-not (Test-Path $Script:LLAMESA_DIR)) {
        New-Item -ItemType Directory -Force -Path $Script:LLAMESA_DIR | Out-Null
    }

    $serverName = Read-Host "Server nickname (e.g., gaming-pc)"
    $hostAddr   = Read-Host "Server IP or hostname"
    $sshUser    = Read-Host "SSH username"
    $port       = Read-Host "LLaMesa server port [1234]"
    if (-not $port) { $port = "1234" }

    # Test SSH
    Write-Host ""
    Write-Host ("{0}Testing SSH connection...{1}" -f $cyan, $reset)

    try {
        $test = ssh -o BatchMode=yes -o ConnectTimeout=5 "${sshUser}@${hostAddr}" "echo 'SSH OK'" 2>&1
        if ($test -match "SSH OK") {
            Write-Host ("{0}✓ SSH connection successful{1}" -f $green, $reset)
        } else {
            Write-Host ("{0}⚠ SSH test returned: {1}{2}" -f $amber, $test, $reset)
            Write-Host ("{0}You may need to set up SSH keys. See docs/windows-setup.md{1}" -f $amber, $reset)
        }
    } catch {
        Write-Host ("{0}⚠ Could not test SSH: {1}{2}" -f $amber, $_.Exception.Message, $reset)
    }

    # Build config
    $serverConfig = [PSCustomObject]@{
        host         = $hostAddr
        ssh_user     = $sshUser
        port         = [int]$port
        llamesa_path = "~/.llamesa/llamesa.sh"
    }

    $config = [PSCustomObject]@{
        servers       = @{ $serverName = $serverConfig }
        active_server = $serverName
    }

    $Script:Config = $config
    Save-Config
    Write-Host ""
    Write-Host ("{0}✓ Config saved to {1}{2}" -f $green, $Script:CONFIG_FILE, $reset)
    Read-Config
}

# ── SSH Helper ────────────────────────────────────────────────────────────

function Invoke-ServerCommand {
    param(
        [string]$command,
        [switch]$raw
    )

    if (-not $Script:ActiveServer) {
        Write-Error "No active server configured."
        return $null
    }

    $sshUser = $Script:ActiveServer.ssh_user
    $sshHost = $Script:ActiveServer.host
    $llamesaPath = $Script:ActiveServer.llamesa_path

    $fullCommand = "bash ${llamesaPath} ${command}"

    try {
        $result = ssh -o BatchMode=yes -o ConnectTimeout=5 "${sshUser}@${sshHost}" $fullCommand 2>$null

        if ($LASTEXITCODE -ne 0 -and -not $raw) {
            Write-Warning "SSH command failed (exit code: $LASTEXITCODE)"
        }

        return $result
    } catch {
        Write-Error "SSH failed: $_"
        return $null
    }
}

function Test-ServerConnection {
    try {
        $sshUser = $Script:ActiveServer.ssh_user
        $sshHost = $Script:ActiveServer.host
        $result = ssh -o BatchMode=yes -o ConnectTimeout=5 "${sshUser}@${sshHost}" "echo ok" 2>&1
        return $result -match "ok"
    } catch {
        return $false
    }
}

# ── Status ────────────────────────────────────────────────────────────────

function Get-ServerStatus {
    $raw = Invoke-ServerCommand "status --gpu all" -raw
    if (-not $raw) { return $null }

    try {
        # Find the first line starting with [ and collect from there — skips any [INFO] prefix lines
        $jsonStartIndex = -1
        for ($i = 0; $i -lt $raw.Count; $i++) {
            if ($raw[$i] -match '^\s*[\[{]' -and $raw[$i] -notmatch '^\s*\[(INFO|WARN|ERROR)\]') {
                $jsonStartIndex = $i
                break
            }
        }
        if ($jsonStartIndex -lt 0) { return $null }
        $jsonText = $raw[$jsonStartIndex..($raw.Count - 1)] -join "`n"
        $result = $jsonText | ConvertFrom-Json
        $Script:GpuStatus = $result
        # If result is an array, return first entry for backward compat
        if ($result -is [array]) {
            return $result[0]
        }
        return $result
    } catch {
        return $null
    }
}

function Get-ModelList {
    $raw = Invoke-ServerCommand "list-models" -raw
    if (-not $raw) { return @() }

    try {
        $jsonText = $raw -join "`n"
        return $jsonText | ConvertFrom-Json
    } catch {
        return @()
    }
}

# ── Formatting Helpers ────────────────────────────────────────────────────

function Format-Bytes {
    param([long]$bytes)
    if ($bytes -ge 1TB) { return "{0:F1} TB" -f ($bytes / 1TB) }
    if ($bytes -ge 1GB) { return "{0:F1} GB" -f ($bytes / 1GB) }
    if ($bytes -ge 1MB) { return "{0:F1} MB" -f ($bytes / 1MB) }
    if ($bytes -ge 1KB) { return "{0:F1} KB" -f ($bytes / 1KB) }
    return "{0} B" -f $bytes
}

function Get-HealthColor {
    param($value, $greenThreshold, $yellowThreshold, [string]$mode = "high-is-good")

    switch ($mode) {
        "high-is-bad" {
            if ($value -lt $yellowThreshold) { return $green }
            if ($value -lt $greenThreshold) { return $amber }
            return $red
        }
        default {
            # high-is-good (like VRAM loaded)
            if ($value -ge $greenThreshold) { return $green }
            if ($value -ge $yellowThreshold) { return $amber }
            return $red
        }
    }
}

# ── UI: ASCII bar helper ──────────────────────────────────────────────────

function New-Bar {
    param([double]$value, [double]$max, [int]$width = 12, [string]$color)
    $fill = if ($max -gt 0) { [Math]::Min([Math]::Round(($value / $max) * $width), $width) } else { 0 }
    $empty = $width - $fill
    return "{0}{1}{2}{3}" -f $color, ("▓" * $fill), ("░" * $empty), $reset
}

# ── UI: GPU Row ───────────────────────────────────────────────────────────

function Show-GpuRow {
    param($gpus)
    if (-not $gpus) { return }

    # If single entry or fallback, treat as array with one item
    if ($gpus -isnot [array]) { $gpus = @($gpus) }

    foreach ($gpu in $gpus) {
        $gpuId          = if ($null -ne $gpu.gpu_id)           { $gpu.gpu_id }           else { 0 }
        $gpuName        = if ($null -ne $gpu.gpu_name)          { $gpu.gpu_name }         else { "GPU${gpuId}" }
        $vramUsedBytes  = if ($null -ne $gpu.vram_used_bytes)   { $gpu.vram_used_bytes }  else { 0 }
        $vramTotalBytes = if ($null -ne $gpu.vram_total_bytes)  { $gpu.vram_total_bytes } else { 0 }
        $gpuBusy        = if ($null -ne $gpu.gpu_busy_percent)  { $gpu.gpu_busy_percent } else { 0 }
        $running        = ($gpu.running -eq $true)

        $vramUsedGb = [math]::Round($vramUsedBytes / 1GB, 1)
        $vramTotalGb = [math]::Round($vramTotalBytes / 1GB, 1)
        $filled = if ($vramTotalGb -gt 0) { [int]([math]::Min(($vramUsedGb / $vramTotalGb) * 12, 12)) } else { 0 }
        $empty = 12 - $filled
        $bar = ("█" * $filled) + ("░" * $empty)

        # Color logic
        $barColor = if ($vramUsedGb -lt 5 -and $running) { $red } else { $blue }
        if (-not $running) { $barColor = $gray }
        $busyColor = if ($gpuBusy -gt 0) { $amber } else { $gray }

        $gpuLabel = "{0}GPU{1}{2}{3}" -f $teal, $gpuId, $reset, $white
        $nameLabel = "  {0,-10}" -f $gpuName
        $barStr = "{0} {1} {2}" -f $barColor, $bar, $reset
        $vramStr = "{0,-5}/{1,-5} GB" -f $vramUsedGb, $vramTotalGb
        $busyStr = "{0}{1,-4}%{2}" -f $busyColor, $gpuBusy, $reset

        $statusDot = if ($running) { "{0}●{1}" -f $teal, $reset } else { "{0}●{1}" -f $red, $reset }

        Write-Host ("  ${statusDot} ${gpuLabel} ${nameLabel}${barStr} ${vramStr}  ${busyStr}")
    }
}

# ── UI: Header ────────────────────────────────────────────────────────────

function Show-Header {
    param($status = $null)

    $w = [Console]::WindowWidth

    # Line 1 — logo + tagline
    $logo    = "{0}LL{1}a{2}M{3}esa{4}" -f $teal, $amber, $teal, $amber, $reset
    $tagline = "{0}local inference control plane · v0.2{1}" -f $dim, $reset
    Write-Host ("{0} {1}" -f $logo, $tagline)

    # Line 2 — server dot + name + host + port
    if ($Script:ActiveServerName) {
        $dot  = if ($Script:ServerOnline) { "{0}●{1}" -f $teal, $reset } else { "{0}●{1}" -f $red, $reset }
        $port = $Script:ActiveServer.port
        Write-Host ("  {0} {1}{2}{3} · {4}{5}{3} · {4}{6}{3}" -f `
            $dot, $teal, $Script:ActiveServerName, $reset, $gray, $Script:ActiveServer.host, $port)
    }

    # GPU rows
    Show-GpuRow $Script:GpuStatus

    # Lines 3-7 — stat cards
    if ($status) {
        $cpu        = [double]($status.cpu_percent)
        $ramUsedGb  = [math]::Round($status.ram_used_mb   / 1024, 1)
        $ramTotGb   = [math]::Round($status.ram_total_mb  / 1024, 1)
        $gpu        = [double]($status.gpu_busy_percent)
        $vramUsedGb = [math]::Round($status.vram_used_bytes  / 1GB, 1)
        $vramTotGb  = [math]::Round($status.vram_total_bytes / 1GB, 1)

        $cpuCol  = if ($cpu -gt 20)        { $red   } elseif ($cpu -gt 5)        { $amber } else { $teal }
        $ramCol  = if ($ramUsedGb -gt 20)  { $red   } elseif ($ramUsedGb -gt 10) { $amber } else { $teal }
        $gpuCol  = if ($gpu -gt 0)         { $amber } else                       { $gray }
        $vramCol = if ($vramUsedGb -lt 5)  { $red   } elseif ($vramUsedGb -lt 15){ $amber } else { $teal }

        $cpuBar  = New-Bar $cpu        100         12 $cpuCol
        $ramBar  = New-Bar $ramUsedGb  $ramTotGb   12 $purple
        $gpuBar  = New-Bar $gpu        100         12 $gpuCol
        $vramBar = New-Bar $vramUsedGb $vramTotGb  12 $blue

        # Card inner widths (visible chars between │ and │):
        #   small cards (CPU/RAM/GPU): 15  →  outer 17  →  top = ┌───────────────┐
        #   VRAM card:                 20  →  outer 22  →  top = ┌────────────────────┐
        #
        # Each content row: │ + leading_space + padded_content + │
        # small: 1 + 1 + 13-char-content + 1 = 16... wait that's only 16 not 17.
        # Correct: inner 15 means │ + 15 chars + │ = 17. Content = leading_space(1) + value.PadRight(14).
        # VRAM inner 20: │ + 20 chars + │ = 22. Content = leading_space(1) + value.PadRight(19).

        $b = $dim; $r = $reset

        # Plain-text values (no color codes) for PadRight
        $cpuVal  = "{0}%" -f $cpu
        $ramVal  = if ($ramTotGb -gt 0)  { "{0} / {1} GB" -f $ramUsedGb, $ramTotGb   } else { "{0} GB" -f $ramUsedGb }
        $gpuVal  = "{0}%" -f $gpu
        $vramVal = if ($vramTotGb -gt 0) { "{0} / {1} GB" -f $vramUsedGb, $vramTotGb } else { "{0} GB" -f $vramUsedGb }

        # Top border — small=15 dashes, VRAM=20 dashes
        Write-Host ("  ${b}┌───────────────┐${r} ${b}┌───────────────┐${r} ${b}┌───────────────┐${r} ${b}┌────────────────────┐${r}")

        # Label row: 1 leading space + label padded to 14 (small) / 19 (VRAM)
        $lblRow  = "  ${b}│${r} ${gray}$("CPU".PadRight(14))${r}${b}│${r} "
        $lblRow += "${b}│${r} ${gray}$("RAM".PadRight(14))${r}${b}│${r} "
        $lblRow += "${b}│${r} ${gray}$("GPU".PadRight(14))${r}${b}│${r} "
        $lblRow += "${b}│${r} ${gray}$("VRAM".PadRight(19))${r}${b}│${r}"
        Write-Host $lblRow

        # Value row: colored value padded to 14 (small) / 19 (VRAM) — PadRight on plain string, then wrap in color
        $valRow  = "  ${b}│${r} ${cpuCol}$($cpuVal.PadRight(14))${r}${b}│${r} "
        $valRow += "${b}│${r} ${ramCol}$($ramVal.PadRight(14))${r}${b}│${r} "
        $valRow += "${b}│${r} ${gpuCol}$($gpuVal.PadRight(14))${r}${b}│${r} "
        $valRow += "${b}│${r} ${vramCol}$($vramVal.PadRight(19))${r}${b}│${r}"
        Write-Host $valRow

        # Bar row: 12-char bar + padding to fill inner (small: 2 spaces, VRAM: 7 spaces)
        $barRow  = "  ${b}│${r} ${cpuBar}  ${b}│${r} "
        $barRow += "${b}│${r} ${ramBar}  ${b}│${r} "
        $barRow += "${b}│${r} ${gpuBar}  ${b}│${r} "
        $barRow += "${b}│${r} ${vramBar}       ${b}│${r}"
        Write-Host $barRow

        # Bottom border
        Write-Host ("  ${b}└───────────────┘${r} ${b}└───────────────┘${r} ${b}└───────────────┘${r} ${b}└────────────────────┘${r}")

        # Model row with pill badges
        if ($status.running) {
            $thinkingPill = if ($status.thinking) { "${teal}[thinking on]${r}"  } else { "${gray}[thinking off]${r}" }
            $ctxPill      = if ($status.ctx -gt 0){ "${teal}[ctx $($status.ctx)]${r}" } else { "" }
            $toksPill     = if ($Script:LastTokS) { "${amber}[$($Script:LastTokS) tok/s]${r}" } else { "" }
            $gpuPill = ""
            if ($Script:GpuStatus -is [array]) {
                $rg = $Script:GpuStatus | Where-Object { $_.running -eq $true } | Select-Object -First 1
                if ($rg) { $gpuPill = "${gray}[GPU$($rg.gpu_id) $($rg.gpu_name)]${r}" }
            } elseif ($Script:GpuStatus -and $Script:GpuStatus.running) {
                $gpuPill = "${gray}[GPU$($Script:GpuStatus.gpu_id) $($Script:GpuStatus.gpu_name)]${r}"
            }
            Write-Host ("  ${gray}MODEL${r}  ${white}$($status.model)${r}  ${ctxPill}  ${thinkingPill}  ${toksPill}  ${gpuPill}")
        } else {
            Write-Host ("  ${gray}MODEL  none${r}")
        }

        # Last-updated timestamp
        if ($Script:LastStatusRefresh) {
            $elapsed = ([DateTime]::Now - $Script:LastStatusRefresh).TotalSeconds
            if ($elapsed -lt 2) {
                $tsStr = "just now"
            } elseif ($elapsed -lt 60) {
                $tsStr = "{0}s ago" -f [int]$elapsed
            } elseif ($elapsed -lt 3600) {
                $tsStr = "{0}m ago" -f [int]($elapsed / 60)
            } else {
                $tsStr = "{0}h ago" -f [int]($elapsed / 3600)
            }
            $stale = if ($elapsed -ge 15) { "${red}[stale]${r}" } else { "" }
            Write-Host ("  ${dim}updated ${tsStr}${r} ${stale}")
        } else {
            Write-Host ("  ${dim}updated --${r}")
        }
    } else {
        # Offline placeholder — same number of lines as card block so layout is stable
        Write-Host ("  ${dim}┌───────────────┐ ┌───────────────┐ ┌───────────────┐ ┌────────────────────┐${reset}")
        Write-Host ("  ${dim}│  offline      │ │               │ │               │ │                    │${reset}")
        Write-Host ("  ${dim}│               │ │               │ │               │ │                    │${reset}")
        Write-Host ("  ${dim}│               │ │               │ │               │ │                    │${reset}")
        Write-Host ("  ${dim}└───────────────┘ └───────────────┘ └───────────────┘ └────────────────────┘${reset}")
        Write-Host ("  ${gray}MODEL  none${reset}")

        # Last-updated timestamp (offline)
        if ($Script:LastStatusRefresh) {
            $elapsed = ([DateTime]::Now - $Script:LastStatusRefresh).TotalSeconds
            if ($elapsed -lt 2) {
                $tsStr = "just now"
            } elseif ($elapsed -lt 60) {
                $tsStr = "{0}s ago" -f [int]$elapsed
            } elseif ($elapsed -lt 3600) {
                $tsStr = "{0}m ago" -f [int]($elapsed / 60)
            } else {
                $tsStr = "{0}h ago" -f [int]($elapsed / 3600)
            }
            $stale = if ($elapsed -ge 15) { "${red}[stale]${r}" } else { "" }
            Write-Host ("  ${dim}updated ${tsStr}${r} ${stale}")
        } else {
            Write-Host ("  ${dim}updated --${r}")
        }
    }

    Write-Host ("${dim}$("─" * [Math]::Max($w - 1, 20))${reset}")
}

# ── UI: Menu ──────────────────────────────────────────────────────────────

function Show-Menu {
    $w   = [Console]::WindowWidth
    $sep = "{0}{1}{2}" -f $dim, ("─" * [Math]::Max($w - 1, 20)), $reset

    function Section([string]$title) {
        Write-Host ("{0}{1}{2}" -f $teal, $title, $reset)
    }
    function Row([string]$cmd, [string]$desc, [string]$hint = "") {
        if ($hint) {
            $hintStr = "${gray}${hint}${reset}"
            # Right-align hint: pad desc to fill space up to terminal width
            $ww = [Console]::WindowWidth
            $plainLen = 2 + 10 + 2 + $desc.Length
            $pad = [Math]::Max(1, $ww - $plainLen - $hint.Length - 2)
            Write-Host ("  ${white}$("{0,-10}" -f $cmd)${reset}  ${desc}$(" " * $pad)${hintStr}")
        } else {
            Write-Host ("  ${white}$("{0,-10}" -f $cmd)${reset}  ${desc}")
        }
    }

    Write-Host ""
    Section "SERVER"
    Row "/start"   "start server"                   "model · thinking · context"
    Row "/stop"    "graceful shutdown"
    Row "/switch"  "hot-swap model"                 "hot-swap"
    Row "/restart" "stop + start with same settings"
    Write-Host ""
    Section "MONITORING"
    Row "/health"  "ping /health and /v1/models"
    Row "/logs"    "tail verbose server output"
    Write-Host ""
    Section "MODELS"
    Row "/models"   "list downloaded models + sizes"
    Row "/download" "download from huggingface"
    Write-Host ""
    Section "CHAT"
    Row "/chat" "chat with the model directly"
    Write-Host ""
    Section "CONFIG"
    Row "/servers" "manage server profiles"
    Row "/config"  "view/edit config"
    Row "/quit"    "exit"
}

# ── GPU Picker ────────────────────────────────────────────────────────────

function Show-GpuPicker {
    # If only one GPU, skip picker
    if (-not $Script:GpuStatus -or ($Script:GpuStatus -isnot [array]) -or $Script:GpuStatus.Count -le 1) {
        return 0
    }

    Write-Host ""
    Write-Host ("  {0}Which GPU?{1}" -f $white, $reset)
    for ($i = 0; $i -lt $Script:GpuStatus.Count; $i++) {
        $g = $Script:GpuStatus[$i]
        $vram = if ($g.vram_total_bytes) { [math]::Round($g.vram_total_bytes / 1GB) } else { 0 }
        Write-Host ("    {0}  GPU{1} {2,-12} {3} GB" -f ($i + 1).ToString(), $g.gpu_id, $g.gpu_name, $vram)
    }
    Write-Host ""
    $choice = Read-Host ">"
    $idx = [int]$choice - 1
    if ($idx -lt 0 -or $idx -ge $Script:GpuStatus.Count) {
        Write-Host ("{0}Invalid selection. Defaulting to GPU 0.{1}" -f $amber, $reset)
        return 0
    }
    return $Script:GpuStatus[$idx].gpu_id
}

# ── Command: /start ───────────────────────────────────────────────────────

function Cmd-Start {
    Write-Host ("{0}Fetching available models...{1}" -f $cyan, $reset)
    $models = Get-ModelList

    if (-not $models -or $models.Count -eq 0) {
        Write-Host ("{0}No models found.{1}" -f $red, $reset)
        return
    }

    Write-Host ""
    Write-Host ("  {0}Select model:{1}" -f $white, $reset)

    for ($i = 0; $i -lt $models.Count; $i++) {
        $m = $models[$i]
        $size = Format-Bytes $m.size_bytes
        $visionTag = if ($m.has_mmproj) { " {0}[vision]{1}" -f $amber, $reset } else { "" }
        Write-Host ("    {0}  {1,-30} {2,-12}{3}" -f ($i + 1).ToString(), $m.name, $size, $visionTag)
    }

    Write-Host ""
    $choice = Read-Host ">"
    $idx = [int]$choice - 1

    if ($idx -lt 0 -or $idx -ge $models.Count) {
        Write-Host ("{0}Invalid selection.{1}" -f $red, $reset)
        return
    }

    $selectedModel = $models[$idx].name

    # GPU picker
    $gpuId = Show-GpuPicker

    # Ask for options
    $thinkingInput = Read-Host "Thinking mode? [on/off]"
    $thinking = if ($thinkingInput -match '^(on|yes|true|1)$') { "true" } else { "false" }

    $ctx = Read-Host "Context size? [131072]"
    if (-not $ctx) { $ctx = "131072" }

    $parallelInput = Read-Host "Parallel slots? [1-4, default: 1]"
    if (-not $parallelInput) { $parallelInput = "1" }
    $parallelInput = [math]::Max(1, [math]::Min(4, [int]$parallelInput))
    $parallelArg = "--parallel $parallelInput"

    Write-Host ""
    $gpuLabel = if ($gpuId) { " on GPU${gpuId}" } else { "" }
    Write-Host ("{0}Starting {1}{2}...{3}" -f $cyan, $selectedModel, $gpuLabel, $reset)

    $raw = Invoke-ServerCommand ("start --model ""{0}"" --gpu {1} --thinking {2} --ctx {3} {4}" -f $selectedModel, $gpuId, $thinking, $ctx, $parallelArg).Trim() -raw
    Write-Host ($raw -join "`n")

    # Poll until loaded
    Write-Host ("{0}Waiting for model to load...{1}" -f $cyan, $reset)
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 2
        $status = Get-ServerStatus
        if ($status -and $status.running -and $status.vram_used_bytes -gt 1GB) {
            Write-Host ("{0}✓ Model loaded!{1}" -f $green, $reset)
            break
        }
        Write-Host ("  Loading... ({0}s)" -f ($i * 2))
    }
}

# ── Command: /stop ────────────────────────────────────────────────────────

function Cmd-Stop {
    # Check how many GPUs are running
    $runningGpus = @()
    if ($Script:GpuStatus -is [array]) {
        $runningGpus = $Script:GpuStatus | Where-Object { $_.running -eq $true }
    } elseif ($Script:GpuStatus -and $Script:GpuStatus.running) {
        $runningGpus = @($Script:GpuStatus)
    }

    $gpuArg = "0"  # default
    if ($runningGpus.Count -gt 1) {
        Write-Host ("  {0}Stop which GPU?{1}" -f $white, $reset)
        for ($i = 0; $i -lt $runningGpus.Count; $i++) {
            $g = $runningGpus[$i]
            Write-Host ("    {0}  GPU{1} {2}" -f ($i + 1).ToString(), $g.gpu_id, $g.gpu_name)
        }
        Write-Host ("    {0}  Both" -f ($runningGpus.Count + 1).ToString())
        Write-Host ""
        $choice = Read-Host ">"
        $idx = [int]$choice
        if ($idx -le $runningGpus.Count) {
            $gpuArg = $runningGpus[$idx - 1].gpu_id
        } else {
            $gpuArg = "all"
        }
    } elseif ($runningGpus.Count -eq 1) {
        $gpuArg = $runningGpus[0].gpu_id
    }

    Write-Host ("{0}Stopping GPU {1}...{2}" -f $cyan, $gpuArg, $reset)
    $raw = Invoke-ServerCommand ("stop --gpu {0}" -f $gpuArg) -raw
    Write-Host ($raw -join "`n")
}

# ── Command: /restart ─────────────────────────────────────────────────────

function Cmd-Restart {
    if (-not $Script:ActiveServer) { Write-Host ("{0}No active server.{1}" -f $red, $reset); return }

    $sshUser     = $Script:ActiveServer.ssh_user
    $sshHost     = $Script:ActiveServer.host
    $llamesaPath = $Script:ActiveServer.llamesa_path
    $port        = $Script:ActiveServer.port

    # Read saved session so we know what to restart with
    $sessionJson = ssh -o BatchMode=yes -o ConnectTimeout=5 "${sshUser}@${sshHost}" "cat ~/.llamesa/last_session.json 2>/dev/null" 2>$null
    if (-not $sessionJson) {
        Write-Host ("{0}No saved session found. Use /start instead.{1}" -f $red, $reset)
        return
    }

    $session   = ($sessionJson -join "`n") | ConvertFrom-Json
    $modelName = $session.model
    $thinking  = if ($session.thinking) { "true" } else { "false" }
    $ctx       = $session.ctx

    Write-Host ("{0}Restarting: {1} (thinking={2}, ctx={3}){4}" -f $cyan, $modelName, $thinking, $ctx, $reset)

    # Stop first (blocking, quick)
    Cmd-Stop
    Write-Host ("{0}Waiting 3s for VRAM to clear...{1}" -f $dim, $reset)
    Start-Sleep -Seconds 3

    # Fire-and-forget: launch start detached so SSH returns immediately.
    # nohup + & + redirected output lets the SSH session close without killing the process.
    # Get GPU id from running status
    $gpuArg = 0
    if ($Script:GpuStatus -is [array]) {
        $rg = $Script:GpuStatus | Where-Object { $_.running -eq $true } | Select-Object -First 1
        if ($rg) { $gpuArg = $rg.gpu_id }
    }
    $startCmd = "nohup bash ${llamesaPath} start --model `"${modelName}`" --gpu ${gpuArg} --thinking ${thinking} --ctx ${ctx} >> ~/.llamesa/restart.log 2>&1 &"
    ssh -o BatchMode=yes -o ConnectTimeout=5 "${sshUser}@${sshHost}" $startCmd 2>$null | Out-Null

    # Poll /health directly over HTTP — no SSH held open during the long load wait
    Write-Host ("{0}Waiting for model to load...{1}" -f $cyan, $reset)
    $loaded = $false
    for ($i = 0; $i -lt 150; $i++) {
        Start-Sleep -Seconds 2
        try {
            $health = Invoke-RestMethod -Uri "http://${sshHost}:${port}/health" -TimeoutSec 3 -ErrorAction Stop
            if ($health.status -eq "ok") {
                $status = Get-ServerStatus
                if ($status -and $status.vram_used_bytes -gt 1GB) {
                    Write-Host ("{0}✓ Server restarted and model loaded!{1}" -f $green, $reset)
                    $loaded = $true
                    break
                }
            }
        } catch {}
        if (($i + 1) % 15 -eq 0) {
            Write-Host ("  Still loading... ({0}s elapsed)" -f (($i + 1) * 2))
        }
    }
    if (-not $loaded) {
        Write-Host ("{0}Timed out waiting for server after restart.{1}" -f $red, $reset)
        Write-Host ("Check logs on Bazzite: tail -f ~/.llamesa/restart.log" )
    }
}

# ── Command: /switch ──────────────────────────────────────────────────────

function Cmd-Switch {
    Cmd-Start  # same flow as start but stops first (handled by server)
}

# ── Command: /models ──────────────────────────────────────────────────────

function Cmd-Models {
    Write-Host ("{0}Fetching model list...{1}" -f $cyan, $reset)
    $models = Get-ModelList

    if (-not $models -or $models.Count -eq 0) {
        Write-Host ("{0}No models found.{1}" -f $red, $reset)
        return
    }

    Write-Host ""
    Write-Host ("  {0,-30} {1,-15} {2}" -f "NAME", "SIZE", "VISION")

    foreach ($m in $models) {
        $size = Format-Bytes $m.size_bytes
        $vision = if ($m.has_mmproj) { "{0}yes{1}" -f $amber, $reset } else { "no" }
        Write-Host ("  {0,-30} {1,-15} {2}" -f $m.name, $size, $vision)
    }

    Write-Host ""
}

# ── Command: /logs ────────────────────────────────────────────────────────

function Cmd-Logs {
    $sshUser     = $Script:ActiveServer.ssh_user
    $sshHost     = $Script:ActiveServer.host
    $llamesaPath = $Script:ActiveServer.llamesa_path

    # Pick GPU — default 0; if a running GPU is known, use it
    $gpuId = 0
    if ($Script:GpuStatus -is [array]) {
        $rg = $Script:GpuStatus | Where-Object { $_.running -eq $true } | Select-Object -First 1
        if ($rg) { $gpuId = $rg.gpu_id }
    } elseif ($Script:GpuStatus -and $Script:GpuStatus.running) {
        $gpuId = $Script:GpuStatus.gpu_id
    }

    ssh "${sshUser}@${sshHost}" "bash ${llamesaPath} logs --gpu ${gpuId}"
}

# ── Command: /health ──────────────────────────────────────────────────────

# ── Helper: Get active GPU port ──────────────────────────────

function Get-ActiveGpuPort {
    if ($Script:GpuStatus -is [array]) {
        $running = $Script:GpuStatus | Where-Object { $_.running -eq $true } | Select-Object -First 1
        if ($running) { return $running.port }
        return $Script:GpuStatus[0].port
    } elseif ($Script:GpuStatus) {
        return $Script:GpuStatus.port
    }
    return $Script:ActiveServer.port
}

function Cmd-Health {
    Write-Host ("{0}Checking server health...{1}" -f $cyan, $reset)

    $port = Get-ActiveGpuPort
    $hostAddr = $Script:ActiveServer.host

    # Check /health endpoint
    try {
        $health = Invoke-RestMethod -Uri "http://${hostAddr}:${port}/health" -TimeoutSec 5 -ErrorAction Stop
        Write-Host ("{0}✓ /health endpoint OK{1}" -f $green, $reset)
        Write-Host ($health | ConvertTo-Json)
    } catch {
        Write-Host ("{0}✗ /health endpoint failed: {1}{2}" -f $red, $_.Exception.Message, $reset)
    }

    Write-Host ""

    # Check /v1/models endpoint
    try {
        $models = Invoke-RestMethod -Uri "http://${hostAddr}:${port}/v1/models" -TimeoutSec 5 -ErrorAction Stop
        Write-Host ("{0}✓ /v1/models endpoint OK{1}" -f $green, $reset)
        Write-Host ($models | ConvertTo-Json -Depth 5)
    } catch {
        Write-Host ("{0}✗ /v1/models endpoint failed: {1}{2}" -f $red, $_.Exception.Message, $reset)
    }

    Write-Host ""
}

# ── Command: /download ────────────────────────────────────────────────────

function Cmd-Download {
    $repo = Read-Host "HuggingFace repo ID (e.g., unsloth/Qwen3.6-27B-GGUF)"

    if (-not $repo) { return }

    $file = Read-Host "Filename pattern (e.g., *UD-Q4_K_XL*, press Enter to list first)"

    if (-not $file) {
        # List files first
        Write-Host ("{0}Listing files...{1}" -f $cyan, $reset)
        $raw = Invoke-ServerCommand ("download --repo ""{0}"" --list" -f $repo) -raw
        Write-Host ($raw -join "`n")
        Write-Host ""

        $file = Read-Host "Enter filename pattern (or 0 to cancel)"
        if ($file -eq "0") { return }
    }

    Write-Host ("{0}Downloading...{1}" -f $cyan, $reset)
    $raw = Invoke-ServerCommand ("download --repo ""{0}"" --file ""{1}""" -f $repo, $file) -raw
    Write-Host ($raw -join "`n")
}

# ── Command: /chat ────────────────────────────────────────────────────────

function Cmd-Chat {
    $Script:CurrentView = "chat"
    $Script:ChatHistory = @()

    $port = Get-ActiveGpuPort
    $hostAddr = $Script:ActiveServer.host

    # Seed thinking mode from server status; user can toggle with /think and /nothink
    $thinkingEnabled = $false
    if ($Script:ServerStatus -and $Script:ServerStatus.thinking) {
        $thinkingEnabled = [bool]$Script:ServerStatus.thinking
    }

    Write-Host ("{0}Chat mode — type /exit to return, /clear to clear history{1}" -f $cyan, $reset)
    Write-Host ("{0}Thinking mode: {1}{2}" -f $gray, $(if ($thinkingEnabled) { "on (toggle with /nothink)" } else { "off (toggle with /think)" }), $reset)

    Clear-Host
    while ($Script:CurrentView -eq "chat") {

        # Chat header
        $logo = "{0}LL{1}a{2}M{3}esa{4} chat" -f $teal, $amber, $teal, $amber, $reset
        Write-Host $logo
        Write-Host ""

        # Show history
        foreach ($msg in $Script:ChatHistory) {
            if ($msg.role -eq "user") {
                Write-Host ("  {0}You:{1}" -f $cyan, $reset)
                Write-Host ("  {0}{1}{2}" -f $white, $msg.content, $reset)
                Write-Host ""
            }
            elseif ($msg.role -eq "assistant") {
                Write-Host ("  {0}Model:{1}" -f $amber, $reset)

                # Handle thinking blocks
                if ($msg.thinking) {
                    Write-Host ("  {0}⟨thinking⟩{1}" -f $gray, $reset)
                    Write-Host ("  {0}{1}{2}" -f $gray, $msg.thinking, $reset)
                    Write-Host ("  {0}⟨/thinking⟩{1}" -f $gray, $reset)
                }

                Write-Host ("  {0}{1}{2}" -f $white, $msg.content, $reset)

                # Token stats if available
                if ($msg.tok_s) {
                    Write-Host ""
                    Write-Host ("  {0}─{1}" -f $dim, "───────────────────────────────────────────────", $reset)
                    $thinkingDisplay = if ($msg.thinking_toks) { "$($msg.thinking_toks) thinking · " } else { "" }
                    Write-Host ("  {0}⬡ {1} prompt · {2}{3} gen · {4} tok/s · {5}s{6}" -f `
                        $amber, $msg.prompt_toks, $thinkingDisplay, $msg.gen_toks, $msg.tok_s, $msg.duration, $reset)
                }

                Write-Host ""
            }
        }

        # Prompt — plain text so the cursor stays pinned to the bottom on resize
        $input = Read-Host "  ›"

        if (-not $input) { continue }

        # Commands
        if ($input -match '^/(exit|quit|back)$') {
            break
        }
        elseif ($input -eq "/clear") {
            $Script:ChatHistory = @()
            continue
        }
        elseif ($input -eq "/think") {
            $thinkingEnabled = $true
            Write-Host ("{0}Thinking mode ON — Qwen3 will reason before responding.{1}" -f $amber, $reset)
            continue
        }
        elseif ($input -eq "/nothink") {
            $thinkingEnabled = $false
            Write-Host ("{0}Thinking mode OFF.{1}" -f $gray, $reset)
            continue
        }

        # Add user message to history
        $Script:ChatHistory += [PSCustomObject]@{
            role    = "user"
            content = $input
        }

        # Build messages array for API
        $messages = @()
        foreach ($msg in $Script:ChatHistory) {
            if ($msg.role -eq "user" -or $msg.role -eq "assistant") {
                $messages += [PSCustomObject]@{
                    role    = $msg.role
                    content = $msg.content
                }
            }
        }

        # Call API with streaming
        Write-Host ("  {0}Model: {1}" -f $amber, $reset)

        # Get model ID directly from /v1/models endpoint
        $modelId = "default"
        try {
            $modelsResponse = Invoke-RestMethod -Uri "http://${hostAddr}:${port}/v1/models" -TimeoutSec 5
            if ($modelsResponse.data -and $modelsResponse.data.Count -gt 0) {
                $modelId = $modelsResponse.data[0].id
            }
        } catch {}

        $requestBody = [PSCustomObject]@{
            model          = $modelId
            messages       = $messages
            stream         = $true
            stream_options = [PSCustomObject]@{ include_usage = $true }
        }
        # chat_template_kwargs is Qwen3-specific; only send it when thinking is on
        # so other models receive a plain request with no extra fields
        if ($thinkingEnabled) {
            $requestBody | Add-Member -NotePropertyName chat_template_kwargs -NotePropertyValue ([PSCustomObject]@{ enable_thinking = $true })
        }
        $body = $requestBody | ConvertTo-Json -Depth 5

        $assistantContent = ""
        $thinkingContent  = ""
        $inThinking       = $false
        $promptToks       = 0
        $genToks          = 0
        $thinkingToks     = 0

        try {
            # Use HttpWebRequest for true SSE streaming (HttpClient buffers response content in .NET/PowerShell)
            Write-Host ("  {0}Connecting to {1}:{2}...{3}" -f $gray, $hostAddr, $port, $reset)

            $request = [System.Net.HttpWebRequest]::Create("http://${hostAddr}:${port}/v1/chat/completions")
            $request.Method = "POST"
            $request.ContentType = "application/json; charset=utf-8"
            $request.Timeout = 120000
            $request.ServicePoint.Expect100Continue = $false

            $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
            $request.ContentLength = $bytes.Length
            $requestStream = $request.GetRequestStream()
            $requestStream.Write($bytes, 0, $bytes.Length)
            $requestStream.Close()

            $response = $request.GetResponse()
            Write-Host ("  {0}HTTP {1}{2}" -f $gray, $response.StatusCode, $reset)
            Write-Host ("  {0}Stream opened, reading...{1}" -f $gray, $reset)

            $stream = $response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
            $streamStart = Get-Date

            try {
                while ($true) {
                    $line = $reader.ReadLine()
                    if ($null -eq $line) { break }
                    if ([string]::IsNullOrEmpty($line)) { continue }

                    if ($line.StartsWith("data:")) {
                        $jsonStr = $line.Substring(5).Trim()
                        if ($jsonStr -eq '[DONE]') { break }

                        try {
                            $delta = $jsonStr | ConvertFrom-Json

                            # Track usage — safe property access required under Set-StrictMode
                            $usage = $delta.PSObject.Properties['usage']?.Value
                            if ($usage) {
                                $pv = $usage.PSObject.Properties['prompt_tokens']?.Value
                                $gv = $usage.PSObject.Properties['completion_tokens']?.Value
                                if ($pv -ne $null) { $promptToks = [int]$pv }
                                if ($gv -ne $null) { $genToks = [int]$gv }
                            }

                            # Handle content deltas — safe property access required under Set-StrictMode
                            if ($delta.choices -and $delta.choices[0].delta) {
                                $deltaObj = $delta.choices[0].delta
                                $reasoningChunk = $deltaObj.PSObject.Properties['reasoning_content']?.Value
                                $contentChunk = $deltaObj.PSObject.Properties['content']?.Value

                                if ($reasoningChunk) {
                                    $thinkingToks++
                                    $thinkingContent += $reasoningChunk
                                    Write-Host $reasoningChunk -NoNewline -ForegroundColor DarkGray
                                }
                                if ($contentChunk) {
                                    if (-not $assistantContent) {
                                        Write-Host ""
                                        Write-Host ""
                                    }
                                    $assistantContent += $contentChunk
                                    Write-Host $contentChunk -NoNewline
                                }
                            }
                        } catch {
                            # Skip malformed lines
                        }
                    }
                }
            } finally {
                $reader.Dispose()
                $response.Close()
            }
            $streamEnd = Get-Date

            Write-Host ""

            $duration = [math]::Round(($streamEnd - $streamStart).TotalSeconds, 1)

            # Fallback: if the server didn't send usage (stream_options not honoured), estimate
            if ($genToks -eq 0) {
                # completion_tokens includes thinking; approximate from both contents
                $genToks = [Math]::Max(1, [int](($assistantContent.Length + $thinkingContent.Length) / 4))
            }
            if ($promptToks -eq 0) {
                $totalMsgLen = ($messages | ForEach-Object { $_.content.Length } | Measure-Object -Sum).Sum
                $promptToks = [Math]::Max(1, [int]($totalMsgLen / 4))
            }

            # Total tokens generated = thinking tokens + content tokens
            $tokS = if ($duration -gt 0) { [math]::Round(($thinkingToks + $genToks) / $duration, 1) } else { 0 }
            if ($tokS -gt 0) { $Script:LastTokS = $tokS }

            # Always display token stats after a successful response
            if ($assistantContent) {
                Write-Host ("  {0}─{1}" -f $dim, "───────────────────────────────────────────────", $reset)
                Write-Host ("  {0}⬡ {1} prompt · {2} thinking · {3} gen · {4} tok/s · {5}s{6}" -f `
                    $amber, $promptToks, $thinkingToks, $genToks, $tokS, [math]::Round($duration, 1), $reset)
                Write-Host ""
            }

            # Add assistant message to history
            $Script:ChatHistory += [PSCustomObject]@{
                role         = "assistant"
                content      = $assistantContent
                thinking     = $thinkingContent
                prompt_toks  = $promptToks
                thinking_toks = $thinkingToks
                gen_toks     = $genToks
                tok_s        = $tokS
                duration     = [math]::Round($duration, 1)
            }

        } catch {
            Write-Host ("{0}Error: {1}{2}" -f $red, $_.Exception.Message, $reset)
            Write-Host ("{0}Detail: {1}{2}" -f $red, $_.Exception.ToString(), $reset)
            Write-Host ("{0}Stack: {1}{2}" -f $red, $_.ScriptStackTrace, $reset)
        }
    }

    $Script:CurrentView = "menu"
    Clear-Host
}

# ── Command: /servers ─────────────────────────────────────────────────────

function Cmd-Servers {
    Write-Host ""
    Write-Host ("  {0}Configured Servers:{1}" -f $teal, $reset)
    Write-Host ""

    $i = 1
    foreach ($prop in $Script:Config.servers.PSObject.Properties) {
        $s = $prop.Value
        $marker = if ($prop.Name -eq $Script:Config.active_server) { "{0}←{1}" -f $green, $reset } else { " " }
        Write-Host ("    {0} {1,-15} {2,-20} {3}" -f $marker, $prop.Name, $s.host, $s.ssh_user)
        $i++
    }

    Write-Host ""
    Write-Host ("  {0}Actions:{1}" -f $gray, $reset)
    Write-Host ("    1. Switch active server")
    Write-Host ("    2. Add new server")
    Write-Host ("    3. Remove server")
    Write-Host ("    0. Back")
    Write-Host ""

    $choice = Read-Host ">"

    switch ($choice) {
        "1" {
            $name = Read-Host "Server name to switch to"
            if ($Script:Config.servers.PSObject.Properties[$name]) {
                $Script:Config.active_server = $name
                Save-Config
                Read-Config
                Write-Host ("{0}Switched to {1}{2}" -f $green, $name, $reset)
            } else {
                Write-Host ("{0}Server not found.{1}" -f $red, $reset)
            }
        }
        "2" {
            Run-SetupWizard
        }
        "3" {
            $name = Read-Host "Server name to remove"
            if ($Script:Config.servers.PSObject.Properties[$name]) {
                $Script:Config.servers.PSObject.Properties.Remove($name)
                if ($Script:Config.active_server -eq $name) {
                    $Script:Config.active_server = $Script:Config.servers.PSObject.Properties[0].Name
                }
                Save-Config
                Read-Config
                Write-Host ("{0}Removed {1}{2}" -f $green, $name, $reset)
            } else {
                Write-Host ("{0}Server not found.{1}" -f $red, $reset)
            }
        }
    }

    Write-Host ""
    Start-Sleep -Seconds 1
}

# ── Command: /config ──────────────────────────────────────────────────────

function Cmd-Config {
    Write-Host ""
    Write-Host ("  {0}Current Config:{1}" -f $teal, $reset)
    Write-Host ("  {0}{1}{2}" -f $dim, $Script:CONFIG_FILE, $reset)
    Write-Host ""

    $configText = Get-Content $Script:CONFIG_FILE -Raw
    Write-Host ("  {0}{1}{2}" -f $white, ($configText | Out-String), $reset)

    Write-Host ""
    $edit = Read-Host "Edit config file? (y/N)"
    if ($edit -eq "y" -or $edit -eq "Y") {
        $editor = $env:EDITOR
        if (-not $editor) { $editor = "code" }
        & $editor $Script:CONFIG_FILE
        Read-Config
    }

    Write-Host ""
}

# ── Command: /help ────────────────────────────────────────────────────────

function Cmd-Help {
    Write-Host ""
    Write-Host ("  {0}LLaMesa Commands{1}" -f $teal, $reset)
    Write-Host ("  {0}─{1}" -f $dim, "──────────────────────────────────────────────────────", $reset)
    Write-Host ""
    Write-Host ("  {0}/start{1}        Start the inference server with model selection" -f $white, $reset)
    Write-Host ("  {0}/stop{1}         Stop the running server gracefully" -f $white, $reset)
    Write-Host ("  {0}/switch{1}       Hot-swap to a different model" -f $white, $reset)
    Write-Host ("  {0}/restart{1}      Restart server with same/new settings" -f $white, $reset)
    Write-Host ("  {0}/health{1}       Check server API endpoints" -f $white, $reset)
    Write-Host ("  {0}/logs{1}         Stream server logs (Ctrl+C to exit)" -f $white, $reset)
    Write-Host ("  {0}/models{1}       List all available models" -f $white, $reset)
    Write-Host ("  {0}/download{1}     Download a model from HuggingFace" -f $white, $reset)
    Write-Host ("  {0}/chat{1}         Chat with the model ({2}/exit{1} to leave)" -f $white, $reset, $gray)
    Write-Host ("  {0}/servers{1}      Manage server profiles" -f $white, $reset)
    Write-Host ("  {0}/config{1}       View/edit configuration" -f $white, $reset)
    Write-Host ("  {0}/help{1}         Show this help" -f $white, $reset)
    Write-Host ("  {0}/quit{1}         Exit LLaMesa" -f $white, $reset)
    Write-Host ""
    Write-Host ("  {0}Chat commands: /clear /think /nothink /exit{1}" -f $gray, $reset)
    Write-Host ""
}

# ── Command Autocomplete ──────────────────────────────────────────────────

$Script:Commands = @(
    "start", "stop", "switch", "restart",
    "health", "logs",
    "models", "download",
    "chat",
    "servers", "config", "help", "quit"
)

function Get-MatchingCommands {
    param([string]$prefix)

    return $Script:Commands | Where-Object { $_ -like "${prefix}*" }
}

# ── Main Loop ─────────────────────────────────────────────────────────────

function Main {
    $host.UI.RawUI.WindowTitle = "LLaMesa"
    Read-Config

    $Script:ServerOnline = $false
    $status = $null
    # MinValue forces an immediate status fetch on the first iteration
    $lastRefresh = [DateTime]::MinValue

    while ($true) {
        # Refresh status every 2s (or on first run / after a command)
        $elapsed = ([DateTime]::Now - $lastRefresh).TotalSeconds
        if ($elapsed -ge 2) {
            try {
                $Script:ServerOnline = Test-ServerConnection
                $status = Get-ServerStatus
                $Script:ServerStatus = $status
                $Script:LastStatusRefresh = [DateTime]::Now
            } catch {
                $Script:ServerOnline = $false
                $status = $null
            }
            $lastRefresh = [DateTime]::Now
        }

        # Full clear + redraw every loop so there's never a stale/doubled header
        Clear-Host
        Show-Header -status $status
        Show-Menu

        # Pin the prompt to the last row — pad with blank lines to fill remaining height
        $usedRows = [Console]::CursorTop
        $padLines = [Math]::Max(0, [Console]::WindowHeight - $usedRows - 2)
        if ($padLines -gt 0) { Write-Host ("`n" * ($padLines - 1)) }

        # Read command — plain prompt (no ANSI codes) so PowerShell keeps the cursor pinned
        $input = Read-Host "  ›:"

        if (-not $input -or -not $input.Trim()) { continue }
        $cmd = $input.Trim().TrimStart('/')

        switch ($cmd) {
            "start"    { Clear-Host; Cmd-Start;    Read-Host "`nPress Enter to continue" }
            "stop"     { Clear-Host; Cmd-Stop;     Read-Host "`nPress Enter to continue" }
            "switch"   { Clear-Host; Cmd-Switch;   Read-Host "`nPress Enter to continue" }
            "restart"  { Clear-Host; Cmd-Restart;  Read-Host "`nPress Enter to continue" }
            "health"   { Clear-Host; Cmd-Health;   Read-Host "`nPress Enter to continue" }
            "logs"     { Cmd-Logs }
            "models"   { Clear-Host; Cmd-Models;   Read-Host "`nPress Enter to continue" }
            "download" { Clear-Host; Cmd-Download; Read-Host "`nPress Enter to continue" }
            "chat"     { Cmd-Chat }
            "servers"  { Clear-Host; Cmd-Servers;  Read-Host "`nPress Enter to continue" }
            "config"   { Clear-Host; Cmd-Config;   Read-Host "`nPress Enter to continue" }
            "help"     { Clear-Host; Cmd-Help;     Read-Host "`nPress Enter to continue" }
            "quit"     { Clear-Host; Write-Host ("{0}Goodbye!{1}" -f $gray, $reset); exit 0 }
            default    { Write-Host ("{0}Unknown command: /{1}{2}" -f $red, $cmd, $reset); Start-Sleep -Seconds 1 }
        }

        # Force immediate status re-fetch after any command
        $lastRefresh = [DateTime]::MinValue
    }
}

# ── Entry Point ───────────────────────────────────────────────────────────

Main