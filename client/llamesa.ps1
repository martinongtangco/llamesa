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
$pink   = "`e[38;2;220;120;180m"  # status bar model name
$reset  = "`e[0m"

# ── Config ────────────────────────────────────────────────────────────────
$Script:LLAMESA_DIR    = Join-Path $env:USERPROFILE ".llamesa"
$Script:CONFIG_FILE    = Join-Path $Script:LLAMESA_DIR "config.json"
$Script:Config         = $null
$Script:ActiveServer   = $null
$Script:ChatHistory        = [System.Collections.Generic.List[object]]::new()   # List, not array — `+=` on an array copies the whole thing every append, which gets O(n^2) and visibly laggy over a long chat
$Script:LastTokS           = $null   # updated after each chat response; shown in header badge
$Script:LastStatusRefresh  = $null   # tracks when stat cards were last fetched
$Script:GpuStatus         = $null   # parsed GPU status array from --gpu all
$Script:ActiveMode       = "single" # single, big, dual — tracks which kind of server was last started (local state only, never written to config)
$Script:ChatPort           = $null   # resolved chat endpoint port; re-resolved when ActiveMode changes
$Script:ChatModeSnapshot   = $null   # ActiveMode at the time ChatPort was resolved
$Script:ThinkingEnabled    = $false  # toggled with /think, /nothink; seeded from server status on first resolve
$Script:ThinkingSeeded     = $false
$Script:RenderBuffer       = [System.Collections.Generic.List[string]]::new()
$Script:PrevFrameLines     = 0

# ── Buffered Rendering ────────────────────────────────────────────────────
# Draw-Screen (and everything it calls) writes lines into $Script:RenderBuffer
# via Out-Line instead of calling Write-Host directly. Render-Frame then
# flushes the whole frame in one pass, overwriting the previous frame in
# place (via ANSI "erase to end of line") instead of Clear-Host — Clear-Host
# followed by a fresh repaint is what caused the visible flicker on every
# keystroke while the palette was open. Only the main idle-redraw path uses
# this; one-off command output (Cmd-Start, chat streaming, etc.) still uses
# plain Write-Host and scrolls normally, unaffected.

function Out-Line {
    param([string]$text = "")
    # Split on embedded newlines (e.g. multi-line chat responses) so the
    # buffer's line count always matches real terminal rows — otherwise
    # Render-Frame would under-count how many rows a frame actually used.
    foreach ($part in ($text -split "\r?\n")) {
        $Script:RenderBuffer.Add($part)
    }
}

function Render-Frame {
    $top = [Console]::WindowTop
    [Console]::SetCursorPosition(0, $top)

    foreach ($line in $Script:RenderBuffer) {
        [Console]::Out.Write($line)
        [Console]::Out.Write("`e[K")   # erase to end of line — clears leftover chars regardless of ANSI codes in $line
        [Console]::Out.Write("`r`n")
    }

    # Clear any rows left over from a previous, taller frame
    if ($Script:PrevFrameLines -gt $Script:RenderBuffer.Count) {
        for ($i = $Script:RenderBuffer.Count; $i -lt $Script:PrevFrameLines; $i++) {
            [Console]::Out.Write("`e[K`r`n")
        }
        [Console]::SetCursorPosition(0, $top + $Script:RenderBuffer.Count)
    }

    $Script:PrevFrameLines = $Script:RenderBuffer.Count
    $Script:RenderBuffer.Clear()
}

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
        $result = ssh -o BatchMode=yes -o ConnectTimeout=3 "${sshUser}@${sshHost}" $fullCommand 2>$null

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
        $result = ssh -o BatchMode=yes -o ConnectTimeout=3 "${sshUser}@${sshHost}" "echo ok" 2>&1
        return $result -match "ok"
    } catch {
        return $false
    }
}

# ── Status ────────────────────────────────────────────────────────────────

