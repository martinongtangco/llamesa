#!/usr/bin/env pwsh
# LLaMesa — Windows PowerShell Client
# local inference control plane · v0.1
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
$Script:CurrentView    = "menu"  # menu, stats, chat, logs
$Script:ChatHistory    = @()
$Script:RefreshTimer   = $null

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
    $raw = Invoke-ServerCommand "status" -raw
    if (-not $raw) { return $null }

    try {
        # Find the first line starting with { and collect from there — skips any [INFO] prefix lines
        $jsonStartIndex = 0
        for ($i = 0; $i -lt $raw.Count; $i++) {
            if ($raw[$i] -match '^\s*\{') { $jsonStartIndex = $i; break }
        }
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

# ── UI: Header ────────────────────────────────────────────────────────────

function Show-Header {
    param($status = $null, [switch]$compact)

    # Logo line
    $logo = "{0}LL{1}a{2}M{3}esa{4}" -f $teal, $amber, $teal, $amber, $reset

    if ($compact) {
        Write-Host ""
        return
    }

    Write-Host ""
    Write-Host ("{0,-20} {1}local inference control plane · v0.1{2}" -f $logo, $dim, $reset)

    # Server line
    if ($Script:ActiveServerName) {
        $online = Test-ServerConnection
        $dot = if ($online) { "{0}●{1}" -f $green, $reset } else { "{0}●{1}" -f $red, $reset }
        Write-Host ("  {0}{1}{2} · {3}{4}{5}" -f $dot, $Script:ActiveServerName, $reset, $gray, $Script:ActiveServer.host, $reset)
    }

    # Stats line
    if ($status) {
        $cpuColor = $green
        if ($status.cpu_percent -gt 20) { $cpuColor = $red }
        elseif ($status.cpu_percent -gt 5) { $cpuColor = $amber }

        $ramColor = $green
        if ($status.ram_used_mb -gt 20480) { $ramColor = $red }
        elseif ($status.ram_used_mb -gt 10240) { $ramColor = $amber }

        $vramUsedStr = Format-Bytes $status.vram_used_bytes
        $vramTotalStr = Format-Bytes $status.vram_total_bytes
        $vramColor = $green
        if ($status.vram_used_bytes -lt 5GB) { $vramColor = $red }

        $gpuColor = $gray
        if ($status.gpu_busy_percent -gt 0) { $gpuColor = $amber }

        $ramBar = "{0}{1} / {2} GB{3}" -f $purple, [math]::Round($status.ram_used_mb / 1024, 1), [math]::Round($status.ram_total_mb / 1024, 1), $reset
        $vramBar = "{0}{1} / {2} GB{3}" -f $blue, $vramUsedStr, $vramTotalStr, $reset

        Write-Host ("  {0}CPU {1}%{2} · {3}RAM {4} · {5}GPU {6}%{2} · {7}VRAM {8}" -f `
            $cpuColor, $status.cpu_percent, $reset, `
            $purple, $ramBar, `
            $gpuColor, $status.gpu_busy_percent, `
            $blue, $vramBar)

        # Model line
        if ($status.running) {
            $thinkingStr = if ($status.thinking) { "on" } else { "off" }
            $modelLine = "{0}{1}{2} · ctx {3} · thinking {4}" -f `
                $white, $status.model, $reset, $status.ctx, $thinkingStr
            Write-Host ("  $modelLine")
        }
    }

    Write-Host ("  {0}─{1}" -f $dim, "──────────────────────────────────────────────────────", $reset)
}

# ── UI: Menu ──────────────────────────────────────────────────────────────

function Show-Menu {
    Write-Host ""
    Write-Host ("  {0}/start{1}        start server — pick model, thinking, context" -f $white, $reset)
    Write-Host ("  {0}/stop{1}         graceful shutdown" -f $white, $reset)
    Write-Host ("  {0}/switch{1}       hot-swap model" -f $white, $reset)
    Write-Host ("  {0}/restart{1}      stop + start with same settings" -f $white, $reset)
    Write-Host ("  {0}─{1}" -f $dim, "──────────────────────────────────────────────────────", $reset)
    Write-Host ("  {0}/stats{1}        live stats + logs split view" -f $white, $reset)
    Write-Host ("  {0}/health{1}       ping /health and /v1/models" -f $white, $reset)
    Write-Host ("  {0}/logs{1}         tail verbose server output" -f $white, $reset)
    Write-Host ("  {0}─{1}" -f $dim, "──────────────────────────────────────────────────────", $reset)
    Write-Host ("  {0}/models{1}       list downloaded models + sizes" -f $white, $reset)
    Write-Host ("  {0}/download{1}     download from huggingface" -f $white, $reset)
    Write-Host ("  {0}─{1}" -f $dim, "──────────────────────────────────────────────────────", $reset)
    Write-Host ("  {0}/chat{1}         chat with the model directly" -f $white, $reset)
    Write-Host ("  {0}─{1}" -f $dim, "──────────────────────────────────────────────────────", $reset)
    Write-Host ("  {0}/servers{1}      manage server profiles" -f $white, $reset)
    Write-Host ("  {0}/config{1}       view/edit config" -f $white, $reset)
    Write-Host ("  {0}/help{1}         show all commands" -f $white, $reset)
    Write-Host ("  {0}/quit{1}         exit" -f $white, $reset)
    Write-Host ""
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

    # Ask for options
    $thinking = Read-Host "Thinking mode? [on/off]"
    if (-not $thinking) { $thinking = "on" }

    $ctx = Read-Host "Context size? [131072]"
    if (-not $ctx) { $ctx = "131072" }

    Write-Host ""
    Write-Host ("{0}Starting {1}...{2}" -f $cyan, $selectedModel, $reset)

    $raw = Invoke-ServerCommand ("start --model ""{0}"" --thinking {1} --ctx {2}" -f $selectedModel, $thinking.ToLower(), $ctx) -raw
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
    Write-Host ("{0}Stopping server...{1}" -f $cyan, $reset)
    $raw = Invoke-ServerCommand "stop" -raw
    Write-Host ($raw -join "`n")
}

# ── Command: /restart ─────────────────────────────────────────────────────

function Cmd-Restart {
    Write-Host ("{0}Restarting server...{1}" -f $cyan, $reset)
    $raw = Invoke-ServerCommand "restart" -raw
    Write-Host ($raw -join "`n")
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

# ── Command: /stats ───────────────────────────────────────────────────────

function Cmd-Stats {
    $Script:CurrentView = "stats"
    Write-Host ("{0}Live stats mode — press Q to return to menu{1}" -f $cyan, $reset)
    Start-Sleep -Seconds 1

    while ($Script:CurrentView -eq "stats") {
        try {
            # Clear and redraw
            $host.UI.RawUI.WindowTitle = "LLaMesa — Stats"

            # Get status
            $status = Get-ServerStatus
            Show-Header -status $status

            Write-Host ""
            Write-Host ("  {0}Live Stats{1}" -f $teal, $reset)
            Write-Host ("  {0}─{1}" -f $dim, "──────────────────────────────────────────────────────", $reset)

            if ($status) {
                # Full JSON status display
                Write-Host ("  Running:    {0}" -f $status.running)
                Write-Host ("  Model:      {0}" -f $status.model)
                Write-Host ("  VRAM:       {0} / {1}" -f (Format-Bytes $status.vram_used_bytes), (Format-Bytes $status.vram_total_bytes))
                Write-Host ("  GPU Busy:   {0}%" -f $status.gpu_busy_percent)
                Write-Host ("  CPU:        {0}%" -f $status.cpu_percent)
                Write-Host ("  RAM:        {0} MB / {1} MB" -f $status.ram_used_mb, $status.ram_total_mb)
                Write-Host ("  Uptime:     {0}" -f $status.uptime)
                Write-Host ("  Port:       {0}" -f $status.port)
            } else {
                Write-Host ("  {0}Could not retrieve status{1}" -f $red, $reset)
            }

            Write-Host ""
            Write-Host ("  {0}[Q] back to menu{1}" -f $gray, $reset)

            # Non-blocking key check
            if ([System.Console]::KeyAvailable) {
                $key = [System.Console]::ReadKey($true)
                if ($key.KeyChar -eq 'q' -or $key.KeyChar -eq 'Q') {
                    break
                }
            }

            Start-Sleep -Seconds 2
            Clear-Host
        }
        catch {
            Start-Sleep -Seconds 2
        }
    }

    $Script:CurrentView = "menu"
    $host.UI.RawUI.WindowTitle = "LLaMesa"
    Clear-Host
}

# ── Command: /logs ────────────────────────────────────────────────────────

function Cmd-Logs {
    Write-Host ("{0}Streaming server logs... (press Ctrl+C to exit){1}" -f $cyan, $reset)

    $sshUser = $Script:ActiveServer.ssh_user
    $sshHost = $Script:ActiveServer.host

    ssh "${sshUser}@${sshHost}" "tail -f ~/.llamesa/server.log"
}

# ── Command: /health ──────────────────────────────────────────────────────

function Cmd-Health {
    Write-Host ("{0}Checking server health...{1}" -f $cyan, $reset)

    $port = $Script:ActiveServer.port
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

    Write-Host ("{0}Chat mode — type /exit to return, /clear to clear history{1}" -f $cyan, $reset)

    $port = $Script:ActiveServer.port
    $hostAddr = $Script:ActiveServer.host

    while ($Script:CurrentView -eq "chat") {
        Clear-Host

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
                    Write-Host ("  {0}⬡ {1} prompt · {2} gen · {3} tok/s · {4}s{5}" -f `
                        $amber, $msg.prompt_toks, $msg.gen_toks, $msg.tok_s, $msg.duration, $reset)
                }

                Write-Host ""
            }
        }

        # Prompt
        $input = Read-Host ("{0}›{1}" -f $cyan, $reset)

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
            Write-Host ("{0}Thinking mode enabled for next request.{1}" -f $amber, $reset)
            continue
        }
        elseif ($input -eq "/nothink") {
            Write-Host ("{0}Thinking mode disabled for next request.{1}" -f $gray, $reset)
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

        $body = [PSCustomObject]@{
            model    = $modelId
            messages = $messages
            stream   = $true
        } | ConvertTo-Json -Depth 5

        $assistantContent = ""
        $thinkingContent  = ""
        $inThinking       = $false
        $startTime        = Get-Date
        $promptToks       = 0
        $genToks          = 0

        try {
            # Use raw HttpClient for true SSE streaming (Invoke-RestMethod buffers the entire response)
            $handler = New-Object System.Net.Http.HttpClientHandler
            $client = New-Object System.Net.Http.HttpClient($handler)
            $client.Timeout = [TimeSpan]::FromSeconds(120)

            $content = New-Object System.Net.Http.StringContent(
                $body,
                [System.Text.Encoding]::UTF8,
                "application/json"
            )

            $task = $client.PostAsync("http://${hostAddr}:${port}/v1/chat/completions", $content)
            $task.Wait()
            $response = $task.Result

            if (-not $response.IsSuccessStatusCode) {
                throw "HTTP $( $response.StatusCode )"
            }

            # Read response stream as SSE
            $streamTask = $response.Content.ReadAsStreamAsync()
            $streamTask.Wait()
            $stream = $streamTask.Result

            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)

            try {
                while (-not $reader.EndOfStream) {
                    $line = $reader.ReadLine()
                    if ([string]::IsNullOrEmpty($line)) { continue }

                    if ($line.StartsWith("data:")) {
                        $jsonStr = $line.Substring(5).Trim()
                        if ($jsonStr -eq '[DONE]') { break }

                        try {
                            $delta = $jsonStr | ConvertFrom-Json

                            # Track usage
                            if ($delta.usage) {
                                $promptToks = $delta.usage.prompt_tokens
                                $genToks = $delta.usage.completion_tokens
                            }

                            # Handle content
                            $chunkContent = ""
                            if ($delta.choices -and $delta.choices[0].delta) {
                                $chunkContent = $delta.choices[0].delta.content
                            }

                            if ($chunkContent) {
                                if ($inThinking) {
                                    $thinkingContent += $chunkContent
                                } else {
                                    $assistantContent += $chunkContent
                                    Write-Host $chunkContent -NoNewline
                                }
                            }
                        } catch {
                            # Skip malformed lines
                        }
                    }
                }
            } finally {
                $reader.Dispose()
            }

            $client.Dispose()
            Write-Host ""

            $endTime = Get-Date
            $duration = ($endTime - $startTime).TotalSeconds
            $tokS = if ($duration -gt 0) { [math]::Round($genToks / $duration, 1) } else { 0 }

            # Add assistant message to history
            $Script:ChatHistory += [PSCustomObject]@{
                role        = "assistant"
                content     = $assistantContent
                thinking    = $thinkingContent
                prompt_toks = $promptToks
                gen_toks    = $genToks
                tok_s       = $tokS
                duration    = [math]::Round($duration, 1)
            }

        } catch {
            Write-Host ("{0}Error: {1}{2}" -f $red, $_.Exception.Message, $reset)
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
    Write-Host ("  {0}/stats{1}        Live stats dashboard (Q to exit)" -f $white, $reset)
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
    "stats", "health", "logs",
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

    # Read config (triggers setup wizard if missing)
    Read-Config

    while ($true) {
        Clear-Host

        # Get status for header (also cached for use in /chat)
        $status = $null
        try {
            $status = Get-ServerStatus
            $Script:ServerStatus = $status
        } catch {
            # Ignore errors, show without stats
        }

        Show-Header -status $status
        Show-Menu

        # Read input with autocomplete hint
        $input = Read-Host ("{0}›{1}" -f $cyan, $reset)

        if (-not $input.Trim()) { continue }

        # Strip leading /
        $cmd = $input.Trim().TrimStart('/')

        switch ($cmd) {
            "start"    { Cmd-Start; Read-Host "`nPress Enter to continue" }
            "stop"     { Cmd-Stop; Read-Host "`nPress Enter to continue" }
            "switch"   { Cmd-Switch; Read-Host "`nPress Enter to continue" }
            "restart"  { Cmd-Restart; Read-Host "`nPress Enter to continue" }
            "stats"    { Cmd-Stats }
            "health"   { Cmd-Health; Read-Host "`nPress Enter to continue" }
            "logs"     { Cmd-Logs }
            "models"   { Cmd-Models; Read-Host "`nPress Enter to continue" }
            "download" { Cmd-Download; Read-Host "`nPress Enter to continue" }
            "chat"     { Cmd-Chat }
            "servers"  { Cmd-Servers; Read-Host "`nPress Enter to continue" }
            "config"   { Cmd-Config; Read-Host "`nPress Enter to continue" }
            "help"     { Cmd-Help; Read-Host "`nPress Enter to continue" }
            "quit"     { Write-Host ("{0}Goodbye!{1}" -f $gray, $reset); exit 0 }
            default    { Write-Host ("{0}Unknown command: {1}. Type /help for commands.{2}" -f $red, $cmd, $reset); Start-Sleep -Seconds 1 }
        }
    }
}

# ── Entry Point ───────────────────────────────────────────────────────────

Main