function Get-ServerStatus {
    $raw = Invoke-ServerCommand "status --gpu all" -raw
    if (-not $raw) { return $null }
    # PowerShell collapses a single-line SSH capture from [string[]] to a
    # plain [string] — without this, $raw[0] below would index the first
    # *character* of that line instead of the line itself, truncating any
    # command whose JSON output happens to come back on exactly one line.
    $raw = @($raw) -split "`r?`n"

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

function Get-BigStatus {
    $raw = Invoke-ServerCommand "status-big" -raw
    if (-not $raw) { return $null }
    $raw = @($raw) -split "`r?`n"   # see Get-ServerStatus — normalize a possible single-line collapse

    try {
        $jsonStartIndex = -1
        for ($i = 0; $i -lt $raw.Count; $i++) {
            if ($raw[$i] -match '^\s*[\[{]' -and $raw[$i] -notmatch '^\s*\[(INFO|WARN|ERROR)\]') {
                $jsonStartIndex = $i
                break
            }
        }
        if ($jsonStartIndex -lt 0) { return $null }
        $jsonText = $raw[$jsonStartIndex..($raw.Count - 1)] -join "`n"
        return $jsonText | ConvertFrom-Json
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

# ── UI: Select Widgets ───────────────────────────────────────────────────
# Arrow-key modal list pickers. Both fully redraw (Clear-Host) on every
# keystroke, same technique already used by the rest of the app (Main's
# loop, Cmd-Servers, etc.) — simple and robust across terminals, at the cost
# of a little flicker. $HeaderFn, if given, is called first each redraw so
# callers can keep printing whatever static context (a title, prior prompts)
# should stay visible above the list.

function Read-SelectList {
    param(
        [Parameter(Mandatory)] [array]$Items,
        [Parameter(Mandatory)] [scriptblock]$LabelFn,
        [scriptblock]$HeaderFn = $null,
        [switch]$Filterable,
        [string]$EmptyText = "No matches."
    )

    if (-not $Items -or $Items.Count -eq 0) { return $null }

    $filter = ""
    $index = 0

    while ($true) {
        $filtered = if ($Filterable -and $filter) {
            @($Items | Where-Object { (& $LabelFn $_) -like "*${filter}*" })
        } else {
            @($Items)
        }
        if ($filtered.Count -eq 0) { $index = 0 } else { $index = [Math]::Min($index, $filtered.Count - 1) }

        Clear-Host
        if ($HeaderFn) { & $HeaderFn }

        if ($filtered.Count -eq 0) {
            Write-Host ("  {0}{1}{2}" -f $gray, $EmptyText, $reset)
        } else {
            for ($i = 0; $i -lt $filtered.Count; $i++) {
                $label = & $LabelFn $filtered[$i]
                if ($i -eq $index) {
                    Write-Host ("  {0}❯ {1}{2}" -f $teal, $label, $reset)
                } else {
                    Write-Host ("    {0}{1}{2}" -f $white, $label, $reset)
                }
            }
        }

        if ($Filterable) {
            Write-Host ""
            Write-Host ("  {0}/{1}{2}█{3}" -f $gray, $reset, $filter, $reset)
        }
        Write-Host ""
        Write-Host ("  {0}up/down navigate  ·  enter select  ·  esc cancel{1}" -f $gray, $reset)

        $key = [Console]::ReadKey($true)
        switch ($key.Key) {
            'UpArrow'   { if ($filtered.Count -gt 0) { $index = ($index - 1 + $filtered.Count) % $filtered.Count } }
            'DownArrow' { if ($filtered.Count -gt 0) { $index = ($index + 1) % $filtered.Count } }
            'Enter'     { if ($filtered.Count -gt 0) { return $filtered[$index] } }
            'Escape'    { return $null }
            'Backspace' { if ($Filterable -and $filter.Length -gt 0) { $filter = $filter.Substring(0, $filter.Length - 1) } }
            default {
                if ($Filterable -and $key.KeyChar -and -not [char]::IsControl($key.KeyChar)) {
                    $filter += $key.KeyChar
                    $index = 0
                }
            }
        }
    }
}

function Read-MultiSelectList {
    param(
        [Parameter(Mandatory)] [array]$Items,
        [Parameter(Mandatory)] [scriptblock]$LabelFn,
        [scriptblock]$HeaderFn = $null,
        [int]$MaxCount = 0   # 0 = unlimited
    )

    if (-not $Items -or $Items.Count -eq 0) { return $null }

    $index = 0
    # List, not [ordered]@{} — OrderedDictionary's indexer is ambiguous with
    # int keys (it also has a *positional* Item(int index) accessor), so
    # $checked[$index] = $true would try to set-by-position on an empty dict
    # and throw "Parameter 'index'" out-of-range instead of adding a key.
    $checkedOrder = [System.Collections.Generic.List[int]]::new()   # insertion order = pick order

    while ($true) {
        Clear-Host
        if ($HeaderFn) { & $HeaderFn }

        for ($i = 0; $i -lt $Items.Count; $i++) {
            $label = & $LabelFn $Items[$i]
            $box = if ($checkedOrder.Contains($i)) { "{0}[x]{1}" -f $teal, $reset } else { "{0}[ ]{1}" -f $gray, $reset }
            if ($i -eq $index) {
                Write-Host ("  {0}❯{1} {2} {3}{4}{5}" -f $teal, $reset, $box, $white, $label, $reset)
            } else {
                Write-Host ("    {0} {1}{2}{3}" -f $box, $white, $label, $reset)
            }
        }

        $capText = if ($MaxCount -gt 0) { " (max {0})" -f $MaxCount } else { "" }
        Write-Host ""
        Write-Host ("  {0}{1} selected{2}{3}" -f $gray, $checkedOrder.Count, $capText, $reset)
        Write-Host ("  {0}up/down navigate  ·  space toggle  ·  enter confirm  ·  esc cancel{1}" -f $gray, $reset)

        $key = [Console]::ReadKey($true)
        switch ($key.Key) {
            'UpArrow'   { $index = ($index - 1 + $Items.Count) % $Items.Count }
            'DownArrow' { $index = ($index + 1) % $Items.Count }
            'Spacebar' {
                if ($checkedOrder.Contains($index)) {
                    $checkedOrder.Remove($index) | Out-Null
                } elseif ($MaxCount -le 0 -or $checkedOrder.Count -lt $MaxCount) {
                    $checkedOrder.Add($index)
                }
            }
            'Enter' {
                if ($checkedOrder.Count -eq 0) {
                    return @($Items[$index])
                }
                return @($checkedOrder | ForEach-Object { $Items[$_] })
            }
            'Escape' { return $null }
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

        Out-Line ("  ${statusDot} ${gpuLabel} ${nameLabel}${barStr} ${vramStr}  ${busyStr}")
    }
}

# ── UI: Header ────────────────────────────────────────────────────────────

function Show-Header {
    param($status = $null)

    $w = [Console]::WindowWidth

    # Line 1 — logo + tagline
    $logo    = "{0}LL{1}a{2}M{3}esa{4}" -f $teal, $amber, $teal, $amber, $reset
    $tagline = "{0}local inference control plane · v0.2{1}" -f $dim, $reset
    Out-Line ("{0} {1}" -f $logo, $tagline)

    # Line 2 — server dot + name + host + port
    if ($Script:ActiveServerName) {
        $dot  = if ($Script:ServerOnline) { "{0}●{1}" -f $teal, $reset } else { "{0}●{1}" -f $red, $reset }
        $port = $Script:ActiveServer.port
        Out-Line ("  {0} {1}{2}{3} · {4}{5}{3} · {4}{6}{3}" -f `
            $dot, $teal, $Script:ActiveServerName, $reset, $gray, $Script:ActiveServer.host, $port)
    }

    # GPU rows
    Show-GpuRow $Script:GpuStatus

    # Lines 3-7 — stat cards. VRAM and per-GPU busy% are already shown above
    # by Show-GpuRow (for every configured GPU, not just one) — repeating
    # them here as cards would either just duplicate that on a single-GPU
    # box, or on a multi-GPU box, misleadingly show only GPU0's numbers
    # under a generic "VRAM"/"GPU" label. So this only covers what Show-GpuRow
    # doesn't: host-level RAM and CPU. Mirrors Show-HeaderBig's card row.
    if ($status) {
        $cpu       = [double]($status.cpu_percent)
        $ramUsedGb = [math]::Round($status.ram_used_mb  / 1024, 1)
        $ramTotGb  = [math]::Round($status.ram_total_mb / 1024, 1)

        $cpuCol = if ($cpu -gt 20)       { $red }   elseif ($cpu -gt 5)        { $amber } else { $teal }
        $ramCol = if ($ramUsedGb -gt 20) { $red }   elseif ($ramUsedGb -gt 10) { $amber } else { $teal }

        $cpuBar = New-Bar $cpu       100        12 $cpuCol
        $ramBar = New-Bar $ramUsedGb $ramTotGb  12 $purple

        $b = $dim; $r = $reset
        $cpuVal = "{0}%" -f $cpu
        $ramVal = if ($ramTotGb -gt 0) { "{0} / {1} GB" -f $ramUsedGb, $ramTotGb } else { "{0} GB" -f $ramUsedGb }

        # Card order: RAM, CPU
        Out-Line ("  ${b}┌───────────────┐${r} ${b}┌───────────────┐${r}")
        Out-Line ("  ${b}│${r} ${gray}$("RAM".PadRight(14))${r}${b}│${r} ${b}│${r} ${gray}$("CPU".PadRight(14))${r}${b}│${r}")
        Out-Line ("  ${b}│${r} ${ramCol}$($ramVal.PadRight(14))${r}${b}│${r} ${b}│${r} ${cpuCol}$($cpuVal.PadRight(14))${r}${b}│${r}")
        Out-Line ("  ${b}│${r} ${ramBar}  ${b}│${r} ${b}│${r} ${cpuBar}  ${b}│${r}")
        Out-Line ("  ${b}└───────────────┘${r} ${b}└───────────────┘${r}")

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
            Out-Line ("  ${gray}MODEL${r}  ${white}$(Get-FriendlyModelName $status.model)${r}  ${ctxPill}  ${thinkingPill}  ${toksPill}  ${gpuPill}")
        } else {
            Out-Line ("  ${gray}MODEL  none${r}")
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
            Out-Line ("  ${dim}updated ${tsStr}${r} ${stale}")
        } else {
            Out-Line ("  ${dim}updated --${r}")
        }
    } else {
        # Offline placeholder — same number of lines as card block so layout is stable
        Out-Line ("  ${dim}┌───────────────┐ ┌───────────────┐${reset}")
        Out-Line ("  ${dim}│  offline      │ │               │${reset}")
        Out-Line ("  ${dim}│               │ │               │${reset}")
        Out-Line ("  ${dim}└───────────────┘ └───────────────┘${reset}")
        Out-Line ("  ${gray}MODEL  none${reset}")

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
            $stale = if ($elapsed -ge 15) { "${red}[stale]${reset}" } else { "" }
            Out-Line ("  ${dim}updated ${tsStr}${reset} ${stale}")
        } else {
            Out-Line ("  ${dim}updated --${reset}")
        }
    }

    Out-Line ("${dim}$("─" * [Math]::Max($w - 1, 20))${reset}")
}

# ── UI: Big-mode header (Vulkan combined-VRAM) ───────────────────────────
# Fully independent of Show-Header above — never calls or modifies it.
# Which of the two renders is dispatched by Show-ActiveHeader below, based on
# $Script:ActiveMode — not by a branch inside Show-Header itself.

function Show-HeaderBig {
    param($status = $null)

    $w = [Console]::WindowWidth

    # Line 1 — logo + tagline
    $logo    = "{0}LL{1}a{2}M{3}esa{4}" -f $teal, $amber, $teal, $amber, $reset
    $tagline = "{0}local inference control plane · v0.2 · Vulkan combined-VRAM{1}" -f $dim, $reset
    Out-Line ("{0} {1}" -f $logo, $tagline)

    # Line 2 — server dot + name + host + port
    if ($Script:ActiveServerName) {
        $dot  = if ($Script:ServerOnline) { "{0}●{1}" -f $teal, $reset } else { "{0}●{1}" -f $red, $reset }
        $port = if ($status -and $status.port) { $status.port } else { $Script:ActiveServer.port }
        Out-Line ("  {0} {1}{2}{3} · {4}{5}{3} · {4}{6}{3}" -f `
            $dot, $teal, $Script:ActiveServerName, $reset, $gray, $Script:ActiveServer.host, $port)
    }

    # Per-device mini-bars, side-by-side, sourced from status-big's devices[]
    if ($status -and $status.devices) {
        foreach ($dev in $status.devices) {
            $vramUsedGb  = [math]::Round($dev.vram_used_bytes  / 1GB, 1)
            $vramTotalGb = [math]::Round($dev.vram_total_bytes / 1GB, 1)
            $filled = if ($vramTotalGb -gt 0) { [int]([math]::Min(($vramUsedGb / $vramTotalGb) * 12, 12)) } else { 0 }
            $empty  = 12 - $filled
            $bar    = ("█" * $filled) + ("░" * $empty)
            $barColor  = if ($status.running) { $blue } else { $gray }
            $busyColor = if ($dev.gpu_busy_percent -gt 0) { $amber } else { $gray }

            $devLabel = "{0}{1,-10}{2}" -f $teal, $dev.id, $reset
            $barStr   = "{0} {1} {2}" -f $barColor, $bar, $reset
            $vramStr  = "{0,-5}/{1,-5} GB" -f $vramUsedGb, $vramTotalGb
            $busyStr  = "{0}{1,-4}%{2}" -f $busyColor, $dev.gpu_busy_percent, $reset

            Out-Line ("  ${devLabel} ${barStr} ${vramStr}  ${busyStr}")
        }
    } else {
        $deviceMsg = if ($Script:ServerOnline) { "no device data" } else { "offline" }
        Out-Line ("  {0}{1}{2}" -f $gray, $deviceMsg, $reset)
    }

    # CPU/RAM stat cards — host-level, single instance (one process spans both GPUs)
    if ($status) {
        $cpu       = [double]($status.cpu_percent)
        $ramUsedGb = [math]::Round($status.ram_used_mb  / 1024, 1)
        $ramTotGb  = [math]::Round($status.ram_total_mb / 1024, 1)

        $cpuCol = if ($cpu -gt 20)       { $red }   elseif ($cpu -gt 5)        { $amber } else { $teal }
        $ramCol = if ($ramUsedGb -gt 20) { $red }   elseif ($ramUsedGb -gt 10) { $amber } else { $teal }

        $cpuBar = New-Bar $cpu       100        12 $cpuCol
        $ramBar = New-Bar $ramUsedGb $ramTotGb  12 $purple

        $b = $dim; $r = $reset
        $cpuVal = "{0}%" -f $cpu
        $ramVal = if ($ramTotGb -gt 0) { "{0} / {1} GB" -f $ramUsedGb, $ramTotGb } else { "{0} GB" -f $ramUsedGb }

        # Card order: RAM, CPU — GPU/VRAM already covered by the per-device bars above.
        Out-Line ("  ${b}┌───────────────┐${r} ${b}┌───────────────┐${r}")
        Out-Line ("  ${b}│${r} ${gray}$("RAM".PadRight(14))${r}${b}│${r} ${b}│${r} ${gray}$("CPU".PadRight(14))${r}${b}│${r}")
        Out-Line ("  ${b}│${r} ${ramCol}$($ramVal.PadRight(14))${r}${b}│${r} ${b}│${r} ${cpuCol}$($cpuVal.PadRight(14))${r}${b}│${r}")
        Out-Line ("  ${b}│${r} ${ramBar}  ${b}│${r} ${b}│${r} ${cpuBar}  ${b}│${r}")
        Out-Line ("  ${b}└───────────────┘${r} ${b}└───────────────┘${r}")

        if ($status.running) {
            $thinkingPill = if ($status.thinking) { "${teal}[thinking on]${reset}" } else { "${gray}[thinking off]${reset}" }
            $ctxPill      = if ($status.ctx -gt 0) { "${teal}[ctx $($status.ctx)]${reset}" } else { "" }
            $toksPill     = if ($Script:LastTokS)  { "${amber}[$($Script:LastTokS) tok/s]${reset}" } else { "" }
            Out-Line ("  ${gray}MODEL${reset}  ${white}$(Get-FriendlyModelName $status.model)${reset}  ${ctxPill}  ${thinkingPill}  ${toksPill}  ${gray}[vulkan · both GPUs]${reset}")
        } else {
            Out-Line ("  ${gray}MODEL  none${reset}")
        }

        if ($Script:LastStatusRefresh) {
            $elapsed = ([DateTime]::Now - $Script:LastStatusRefresh).TotalSeconds
            if ($elapsed -lt 2) { $tsStr = "just now" }
            elseif ($elapsed -lt 60) { $tsStr = "{0}s ago" -f [int]$elapsed }
            elseif ($elapsed -lt 3600) { $tsStr = "{0}m ago" -f [int]($elapsed / 60) }
            else { $tsStr = "{0}h ago" -f [int]($elapsed / 3600) }
            $stale = if ($elapsed -ge 15) { "${red}[stale]${reset}" } else { "" }
            Out-Line ("  ${dim}updated ${tsStr}${reset} ${stale}")
        } else {
            Out-Line ("  ${dim}updated --${reset}")
        }
    } else {
        Out-Line ("  {0}┌───────────────┐ ┌───────────────┐{1}" -f $dim, $reset)
        Out-Line ("  {0}│  offline      │ │               │{1}" -f $dim, $reset)
        Out-Line ("  {0}│               │ │               │{1}" -f $dim, $reset)
        Out-Line ("  {0}└───────────────┘ └───────────────┘{1}" -f $dim, $reset)
        Out-Line ("  {0}MODEL  none{1}" -f $gray, $reset)
        Out-Line ("  {0}updated --{1}" -f $dim, $reset)
    }

    Out-Line ("${dim}$("─" * [Math]::Max($w - 1, 20))${reset}")
}

# ── UI: Dual-mode header (two independent ROCm instances) ────────────────
# Fully independent of Show-Header/Show-HeaderBig above — never calls or
# modifies them. Dispatched by Show-ActiveHeader based on $Script:ActiveMode.

function Show-DualInstanceRow {
    param($inst)

    $running    = ($inst.running -eq $true)
    $gpuId      = $inst.gpu_id
    $cpu        = if ($null -ne $inst.cpu_percent)       { [double]$inst.cpu_percent } else { 0 }
    $ramUsedGb  = if ($null -ne $inst.ram_used_mb)       { [math]::Round($inst.ram_used_mb  / 1024, 1) } else { 0 }
    $ramTotGb   = if ($null -ne $inst.ram_total_mb)      { [math]::Round($inst.ram_total_mb / 1024, 1) } else { 0 }
    $gpuBusy    = if ($null -ne $inst.gpu_busy_percent)  { [double]$inst.gpu_busy_percent } else { 0 }
    $vramUsedGb = if ($null -ne $inst.vram_used_bytes)   { [math]::Round($inst.vram_used_bytes  / 1GB, 1) } else { 0 }
    $vramTotGb  = if ($null -ne $inst.vram_total_bytes)  { [math]::Round($inst.vram_total_bytes / 1GB, 1) } else { 0 }

    $cpuCol  = if ($cpu -gt 20)        { $red   } elseif ($cpu -gt 5)         { $amber } else { $teal }
    $ramCol  = if ($ramUsedGb -gt 20)  { $red   } elseif ($ramUsedGb -gt 10)  { $amber } else { $teal }
    $gpuCol  = if ($gpuBusy -gt 0)     { $amber } else                        { $gray }
    $vramCol = if ($vramUsedGb -lt 5)  { $red   } elseif ($vramUsedGb -lt 15) { $amber } else { $teal }

    $cpuBar  = New-Bar $cpu        100         12 $cpuCol
    $ramBar  = New-Bar $ramUsedGb  $ramTotGb   12 $purple
    $gpuBar  = New-Bar $gpuBusy    100         12 $gpuCol
    $vramBar = New-Bar $vramUsedGb $vramTotGb  12 $blue

    $b = $dim; $r = $reset
    $cpuVal  = "{0}%" -f $cpu
    $ramVal  = if ($ramTotGb -gt 0)  { "{0} / {1} GB" -f $ramUsedGb, $ramTotGb   } else { "{0} GB" -f $ramUsedGb }
    $gpuVal  = "{0}%" -f $gpuBusy
    $vramVal = if ($vramTotGb -gt 0) { "{0} / {1} GB" -f $vramUsedGb, $vramTotGb } else { "{0} GB" -f $vramUsedGb }

    $dotColor = if ($running) { $teal } else { $red }
    Out-Line ("  {0}●{1} {2}{3}{4}" -f $dotColor, $r, $teal, $gpuId, $r)

    # Card order: VRAM, GPU, RAM, CPU — "loaded memory to gpus" first, CPU last.
    Out-Line ("  ${b}┌────────────────────┐${r} ${b}┌───────────────┐${r} ${b}┌───────────────┐${r} ${b}┌───────────────┐${r}")

    $lblRow  = "  ${b}│${r} ${gray}$("VRAM".PadRight(19))${r}${b}│${r} "
    $lblRow += "${b}│${r} ${gray}$("GPU".PadRight(14))${r}${b}│${r} "
    $lblRow += "${b}│${r} ${gray}$("RAM".PadRight(14))${r}${b}│${r} "
    $lblRow += "${b}│${r} ${gray}$("CPU".PadRight(14))${r}${b}│${r}"
    Out-Line $lblRow

    $valRow  = "  ${b}│${r} ${vramCol}$($vramVal.PadRight(19))${r}${b}│${r} "
    $valRow += "${b}│${r} ${gpuCol}$($gpuVal.PadRight(14))${r}${b}│${r} "
    $valRow += "${b}│${r} ${ramCol}$($ramVal.PadRight(14))${r}${b}│${r} "
    $valRow += "${b}│${r} ${cpuCol}$($cpuVal.PadRight(14))${r}${b}│${r}"
    Out-Line $valRow

    $barRow  = "  ${b}│${r} ${vramBar}       ${b}│${r} "
    $barRow += "${b}│${r} ${gpuBar}  ${b}│${r} "
    $barRow += "${b}│${r} ${ramBar}  ${b}│${r} "
    $barRow += "${b}│${r} ${cpuBar}  ${b}│${r}"
    Out-Line $barRow

    Out-Line ("  ${b}└────────────────────┘${r} ${b}└───────────────┘${r} ${b}└───────────────┘${r} ${b}└───────────────┘${r}")

    if ($running) {
        $thinkingPill = if ($inst.thinking) { "${teal}[thinking on]${r}" } else { "${gray}[thinking off]${r}" }
        $ctxPill      = if ($inst.ctx -gt 0) { "${teal}[ctx $($inst.ctx)]${r}" } else { "" }
        Out-Line ("  ${gray}MODEL${r}  ${white}$(Get-FriendlyModelName $inst.model)${r}  ${ctxPill}  ${thinkingPill}")
    } else {
        Out-Line ("  ${gray}MODEL  none${r}")
    }
    Out-Line ""
}

function Show-HeaderDual {
    param($status = $null)

    $w = [Console]::WindowWidth

    $logo    = "{0}LL{1}a{2}M{3}esa{4}" -f $teal, $amber, $teal, $amber, $reset
    $tagline = "{0}local inference control plane · v0.2 · dual independent servers{1}" -f $dim, $reset
    Out-Line ("{0} {1}" -f $logo, $tagline)

    if ($Script:ActiveServerName) {
        $dot = if ($Script:ServerOnline) { "{0}●{1}" -f $teal, $reset } else { "{0}●{1}" -f $red, $reset }
        Out-Line ("  {0} {1}{2}{3} · {4}{5}{3}" -f `
            $dot, $teal, $Script:ActiveServerName, $reset, $gray, $Script:ActiveServer.host)
    }

    $instances = @()
    if ($status -is [array]) { $instances = $status }
    elseif ($status) { $instances = @($status) }

    if ($instances.Count -eq 0) {
        $instanceMsg = if ($Script:ServerOnline) { "no dual instance data" } else { "offline" }
        Out-Line ("  {0}{1}{2}" -f $gray, $instanceMsg, $reset)
    } else {
        foreach ($inst in $instances) {
            Show-DualInstanceRow $inst
        }
    }

    if ($Script:LastStatusRefresh) {
        $elapsed = ([DateTime]::Now - $Script:LastStatusRefresh).TotalSeconds
        if ($elapsed -lt 2) { $tsStr = "just now" }
        elseif ($elapsed -lt 60) { $tsStr = "{0}s ago" -f [int]$elapsed }
        elseif ($elapsed -lt 3600) { $tsStr = "{0}m ago" -f [int]($elapsed / 60) }
        else { $tsStr = "{0}h ago" -f [int]($elapsed / 3600) }
        $stale = if ($elapsed -ge 15) { "${red}[stale]${reset}" } else { "" }
        Out-Line ("  ${dim}updated ${tsStr}${reset} ${stale}")
    } else {
        Out-Line ("  ${dim}updated --${reset}")
    }

    Out-Line ("${dim}$("─" * [Math]::Max($w - 1, 20))${reset}")
}

# ── UI: Header/status dispatch (mode-aware) ──────────────────────────────
# Decides which header renderer and status source to use based on
# $Script:ActiveMode. Neither Show-Header nor Get-ServerStatus is branched
# internally — the mode switch lives entirely in these two new functions.

function Show-ActiveHeader {
    param($status = $null)
    if ($Script:ActiveMode -eq "big") {
        Show-HeaderBig -status $status
    } elseif ($Script:ActiveMode -eq "dual") {
        Show-HeaderDual -status $status
    } else {
        Show-Header -status $status
    }
}

function Get-ActiveStatus {
    if ($Script:ActiveMode -eq "big") {
        return Get-BigStatus
    }
    if ($Script:ActiveMode -eq "dual") {
        return Get-DualStatus
    }
    return Get-ServerStatus
}

# One-time check at client startup: $Script:ActiveMode is local, in-memory state
# that only gets set when *this session* runs /start-big or /start-dual. If a
# -big/-dual server was already started by an earlier session (or over SSH
# directly), a fresh client launch would otherwise default to "single" and
# /chat would try the wrong port. This adopts whichever mode is actually
# running server-side, so relaunching the client doesn't require reloading
# an already-running model.
function Detect-ActiveMode {
    $big = Get-BigStatus
    if ($big -and $big.running) {
        $Script:ActiveMode = "big"
        return
    }

    $dual = Get-DualStatus
    $dualInstances = @()
    if ($dual -is [array]) { $dualInstances = $dual }
    elseif ($dual) { $dualInstances = @($dual) }
    if (@($dualInstances | Where-Object { $_.running -eq $true }).Count -gt 0) {
        $Script:ActiveMode = "dual"
        return
    }

    $Script:ActiveMode = "single"
}

# $Script:GpuStatus is only kept fresh by Main's 2s loop while ActiveMode is
# "single" — Get-ActiveStatus calls Get-BigStatus/Get-DualStatus instead in
# those modes, which don't touch $Script:GpuStatus at all. A session that
# launches straight into (or was ever in) -big/-dual mode would otherwise
# leave $Script:GpuStatus stale or $null, and anything computing "how many
# GPUs does this box have" from it would wrongly see 1. GPU count is static
# hardware info, so fetch it directly once here and cache it, independent of
# whatever mode happens to be active when it's first asked for.
$Script:GpuCount = $null

function Get-GpuCount {
    if ($Script:GpuCount) { return $Script:GpuCount }
    Get-ServerStatus | Out-Null
    if ($Script:GpuStatus -is [array]) {
        $Script:GpuCount = $Script:GpuStatus.Count
    } elseif ($Script:GpuStatus) {
        $Script:GpuCount = 1
    }
    if ($Script:GpuCount) { return $Script:GpuCount }
    return 1   # fetch failed (e.g. transient SSH hiccup) — don't cache a guess, retry next call
}

# ── Server-side command helpers (shared by /start, /stop, /restart) ──────

# Unlike Invoke-ServerCommand -raw (which discards the SSH session's stderr —
# fine for short-lived calls), start-big/start-dual/stop-big/stop-dual/etc.
# fail fast with an error written only to stderr (never stdout, per the
# server's JSON discipline). This variant merges stderr into the captured
# output and reports the exit code, so callers can detect failure before
# entering a wait loop.
function Invoke-ServerCommandChecked {
    param([string]$command)

    if (-not $Script:ActiveServer) {
        Write-Error "No active server configured."
        return [PSCustomObject]@{ Output = @(); ExitCode = 1 }
    }

    $sshUser = $Script:ActiveServer.ssh_user
    $sshHost = $Script:ActiveServer.host
    $llamesaPath = $Script:ActiveServer.llamesa_path
    $fullCommand = "bash ${llamesaPath} ${command} 2>&1"

    try {
        $result = ssh -o BatchMode=yes -o ConnectTimeout=3 "${sshUser}@${sshHost}" $fullCommand
        return [PSCustomObject]@{ Output = $result; ExitCode = $LASTEXITCODE }
    } catch {
        return [PSCustomObject]@{ Output = @("SSH failed: $_"); ExitCode = 1 }
    }
}

function Get-DualStatus {
    param([string]$gpu = "")
    $cmdStr = if ($gpu) { "status-dual --gpu $gpu" } else { "status-dual" }
    $raw = Invoke-ServerCommand $cmdStr -raw
    if (-not $raw) { return $null }
    $raw = @($raw) -split "`r?`n"   # see Get-ServerStatus — normalize a possible single-line collapse

    try {
        $jsonStartIndex = -1
        for ($i = 0; $i -lt $raw.Count; $i++) {
            if ($raw[$i] -match '^\s*[\[{]' -and $raw[$i] -notmatch '^\s*\[(INFO|WARN|ERROR)\]') {
                $jsonStartIndex = $i
                break
            }
        }
        if ($jsonStartIndex -lt 0) { return $null }
        $jsonText = $raw[$jsonStartIndex..($raw.Count - 1)] -join "`n"
        return $jsonText | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Wait-BigLoaded {
    Write-Host ("{0}Waiting for model to load...{1}" -f $cyan, $reset)
    for ($i = 0; $i -lt 150; $i++) {
        Start-Sleep -Seconds 2
        $bigStatus = Get-BigStatus
        if ($bigStatus -and $bigStatus.running) {
            Write-Host ("{0}✓ Model loaded!{1}" -f $green, $reset)
            return
        }
        if (($i + 1) % 15 -eq 0) {
            Write-Host ("  Loading... ({0}s elapsed)" -f (($i + 1) * 2))
        }
    }
    Write-Host ("{0}Timed out waiting for the Vulkan server to load.{1}" -f $red, $reset)
}

function Format-ModelLabel {
    param($m)
    $size = Format-Bytes $m.size_bytes
    $visionTag = if ($m.has_mmproj) { " {0}[vision]{1}" -f $amber, $reset } else { "" }
    return "{0,-30} {1,-12}{2}" -f $m.name, $size, $visionTag
}

# Leaving this blank omits --ctx from the start command entirely, so the
# server falls back to its own configured default_context — the operator's
# intended max — rather than the client guessing/hardcoding a number that
# could be stale relative to what's actually configured on the box.
# Reads a model's native max context length straight from its GGUF metadata
# (via the server's model-context command — llama.cpp's bundled gguf-py,
# no extra install). Returns $null on any failure (gguf-py not found, parse
# error, etc.) so callers can fall back to the server's configured default.
function Get-ModelContextLength {
    param([string]$path)
    if (-not $path) { return $null }
    $raw = Invoke-ServerCommand ("model-context --path ""{0}""" -f $path) -raw
    if (-not $raw) { return $null }
    $raw = @($raw) -split "`r?`n"   # see Get-ServerStatus — normalize a possible single-line collapse
    try {
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
        if ($result.context_length) { return [int]$result.context_length }
        return $null
    } catch {
        return $null
    }
}

function Read-CtxArg {
    param([Nullable[int]]$SuggestedMax = $null)

    if ($SuggestedMax) {
        Write-Host ("  {0}Context size — model's max is {1}. Press enter to use it, or type a smaller value.{2}" -f $gray, $SuggestedMax, $reset)
        $ctx = Read-Host "Context size"
        if (-not $ctx) { return "--ctx $SuggestedMax" }
        return "--ctx $ctx"
    }

    # Couldn't read the model's real native max off its GGUF metadata (gguf-py
    # missing/relocated, unsupported quant, etc.) — say so explicitly instead
    # of silently falling back, since the server's configured default_context
    # can be well below what the model actually supports.
    Write-Host ("  {0}Couldn't detect the model's native max context — leave blank to use the server's configured default (may be lower than the model supports), or enter a value yourself.{1}" -f $amber, $reset)
    $ctx = Read-Host "Context size"
    if ($ctx) { return "--ctx $ctx" }
    return ""
}

# ── Command: /start ───────────────────────────────────────────────────────
# Unified entry point: picks 1..gpuCount models and infers the mode from how
# many were picked — 1 model → combined VRAM across all GPUs (single-GPU
# boxes just use that one GPU); exactly 2 models on a 2-GPU box → one model
# per GPU (independent instances). Absorbs the old dedicated -big/-dual flows.

function Cmd-Start {
    $gpuCount = Get-GpuCount
    $maxSelectable = [Math]::Min([Math]::Max($gpuCount, 1), 2)

    Write-Host ("{0}Fetching available models...{1}" -f $cyan, $reset)
    $models = Get-ModelList
    if (-not $models -or $models.Count -eq 0) {
        Write-Host ("{0}No models found.{1}" -f $red, $reset)
        return
    }

    $labelFn = { param($m) Format-ModelLabel $m }
    $headerFn = {
        if ($gpuCount -gt 1) {
            Write-Host ("  {0}Select model(s) — pick 1 to load across all {1} GPUs (combined VRAM), or 2 to load one per GPU:{2}" -f $white, $gpuCount, $reset)
        } else {
            Write-Host ("  {0}Select a model:{1}" -f $white, $reset)
        }
        Write-Host ""
    }

    $selected = $null
    while ($true) {
        $selected = Read-MultiSelectList -Items $models -LabelFn $labelFn -HeaderFn $headerFn -MaxCount $maxSelectable
        if (-not $selected) { Write-Host ("{0}Cancelled.{1}" -f $gray, $reset); return }
        if ($selected.Count -eq 1 -or ($selected.Count -eq 2 -and $gpuCount -ge 2)) { break }
        Write-Host ("{0}Pick 1 model (combined VRAM) or exactly 2 (one per GPU) — you picked {1}.{2}" -f $red, $selected.Count, $reset)
        Start-Sleep -Seconds 2
    }

    $thinkChoice = Read-SelectList -Items @("on", "off") -LabelFn { param($x) $x } `
        -HeaderFn { Write-Host ("  {0}Thinking mode?{1}" -f $white, $reset) }
    if (-not $thinkChoice) { Write-Host ("{0}Cancelled.{1}" -f $gray, $reset); return }
    $thinking = if ($thinkChoice -eq "on") { "true" } else { "false" }

    # Offer the model's own native max as the default rather than a generic
    # server-configured one — for two models sharing one --ctx value (dual
    # mode), that's the smaller of the two so neither is asked to exceed
    # what it actually supports.
    Write-Host ("{0}Checking model's max context...{1}" -f $gray, $reset)
    $ctxSuggestion = $null
    if ($selected.Count -eq 1) {
        $ctxSuggestion = Get-ModelContextLength $selected[0].path
    } elseif ($selected.Count -eq 2) {
        $ctxA = Get-ModelContextLength $selected[0].path
        $ctxB = Get-ModelContextLength $selected[1].path
        if ($ctxA -and $ctxB) { $ctxSuggestion = [Math]::Min($ctxA, $ctxB) }
        elseif ($ctxA) { $ctxSuggestion = $ctxA }
        elseif ($ctxB) { $ctxSuggestion = $ctxB }
    }
    $ctxArg = Read-CtxArg -SuggestedMax $ctxSuggestion

    if ($selected.Count -eq 1 -and $gpuCount -le 1) {
        $parallelInput = Read-Host "Parallel slots? [1-4, default: 1]"
        if (-not $parallelInput) { $parallelInput = "1" }
        $parallelInput = [math]::Max(1, [math]::Min(4, [int]$parallelInput))
        $parallelArg = "--parallel $parallelInput"

        $selectedModel = $selected[0].name
        Write-Host ""
        Write-Host ("{0}Starting {1}...{2}" -f $cyan, $selectedModel, $reset)
        $raw = Invoke-ServerCommand ("start --model ""{0}"" --gpu 0 --thinking {1} {2} {3}" -f $selectedModel, $thinking, $ctxArg, $parallelArg).Trim() -raw
        Write-Host ($raw -join "`n")

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
        $Script:ActiveMode = "single"
        return
    }

    if ($selected.Count -eq 1) {
        $selectedModel = $selected[0].name
        Write-Host ""
        Write-Host ("{0}Starting {1} (combined VRAM across {2} GPUs)...{3}" -f $cyan, $selectedModel, $gpuCount, $reset)
        $result = Invoke-ServerCommandChecked ("start-big --model ""{0}"" --thinking {1} {2}" -f $selectedModel, $thinking, $ctxArg)
        Write-Host ($result.Output -join "`n")
        if ($result.ExitCode -ne 0) {
            Write-Host ("{0}start failed — see error above.{1}" -f $red, $reset)
            return
        }
        $Script:ActiveMode = "big"
        Wait-BigLoaded
        return
    }

    # 2 models on a 2-GPU box: one per GPU (server keys these r9700a/r9700b — picker order maps in order)
    $modelA = $selected[0].name
    $modelB = $selected[1].name
    Write-Host ""
    Write-Host ("{0}Starting one model per GPU: {1} · {2}...{3}" -f $cyan, $modelA, $modelB, $reset)
    $result = Invoke-ServerCommandChecked ("start-dual --model-r9700a ""{0}"" --model-r9700b ""{1}"" --thinking {2} {3}" -f $modelA, $modelB, $thinking, $ctxArg)
    Write-Host ($result.Output -join "`n")
    if ($result.ExitCode -ne 0) {
        Write-Host ("{0}start failed — see error above.{1}" -f $red, $reset)
        return
    }
    $Script:ActiveMode = "dual"

    Write-Host ("{0}Waiting for both instances to load...{1}" -f $cyan, $reset)
    for ($i = 0; $i -lt 150; $i++) {
        Start-Sleep -Seconds 2
        $dualStatus = Get-DualStatus
        if ($dualStatus -is [array] -and (@($dualStatus | Where-Object { $_.running -eq $true })).Count -eq 2) {
            Write-Host ("{0}✓ Both models loaded!{1}" -f $green, $reset)
            break
        }
        if (($i + 1) % 15 -eq 0) { Write-Host ("  Loading... ({0}s elapsed)" -f (($i + 1) * 2)) }
    }
}

# ── Command: /stop ────────────────────────────────────────────────────────
# Unified entry point: detects whatever's actually running (combined-VRAM,
# dual instances, or plain single-GPU) and stops it directly with no prompt
# when there's only one thing running; asks which (or "Both") otherwise.

function Cmd-Stop {
    $running = @()

    $bigStatus = Get-BigStatus
    if ($bigStatus -and $bigStatus.running) {
        $running += [PSCustomObject]@{ Label = "{0} (combined VRAM)" -f (Get-FriendlyModelName $bigStatus.model); Mode = "big"; GpuArg = $null }
    } else {
        $dualStatus = Get-DualStatus
        $dualInstances = @()
        if ($dualStatus -is [array]) { $dualInstances = $dualStatus } elseif ($dualStatus) { $dualInstances = @($dualStatus) }
        foreach ($inst in @($dualInstances | Where-Object { $_.running -eq $true })) {
            $running += [PSCustomObject]@{ Label = "{0}: {1}" -f $inst.gpu_id, (Get-FriendlyModelName $inst.model); Mode = "dual"; GpuArg = $inst.gpu_id }
        }

        if ($running.Count -eq 0) {
            # $Script:GpuStatus may be stale/unset if we just came from -big/-dual
            # mode (only Main's "single" branch keeps it refreshed) — query fresh.
            Get-ServerStatus | Out-Null
            $runningGpus = @()
            if ($Script:GpuStatus -is [array]) { $runningGpus = @($Script:GpuStatus | Where-Object { $_.running -eq $true }) }
            elseif ($Script:GpuStatus -and $Script:GpuStatus.running) { $runningGpus = @($Script:GpuStatus) }
            foreach ($g in $runningGpus) {
                $running += [PSCustomObject]@{ Label = "GPU{0} {1}" -f $g.gpu_id, $g.gpu_name; Mode = "single"; GpuArg = $g.gpu_id }
            }
        }
    }

    if ($running.Count -eq 0) {
        Write-Host ("{0}Nothing running.{1}" -f $gray, $reset)
        return
    }

    $targets = $running
    if ($running.Count -gt 1) {
        $bothOption = [PSCustomObject]@{ Label = "Both"; Mode = "__both__"; GpuArg = $null }
        $pick = Read-SelectList -Items (@($running) + @($bothOption)) -LabelFn { param($t) $t.Label } `
            -HeaderFn { Write-Host ("  {0}Stop which?{1}" -f $white, $reset) }
        if (-not $pick) { Write-Host ("{0}Cancelled.{1}" -f $gray, $reset); return }
        $targets = if ($pick.Mode -eq "__both__") { $running } else { @($pick) }
    }

    foreach ($t in $targets) {
        Write-Host ("{0}Stopping {1}...{2}" -f $cyan, $t.Label, $reset)
        switch ($t.Mode) {
            "big" {
                $result = Invoke-ServerCommandChecked "stop-big"
                Write-Host ($result.Output -join "`n")
                if ($result.ExitCode -eq 0 -and $Script:ActiveMode -eq "big") { $Script:ActiveMode = "single" }
            }
            "dual" {
                $result = Invoke-ServerCommandChecked ("stop-dual --gpu {0}" -f $t.GpuArg)
                Write-Host ($result.Output -join "`n")
            }
            "single" {
                $raw = Invoke-ServerCommand ("stop --gpu {0}" -f $t.GpuArg) -raw
                Write-Host ($raw -join "`n")
            }
        }
    }

    $stoppedAllDual = ($targets.Count -eq $running.Count) -and (@($targets | Where-Object { $_.Mode -eq "dual" }).Count -gt 0)
    if ($stoppedAllDual -and $Script:ActiveMode -eq "dual") { $Script:ActiveMode = "single" }
}

# ── Command: /restart ─────────────────────────────────────────────────────
# Unified entry point: detects which mode is actually running (or was last
# running) and delegates to that mode's restart flow.

function Restart-SingleMode {
    if (-not $Script:ActiveServer) { Write-Host ("{0}No active server.{1}" -f $red, $reset); return }

    $sshUser     = $Script:ActiveServer.ssh_user
    $sshHost     = $Script:ActiveServer.host
    $llamesaPath = $Script:ActiveServer.llamesa_path
    $port        = $Script:ActiveServer.port

    # Read saved session so we know what to restart with
    $sessionJson = ssh -o BatchMode=yes -o ConnectTimeout=3 "${sshUser}@${sshHost}" "cat ~/.llamesa/last_session.json 2>/dev/null" 2>$null
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
    # Get GPU id from running status. This relies on $Script:GpuStatus still
    # holding the pre-stop snapshot: Cmd-Stop's single-mode fallback (above)
    # refreshes it fresh right before issuing the stop, and nothing since has
    # overwritten it — fetching live here instead would just show nothing
    # running (we already stopped it) and always fall back to GPU 0.
    $gpuArg = 0
    if ($Script:GpuStatus -is [array]) {
        $rg = $Script:GpuStatus | Where-Object { $_.running -eq $true } | Select-Object -First 1
        if ($rg) { $gpuArg = $rg.gpu_id }
    }
    $startCmd = "nohup bash ${llamesaPath} start --model `"${modelName}`" --gpu ${gpuArg} --thinking ${thinking} --ctx ${ctx} >> ~/.llamesa/restart.log 2>&1 &"
    ssh -o BatchMode=yes -o ConnectTimeout=3 "${sshUser}@${sshHost}" $startCmd 2>$null | Out-Null

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
    $Script:ActiveMode = "single"
}

function Restart-BigMode {
    Write-Host ("{0}Combined-VRAM mode doesn't remember the last model — select it again.{1}" -f $gray, $reset)
    $models = Get-ModelList
    if (-not $models -or $models.Count -eq 0) {
        Write-Host ("{0}No models found.{1}" -f $red, $reset)
        return
    }

    $model = Read-SelectList -Items $models -LabelFn { param($m) Format-ModelLabel $m } `
        -HeaderFn { Write-Host ("  {0}Select model (combined VRAM):{1}" -f $white, $reset) }
    if (-not $model) { Write-Host ("{0}Cancelled.{1}" -f $gray, $reset); return }

    $thinkChoice = Read-SelectList -Items @("on", "off") -LabelFn { param($x) $x } `
        -HeaderFn { Write-Host ("  {0}Thinking mode?{1}" -f $white, $reset) }
    if (-not $thinkChoice) { Write-Host ("{0}Cancelled.{1}" -f $gray, $reset); return }
    $thinking = if ($thinkChoice -eq "on") { "true" } else { "false" }

    Write-Host ("{0}Checking model's max context...{1}" -f $gray, $reset)
    $ctxArg = Read-CtxArg -SuggestedMax (Get-ModelContextLength $model.path)

    Write-Host ""
    Write-Host ("{0}Restarting with {1} (combined VRAM)...{2}" -f $cyan, $model.name, $reset)
    $result = Invoke-ServerCommandChecked ("restart-big --model ""{0}"" --thinking {1} {2}" -f $model.name, $thinking, $ctxArg)
    Write-Host ($result.Output -join "`n")

    if ($result.ExitCode -ne 0) {
        Write-Host ("{0}restart failed — see error above.{1}" -f $red, $reset)
        return
    }

    $Script:ActiveMode = "big"
    Wait-BigLoaded
}

function Restart-DualMode {
    $dualStatus = Get-DualStatus
    $knownInstances = @()
    if ($dualStatus -is [array]) { $knownInstances = $dualStatus }

    $gpuArg = ""
    if ($knownInstances.Count -gt 1) {
        $bothOption = [PSCustomObject]@{ gpu_id = $null; __label = "Both" }
        $items = @($knownInstances | ForEach-Object { [PSCustomObject]@{ gpu_id = $_.gpu_id; __label = $_.gpu_id } }) + @($bothOption)
        $pick = Read-SelectList -Items $items -LabelFn { param($x) $x.__label } `
            -HeaderFn { Write-Host ("  {0}Restart which instance?{1}" -f $white, $reset) }
        if (-not $pick) { Write-Host ("{0}Cancelled.{1}" -f $gray, $reset); return }
        if ($pick.gpu_id) { $gpuArg = $pick.gpu_id }
    }

    $cmdStr = if ($gpuArg) { "restart-dual --gpu $gpuArg" } else { "restart-dual" }
    $scopeLabel = if ($gpuArg) { $gpuArg } else { "both" }
    Write-Host ("{0}Restarting dual instance(s) ({1}) with remembered model(s)...{2}" -f $cyan, $scopeLabel, $reset)
    $result = Invoke-ServerCommandChecked $cmdStr
    Write-Host ($result.Output -join "`n")

    if ($result.ExitCode -ne 0) {
        Write-Host ("{0}restart failed — see error above.{1}" -f $red, $reset)
        return
    }

    $Script:ActiveMode = "dual"

    Write-Host ("{0}Waiting for instance(s) to load...{1}" -f $cyan, $reset)
    for ($i = 0; $i -lt 150; $i++) {
        Start-Sleep -Seconds 2
        $s = Get-DualStatus -gpu $gpuArg
        $ready = $false
        if ($gpuArg) {
            $ready = ($s -and $s.running -eq $true)
        } else {
            $ready = ($s -is [array] -and (@($s | Where-Object { $_.running -eq $true })).Count -eq 2)
        }
        if ($ready) {
            Write-Host ("{0}✓ Loaded!{1}" -f $green, $reset)
            break
        }
        if (($i + 1) % 15 -eq 0) { Write-Host ("  Loading... ({0}s elapsed)" -f (($i + 1) * 2)) }
    }
}

function Cmd-Restart {
    $bigStatus = Get-BigStatus
    if ($bigStatus -and $bigStatus.running) {
        Restart-BigMode
        return
    }

    $dualStatus = Get-DualStatus
    $dualInstances = @()
    if ($dualStatus -is [array]) { $dualInstances = $dualStatus } elseif ($dualStatus) { $dualInstances = @($dualStatus) }
    if (@($dualInstances | Where-Object { $_.running -eq $true }).Count -gt 0) {
        Restart-DualMode
        return
    }

    Restart-SingleMode
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

# Which port(s) to check depends on the active mode — big/dual run on
# entirely different ports than the v1 per-GPU path Get-ActiveGpuPort
# resolves (e.g. combined-VRAM's vulkan_split.port), so this mirrors the
# same mode dispatch Resolve-ChatEndpoint already uses for chat.
function Get-HealthCheckTargets {
    $targets = @()
    switch ($Script:ActiveMode) {
        "big" {
            $bigStatus = Get-BigStatus
            if ($bigStatus -and $bigStatus.port) {
                $targets += [PSCustomObject]@{ Label = "combined VRAM"; Port = $bigStatus.port }
            }
        }
        "dual" {
            $dualStatus = Get-DualStatus
            $instances = @()
            if ($dualStatus -is [array]) { $instances = $dualStatus } elseif ($dualStatus) { $instances = @($dualStatus) }
            foreach ($inst in @($instances | Where-Object { $_.running -eq $true -and $_.port })) {
                $targets += [PSCustomObject]@{ Label = $inst.gpu_id; Port = $inst.port }
            }
        }
        default {
            $targets += [PSCustomObject]@{ Label = "GPU"; Port = (Get-ActiveGpuPort) }
        }
    }
    return $targets
}

function Cmd-Health {
    Write-Host ("{0}Checking server health...{1}" -f $cyan, $reset)

    $hostAddr = $Script:ActiveServer.host
    $targets = Get-HealthCheckTargets

    if ($targets.Count -eq 0) {
        Write-Host ("{0}Nothing running to check.{1}" -f $gray, $reset)
        return
    }

    foreach ($t in $targets) {
        if ($targets.Count -gt 1) {
            Write-Host ""
            Write-Host ("{0}── {1} (port {2}) ──{3}" -f $teal, $t.Label, $t.Port, $reset)
        }
        $port = $t.Port

        # Check /health endpoint
        try {
            $health = Invoke-RestMethod -Uri "http://${hostAddr}:${port}/health" -TimeoutSec 5 -ErrorAction Stop
            Write-Host ("{0}✓ /health endpoint OK (port {1}){2}" -f $green, $port, $reset)
            Write-Host ($health | ConvertTo-Json)
        } catch {
            Write-Host ("{0}✗ /health endpoint failed (port {1}): {2}{3}" -f $red, $port, $_.Exception.Message, $reset)
        }

        Write-Host ""

        # Check /v1/models endpoint
        try {
            $models = Invoke-RestMethod -Uri "http://${hostAddr}:${port}/v1/models" -TimeoutSec 5 -ErrorAction Stop
            Write-Host ("{0}✓ /v1/models endpoint OK (port {1}){2}" -f $green, $port, $reset)
            Write-Host ($models | ConvertTo-Json -Depth 5)
        } catch {
            Write-Host ("{0}✗ /v1/models endpoint failed (port {1}): {2}{3}" -f $red, $port, $_.Exception.Message, $reset)
        }

        Write-Host ""
    }
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

# ── Chat ──────────────────────────────────────────────────────────────────
# Chat is no longer a separate mode — bare text typed at the fixed bottom
# input is sent as a chat message directly (see Main). These are the pieces
# that used to live inline in a dedicated Cmd-Chat loop: endpoint resolution,
# history rendering, and the streaming send itself.

# Resolves which port/model to talk to for the active mode, caching the
# result until $Script:ActiveMode changes (so it doesn't re-prompt "which
# GPU?" on every single message in dual mode). Returns $false if nothing is
# running to chat with.
function Resolve-ChatEndpoint {
    if ($Script:ChatPort -and $Script:ChatModeSnapshot -eq $Script:ActiveMode) {
        return $true
    }

    # -big sessions: one model, one endpoint, but still on a different port
    # than the v1 single-GPU path Get-ActiveGpuPort resolves.
    $bigPort = $null
    $bigThinking = $null
    if ($Script:ActiveMode -eq "big") {
        $bigStatus = Get-BigStatus
        if (-not $bigStatus -or -not $bigStatus.running) {
            Write-Host ("{0}No running model to chat with.{1}" -f $red, $reset)
            return $false
        }
        $bigPort = $bigStatus.port
        $bigThinking = [bool]$bigStatus.thinking
    }

    # -dual sessions: pick which GPU's endpoint to chat against, if both are running.
    $dualPort = $null
    $dualThinking = $null
    if ($Script:ActiveMode -eq "dual") {
        $dualStatus = Get-DualStatus
        $dualInstances = @()
        if ($dualStatus -is [array]) { $dualInstances = $dualStatus }
        elseif ($dualStatus) { $dualInstances = @($dualStatus) }

        $runningInstances = @($dualInstances | Where-Object { $_.running -eq $true })
        if ($runningInstances.Count -eq 0) {
            Write-Host ("{0}No running model to chat with.{1}" -f $red, $reset)
            return $false
        } elseif ($runningInstances.Count -eq 1) {
            $dualPort = $runningInstances[0].port
            $dualThinking = [bool]$runningInstances[0].thinking
        } else {
            $pick = Read-SelectList -Items $runningInstances -LabelFn { param($i) "{0}  {1}" -f $i.gpu_id, $i.model } `
                -HeaderFn { Write-Host ("  {0}Which model do you want to chat with?{1}" -f $white, $reset) }
            if (-not $pick) { return $false }
            $dualPort = $pick.port
            $dualThinking = [bool]$pick.thinking
        }
    }

    if ($Script:ActiveMode -eq "single" -and (-not $Script:ServerStatus -or -not $Script:ServerStatus.running)) {
        Write-Host ("{0}No running model to chat with.{1}" -f $red, $reset)
        return $false
    }

    $Script:ChatPort = if ($dualPort) { $dualPort } elseif ($bigPort) { $bigPort } else { Get-ActiveGpuPort }

    # Seed thinking mode from server status once; after that /think and /nothink own it.
    if (-not $Script:ThinkingSeeded) {
        if ($null -ne $dualThinking) { $Script:ThinkingEnabled = $dualThinking }
        elseif ($null -ne $bigThinking) { $Script:ThinkingEnabled = $bigThinking }
        elseif ($Script:ServerStatus -and $Script:ServerStatus.thinking) { $Script:ThinkingEnabled = [bool]$Script:ServerStatus.thinking }
        $Script:ThinkingSeeded = $true
    }

    $Script:ChatModeSnapshot = $Script:ActiveMode
    return $true
}

# Renders $Script:ChatHistory — called as part of every screen redraw so
# chat is always visible, not just in a dedicated mode.
function Show-ChatHistory {
    foreach ($msg in $Script:ChatHistory) {
        if ($msg.role -eq "user") {
            Out-Line ("  {0}You:{1}" -f $cyan, $reset)
            Out-Line ("  {0}{1}{2}" -f $white, $msg.content, $reset)
            Out-Line ""
        }
        elseif ($msg.role -eq "assistant") {
            Out-Line ("  {0}Model:{1}" -f $amber, $reset)

            if ($msg.thinking) {
                Out-Line ("  {0}⟨thinking⟩{1}" -f $gray, $reset)
                Out-Line ("  {0}{1}{2}" -f $gray, $msg.thinking, $reset)
                Out-Line ("  {0}⟨/thinking⟩{1}" -f $gray, $reset)
            }

            Out-Line ("  {0}{1}{2}" -f $white, $msg.content, $reset)

            if ($msg.tok_s) {
                Out-Line ""
                Out-Line ("  {0}─{1}" -f $dim, "───────────────────────────────────────────────", $reset)
                $thinkingDisplay = if ($msg.thinking_toks) { "$($msg.thinking_toks) thinking · " } else { "" }
                Out-Line ("  {0}⬡ {1} prompt · {2}{3} gen · {4} tok/s · {5}s{6}" -f `
                    $amber, $msg.prompt_toks, $thinkingDisplay, $msg.gen_toks, $msg.tok_s, $msg.duration, $reset)
            }

            Out-Line ""
        }
    }
}

function Cmd-ClearChat {
    $Script:ChatHistory.Clear()
    Write-Host ("{0}Chat history cleared.{1}" -f $gray, $reset)
}

function Cmd-Think {
    $Script:ThinkingEnabled = $true
    $Script:ThinkingSeeded = $true
    Write-Host ("{0}Thinking mode ON — the model will reason before responding.{1}" -f $amber, $reset)
}

function Cmd-NoThink {
    $Script:ThinkingEnabled = $false
    $Script:ThinkingSeeded = $true
    Write-Host ("{0}Thinking mode OFF.{1}" -f $gray, $reset)
}

# Sends one message and streams the response inline. Blocks the main loop
# for the duration of the response, same as the app already does for every
# other command — the idle auto-refresh resumes once this returns.
function Send-ChatMessage {
    param([string]$text)

    if (-not (Resolve-ChatEndpoint)) { return }

    $port = $Script:ChatPort
    $hostAddr = $Script:ActiveServer.host

    $Script:ChatHistory.Add([PSCustomObject]@{
        role    = "user"
        content = $text
    })

    $messages = @()
    foreach ($msg in $Script:ChatHistory) {
        if ($msg.role -eq "user" -or $msg.role -eq "assistant") {
            $messages += [PSCustomObject]@{
                role    = $msg.role
                content = $msg.content
            }
        }
    }

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
    # Always send enable_thinking explicitly (true or false) rather than omitting
    # it when off — some chat templates (e.g. Qwen3.6) default to thinking-on when
    # the kwarg is absent, so omission failed to actually turn thinking off for them.
    # Unrecognized template kwargs are harmlessly ignored by templates that don't use them.
    $requestBody | Add-Member -NotePropertyName chat_template_kwargs -NotePropertyValue ([PSCustomObject]@{ enable_thinking = $Script:ThinkingEnabled })
    $body = $requestBody | ConvertTo-Json -Depth 5

    # StringBuilder, not `+=` — a long thinking/response stream appends per
    # token, and `+=` on a string copies the whole thing each time (O(n^2)
    # over a long generation).
    $assistantSb      = [System.Text.StringBuilder]::new()
    $thinkingSb        = [System.Text.StringBuilder]::new()
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
                                [void]$thinkingSb.Append($reasoningChunk)
                                Write-Host $reasoningChunk -NoNewline -ForegroundColor DarkGray
                            }
                            if ($contentChunk) {
                                if ($assistantSb.Length -eq 0) {
                                    Write-Host ""
                                    Write-Host ""
                                }
                                [void]$assistantSb.Append($contentChunk)
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
        $assistantContent = $assistantSb.ToString()
        $thinkingContent  = $thinkingSb.ToString()

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
        $Script:ChatHistory.Add([PSCustomObject]@{
            role         = "assistant"
            content      = $assistantContent
            thinking     = $thinkingContent
            prompt_toks  = $promptToks
            thinking_toks = $thinkingToks
            gen_toks     = $genToks
            tok_s        = $tokS
            duration     = [math]::Round($duration, 1)
        })

    } catch {
        Write-Host ("{0}Error: {1}{2}" -f $red, $_.Exception.Message, $reset)
        Write-Host ("{0}Detail: {1}{2}" -f $red, $_.Exception.ToString(), $reset)
        Write-Host ("{0}Stack: {1}{2}" -f $red, $_.ScriptStackTrace, $reset)
    }
}

# ── Command: /servers ─────────────────────────────────────────────────────

function Cmd-Servers {
    Write-Host ""
    Write-Host ("  {0}Configured Servers:{1}" -f $teal, $reset)
    Write-Host ""
    Write-Host ("      {0,-15} {1,-20} {2,-15} {3}" -f "NAME", "HOST", "SSH USER", "PORT")

    $i = 1
    foreach ($prop in $Script:Config.servers.PSObject.Properties) {
        $s = $prop.Value
        $isActive = ($prop.Name -eq $Script:Config.active_server)
        $marker = if ($isActive) { "{0}←{1}" -f $green, $reset } else { " " }

        # Base configured port always shown; for the active server, if a
        # -dual or -big session is actually running, show its live port(s)
        # instead — a single "port" field is misleading once a box is
        # running multiple instances on multiple ports at once.
        $portLabel = if ($s.port) { "$($s.port)" } else { "-" }
        if ($isActive -and $Script:ActiveMode -eq "dual") {
            $dualStatus = Get-DualStatus
            $instances = @()
            if ($dualStatus -is [array]) { $instances = $dualStatus } elseif ($dualStatus) { $instances = @($dualStatus) }
            $running = @($instances | Where-Object { $_.running -eq $true -and $_.port })
            if ($running.Count -gt 0) {
                $portLabel = ($running | ForEach-Object { "$($_.gpu_id):$($_.port)" }) -join ", "
            }
        } elseif ($isActive -and $Script:ActiveMode -eq "big") {
            $bigStatus = Get-BigStatus
            if ($bigStatus -and $bigStatus.running -and $bigStatus.port) {
                $portLabel = "big:$($bigStatus.port)"
            }
        }

        Write-Host ("    {0} {1,-15} {2,-20} {3,-15} {4}" -f $marker, $prop.Name, $s.host, $s.ssh_user, $portLabel)
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

# ── Command Palette ───────────────────────────────────────────────────────
# Single source of truth for "/" — both what the palette lists and what
# typing a full command name (e.g. "/start" + Enter) dispatches to.

$Script:PaletteCommands = @(
    [PSCustomObject]@{ Name = "start";    Desc = "start server — model(s), thinking, context" }
    [PSCustomObject]@{ Name = "stop";     Desc = "stop what's running" }
    [PSCustomObject]@{ Name = "restart";  Desc = "stop + start with same settings" }
    [PSCustomObject]@{ Name = "health";   Desc = "ping /health and /v1/models" }
    [PSCustomObject]@{ Name = "logs";     Desc = "tail verbose server output" }
    [PSCustomObject]@{ Name = "models";   Desc = "list downloaded models + sizes" }
    [PSCustomObject]@{ Name = "download"; Desc = "download from huggingface" }
    [PSCustomObject]@{ Name = "clear";    Desc = "clear chat history" }
    [PSCustomObject]@{ Name = "think";    Desc = "enable thinking mode" }
    [PSCustomObject]@{ Name = "nothink";  Desc = "disable thinking mode" }
    [PSCustomObject]@{ Name = "servers";  Desc = "manage server profiles" }
    [PSCustomObject]@{ Name = "config";   Desc = "view/edit config" }
    [PSCustomObject]@{ Name = "quit";     Desc = "exit LLaMesa" }
)

$Script:ServerDependentCommands = @("start", "stop", "restart", "health", "logs", "models", "download")

function Invoke-PaletteCommand {
    param([string]$cmd)

    # Fail fast instead of blocking on a doomed SSH attempt — $Script:ServerOnline
    # is refreshed every cycle by Main, so this is at most one refresh interval
    # stale. /servers, /config, /clear, /think, /nothink, and /quit don't touch
    # the current server at all, so they're left free to run regardless.
    if ($cmd -in $Script:ServerDependentCommands -and -not $Script:ServerOnline) {
        Write-Host ("{0}Server unreachable — check the connection and try again.{1}" -f $red, $reset)
        return
    }

    switch ($cmd) {
        "start"    { Cmd-Start;    Read-Host "`nPress Enter to continue" | Out-Null }
        "stop"     { Cmd-Stop;     Read-Host "`nPress Enter to continue" | Out-Null }
        "restart"  { Cmd-Restart;  Read-Host "`nPress Enter to continue" | Out-Null }
        "health"   { Cmd-Health;   Read-Host "`nPress Enter to continue" | Out-Null }
        "logs"     { Cmd-Logs }
        "models"   { Cmd-Models;   Read-Host "`nPress Enter to continue" | Out-Null }
        "download" { Cmd-Download; Read-Host "`nPress Enter to continue" | Out-Null }
        "clear"    { Cmd-ClearChat }
        "think"    { Cmd-Think }
        "nothink"  { Cmd-NoThink }
        "servers"  { Cmd-Servers }
        "config"   { Cmd-Config }
        "help"     { } # "/" already opens the palette — kept as a recognized no-op alias
        "quit"     { [Console]::CursorVisible = $true; Write-Host ("{0}Goodbye!{1}" -f $gray, $reset); exit 0 }
        default    { Write-Host ("{0}Unknown command: /{1}{2}" -f $red, $cmd, $reset); Start-Sleep -Seconds 1 }
    }
}

function Test-ModelLoaded {
    switch ($Script:ActiveMode) {
        "big" {
            $s = Get-BigStatus
            return [bool]($s -and $s.running)
        }
        "dual" {
            $s = Get-DualStatus
            $inst = @()
            if ($s -is [array]) { $inst = $s } elseif ($s) { $inst = @($s) }
            return (@($inst | Where-Object { $_.running -eq $true }).Count -gt 0)
        }
        default {
            return [bool]($Script:ServerStatus -and $Script:ServerStatus.running)
        }
    }
}

# ── Main Loop ─────────────────────────────────────────────────────────────
# Non-blocking key poll — this is what makes the dashboard actually
# auto-refresh while idle (previously gated behind a blocking Read-Host) and
# lets "/" open a live-filtering palette above a fixed bottom input, Pi
# Agent-style. Bare text is sent as a chat message; the chat scrollback and
# "/" palette are both rendered as part of the same full-screen redraw.

# ── UI: Status Bar ────────────────────────────────────────────────────────
# The Pi Agent-style single-line footer directly above the input: model,
# thinking mode, GPU mode, server, connection. Reuses the $status object the
# 2s poll already fetched — no extra SSH round trip per redraw.

# status-big/status-dual sometimes echo the model's resolved .gguf file path
# instead of the friendly directory name used everywhere else (list-models,
# the /start picker) — a full path is both the wrong label and, printed on
# the single-line status bar, long enough to wrap the terminal and corrupt
# the buffered redraw. Normalize to that friendly name, and hard-cap length
# as a defensive backstop against any other unexpectedly long value.
function Get-FriendlyModelName {
    param([string]$raw)
    if (-not $raw) { return $raw }
    $name = $raw
    if ($name -match '[\\/]') {
        $parent = Split-Path -Path $name -Parent
        if ($parent) {
            $leaf = Split-Path -Path $parent -Leaf
            if ($leaf) { $name = $leaf }
        }
    }
    if ($name.Length -gt 40) { $name = $name.Substring(0, 37) + "..." }
    return $name
}

function Get-StatusBarModelName {
    param($status)
    if (-not $status) { return "no model" }
    if ($status -is [array]) {
        $running = @($status | Where-Object { $_.running -eq $true })
        if ($running.Count -eq 2) { return "{0} + {1}" -f (Get-FriendlyModelName $running[0].model), (Get-FriendlyModelName $running[1].model) }
        if ($running.Count -eq 1) { return Get-FriendlyModelName $running[0].model }
        return "no model"
    }
    if ($status.running -and $status.model) { return Get-FriendlyModelName $status.model }
    return "no model"
}

function Get-StatusBarThinking {
    param($status)
    if ($status -is [array]) {
        $running = @($status | Where-Object { $_.running -eq $true })
        if ($running.Count -gt 0) { return [bool]$running[0].thinking }
    } elseif ($status -and $status.running) {
        return [bool]$status.thinking
    }
    return $Script:ThinkingEnabled
}

function Show-StatusBar {
    param($status)

    $w = [Console]::WindowWidth
    Out-Line ("{0}{1}{2}" -f $dim, ("─" * [Math]::Max($w - 1, 20)), $reset)

    $modelName = Get-StatusBarModelName $status
    $thinking  = if (Get-StatusBarThinking $status) { "on" } else { "off" }
    $serverStr = if ($Script:ActiveServerName) { "{0}@{1}" -f $Script:ActiveServerName, $Script:ActiveServer.host } else { "no server" }
    $onlineStr = if ($Script:ServerOnline) { "{0}● online{1}" -f $green, $reset } else { "{0}● offline{1}" -f $red, $reset }
    $sep = "{0}|{1}" -f $gray, $reset

    $line  = "  {0}{1}{2}" -f $pink, $modelName, $reset
    $line += "  {0}  {1}think:{2}{3}" -f $sep, $cyan, $thinking, $reset
    $line += "  {0}  {1}{2} mode{3}" -f $sep, $cyan, $Script:ActiveMode, $reset
    $line += "  {0}  {1}{2}{3}" -f $sep, $amber, $serverStr, $reset
    $line += "  {0}  {1}" -f $sep, $onlineStr
    Out-Line $line
}

# ── UI: Main Screen ───────────────────────────────────────────────────────
# Everything is top-anchored — no padding to push the input to the last row.
# Dashboard, chat scrollback, status bar, and input all flow directly one
# after another; the palette (when open) drops down right under the input,
# Pi Agent-style, instead of being pinned separately with dead space between.

function Draw-Screen {
    param($status, [string]$inputBuffer, [bool]$paletteOpen, [string]$paletteFilter, [int]$paletteIndex)

    $Script:RenderBuffer.Clear()

    Show-ActiveHeader -status $status
    Show-ChatHistory

    if ($Script:InputHint) {
        Out-Line ("  {0}{1}{2}" -f $amber, $Script:InputHint, $reset)
    }

    Show-StatusBar $status

    # Self-drawn block cursor instead of relying on the native terminal
    # cursor — thicker, always visible regardless of terminal cursor style,
    # and its position in the text is exact since it's just another glyph.
    $prefix = if ($paletteOpen) { "/$paletteFilter" } else { $inputBuffer }
    Out-Line ("  {0}›{1} {2}{3}█{4}" -f $teal, $reset, $white, $prefix, $reset)

    if ($paletteOpen) {
        $filtered = @($Script:PaletteCommands | Where-Object { $_.Name -like "*${paletteFilter}*" })
        if ($filtered.Count -eq 0) {
            Out-Line ("  {0}No matching commands.{1}" -f $gray, $reset)
        } else {
            for ($i = 0; $i -lt $filtered.Count; $i++) {
                $c = $filtered[$i]
                $nameCol = "{0,-16}" -f $c.Name
                if ($i -eq $paletteIndex) {
                    Out-Line ("  {0}→{1} {2}{3}{4}  {5}{6}{4}" -f $teal, $reset, $white, $nameCol, $reset, $gray, $c.Desc)
                } else {
                    Out-Line ("    {0}{1}{2}  {3}{4}{2}" -f $gray, $nameCol, $reset, $gray, $c.Desc)
                }
            }
        }
        $pageLabel = if ($filtered.Count -gt 0) { "({0}/{1})" -f ($paletteIndex + 1), $filtered.Count } else { "(0/0)" }
        Out-Line ("  {0}{1}{2}" -f $gray, $pageLabel, $reset)
    }

    Render-Frame
}

function Main {
    $host.UI.RawUI.WindowTitle = "LLaMesa"
    Read-Config
    Detect-ActiveMode

    $Script:ServerOnline = $false
    $Script:InputHint = $null
    $status = $null
    # MinValue forces an immediate status fetch on the first iteration
    $lastRefresh = [DateTime]::MinValue
    $refreshInterval = 2
    $offlineStreak = 0

    $inputBuffer = ""
    $paletteOpen = $false
    $paletteFilter = ""
    $paletteIndex = 0
    $needsRedraw = $true

    # Hide the native terminal cursor — the input line draws its own thick
    # block cursor instead, so a second native cursor blinking wherever
    # SetCursorPosition last left it would just be visual noise.
    [Console]::CursorVisible = $false
    try {

    while ($true) {
        # Auto-refresh, cadence depends on $refreshInterval (see below). Skip
        # it entirely while a keystroke is already waiting — each refresh is
        # a blocking SSH round trip, and running it mid-keystroke is what
        # made typing feel broken (input sat queued until the SSH call
        # returned). Deferring means we just check again next loop tick
        # once the user pauses.
        $elapsed = ([DateTime]::Now - $lastRefresh).TotalSeconds
        if ($elapsed -ge $refreshInterval -and -not [Console]::KeyAvailable) {
            try {
                if ($Script:ServerOnline) {
                    # Already known online — skip the extra "echo ok" ping and
                    # let the status call itself double as the liveness check,
                    # halving the blocking SSH round trips in the steady state.
                    $status = Get-ActiveStatus
                    $Script:ServerOnline = $null -ne $status
                } else {
                    # Coming back from offline (or first run): a dead/unreachable
                    # server fails this ping fast; only pay for the heavier,
                    # mode-specific status round trip once it's actually
                    # reachable — avoids stacking two SSH timeouts back to back.
                    $Script:ServerOnline = Test-ServerConnection
                    $status = if ($Script:ServerOnline) { Get-ActiveStatus } else { $null }
                }
                $Script:ServerStatus = $status
                $Script:LastStatusRefresh = [DateTime]::Now
            } catch {
                $Script:ServerOnline = $false
                $status = $null
            }

            if ($Script:ServerOnline) {
                $offlineStreak = 0
                $refreshInterval = 2
            } else {
                # Back off how often we retry while offline (capped at 15s)
                # instead of hammering a dead connection every 2s — each
                # attempt still blocks the UI for up to the SSH connect
                # timeout, so this is what keeps typing/navigating responsive
                # while the server is down.
                $offlineStreak++
                $refreshInterval = [Math]::Min(2 + ($offlineStreak * 3), 15)
            }

            $lastRefresh = [DateTime]::Now
            $needsRedraw = $true
        }

        if ($needsRedraw) {
            Draw-Screen -status $status -inputBuffer $inputBuffer -paletteOpen $paletteOpen -paletteFilter $paletteFilter -paletteIndex $paletteIndex
            $needsRedraw = $false
        }

        if (-not [Console]::KeyAvailable) {
            Start-Sleep -Milliseconds 50
            continue
        }

        $key = [Console]::ReadKey($true)

        if ($paletteOpen) {
            $filtered = @($Script:PaletteCommands | Where-Object { $_.Name -like "*${paletteFilter}*" })
            switch ($key.Key) {
                'UpArrow'   { if ($filtered.Count -gt 0) { $paletteIndex = ($paletteIndex - 1 + $filtered.Count) % $filtered.Count } }
                'DownArrow' { if ($filtered.Count -gt 0) { $paletteIndex = ($paletteIndex + 1) % $filtered.Count } }
                'Escape'    { $paletteOpen = $false; $paletteFilter = ""; $paletteIndex = 0; $inputBuffer = "" }
                'Backspace' {
                    if ($paletteFilter.Length -gt 0) { $paletteFilter = $paletteFilter.Substring(0, $paletteFilter.Length - 1) }
                    else { $paletteOpen = $false }
                    $paletteIndex = 0
                }
                'Enter' {
                    if ($filtered.Count -gt 0) {
                        $cmd = $filtered[$paletteIndex].Name
                        $paletteOpen = $false; $paletteFilter = ""; $paletteIndex = 0; $inputBuffer = ""; $Script:InputHint = $null
                        Clear-Host
                        Invoke-PaletteCommand $cmd
                        # The command just printed a variable, unbuffered amount of
                        # raw output that scrolled the terminal — clear it and reset
                        # Render-Frame's row bookkeeping so the next buffered redraw
                        # doesn't leave any of it behind or miscount rows against it.
                        Clear-Host
                        $Script:PrevFrameLines = 0
                        $lastRefresh = [DateTime]::MinValue
                    }
                }
                default {
                    if ($key.KeyChar -and -not [char]::IsControl($key.KeyChar)) {
                        $paletteFilter += $key.KeyChar
                        $paletteIndex = 0
                    }
                }
            }
        } else {
            switch ($key.Key) {
                'Enter' {
                    $text = $inputBuffer.Trim()
                    if ($text) {
                        if ($text.StartsWith("/")) {
                            $inputBuffer = ""; $Script:InputHint = $null
                            Clear-Host
                            Invoke-PaletteCommand ($text.TrimStart('/'))
                            # See the palette Enter handler above — clears the
                            # command's own raw output before the next buffered redraw.
                            Clear-Host
                            $Script:PrevFrameLines = 0
                            $lastRefresh = [DateTime]::MinValue
                        } elseif (-not $Script:ServerOnline) {
                            # Skip Test-ModelLoaded here — in big/dual mode it's
                            # its own fresh SSH call, no point making a second
                            # doomed attempt right after the one that just failed.
                            $Script:InputHint = "Server unreachable — check the connection."
                        } elseif (Test-ModelLoaded) {
                            $inputBuffer = ""; $Script:InputHint = $null
                            Clear-Host
                            Send-ChatMessage $text
                            Clear-Host
                            $Script:PrevFrameLines = 0
                            $lastRefresh = [DateTime]::MinValue
                        } else {
                            $Script:InputHint = "No model loaded — press / then /start to load one."
                        }
                    }
                }
                'Backspace' {
                    if ($inputBuffer.Length -gt 0) { $inputBuffer = $inputBuffer.Substring(0, $inputBuffer.Length - 1) }
                }
                default {
                    if ($key.KeyChar -and -not [char]::IsControl($key.KeyChar)) {
                        if ($key.KeyChar -eq '/' -and $inputBuffer.Length -eq 0) {
                            $paletteOpen = $true
                            $paletteFilter = ""
                            $paletteIndex = 0
                        } else {
                            $inputBuffer += $key.KeyChar
                        }
                    }
                }
            }
        }

        $needsRedraw = $true
    }

    } finally {
        [Console]::CursorVisible = $true
    }
}

# ── Entry Point ───────────────────────────────────────────────────────────

Main