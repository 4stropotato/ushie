param(
    [Alias("m","Profile")]
    [ValidateSet("Safe","Extreme")]
    [string]$Mode = "Safe",
    [string]$Dns = "Auto",
    [string[]]$DnsServers,
    [Alias("v")]
    [switch]$VerboseOutput,
    [switch]$KeepWSL,
    [switch]$SkipVerify,
    [switch]$VerifyOnly,
    [Alias("rf")]
    [switch]$RemoteFix,
    [Alias("rz","razer")]
    [switch]$FixRazer,
    [Alias("gaming","rzg")]
    [switch]$RazerGaming,
    [Alias("rzon")]
    [switch]$RazerOn,
    [Alias("rzcheck","rzstatus")]
    [switch]$RazerStatus,
    [Alias("undo","rollback")]
    [switch]$Restore,
    [Alias("network")]
    [switch]$Net,
    [Alias("mem")]
    [switch]$Memory,
    [Alias("graphics")]
    [switch]$Gpu,
    [Alias("disk")]
    [switch]$Storage,
    [Alias("processor")]
    [switch]$Cpu,
    [Alias("temps","thermal")]
    [switch]$Temp,
    [Alias("turbo")]
    [switch]$Boost,
    [Alias("startupapps")]
    [switch]$Startup,
    [Alias("vbs")]
    [switch]$RiskyBoost,
    [Alias("svc")]
    [switch]$Services,
    [Alias("nr")]
    [switch]$NoRestore,
    [Alias("h","help","man","?")]
    [switch]$Manual
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

function New-Style {
    $esc = [char]27
    return @{
        Reset      = "$esc[0m"
        Bold       = "$esc[1m"
        Red        = "$esc[91m"
        Green      = "$esc[92m"
        Yellow     = "$esc[93m"
        Blue       = "$esc[94m"
        Purple     = "$esc[95m"
        Cyan       = "$esc[96m"
        Gray       = "$esc[90m"
        NeonBlue   = "$esc[38;2;0;210;255m"
        NeonPink   = "$esc[38;2;255;90;180m"
        NeonYellow = "$esc[38;2;255;220;90m"
        NeonMint   = "$esc[38;2;85;255;190m"
        Slate      = "$esc[38;2;160;170;185m"
    }
}

$S = New-Style
$script:StepNo = 0
$script:CheckNo = 0
$script:RunProfile = $Mode
$script:DnsSelection = "<not set>"
$script:StateRoot = "HKCU:\Software\ushie\WinLagFix"
$script:ActiveSectionRow = -1
$script:ActiveDetailRow = -1
$script:ActiveSectionText = ""
$script:ActiveSectionColor = $null
$script:HeaderSpinnerActive = $false
$script:ActiveSectionRule = ""
$script:ActiveUseDetailLine = $false
$script:VerboseSectionPending = $false

function Initialize-ConsoleRendering {
    try {
        if (-not [Console]::IsOutputRedirected) {
            $utf8 = New-Object System.Text.UTF8Encoding($false)
            [Console]::OutputEncoding = $utf8
            $global:OutputEncoding = $utf8
        }
    } catch {}
}

Initialize-ConsoleRendering

if (-not ("UshieHeaderSpinnerHost" -as [type])) {
    Add-Type @"
using System;
using System.Threading;

public static class UshieHeaderSpinnerHost
{
    static readonly object Sync = new object();
    static Timer Timer;
    static string[] Frames = new[] { "|", "/", "-", "\\" };
    static int Index;
    static int Row = -1;
    static string Text = "";
    static string Color = "";
    static string Reset = "";

    static int Width()
    {
        try { return Math.Max(Console.WindowWidth - 1, 72); }
        catch { return 100; }
    }

    static string Pad(string value)
    {
        value = value ?? "";
        int width = Width();
        return value.Length < width ? value.PadRight(width) : value;
    }

    static void Tick(object state)
    {
        lock (Sync) {
            if (Row < 0) return;
            int left;
            int top;
            try {
                left = Console.CursorLeft;
                top = Console.CursorTop;
                string frame = Frames[Index % Frames.Length];
                Index++;
                Console.SetCursorPosition(0, Row);
                Console.Write(Color + Pad("   " + frame + "  " + Text) + Reset);
                Console.Out.Flush();
                Console.SetCursorPosition(left, top);
            } catch {}
        }
    }

    public static void Start(int row, string text, string color, string reset, string[] frames, int intervalMs, int initialDelayMs)
    {
        lock (Sync) {
            Stop();
            Row = row;
            Text = text ?? "";
            Color = color ?? "";
            Reset = reset ?? "";
            Frames = (frames != null && frames.Length > 0) ? frames : new[] { "|", "/", "-", "\\" };
            Index = 0;
            Timer = new Timer(Tick, null, initialDelayMs, intervalMs);
        }
    }

    public static void Stop()
    {
        lock (Sync) {
            if (Timer != null) {
                Timer.Dispose();
                Timer = null;
            }
            Row = -1;
            Text = "";
            Color = "";
            Reset = "";
        }
    }
}
"@
}

function Paint([string]$Text, [string]$Color) {
    if (-not $Color) { return $Text }
    return "$Color$Text$($S.Reset)"
}

function Write-Detail([string]$Text) {
    if ($VerboseOutput) {
        Write-Host (Paint ("[DETAIL] " + $Text) $S.Gray)
    }
}

function Invoke-BcdSet([string]$Setting, [string]$Value) {
    $out = (bcdedit /set $Setting $Value 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        Write-Host (Paint ("[WARN] bcdedit /set $Setting $Value : $out") $S.Yellow)
    }
}

function Assert-Admin {
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).
        IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host (Paint "Run this script as Administrator." $S.Red)
        exit 1
    }
}

function Get-ConsoleWidth {
    try {
        return [Math]::Max([Console]::WindowWidth - 1, 72)
    } catch {
        return 100
    }
}

function Test-CanAnimate {
    try {
        if ([Console]::IsOutputRedirected) { return $false }
        $null = $Host.UI.RawUI.WindowSize.Width
        $null = [Console]::CursorTop
        return $true
    } catch {
        return $false
    }
}



function Get-UsableSpinnerFrames {
    try {
        $encodingName = [Console]::OutputEncoding.WebName
        if ($encodingName -match "utf") {
            return @(
                [string][char]0x280B,
                [string][char]0x2819,
                [string][char]0x2839,
                [string][char]0x2838,
                [string][char]0x283C,
                [string][char]0x2834,
                [string][char]0x2826,
                [string][char]0x2827,
                [string][char]0x2807,
                [string][char]0x280F
            )
        }
    } catch {}

    return @("|","/","-","\")
}



function Format-SectionSpinnerLine([string]$Frame, [string]$Text, [string]$Color, [string]$Detail = "") {
    $width = Get-ConsoleWidth
    $lineText = ("   {0}  {1}" -f $Frame, $Text)
    return Paint ($lineText.PadRight($width)) $Color
}

function Format-SectionDetailLine([string]$Detail, [string]$Frame = "") {
    $width = Get-ConsoleWidth
    $lineText = if ([string]::IsNullOrWhiteSpace($Detail)) {
        ""
    } elseif ([string]::IsNullOrWhiteSpace($Frame)) {
        "      " + $Detail
    } else {
        ("   {0}  {1}" -f $Frame, $Detail)
    }
    return Paint ($lineText.PadRight($width)) $S.Gray
}

function Start-SectionSpinner([string]$Text, [string]$Color, [switch]$UseDetailLine) {
    $script:ActiveSectionText = $Text
    $script:ActiveSectionColor = $Color
    $script:ActiveSectionRow = -1
    $script:ActiveDetailRow = -1

    $frames = Get-UsableSpinnerFrames
    $initialLine = Format-SectionSpinnerLine -Frame $frames[0] -Text $Text -Color $Color
    if ($VerboseOutput) {
        Microsoft.PowerShell.Utility\Write-Host -NoNewline $initialLine
    } else {
        Write-Host $initialLine
    }

    if (Test-CanAnimate) {
        try {
            $script:ActiveSectionRow = if ($VerboseOutput) { [Console]::CursorTop } else { [Console]::CursorTop - 1 }
        } catch {
            $script:ActiveSectionRow = -1
        }
    }
}

function Ensure-VerboseSectionBody([switch]$NeedDetailLine) {
    if (-not $VerboseOutput) { return }

    $shouldPrint = $script:VerboseSectionPending
    $needsDetail = $script:ActiveUseDetailLine -or $NeedDetailLine

    if ($script:HeaderSpinnerActive) {
        Stop-HeaderSpinnerTimer
    }

    if ($shouldPrint) {
        Microsoft.PowerShell.Utility\Write-Host ""
        Microsoft.PowerShell.Utility\Write-Host (Paint $script:ActiveSectionRule $S.Slate)
        $script:VerboseSectionPending = $false
    }

    if ($needsDetail -and $script:ActiveDetailRow -lt 0) {
        Microsoft.PowerShell.Utility\Write-Host (Format-SectionDetailLine -Detail "")
        if (Test-CanAnimate) {
            try { $script:ActiveDetailRow = [Console]::CursorTop - 1 } catch { $script:ActiveDetailRow = -1 }
        }
    }
}

function Update-SectionSpinner([string]$Detail, [int]$Tick) {
    if (-not (Test-CanAnimate)) { return }
    if ($script:ActiveSectionRow -lt 0 -and $script:ActiveDetailRow -lt 0) { return }

    $frames = Get-UsableSpinnerFrames
    $frame = $frames[$Tick % $frames.Count]
    $currentTop = [Console]::CursorTop
    $currentLeft = [Console]::CursorLeft

    try {
        if ($VerboseOutput) {
            Ensure-VerboseSectionBody -NeedDetailLine
        }
        if (-not $VerboseOutput) {
            [Console]::SetCursorPosition(0, $script:ActiveSectionRow)
            Write-Host -NoNewline (Format-SectionSpinnerLine -Frame $frame -Text $script:ActiveSectionText -Color $script:ActiveSectionColor -Detail $Detail)
        }
        if ($script:ActiveDetailRow -ge 0) {
            [Console]::SetCursorPosition(0, $script:ActiveDetailRow)
            $detailFrame = if ($VerboseOutput -and -not [string]::IsNullOrWhiteSpace($Detail)) { $frame } else { "" }
            [Console]::Write((Format-SectionDetailLine -Detail $Detail -Frame $detailFrame))
        }
        [Console]::Out.Flush()
        [Console]::SetCursorPosition($currentLeft, $currentTop)
    } catch {}
}

function Complete-SectionSpinner {
    Stop-HeaderSpinnerTimer
    if ($VerboseOutput -or -not (Test-CanAnimate)) {
        if ($VerboseOutput -and $script:VerboseSectionPending) {
            Ensure-VerboseSectionBody
        }
        $script:ActiveSectionRow = -1
        $script:ActiveDetailRow = -1
        $script:ActiveSectionText = ""
        $script:ActiveSectionColor = $null
        $script:ActiveSectionRule = ""
        $script:ActiveUseDetailLine = $false
        $script:VerboseSectionPending = $false
        return
    }
    if ($script:ActiveSectionRow -lt 0) { return }

    $currentTop = [Console]::CursorTop
    $currentLeft = [Console]::CursorLeft

    try {
        [Console]::SetCursorPosition(0, $script:ActiveSectionRow)
        [Console]::Write(("".PadRight((Get-ConsoleWidth))))
        if ($script:ActiveDetailRow -ge 0) {
            [Console]::SetCursorPosition(0, $script:ActiveDetailRow)
            [Console]::Write(("".PadRight((Get-ConsoleWidth))))
        }
        [Console]::Out.Flush()
        [Console]::SetCursorPosition($currentLeft, $currentTop)
    } catch {}

    $script:ActiveSectionRow = -1
    $script:ActiveDetailRow = -1
    $script:ActiveSectionText = ""
    $script:ActiveSectionColor = $null
    $script:ActiveSectionRule = ""
    $script:ActiveUseDetailLine = $false
    $script:VerboseSectionPending = $false
}

function Start-HeaderSpinnerTimer {
    if (-not (Test-CanAnimate)) { return }
    if ($script:ActiveSectionRow -lt 0) {
        return
    }
    try {
        [UshieHeaderSpinnerHost]::Start(
            $script:ActiveSectionRow,
            $script:ActiveSectionText,
            $script:ActiveSectionColor,
            $S.Reset,
            (Get-UsableSpinnerFrames),
            80,
            0
        )
        $script:HeaderSpinnerActive = $true
    } catch {
        $script:HeaderSpinnerActive = $false
    }
}

function Stop-HeaderSpinnerTimer {
    if (-not $script:HeaderSpinnerActive) { return }
    try { [UshieHeaderSpinnerHost]::Stop() } catch {}
    $script:HeaderSpinnerActive = $false
}

function Write-Host {
    [CmdletBinding()]
    param(
        [Parameter(Position=0, ValueFromPipeline=$true, ValueFromRemainingArguments=$true)]
        [object[]]$Object,
        [object]$Separator,
        [switch]$NoNewline,
        [ConsoleColor]$ForegroundColor,
        [ConsoleColor]$BackgroundColor
    )

    process {
        if ($VerboseOutput -and $script:VerboseSectionPending) {
            Ensure-VerboseSectionBody
        } elseif ($script:HeaderSpinnerActive) {
            Stop-HeaderSpinnerTimer
        }
        Microsoft.PowerShell.Utility\Write-Host @PSBoundParameters
    }
}

function Out-Default {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true)]
        [psobject]$InputObject
    )

    begin {
        if ($VerboseOutput -and $script:VerboseSectionPending) {
            Ensure-VerboseSectionBody
        } elseif ($script:HeaderSpinnerActive) {
            Stop-HeaderSpinnerTimer
        }
        $buffer = New-Object System.Collections.Generic.List[object]
    }

    process {
        $null = $buffer.Add($InputObject)
    }

    end {
        if ($buffer.Count -gt 0) {
            $buffer.ToArray() | Microsoft.PowerShell.Core\Out-Default
        }
    }
}

function Out-Host {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true)]
        [psobject]$InputObject,
        [switch]$Paging
    )

    begin {
        if ($VerboseOutput -and $script:VerboseSectionPending) {
            Ensure-VerboseSectionBody
        } elseif ($script:HeaderSpinnerActive) {
            Stop-HeaderSpinnerTimer
        }
        $buffer = New-Object System.Collections.Generic.List[object]
    }

    process {
        $null = $buffer.Add($InputObject)
    }

    end {
        if ($buffer.Count -gt 0) {
            $outHostParams = @{}
            if ($PSBoundParameters.ContainsKey('Paging')) {
                $outHostParams.Paging = $Paging
            }
            $buffer.ToArray() | Microsoft.PowerShell.Core\Out-Host @outHostParams
        }
    }
}



function Invoke-ProcessWithSpinner([string]$FilePath, [string[]]$ArgumentList, [string]$Label, [string]$AccentColor) {
    if (-not (Test-CanAnimate)) {
        $proc = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -WindowStyle Hidden -PassThru -Wait
        return $proc.ExitCode
    }

    $frames = Get-UsableSpinnerFrames
    $width = Get-ConsoleWidth
    $proc = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -WindowStyle Hidden -PassThru
    $i = 0

    while (-not $proc.HasExited) {
        Update-SectionSpinner -Detail $Label -Tick $i
        Start-Sleep -Milliseconds 120
        try { $proc.Refresh() } catch {}
        $i++
    }
    return $proc.ExitCode
}

function Show-SectionHeader([string]$Kind, [string]$Id, [string]$Message, [string]$AccentColor, [switch]$UseDetailLine) {
    $width = Get-ConsoleWidth
    $sectionText = ("[{0} {1}] {2}" -f $Kind, $Id, $Message)
    $ruleWidth = [Math]::Min($width, [Math]::Max(($sectionText.Length + 8), 54))
    $rule = ("-" * $ruleWidth)

    Complete-SectionSpinner
    Start-SectionSpinner -Text $sectionText -Color $AccentColor -UseDetailLine:$UseDetailLine
    $script:ActiveSectionRule = $rule
    $script:ActiveUseDetailLine = [bool]$UseDetailLine
    $script:VerboseSectionPending = $VerboseOutput

    if (-not $VerboseOutput) {
        Write-Host (Paint $rule $S.Slate)
        if ($UseDetailLine) {
            Write-Host (Format-SectionDetailLine -Detail "")
            if (Test-CanAnimate) {
                try { $script:ActiveDetailRow = [Console]::CursorTop - 1 } catch { $script:ActiveDetailRow = -1 }
            }
        }
    }
    Start-HeaderSpinnerTimer
    if (Test-CanAnimate) {
        Start-Sleep -Milliseconds 120
    }
}

function Step([string]$Message) {
    $script:StepNo++
    $id = "{0:d2}" -f $script:StepNo
    if (-not $VerboseOutput) {
        Complete-SectionSpinner
        Clear-Host
        Show-Banner
    } elseif ($script:StepNo -eq 1) {
        Show-Banner
    }
    Show-SectionHeader -Kind "PHASE" -Id $id -Message $Message -AccentColor $S.NeonBlue -UseDetailLine
}

function Show-Banner {
    Write-Host ""
    $art = @'
                               /$$       /$$
                              | $$      |__/
           /$$   /$$  /$$$$$$$| $$$$$$$  /$$  /$$$$$$
          | $$  | $$ /$$_____/| $$__  $$| $$ /$$__  $$
          | $$  | $$|  $$$$$$ | $$  \ $$| $$| $$$$$$$$
          | $$  | $$ \____  $$| $$  | $$| $$| $$_____/
          |  $$$$$$/ /$$$$$$$/| $$  | $$| $$|  $$$$$$$
           \______/ |_______/ |__/  |__/|__/ \_______/
'@
    $lines = $art -split "`r?`n"
    foreach ($line in $lines) {
        if ($line.Trim().Length -eq 0) {
            Write-Host ""
        } else {
            Write-Host (Paint $line $S.NeonBlue)
        }
    }
    Write-Host (Paint "               USHIE ONE-SHOT LATENCY OPTIMIZER" $S.NeonPink)
    $runMode = if ($Manual) { "MANUAL / HELP" } elseif ($RemoteFix) { "REMOTE ACCESS REPAIR" } elseif ($FixRazer) { "RAZER SYNAPSE REPAIR" } elseif ($RazerGaming) { "RAZER GAMING (MIN RESOURCES)" } elseif ($RazerOn) { "RAZER RESTORE (FULL)" } elseif ($RazerStatus) { "RAZER STATUS (READ-ONLY)" } elseif ($Restore) { "RESTORE / UNDO" } elseif ($Net) { "NETWORK BOOST (FOCUSED)" } elseif ($Memory) { "MEMORY BOOST (FOCUSED)" } elseif ($Gpu) { "GPU BOOST (FOCUSED)" } elseif ($Storage) { "STORAGE BOOST (FOCUSED)" } elseif ($Cpu) { "CPU BOOST (FOCUSED)" } elseif ($Temp) { "THERMAL MONITOR (READ-ONLY)" } elseif ($Boost) { "SAFE BOOST + PLAYBOOK" } elseif ($Startup) { "STARTUP APPS (READ-ONLY)" } elseif ($RiskyBoost) { "RISKY BOOST (VBS OFF)" } elseif ($Services) { "SERVICES DEBLOAT" } elseif ($VerifyOnly) { "VERIFY-ONLY (READ-ONLY)" } else { "APPLY ALL-IN-ONE" }
    Write-Host (Paint "               NO PERSISTENT BACKGROUND SERVICES" $S.NeonPink)
    Write-Host (Paint ("               MODE: " + $script:RunProfile + "   VERBOSE: " + $(if ($VerboseOutput) { "ON" } else { "OFF" })) $S.Slate)
    Write-Host (Paint ("               RUN MODE: " + $runMode) $S.Slate)
    if ($NoRestore -and $script:RunProfile -eq "Extreme") {
        Write-Host (Paint "                                   EXTREME RESTOREPOINT: SKIP (-NoRestore)" $S.Yellow)
    }
    Write-Host ""
}

function Show-Manual {
    Write-Host (Paint "Usage:" $S.NeonBlue)
    Write-Host "  .\scripts\ushie.ps1 [-m Safe|Extreme] [-v] [-Dns Auto|Cloudflare|Google|Quad9|OpenDNS|AdGuard|ControlD|DNSSB|Comodo] [-DnsServers ip,ip,...]"
    Write-Host "  .\scripts\ushie.ps1 -RemoteFix [-v]"
    Write-Host "  .\scripts\ushie.ps1 -FixRazer [-v]"
    Write-Host "  .\scripts\ushie.ps1 -RazerGaming [-v]"
    Write-Host "  .\scripts\ushie.ps1 -RazerOn [-v]"
    Write-Host "  .\scripts\ushie.ps1 -RazerStatus"
    Write-Host "  .\scripts\ushie.ps1 -Restore [-v]"
    Write-Host "  .\scripts\ushie.ps1 -Net | -Memory | -Gpu | -Storage | -Cpu [-v]"
    Write-Host "  .\scripts\ushie.ps1 -Temp"
    Write-Host "  .\scripts\ushie.ps1 -Boost [-v]"
    Write-Host "  .\scripts\ushie.ps1 -Startup"
    Write-Host "  .\scripts\ushie.ps1 -RiskyBoost [-v]"
    Write-Host "  .\scripts\ushie.ps1 -Services [-v]"
    Write-Host "  .\scripts\ushie.ps1 -VerifyOnly [-v]"
    Write-Host "  .\scripts\ushie.ps1 -h"
    Write-Host ""
    Write-Host (Paint "Main switches:" $S.NeonBlue)
    Write-Host "  -m              Profile mode (Safe = live/no-restart, Extreme = deeper tuning + reboot)"
    Write-Host "  -v              Verbose/full view output"
    Write-Host "  -RemoteFix      Repair RDP/Tailscale/SSH access only (no optimizer pass)"
    Write-Host "  -FixRazer       Fix runaway Razer Synapse (clears duplicate RazerAppEngine, relaunches clean; keeps macros)"
    Write-Host "  -RazerGaming    Min-resource mode: lighting off + Chroma services disabled (no CPU/RAM/disk use); keeps macros"
    Write-Host "  -RazerOn        Restore Razer fully: re-enable lighting + macros (undo -RazerGaming)"
    Write-Host "  -RazerStatus    Read-only checker: shows Razer processes, memory, services, mode + verdict (no admin)"
    Write-Host "  -Restore        Undo: re-import the latest ushie registry backup + list System Restore points"
    Write-Host "  -Net            Focused: network/connection/packet tweaks only (backs up first)"
    Write-Host "  -Memory         Focused: memory tweaks only (MMAgent, paging) (backs up first)"
    Write-Host "  -Gpu            Focused: GPU tweaks only (HAGS, GameDVR off) (backs up first)"
    Write-Host "  -Storage        Focused: storage/NTFS + cache cleanup only (backs up first)"
    Write-Host "  -Cpu            Focused: CPU tweaks only (power-throttling off, core unpark, priority) (backs up first)"
    Write-Host "  -Temp           Read-only: CPU/GPU temperature, clocks, utilization, power draw (no admin)"
    Write-Host "  -Boost          Safe max-perf posture + thermal readout + manual undervolt/overclock playbook"
    Write-Host "  -Startup        Read-only: list startup programs (Run keys + Startup folder) (no admin)"
    Write-Host "  -RiskyBoost     OPT-IN: disable VBS/Memory Integrity for gaming FPS (lowers a security layer)"
    Write-Host "  -Services       Debloat non-essential services (conservative, Manual-first, RDP-safe, reversible)"
    Write-Host "  -Dns            DNS preset (Auto default)"
    Write-Host "  -DnsServers     Manual DNS override list (highest priority)"
    Write-Host "  -KeepWSL        Do not disable WSL / VirtualMachinePlatform"
    Write-Host "  -SkipVerify     Apply changes without auto verify"
    Write-Host "  -VerifyOnly     Run checks only (read-only)"
    Write-Host "  -NoRestore      Skip restore-point creation in Extreme mode"
    Write-Host "  -h / -help / -man  Show this manual"
    Write-Host ""
    Write-Host (Paint "One-liner (Safe):" $S.NeonBlue)
    Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -Command ""& ([ScriptBlock]::Create((irm 'https://raw.githubusercontent.com/4stropotato/ushie/main/scripts/ushie.ps1'))) -m Safe"""
    Write-Host (Paint "One-liner (Extreme):" $S.NeonBlue)
    Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -Command ""& ([ScriptBlock]::Create((irm 'https://raw.githubusercontent.com/4stropotato/ushie/main/scripts/ushie.ps1'))) -m Extreme -v"""
    Write-Host (Paint "One-liner (RemoteFix):" $S.NeonBlue)
    Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -Command ""& ([ScriptBlock]::Create((irm 'https://raw.githubusercontent.com/4stropotato/ushie/main/scripts/ushie.ps1'))) -RemoteFix -v"""
    Write-Host (Paint "One-liner (FixRazer):" $S.NeonBlue)
    Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -Command ""& ([ScriptBlock]::Create((irm 'https://raw.githubusercontent.com/4stropotato/ushie/main/scripts/ushie.ps1'))) -FixRazer -v"""
    Write-Host (Paint "One-liner (RazerGaming):" $S.NeonBlue)
    Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -Command ""& ([ScriptBlock]::Create((irm 'https://raw.githubusercontent.com/4stropotato/ushie/main/scripts/ushie.ps1'))) -RazerGaming -v"""
    Write-Host (Paint "One-liner (RazerOn):" $S.NeonBlue)
    Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -Command ""& ([ScriptBlock]::Create((irm 'https://raw.githubusercontent.com/4stropotato/ushie/main/scripts/ushie.ps1'))) -RazerOn -v"""
    Write-Host (Paint "One-liner (RazerStatus):" $S.NeonBlue)
    Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -Command ""& ([ScriptBlock]::Create((irm 'https://raw.githubusercontent.com/4stropotato/ushie/main/scripts/ushie.ps1'))) -RazerStatus"""
    Write-Host (Paint "One-liner (Restore):" $S.NeonBlue)
    Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -Command ""& ([ScriptBlock]::Create((irm 'https://raw.githubusercontent.com/4stropotato/ushie/main/scripts/ushie.ps1'))) -Restore -v"""
    Write-Host (Paint "One-liner (Temp):" $S.NeonBlue)
    Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -Command ""& ([ScriptBlock]::Create((irm 'https://raw.githubusercontent.com/4stropotato/ushie/main/scripts/ushie.ps1'))) -Temp"""
    Write-Host (Paint "One-liner (Boost):" $S.NeonBlue)
    Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -Command ""& ([ScriptBlock]::Create((irm 'https://raw.githubusercontent.com/4stropotato/ushie/main/scripts/ushie.ps1'))) -Boost -v"""
    Write-Host (Paint "One-liner (Help):" $S.NeonBlue)
    Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -Command ""& ([ScriptBlock]::Create((irm 'https://raw.githubusercontent.com/4stropotato/ushie/main/scripts/ushie.ps1'))) -h"""
}

function Repair-RemoteAccessStack {
    reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f | Out-Null
    netsh advfirewall firewall set rule group="Remote Desktop" new enable=Yes | Out-Null

    sc.exe config TermService start= auto | Out-Null
    sc.exe config NlaSvc start= auto | Out-Null
    sc.exe config netprofm start= auto | Out-Null
    sc.exe config SessionEnv start= demand | Out-Null
    sc.exe config UmRdpService start= demand | Out-Null

    Start-Service NlaSvc -ErrorAction SilentlyContinue
    Start-Service netprofm -ErrorAction SilentlyContinue
    Start-Service SessionEnv -ErrorAction SilentlyContinue
    Start-Service TermService -ErrorAction SilentlyContinue
    Start-Service UmRdpService -ErrorAction SilentlyContinue

    if (Get-Service -Name Tailscale -ErrorAction SilentlyContinue) {
        sc.exe config Tailscale start= auto | Out-Null
        Start-Service Tailscale -ErrorAction SilentlyContinue
    }
    if (Get-Service -Name sshd -ErrorAction SilentlyContinue) {
        sc.exe config sshd start= auto | Out-Null
        Start-Service sshd -ErrorAction SilentlyContinue
    }
}

function Get-RemoteAccessSnapshot {
    $listener = Get-NetTCPConnection -State Listen -LocalPort 3389 -ErrorAction SilentlyContinue | Select-Object -First 1
    $tailIp = ""
    if (Get-Command tailscale -ErrorAction SilentlyContinue) {
        $tailIp = ((tailscale ip -4 2>$null) | Select-Object -First 1)
    }
    return [PSCustomObject]@{
        TermService = (Get-Service -Name TermService -ErrorAction SilentlyContinue)
        SessionEnv  = (Get-Service -Name SessionEnv -ErrorAction SilentlyContinue)
        UmRdpService = (Get-Service -Name UmRdpService -ErrorAction SilentlyContinue)
        Tailscale   = (Get-Service -Name Tailscale -ErrorAction SilentlyContinue)
        Sshd        = (Get-Service -Name sshd -ErrorAction SilentlyContinue)
        Port3389    = [bool]($null -ne $listener)
        TailscaleIp = $tailIp
    }
}

function Show-RemoteAccessSnapshot([object]$Snapshot) {
    Print-Result "RdpRegistry" ((Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" -Name fDenyTSConnections -ErrorAction SilentlyContinue).fDenyTSConnections) "OK"
    Print-Result "TermService" $(if ($null -ne $Snapshot.TermService) { $Snapshot.TermService.Status } else { "Missing" }) $(if ($null -ne $Snapshot.TermService -and $Snapshot.TermService.Status -eq "Running") { "OK" } else { "WARN" })
    Print-Result "SessionEnv" $(if ($null -ne $Snapshot.SessionEnv) { $Snapshot.SessionEnv.Status } else { "Missing" }) $(if ($null -ne $Snapshot.SessionEnv) { "OK" } else { "WARN" })
    Print-Result "UmRdpService" $(if ($null -ne $Snapshot.UmRdpService) { $Snapshot.UmRdpService.Status } else { "Missing" }) $(if ($null -ne $Snapshot.UmRdpService) { "OK" } else { "WARN" })
    Print-Result "RdpPort3389" $(if ($Snapshot.Port3389) { "Listening" } else { "Not listening" }) $(if ($Snapshot.Port3389) { "OK" } else { "WARN" })
    if ($null -ne $Snapshot.Tailscale) {
        Print-Result "TailscaleService" $Snapshot.Tailscale.Status $(if ($Snapshot.Tailscale.Status -eq "Running") { "OK" } else { "WARN" })
        if (-not [string]::IsNullOrWhiteSpace($Snapshot.TailscaleIp)) {
            Print-Result "TailscaleIPv4" $Snapshot.TailscaleIp "OK"
        }
    }
    if ($null -ne $Snapshot.Sshd) {
        Print-Result "sshd" $Snapshot.Sshd.Status $(if ($Snapshot.Sshd.Status -eq "Running") { "OK" } else { "WARN" })
    }
}

function Get-RazerLaunchCommand {
    # Read the official Synapse autostart command from the Run keys so we relaunch exactly how Windows does at login.
    $runKeys = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
    )
    foreach ($key in $runKeys) {
        if (Test-Path $key) {
            $props = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
            if ($null -ne $props) {
                foreach ($prop in $props.PSObject.Properties) {
                    if (($prop.Value -is [string]) -and ($prop.Value -match 'RazerAppEngine\.exe')) {
                        return [string]$prop.Value
                    }
                }
            }
        }
    }
    # Fallback: default stub launcher with standard Synapse + Chroma params.
    $stub = "C:\Program Files\Razer\RazerAppEngine\RazerAppEngine.exe"
    if (Test-Path $stub) {
        return ('"' + $stub + '" --url-params=apps=synapse,chroma-app --launch-force-hidden=synapse,chroma-app --autoStart=1')
    }
    return ""
}

function Get-RazerSnapshot {
    $engine = @(Get-Process -Name RazerAppEngine -ErrorAction SilentlyContinue)
    $memMB = 0
    if ($engine.Count -gt 0) {
        $memBytes = ($engine | Measure-Object -Property WorkingSet64 -Sum).Sum
        $memMB = [math]::Round($memBytes / 1MB, 0)
    }
    $gms = Get-Service -Name 'Razer Game Manager Service 3' -ErrorAction SilentlyContinue
    $elev = Get-Service -Name 'Razer Elevation Service' -ErrorAction SilentlyContinue
    return [PSCustomObject]@{
        EngineCount = $engine.Count
        EngineMemMB = $memMB
        GameManager = $gms
        Elevation   = $elev
    }
}

function Show-RazerSnapshot([object]$Snapshot) {
    $countLevel = if ($Snapshot.EngineCount -le 4) { "OK" } else { "WARN" }
    Print-Result "RazerAppEngineProcesses" $Snapshot.EngineCount $countLevel
    Print-Result "RazerAppEngineMemoryMB" $Snapshot.EngineMemMB $countLevel
    Print-Result "GameManagerService" $(if ($null -ne $Snapshot.GameManager) { $Snapshot.GameManager.Status } else { "Missing" }) $(if ($null -ne $Snapshot.GameManager -and $Snapshot.GameManager.Status -eq "Running") { "OK" } else { "WARN" })
    Print-Result "ElevationService" $(if ($null -ne $Snapshot.Elevation) { $Snapshot.Elevation.Status } else { "Missing" }) "OK"
}

function Repair-RazerSynapse {
    # Capture the official launch command BEFORE killing anything, so we can relaunch a clean instance.
    $launchCmd = Get-RazerLaunchCommand

    # Kill only the front-end module-host processes that pile up (the runaway duplicates).
    # Game Manager Service + Elevation Service are intentionally left running: those drive macros.
    $frontEnd = @('RazerAppEngine', 'RzEngineMon', 'razerwdl')
    Get-Process -Name $frontEnd -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 1500

    # Relaunch a single clean Synapse instance (restores macros + lighting UI).
    $relaunched = $false
    if (-not [string]::IsNullOrWhiteSpace($launchCmd)) {
        $exePath = ""
        $argLine = ""
        if ($launchCmd -match '^\s*"([^"]+)"\s*(.*)$') {
            $exePath = $matches[1]; $argLine = $matches[2]
        } elseif ($launchCmd -match '^\s*(\S+)\s*(.*)$') {
            $exePath = $matches[1]; $argLine = $matches[2]
        }
        if ((-not [string]::IsNullOrWhiteSpace($exePath)) -and (Test-Path $exePath)) {
            try {
                if ([string]::IsNullOrWhiteSpace($argLine)) {
                    Start-Process -FilePath $exePath -ErrorAction Stop
                } else {
                    Start-Process -FilePath $exePath -ArgumentList $argLine -ErrorAction Stop
                }
                $relaunched = $true
            } catch {
                $relaunched = $false
            }
        }
    }
    return $relaunched
}

function Start-RazerFromCommand([string]$Cmd) {
    if ([string]::IsNullOrWhiteSpace($Cmd)) { return $false }
    $exePath = ""
    $argLine = ""
    if ($Cmd -match '^\s*"([^"]+)"\s*(.*)$') {
        $exePath = $matches[1]; $argLine = $matches[2]
    } elseif ($Cmd -match '^\s*(\S+)\s*(.*)$') {
        $exePath = $matches[1]; $argLine = $matches[2]
    }
    if ([string]::IsNullOrWhiteSpace($exePath) -or -not (Test-Path $exePath)) { return $false }
    try {
        if ([string]::IsNullOrWhiteSpace($argLine)) {
            Start-Process -FilePath $exePath -ErrorAction Stop
        } else {
            Start-Process -FilePath $exePath -ArgumentList $argLine -ErrorAction Stop
        }
        return $true
    } catch {
        return $false
    }
}

function Get-RazerExePath {
    $cmd = Get-RazerLaunchCommand
    if ($cmd -match '^\s*"([^"]+)"') { return $matches[1] }
    if ($cmd -match '^\s*(\S+)') { return $matches[1] }
    return "C:\Program Files\Razer\RazerAppEngine\RazerAppEngine.exe"
}

function New-RazerLaunchCommand([string]$Apps) {
    $exe = Get-RazerExePath
    return ('"' + $exe + '" --url-params=apps=' + $Apps + ' --launch-force-hidden=' + $Apps + ' --autoStart=1')
}

function Set-RazerAutostart([string]$Apps) {
    # Adjust the login autostart so Synapse comes back in the same mode after a reboot.
    # Modifies only the existing value (safe) - never recreates the Run key.
    $cmd = New-RazerLaunchCommand $Apps
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if (Test-Path $runKey) {
        Set-ItemProperty -Path $runKey -Name 'RazerAppEngine' -Value $cmd -ErrorAction SilentlyContinue
    }
}

function Set-RazerChromaServices([string]$StartupType, [bool]$Running) {
    # Chroma SDK services drive lighting only. Disabling them frees CPU/RAM and blocks respawn.
    $chroma = @(
        'Razer Chroma SDK Service',
        'Razer Chroma SDK Server',
        'Razer Chroma Stream Server',
        'Razer Chroma SDK Diagnostic Service'
    )
    foreach ($name in $chroma) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($null -ne $svc) {
            try { Set-Service -Name $name -StartupType $StartupType -ErrorAction SilentlyContinue } catch {}
            if ($Running) {
                Start-Service -Name $name -ErrorAction SilentlyContinue
            } else {
                Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Stop-RazerChromaProcesses {
    $names = @(
        'RzAppManager','RzBTLEManager','RzChromaConnectManager','RzChromaConnectServer',
        'RzChromaStreamServer','RzDeviceManager','RzDeviceManagerEx','RzIoTDeviceManager',
        'RzSmartlightingDeviceManager','RzWDLDeviceManager','razerwdl'
    )
    Get-Process -Name $names -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

function Ensure-RazerMacroEngine {
    # Game Manager Service 3 = macros. Keep it enabled + running.
    $gms = Get-Service -Name 'Razer Game Manager Service 3' -ErrorAction SilentlyContinue
    if ($null -ne $gms) {
        try { Set-Service -Name 'Razer Game Manager Service 3' -StartupType Automatic -ErrorAction SilentlyContinue } catch {}
        Start-Service -Name 'Razer Game Manager Service 3' -ErrorAction SilentlyContinue
    }
}

function Set-RazerGamingMode {
    # Min-resource mode: lighting OFF + blocked (Chroma services disabled), macros KEPT.
    Set-RazerChromaServices -StartupType 'Disabled' -Running $false
    Set-RazerAutostart -Apps 'synapse'
    Stop-RazerChromaProcesses
    Get-Process -Name 'RazerAppEngine','RzEngineMon' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 1500
    Ensure-RazerMacroEngine
    return (Start-RazerFromCommand (New-RazerLaunchCommand 'synapse'))
}

function Set-RazerFullMode {
    # Restore everything: lighting + macros.
    Set-RazerChromaServices -StartupType 'Automatic' -Running $true
    Set-RazerAutostart -Apps 'synapse,chroma-app'
    Ensure-RazerMacroEngine
    Get-Process -Name 'RazerAppEngine','RzEngineMon' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 1500
    return (Start-RazerFromCommand (New-RazerLaunchCommand 'synapse,chroma-app'))
}

function Get-RazerStatusReport {
    # Read-only inventory of the current Razer state. No admin needed (reads processes, services, HKCU).
    $allProcs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(Razer|Rz|GameManager)' })
    $engine = @($allProcs | Where-Object { $_.Name -eq 'RazerAppEngine' })
    $totalMem = 0
    if ($allProcs.Count -gt 0) { $totalMem = [math]::Round((($allProcs | Measure-Object WorkingSet64 -Sum).Sum) / 1MB, 0) }
    $engineMem = 0
    if ($engine.Count -gt 0) { $engineMem = [math]::Round((($engine | Measure-Object WorkingSet64 -Sum).Sum) / 1MB, 0) }

    $chromaNames = @('Razer Chroma SDK Service', 'Razer Chroma SDK Server', 'Razer Chroma Stream Server', 'Razer Chroma SDK Diagnostic Service')
    $chromaTotal = 0; $chromaRunning = 0; $chromaDisabled = 0
    foreach ($n in $chromaNames) {
        $svc = Get-CimInstance -ClassName Win32_Service -Filter ("Name='" + $n + "'") -ErrorAction SilentlyContinue
        if ($null -ne $svc) {
            $chromaTotal++
            if ($svc.State -eq 'Running') { $chromaRunning++ }
            if ($svc.StartMode -eq 'Disabled') { $chromaDisabled++ }
        }
    }
    $chromaSummary = ("" + $chromaRunning + "/" + $chromaTotal + " running")
    if ($chromaDisabled -gt 0) { $chromaSummary = $chromaSummary + ", " + $chromaDisabled + " disabled" }

    $gms = Get-CimInstance -ClassName Win32_Service -Filter "Name='Razer Game Manager Service 3'" -ErrorAction SilentlyContinue
    $gmsState = if ($null -ne $gms) { $gms.State } else { "Missing" }
    $elev = Get-CimInstance -ClassName Win32_Service -Filter "Name='Razer Elevation Service'" -ErrorAction SilentlyContinue
    $elevState = if ($null -ne $elev) { $elev.State } else { "Missing" }

    $autostart = "unknown"
    $runProps = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue
    if (($null -ne $runProps) -and ($runProps.PSObject.Properties.Name -contains 'RazerAppEngine')) {
        $runVal = [string]$runProps.RazerAppEngine
        if ($runVal -match 'chroma-app') { $autostart = "full (synapse + chroma)" }
        elseif ($runVal -match 'apps=synapse') { $autostart = "synapse-only (gaming)" }
    }

    $verdict = "Mixed / partial state"
    $rec = ""
    if ($engine.Count -gt 6) {
        $verdict = "RUNAWAY processes detected"
        $rec = "Run  -FixRazer  to clear the duplicates."
    } elseif (($chromaTotal -gt 0) -and ($chromaDisabled -eq $chromaTotal) -and ($chromaRunning -eq 0)) {
        $verdict = "GAMING mode active (lighting OFF + blocked)"
        $rec = "Run  -RazerOn  to bring lighting back."
    } elseif (($chromaTotal -gt 0) -and ($chromaRunning -eq $chromaTotal)) {
        $verdict = "FULL mode (lighting ON)"
        $rec = "Run  -RazerGaming  before gaming to cut resources."
    }

    return [PSCustomObject]@{
        EngineCount      = $engine.Count
        EngineMemMB      = $engineMem
        TotalCount       = $allProcs.Count
        TotalMemMB       = $totalMem
        ChromaSummary    = $chromaSummary
        GameManagerState = $gmsState
        ElevationState   = $elevState
        AutostartMode    = $autostart
        Verdict          = $verdict
        Recommendation   = $rec
    }
}

function Show-RazerStatus {
    $r = Get-RazerStatusReport
    $engineLevel = if ($r.EngineCount -le 4) { "OK" } else { "WARN" }
    $macroLevel = if ($r.GameManagerState -eq "Running") { "OK" } else { "WARN" }
    Write-Host ""
    Write-Host (Paint "   RAZER STATUS CHECK (read-only)" $S.NeonBlue)
    Write-Host (Paint "   -----------------------------" $S.Gray)
    Print-Result "RazerAppEngineProcesses" $r.EngineCount $engineLevel
    Print-Result "RazerAppEngineMemoryMB" $r.EngineMemMB $engineLevel
    Print-Result "TotalRazerProcesses" $r.TotalCount "OK"
    Print-Result "TotalRazerMemoryMB" $r.TotalMemMB "OK"
    Print-Result "ChromaLighting" $r.ChromaSummary "OK"
    Print-Result "GameManager(Macros)" $r.GameManagerState $macroLevel
    Print-Result "ElevationService" $r.ElevationState "OK"
    Print-Result "AutostartMode" $r.AutostartMode "OK"
    Write-Host ""
    Write-Host ((Paint "   VERDICT: " $S.NeonYellow) + $r.Verdict)
    if (-not [string]::IsNullOrWhiteSpace($r.Recommendation)) {
        Write-Host (Paint ("   TIP: " + $r.Recommendation) $S.Slate)
    }
    Write-Host ""
}

function New-UshieRestorePoint {
    # Full OS-level checkpoint - the complete undo (reg-import only reverts changed values,
    # it cannot delete newly-added ones, so a System Restore point is the real safety net).
    $sysDrive = ("" + $env:SystemDrive).Trim()
    if ([string]::IsNullOrWhiteSpace($sysDrive)) { $sysDrive = "C:" }
    try { Enable-ComputerRestore -Drive $sysDrive -ErrorAction Stop | Out-Null } catch {}
    reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore" /v SystemRestorePointCreationFrequency /t REG_DWORD /d 0 /f | Out-Null
    try {
        Checkpoint-Computer -Description "Before-Ushie-Tweaks" -RestorePointType "MODIFY_SETTINGS" -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return $false
    }
}

function New-UshieBackup {
    $desktop = [Environment]::GetFolderPath('Desktop')
    if ([string]::IsNullOrWhiteSpace($desktop)) { $desktop = Join-Path $env:USERPROFILE "Desktop" }
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $dir = Join-Path $desktop "ushie_oneshot_backup_$stamp"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Backup-Registry -BackupDir $dir
    $rpOk = New-UshieRestorePoint
    Write-Detail ("System Restore point: " + $(if ($rpOk) { "created (complete undo available)" } else { "could not create (use reg backup / enable System Protection)" }))
    return $dir
}

function Complete-StandaloneRun([string]$Message, [string]$Color) {
    Complete-SectionSpinner
    if (-not $VerboseOutput) {
        Clear-Host
        Show-Banner
    }
    Write-Host ""
    Write-Host (Paint ("   " + $Message) $Color)
}

function Optimize-Network {
    $mm = "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"
    reg add $mm /v NetworkThrottlingIndex /t REG_DWORD /d 4294967295 /f | Out-Null
    reg add $mm /v SystemResponsiveness /t REG_DWORD /d 10 /f | Out-Null
    cmd /c "netsh int tcp set global autotuninglevel=normal >nul 2>&1" | Out-Null
    cmd /c "netsh int tcp set global rss=enabled >nul 2>&1" | Out-Null
    cmd /c "netsh int tcp set global timestamps=disabled >nul 2>&1" | Out-Null
    cmd /c "ipconfig /flushdns >nul 2>&1" | Out-Null
}

function Optimize-Memory {
    Apply-MemoryPolicy -CurrentProfile "Extreme"
    $mem = "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management"
    reg add $mem /v ClearPageFileAtShutdown /t REG_DWORD /d 0 /f | Out-Null
    reg add $mem /v DisablePagingExecutive /t REG_DWORD /d 1 /f | Out-Null
}

function Optimize-Gpu {
    reg add "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" /v HwSchMode /t REG_DWORD /d 2 /f | Out-Null
    reg add "HKCU\System\GameConfigStore" /v GameDVR_Enabled /t REG_DWORD /d 0 /f | Out-Null
    reg add "HKCU\System\GameConfigStore" /v GameDVR_FSEBehaviorMode /t REG_DWORD /d 2 /f | Out-Null
    reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\GameDVR" /v AllowGameDVR /t REG_DWORD /d 0 /f | Out-Null
    reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR" /v AppCaptureEnabled /t REG_DWORD /d 0 /f | Out-Null
}

function Optimize-Storage {
    cmd /c "fsutil behavior set disablelastaccess 1 >nul 2>&1" | Out-Null
    cmd /c "fsutil behavior set disable8dot3 1 >nul 2>&1" | Out-Null
    Clear-TempAndCache -CurrentProfile "Extreme"
}

function Optimize-Cpu {
    # PowerThrottling off + foreground priority boost + unpark all cores. Safe + reversible (plugged-in laptop).
    reg add "HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling" /v PowerThrottlingOff /t REG_DWORD /d 1 /f | Out-Null
    reg add "HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl" /v Win32PrioritySeparation /t REG_DWORD /d 38 /f | Out-Null
    reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" /v SystemResponsiveness /t REG_DWORD /d 10 /f | Out-Null
    cmd /c "powercfg -setacvalueindex SCHEME_CURRENT SUB_PROCESSOR CPMINCORES 100 >nul 2>&1" | Out-Null
    cmd /c "powercfg -setactive SCHEME_CURRENT >nul 2>&1" | Out-Null
}

function Get-NvidiaSmiPath {
    $cmd = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if ($null -ne $cmd) { return $cmd.Source }
    $candidates = @(
        (Join-Path $env:SystemRoot "System32\nvidia-smi.exe"),
        "C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe"
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    return ""
}

function Show-ThermalReadout {
    Write-Host ""
    Write-Host (Paint "   THERMAL / PERFORMANCE READOUT" $S.NeonBlue)
    Write-Host (Paint "   ----------------------------" $S.Gray)
    $cpuTemp = "n/a"
    try {
        $tz = Get-CimInstance -Namespace "root/wmi" -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop | Select-Object -First 1
        if (($null -ne $tz) -and ($tz.CurrentTemperature -gt 0)) {
            $cpuTemp = ("" + [math]::Round(($tz.CurrentTemperature / 10) - 273.15, 0) + " C")
        }
    } catch {}
    Print-Result "CPU_Temp(ACPI)" $cpuTemp $(if ($cpuTemp -eq "n/a") { "WARN" } else { "OK" })
    $smi = Get-NvidiaSmiPath
    if (-not [string]::IsNullOrWhiteSpace($smi)) {
        $line = (& $smi --query-gpu=temperature.gpu,utilization.gpu,clocks.sm,power.draw,power.limit --format=csv,noheader,nounits 2>$null | Select-Object -First 1)
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            $parts = @(($line -split ',') | ForEach-Object { $_.Trim() })
            if ($parts.Count -ge 5) {
                Print-Result "GPU_Temp" ($parts[0] + " C") "OK"
                Print-Result "GPU_Util" ($parts[1] + " %") "OK"
                Print-Result "GPU_Clock" ($parts[2] + " MHz") "OK"
                Print-Result "GPU_Power" ($parts[3] + " / " + $parts[4] + " W") "OK"
            }
        }
    } else {
        Print-Result "GPU(nvidia-smi)" "not found" "WARN"
    }
}

function Show-UndervoltPlaybook {
    Write-Host ""
    Write-Host (Paint "   LAPTOP-SAFE UNDERVOLT / OVERCLOCK PLAYBOOK (manual, do this AT the laptop)" $S.NeonYellow)
    Write-Host (Paint "   -----------------------------------------------------------------------" $S.Gray)
    Write-Host "   Undervolting LOWERS heat + throttling (faster sustained perf) and CANNOT"
    Write-Host "   damage hardware - worst case is an unstable boot you reset. Overclocking a"
    Write-Host "   laptop is NOT recommended. Do these only when PHYSICALLY at the laptop"
    Write-Host "   (a crash over RDP can lock you out)."
    Write-Host ""
    Write-Host (Paint "   CPU undervolt (Intel i7-10750H) - tool: ThrottleStop" $S.NeonMint)
    Write-Host "     1. Install ThrottleStop, open FIVR."
    Write-Host "     2. CPU Core -50 mV, Cache -50 mV. Apply."
    Write-Host "     3. Stress test (TS Bench / a game) ~15-30 min."
    Write-Host "     4. If stable, lower Core in -10 mV steps (core can go lower than cache,"
    Write-Host "        e.g. cache -100 mV, core -150/-200 mV). Back off 10-20 mV from first crash."
    Write-Host "     NOTE: ASUS BIOS may LOCK undervolt (Plundervolt). If -50 mV does nothing, skip."
    Write-Host ""
    Write-Host (Paint "   GPU (NVIDIA RTX 2060 laptop) - tool: MSI Afterburner" $S.NeonMint)
    Write-Host "     - Undervolt curve ~0.8-0.85V = cooler + similar/faster; OR mild +100 core /"
    Write-Host "       +200 mem offset, test, back off on artifacts. Resets on reboot unless saved."
    Write-Host ""
    Write-Host (Paint "   THRESHOLDS (you have an external cooler):" $S.NeonPink)
    Write-Host "     - Keep CPU < ~90 C, GPU < ~80 C under load. Hotter = back off."
    Write-Host "     - Any crash/BSOD/artifact = too aggressive; raise voltage / lower clock."
    Write-Host "     - Run  -Temp  before and after to compare."
}

function Optimize-Services {
    # Conservative, reversible. Disable = clearly safe; Manual = on-demand (Chris Titus style).
    # Deliberately AVOIDS network/RDP/audio/search/security/input services (RDP-safe).
    $disable = @('DiagTrack', 'dmwappushservice', 'RetailDemo', 'RemoteRegistry')
    $manual  = @('MapsBroker', 'Fax', 'WMPNetworkSvc', 'WerSvc', 'lfsvc', 'PcaSvc', 'DusmSvc')
    foreach ($s in $disable) {
        if ($null -ne (Get-Service -Name $s -ErrorAction SilentlyContinue)) {
            cmd /c "sc.exe config `"$s`" start= disabled >nul 2>&1" | Out-Null
            cmd /c "sc.exe stop `"$s`" >nul 2>&1" | Out-Null
        }
    }
    foreach ($s in $manual) {
        if ($null -ne (Get-Service -Name $s -ErrorAction SilentlyContinue)) {
            cmd /c "sc.exe config `"$s`" start= demand >nul 2>&1" | Out-Null
        }
    }
}

function Optimize-Latency {
    # USB selective suspend off + PCIe ASPM off (lower latency, plugged-in) + Windows Game Mode on.
    cmd /c "powercfg -setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 >nul 2>&1" | Out-Null
    cmd /c "powercfg -setacvalueindex SCHEME_CURRENT 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 0 >nul 2>&1" | Out-Null
    cmd /c "powercfg -setactive SCHEME_CURRENT >nul 2>&1" | Out-Null
    reg add "HKCU\Software\Microsoft\GameBar" /v AutoGameModeEnabled /t REG_DWORD /d 1 /f | Out-Null
    reg add "HKCU\Software\Microsoft\GameBar" /v AllowAutoGameMode /t REG_DWORD /d 1 /f | Out-Null
}

function Disable-VBS {
    # Virtualization-Based Security / Memory Integrity off. Real gaming gain, but lowers a security layer.
    reg add "HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard" /v EnableVirtualizationBasedSecurity /t REG_DWORD /d 0 /f | Out-Null
    reg add "HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" /v Enabled /t REG_DWORD /d 0 /f | Out-Null
}

function Show-StartupApps {
    Write-Host ""
    Write-Host (Paint "   STARTUP PROGRAMS (read-only)" $S.NeonBlue)
    Write-Host (Paint "   ---------------------------" $S.Gray)
    $keys = @(
        @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Tag = 'HKCU' },
        @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'; Tag = 'HKLM' },
        @{ Path = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Tag = 'HKLM32' }
    )
    $count = 0
    foreach ($k in $keys) {
        if (Test-Path $k.Path) {
            $props = Get-ItemProperty -Path $k.Path -ErrorAction SilentlyContinue
            if ($null -ne $props) {
                foreach ($pr in $props.PSObject.Properties) {
                    if ($pr.Name -notmatch '^PS(Path|ParentPath|ChildName|Drive|Provider)$') {
                        Write-Host ("   [" + $k.Tag + "] " + $pr.Name)
                        $count++
                    }
                }
            }
        }
    }
    $startupFolder = [Environment]::GetFolderPath('Startup')
    if (-not [string]::IsNullOrWhiteSpace($startupFolder) -and (Test-Path $startupFolder)) {
        foreach ($f in @(Get-ChildItem -Path $startupFolder -ErrorAction SilentlyContinue)) {
            Write-Host ("   [Startup folder] " + $f.Name)
            $count++
        }
    }
    if ($count -eq 0) { Write-Host (Paint "   (no user/machine startup entries found)" $S.Gray) }
    Write-Host ""
    Write-Host (Paint "   To disable one: Task Manager > Startup apps, or Settings > Apps > Startup." $S.Slate)
}

function Print-Result([string]$Name, [object]$Value, [string]$Level = "OK") {
    $tag = "[OK]"
    $color = $S.Green
    if ($Level -eq "WARN") { $tag = "[WARN]"; $color = $S.Yellow }
    if ($Level -eq "FAIL") { $tag = "[FAIL]"; $color = $S.Red }
    Write-Host ((Paint $tag $color) + " " + (Paint ($Name + ": ") $S.Gray) + $Value)
}

function Prompt-RestartNow {
    $canPrompt = $false
    try {
        $canPrompt = ($Host.Name -eq "ConsoleHost" -and -not [Console]::IsInputRedirected)
    } catch {
        $canPrompt = ($Host.Name -eq "ConsoleHost")
    }

    if (-not $canPrompt) { return }

    Write-Host (Paint "   Press Enter to restart now. Type N then Enter to skip." $S.Yellow)
    $answer = Read-Host "   Restart now?"
    if ([string]::IsNullOrWhiteSpace($answer) -or $answer.Trim().ToLowerInvariant() -eq "y") {
        Write-Host (Paint "   Restarting now..." $S.Yellow)
        shutdown /r /t 0 | Out-Null
    } else {
        Write-Host (Paint "   Restart skipped. Reboot later to finalize changes." $S.Gray)
    }
}

function Set-MaxPerformancePlan {
    $ultimate = "e9a42b02-d5df-448d-aa00-03f14749eb61"
    $guid = ""

    $schemesText = (powercfg /L | Out-String)
    $uMatch = [regex]::Match($schemesText, "Power Scheme GUID:\s*([0-9a-fA-F\-]{36})\s+\(Ultimate Performance\)")
    if ($uMatch.Success) {
        $guid = $uMatch.Groups[1].Value
    } else {
        $dupOut = powercfg /duplicatescheme $ultimate 2>$null
        if ($dupOut -match "[0-9a-fA-F\-]{36}") {
            $guid = $matches[0]
        }
    }

    if (-not $guid) {
        $active = ([regex]::Match((powercfg /GETACTIVESCHEME), "[0-9a-fA-F\-]{36}")).Value
        if ($active) { $guid = $active }
    }

    if (-not $guid) {
        powercfg /setactive SCHEME_MIN | Out-Null
        $guid = ([regex]::Match((powercfg /GETACTIVESCHEME), "[0-9a-fA-F\-]{36}")).Value
    } else {
        powercfg /setactive $guid | Out-Null
    }

    if ($guid) {
        powercfg /setacvalueindex $guid SUB_PROCESSOR PROCTHROTTLEMIN 100 | Out-Null
        powercfg /setdcvalueindex $guid SUB_PROCESSOR PROCTHROTTLEMIN 100 | Out-Null
        powercfg /setacvalueindex $guid SUB_PROCESSOR PROCTHROTTLEMAX 100 | Out-Null
        powercfg /setdcvalueindex $guid SUB_PROCESSOR PROCTHROTTLEMAX 100 | Out-Null
        powercfg /setacvalueindex $guid SUB_PROCESSOR SYSCOOLPOL 1 | Out-Null
        powercfg /setdcvalueindex $guid SUB_PROCESSOR SYSCOOLPOL 1 | Out-Null
        powercfg /setactive $guid | Out-Null
    }

    return $guid
}

function Export-RegKeyIfExists([string]$KeyPath, [string]$OutFile) {
    $psPath = if ($KeyPath -like "HKLM\*") {
        "Registry::HKEY_LOCAL_MACHINE\" + $KeyPath.Substring(5)
    } elseif ($KeyPath -like "HKCU\*") {
        "Registry::HKEY_CURRENT_USER\" + $KeyPath.Substring(5)
    } else {
        $null
    }
    if ($psPath -and (Test-Path $psPath)) {
        cmd /c "reg export `"$KeyPath`" `"$OutFile`" /y >nul 2>&1" | Out-Null
    }
}

function Backup-Registry([string]$BackupDir) {
    Export-RegKeyIfExists "HKLM\SOFTWARE\Microsoft\Windows\Dwm" (Join-Path $BackupDir "HKLM_Dwm.reg")
    Export-RegKeyIfExists "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters" (Join-Path $BackupDir "HKLM_Tcpip6.reg")
    Export-RegKeyIfExists "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching" (Join-Path $BackupDir "HKLM_DriverSearching.reg")
    Export-RegKeyIfExists "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Installer" (Join-Path $BackupDir "HKLM_DeviceInstaller.reg")
    Export-RegKeyIfExists "HKCU\Control Panel\Accessibility\Keyboard Response" (Join-Path $BackupDir "HKCU_KeyboardResponse.reg")
    Export-RegKeyIfExists "HKCU\Control Panel\Keyboard" (Join-Path $BackupDir "HKCU_Keyboard.reg")
    Export-RegKeyIfExists "HKCU\Control Panel\Desktop" (Join-Path $BackupDir "HKCU_Desktop.reg")
    Export-RegKeyIfExists "HKCU\Control Panel\Desktop\WindowMetrics" (Join-Path $BackupDir "HKCU_WindowMetrics.reg")
    Export-RegKeyIfExists "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" (Join-Path $BackupDir "HKCU_ExplorerAdvanced.reg")
    Export-RegKeyIfExists "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" (Join-Path $BackupDir "HKCU_VisualEffects.reg")
    Export-RegKeyIfExists "HKCU\Software\Policies\Microsoft\Windows\Explorer" (Join-Path $BackupDir "HKCU_ExplorerPolicy.reg")
    Export-RegKeyIfExists "HKCU\Software\Microsoft\Windows\CurrentVersion\PushNotifications" (Join-Path $BackupDir "HKCU_PushNotifications.reg")
    Export-RegKeyIfExists "HKCU\Software\Microsoft\Windows\CurrentVersion\Search" (Join-Path $BackupDir "HKCU_Search.reg")
    Export-RegKeyIfExists "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" (Join-Path $BackupDir "HKLM_MultimediaSystemProfile.reg")
    Export-RegKeyIfExists "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" (Join-Path $BackupDir "HKLM_MemoryManagement.reg")
    Export-RegKeyIfExists "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" (Join-Path $BackupDir "HKLM_GraphicsDrivers.reg")
    Export-RegKeyIfExists "HKCU\System\GameConfigStore" (Join-Path $BackupDir "HKCU_GameConfigStore.reg")
    Export-RegKeyIfExists "HKLM\SOFTWARE\Policies\Microsoft\Windows\GameDVR" (Join-Path $BackupDir "HKLM_GameDVRPolicy.reg")
    Export-RegKeyIfExists "HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR" (Join-Path $BackupDir "HKCU_GameDVR.reg")
    Export-RegKeyIfExists "HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl" (Join-Path $BackupDir "HKLM_PriorityControl.reg")
    Export-RegKeyIfExists "HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling" (Join-Path $BackupDir "HKLM_PowerThrottling.reg")
    Export-RegKeyIfExists "HKCU\Software\Microsoft\GameBar" (Join-Path $BackupDir "HKCU_GameBar.reg")
    Export-RegKeyIfExists "HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard" (Join-Path $BackupDir "HKLM_DeviceGuard.reg")
}

function Get-LatestUshieBackup {
    $desktop = [Environment]::GetFolderPath('Desktop')
    if ([string]::IsNullOrWhiteSpace($desktop)) { $desktop = Join-Path $env:USERPROFILE "Desktop" }
    $dirs = @(Get-ChildItem -Path $desktop -Directory -Filter 'ushie_oneshot_backup_*' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($dirs.Count -gt 0) { return $dirs[0].FullName }
    return ""
}

function Restore-FromBackup([string]$BackupDir) {
    $regFiles = @(Get-ChildItem -Path $BackupDir -Filter '*.reg' -ErrorAction SilentlyContinue)
    $imported = 0
    foreach ($f in $regFiles) {
        cmd /c "reg import `"$($f.FullName)`" >nul 2>&1" | Out-Null
        if ($LASTEXITCODE -eq 0) { $imported++ }
    }
    return [PSCustomObject]@{ Total = $regFiles.Count; Imported = $imported }
}

function Ensure-ExtremeRestorePoint {
    if ($script:RunProfile -ne "Extreme") { return }

    $sysDrive = ("" + $env:SystemDrive).Trim()
    if ([string]::IsNullOrWhiteSpace($sysDrive)) { $sysDrive = "C:" }
    $description = "Before-Ushie-Extreme"

    try {
        Enable-ComputerRestore -Drive $sysDrive -ErrorAction Stop | Out-Null
    } catch {
        Print-Result "RestorePointPrep" ("Enable-ComputerRestore failed: " + $_.Exception.Message) "WARN"
    }

    reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore" /v SystemRestorePointCreationFrequency /t REG_DWORD /d 0 /f | Out-Null

    try {
        Checkpoint-Computer -Description $description -RestorePointType "MODIFY_SETTINGS" -ErrorAction Stop | Out-Null
        $latest = Get-ComputerRestorePoint -ErrorAction SilentlyContinue | Sort-Object SequenceNumber -Descending | Select-Object -First 1
        if ($null -ne $latest) {
            Print-Result "RestorePointCreated" ($latest.Description + " (#" + $latest.SequenceNumber + ")") "OK"
        } else {
            Print-Result "RestorePointCreated" $description "OK"
        }
    } catch {
        Print-Result "RestorePointCreated" ("Failed: " + $_.Exception.Message) "WARN"
    }
}

function Get-PowerCfgAcSettingIndex([string]$PlanGuid, [string]$SubGroup, [string]$Setting) {
    try {
        $text = (powercfg /Q $PlanGuid $SubGroup $Setting | Out-String)
        $match = [regex]::Match($text, "Current AC Power Setting Index:\s*(0x[0-9a-fA-F]+)")
        if ($match.Success) {
            return [Convert]::ToInt32($match.Groups[1].Value, 16)
        }
    } catch {}
    return -1
}

function Apply-SafeProfile {
    reg add "HKCU\Control Panel\Desktop" /v DragFullWindows /t REG_SZ /d 0 /f | Out-Null
    reg add "HKCU\Control Panel\Desktop" /v MenuShowDelay /t REG_SZ /d 0 /f | Out-Null
    reg add "HKCU\Control Panel\Desktop\WindowMetrics" /v MinAnimate /t REG_SZ /d 0 /f | Out-Null

    reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v TaskbarAnimations /t REG_DWORD /d 0 /f | Out-Null
    reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v ListviewAlphaSelect /t REG_DWORD /d 0 /f | Out-Null
    reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v ListviewShadow /t REG_DWORD /d 0 /f | Out-Null
    reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v TaskbarMn /t REG_DWORD /d 0 /f | Out-Null
    reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v ShowTaskViewButton /t REG_DWORD /d 1 /f | Out-Null
    reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v DisablePreviewDesktop /t REG_DWORD /d 1 /f | Out-Null
    reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" /v VisualFXSetting /t REG_DWORD /d 2 /f | Out-Null
    reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Search" /v SearchboxTaskbarMode /t REG_DWORD /d 1 /f | Out-Null
    reg add "HKCU\Software\Microsoft\Windows\DWM" /v EnableAeroPeek /t REG_DWORD /d 0 /f | Out-Null
    reg add "HKCU\Software\Microsoft\Windows\DWM" /v Animations /t REG_DWORD /d 0 /f | Out-Null
    reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v EnableTransparency /t REG_DWORD /d 0 /f | Out-Null

    reg delete "HKCU\Software\Policies\Microsoft\Windows\Explorer" /v DisableNotificationCenter /f 2>$null | Out-Null
    reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\PushNotifications" /v ToastEnabled /t REG_DWORD /d 1 /f | Out-Null
    Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name UserPreferencesMask -Type Binary -Value ([byte[]](144,18,3,128,16,0,0,0))

    # Restore default mouse acceleration profile for non-Extreme mode.
    reg add "HKCU\Control Panel\Mouse" /v MouseSpeed /t REG_SZ /d 1 /f | Out-Null
    reg add "HKCU\Control Panel\Mouse" /v MouseThreshold1 /t REG_SZ /d 6 /f | Out-Null
    reg add "HKCU\Control Panel\Mouse" /v MouseThreshold2 /t REG_SZ /d 10 /f | Out-Null

    # Restore cursor blink to default.
    reg add "HKCU\Control Panel\Desktop" /v CursorBlinkRate /t REG_SZ /d 530 /f | Out-Null
}

function Apply-ExtremeProfile {
    reg add "HKCU\Control Panel\Desktop" /v DragFullWindows /t REG_SZ /d 0 /f | Out-Null
    reg add "HKCU\Control Panel\Desktop" /v MenuShowDelay /t REG_SZ /d 0 /f | Out-Null
    reg add "HKCU\Control Panel\Desktop\WindowMetrics" /v MinAnimate /t REG_SZ /d 0 /f | Out-Null

    reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v TaskbarAnimations /t REG_DWORD /d 0 /f | Out-Null
    reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v ListviewAlphaSelect /t REG_DWORD /d 0 /f | Out-Null
    reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v ListviewShadow /t REG_DWORD /d 0 /f | Out-Null
    reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v TaskbarMn /t REG_DWORD /d 0 /f | Out-Null
    reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v ShowTaskViewButton /t REG_DWORD /d 0 /f | Out-Null
    reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" /v VisualFXSetting /t REG_DWORD /d 2 /f | Out-Null
    reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Search" /v SearchboxTaskbarMode /t REG_DWORD /d 0 /f | Out-Null
    reg add "HKCU\Software\Microsoft\Windows\DWM" /v EnableAeroPeek /t REG_DWORD /d 0 /f | Out-Null
    reg add "HKCU\Software\Microsoft\Windows\DWM" /v Animations /t REG_DWORD /d 0 /f | Out-Null

    reg add "HKCU\Software\Policies\Microsoft\Windows\Explorer" /v DisableNotificationCenter /t REG_DWORD /d 1 /f | Out-Null
    reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\PushNotifications" /v ToastEnabled /t REG_DWORD /d 0 /f | Out-Null

    # Align with Winutil display-performance mask for visual responsiveness.
    Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name UserPreferencesMask -Type Binary -Value ([byte[]](144,18,3,128,16,0,0,0))

    # Disable cursor blink - removes unnecessary screen redraws.
    reg add "HKCU\Control Panel\Desktop" /v CursorBlinkRate /t REG_SZ /d -1 /f | Out-Null

    # Disable mouse acceleration (enhanced pointer precision) - flat, predictable aim.
    reg add "HKCU\Control Panel\Mouse" /v MouseSpeed /t REG_SZ /d 0 /f | Out-Null
    reg add "HKCU\Control Panel\Mouse" /v MouseThreshold1 /t REG_SZ /d 0 /f | Out-Null
    reg add "HKCU\Control Panel\Mouse" /v MouseThreshold2 /t REG_SZ /d 0 /f | Out-Null
}

function Apply-ExtremeSystemWide {
    # Extreme-only: kill transparency + Aero Peek.
    reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v EnableTransparency /t REG_DWORD /d 0 /f | Out-Null
    reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v DisablePreviewDesktop /t REG_DWORD /d 1 /f | Out-Null
}

function Apply-ExtremeTelemetry {
    # Telemetry and privacy registry - winutil essential set.
    reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" /v Enabled /t REG_DWORD /d 0 /f | Out-Null
    reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Privacy" /v TailoredExperiencesWithDiagnosticDataEnabled /t REG_DWORD /d 0 /f | Out-Null
    reg add "HKCU\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy" /v HasAccepted /t REG_DWORD /d 0 /f | Out-Null
    reg add "HKCU\Software\Microsoft\Input\TIPC" /v Enabled /t REG_DWORD /d 0 /f | Out-Null
    reg add "HKCU\Software\Microsoft\InputPersonalization" /v RestrictImplicitInkCollection /t REG_DWORD /d 1 /f | Out-Null
    reg add "HKCU\Software\Microsoft\InputPersonalization" /v RestrictImplicitTextCollection /t REG_DWORD /d 1 /f | Out-Null
    reg add "HKCU\Software\Microsoft\InputPersonalization\TrainedDataStore" /v HarvestContacts /t REG_DWORD /d 0 /f | Out-Null
    reg add "HKCU\Software\Microsoft\Personalization\Settings" /v AcceptedPrivacyPolicy /t REG_DWORD /d 0 /f | Out-Null
    reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" /v AllowTelemetry /t REG_DWORD /d 0 /f | Out-Null
    reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v Start_TrackProgs /t REG_DWORD /d 0 /f | Out-Null
    reg add "HKCU\Software\Microsoft\Siuf\Rules" /v NumberOfSIUFInPeriod /t REG_DWORD /d 0 /f | Out-Null

    # Bing search in Start Menu off.
    reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Search" /v BingSearchEnabled /t REG_DWORD /d 0 /f | Out-Null

    # Delivery Optimization: local only - no peer upload to random internet PCs.
    reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" /v DODownloadMode /t REG_DWORD /d 0 /f | Out-Null

    # SvcHost split: raise threshold to total RAM so services share fewer host processes.
    $ramKB = [int]((Get-CimInstance Win32_PhysicalMemory | Measure-Object Capacity -Sum).Sum / 1KB)
    reg add "HKLM\SYSTEM\CurrentControlSet\Control" /v SvcHostSplitThresholdInKB /t REG_DWORD /d $ramKB /f | Out-Null

    # Teredo tunneling off - not needed on modern networks, reduces latency jitter.
    netsh interface teredo set state disabled | Out-Null
    # Prefer IPv4 over IPv6 (bit 5 = 32) for lower latency on private networks.
    reg add "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters" /v DisabledComponents /t REG_DWORD /d 32 /f | Out-Null

    # Defender: disable auto sample submission (AV stays on, just stops uploading samples).
    Set-MpPreference -SubmitSamplesConsent 2 -ErrorAction SilentlyContinue

    # Disable CEIP / compatibility appraiser / disk diagnostic telemetry tasks.
    $teleTasks = @(
        '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
        '\Microsoft\Windows\Application Experience\ProgramDataUpdater',
        '\Microsoft\Windows\Autochk\Proxy',
        '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
        '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip',
        '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector'
    )
    foreach ($task in $teleTasks) {
        $taskPath = (Split-Path $task -Parent).TrimEnd('\') + '\'
        $taskName = Split-Path $task -Leaf
        Disable-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction SilentlyContinue | Out-Null
    }
}

function Apply-MemoryPolicy([string]$CurrentProfile) {
    if ($CurrentProfile -eq "Extreme") {
        Disable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue | Out-Null
        Disable-MMAgent -PageCombining -ErrorAction SilentlyContinue | Out-Null
    } else {
        Enable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue | Out-Null
        Enable-MMAgent -PageCombining -ErrorAction SilentlyContinue | Out-Null
    }
}

function Apply-ExtremeLatencyStack {
    # MMCSS + scheduler path used by many games and media workloads.
    reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" /v SystemResponsiveness /t REG_DWORD /d 0 /f | Out-Null
    reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" /v NetworkThrottlingIndex /t REG_DWORD /d 4294967295 /f | Out-Null
    reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "GPU Priority" /t REG_DWORD /d 8 /f | Out-Null
    reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "Priority" /t REG_DWORD /d 6 /f | Out-Null
    reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "Scheduling Category" /t REG_SZ /d High /f | Out-Null
    reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "SFIO Priority" /t REG_SZ /d High /f | Out-Null
    reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Pro Audio" /v "Affinity" /t REG_DWORD /d 0 /f | Out-Null
    reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Pro Audio" /v "Background Only" /t REG_SZ /d False /f | Out-Null
    reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Pro Audio" /v "Clock Rate" /t REG_DWORD /d 10000 /f | Out-Null
    reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Pro Audio" /v "GPU Priority" /t REG_DWORD /d 8 /f | Out-Null
    reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Pro Audio" /v "Priority" /t REG_DWORD /d 6 /f | Out-Null
    reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Pro Audio" /v "Scheduling Category" /t REG_SZ /d High /f | Out-Null
    reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Pro Audio" /v "SFIO Priority" /t REG_SZ /d High /f | Out-Null

    # Favor foreground responsiveness for interactive desktop/game load.
    reg add "HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl" /v Win32PrioritySeparation /t REG_DWORD /d 38 /f | Out-Null
    reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" /v DisablePagingExecutive /t REG_DWORD /d 1 /f | Out-Null
    reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters" /v EnablePrefetcher /t REG_DWORD /d 0 /f | Out-Null
    reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters" /v EnableSuperfetch /t REG_DWORD /d 0 /f | Out-Null

    # Boot timer policy for lower input latency.
    Invoke-BcdSet "useplatformclock" "false"
    Invoke-BcdSet "disabledynamictick" "yes"
    Invoke-BcdSet "tscsyncpolicy" "Enhanced"

    # TCP stack baseline for low-latency gaming while keeping compatibility.
    netsh int tcp set heuristics disabled | Out-Null
    netsh int tcp set global rss=enabled | Out-Null
    netsh int tcp set global autotuninglevel=normal | Out-Null
    netsh int tcp set global chimney=disabled | Out-Null
    netsh int tcp set global ecncapability=disabled | Out-Null
    netsh int tcp set global timestamps=disabled | Out-Null
    netsh int tcp set global rsc=disabled | Out-Null

    # Disable Nagle-related delay per active interface where key exists.
    $activeAdapters = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq "Up" }
    foreach ($ifc in $activeAdapters) {
        $guidRaw = ("" + $ifc.NetAdapter.InterfaceGuid).Trim("{}")
        $path = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\{$guidRaw}"
        if (Test-Path $path) {
            Set-ItemProperty -Path $path -Name TcpAckFrequency -Type DWord -Value 1
            Set-ItemProperty -Path $path -Name TCPNoDelay -Type DWord -Value 1
            Set-ItemProperty -Path $path -Name TcpDelAckTicks -Type DWord -Value 0
        }
    }
}

function Apply-ExtremeCpuPowerPolicy([string]$PlanGuid) {
    if (-not $PlanGuid) { return }

    # Aggressive low-latency CPU behavior in extreme mode.
    powercfg /setacvalueindex $PlanGuid SUB_PROCESSOR IDLEDISABLE 1 2>$null | Out-Null
    powercfg /setdcvalueindex $PlanGuid SUB_PROCESSOR IDLEDISABLE 1 2>$null | Out-Null
    powercfg /setacvalueindex $PlanGuid SUB_PROCESSOR PERFBOOSTMODE 2 2>$null | Out-Null
    powercfg /setdcvalueindex $PlanGuid SUB_PROCESSOR PERFBOOSTMODE 2 2>$null | Out-Null
    powercfg /setacvalueindex $PlanGuid SUB_PROCESSOR PERFEPP 0 2>$null | Out-Null
    powercfg /setdcvalueindex $PlanGuid SUB_PROCESSOR PERFEPP 0 2>$null | Out-Null
    powercfg /setactive $PlanGuid | Out-Null
}

function Set-ProfileMarker {
    if (-not (Test-Path $script:StateRoot)) {
        New-Item -Path $script:StateRoot -Force | Out-Null
    }
    Set-ItemProperty -Path $script:StateRoot -Name Profile -Type String -Value $script:RunProfile
    Set-ItemProperty -Path $script:StateRoot -Name LastAppliedAt -Type String -Value (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
}

function Remove-LegacyWinLagTasks {
    schtasks /Delete /TN "\WinLagFix\ForcePowerOnLogon" /F 2>$null | Out-Null
    schtasks /Delete /TN "\WinLagFix\ForcePowerOnStartup" /F 2>$null | Out-Null
    schtasks /Delete /TN "\WinLagFix\ForcePowerEveryMinute" /F 2>$null | Out-Null
    Remove-Item "$env:ProgramData\WinLagFix\Force-Ultimate.ps1" -Force -ErrorAction SilentlyContinue
}

function Get-DnsPresets {
    return @{
        Cloudflare = @("1.1.1.1","1.0.0.1")
        Google     = @("8.8.8.8","8.8.4.4")
        Quad9      = @("9.9.9.9","149.112.112.112")
        OpenDNS    = @("208.67.222.222","208.67.220.220")
        AdGuard    = @("94.140.14.14","94.140.15.15")
        ControlD   = @("76.76.2.0","76.76.10.0")
        DNSSB      = @("185.222.222.222","45.11.45.11")
        Comodo     = @("8.26.56.26","8.20.247.20")
    }
}

function Test-IPv4String([string]$Value) {
    return ($Value -match '^(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])){3}$')
}

function New-DnsQueryPacket([string]$Name) {
    $id = Get-Random -Minimum 0 -Maximum 65535
    $bytes = New-Object 'System.Collections.Generic.List[byte]'

    $bytes.Add([byte](($id -shr 8) -band 0xFF))
    $bytes.Add([byte]($id -band 0xFF))
    $bytes.Add(0x01)
    $bytes.Add(0x00)
    $bytes.Add(0x00)
    $bytes.Add(0x01)
    $bytes.Add(0x00)
    $bytes.Add(0x00)
    $bytes.Add(0x00)
    $bytes.Add(0x00)
    $bytes.Add(0x00)
    $bytes.Add(0x00)

    foreach ($label in ($Name -split '\.')) {
        $labelBytes = [System.Text.Encoding]::ASCII.GetBytes($label)
        $bytes.Add([byte]$labelBytes.Length)
        foreach ($b in $labelBytes) {
            $bytes.Add($b)
        }
    }

    $bytes.Add(0x00)
    $bytes.Add(0x00)
    $bytes.Add(0x01)
    $bytes.Add(0x00)
    $bytes.Add(0x01)

    return @{
        Id     = $id
        Packet = $bytes.ToArray()
    }
}

function Measure-DnsQueryLatencyMs([string]$Name, [string]$Server, [string]$Detail, [object]$TickRef = $null) {
    $query = New-DnsQueryPacket -Name $Name
    $udp = $null
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.Client.SendTimeout = 2500
        $udp.Client.ReceiveTimeout = 2500
        $udp.Connect($Server, 53)
        [void]$udp.Send($query.Packet, $query.Packet.Length)

        $async = $udp.BeginReceive($null, $null)
        while (-not $async.AsyncWaitHandle.WaitOne(80)) {
            if ($null -ne $TickRef) {
                Update-SectionSpinner -Detail $Detail -Tick $TickRef.Value
                $TickRef.Value++
            }
            if ($sw.ElapsedMilliseconds -ge 2500) {
                throw "DNS query timeout"
            }
        }

        $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $response = $udp.EndReceive($async, [ref]$remote)
        $sw.Stop()

        if ($response.Length -lt 12) { return 2500.0 }
        if ($response[0] -ne [byte](($query.Id -shr 8) -band 0xFF)) { return 2500.0 }
        if ($response[1] -ne [byte]($query.Id -band 0xFF)) { return 2500.0 }

        $rcode = ($response[3] -band 0x0F)
        if ($rcode -ne 0) { return 2500.0 }

        return [math]::Round($sw.Elapsed.TotalMilliseconds, 2)
    } catch {
        return 2500.0
    } finally {
        if ($sw.IsRunning) { $sw.Stop() }
        if ($null -ne $udp) {
            try { $udp.Close() } catch {}
            try { $udp.Dispose() } catch {}
        }
    }
}

function Measure-DnsServerLatencyMs([string]$Server, [string]$DetailPrefix = "", [object]$TickRef = $null) {
    $targets = @("api.steampowered.com","dota2.com","microsoft.com")
    $samples = @()
    foreach ($name in $targets) {
        try {
            if ((Test-CanAnimate) -and $null -ne $TickRef) {
                $detail = if ([string]::IsNullOrWhiteSpace($DetailPrefix)) {
                    "dns lookup $name via $Server"
                } else {
                    "$DetailPrefix  $name via $Server"
                }
                $samples += (Measure-DnsQueryLatencyMs -Name $name -Server $Server -Detail $detail -TickRef $TickRef)
            } else {
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                Resolve-DnsName -Name $name -Server $Server -Type A -DnsOnly -ErrorAction Stop | Out-Null
                $sw.Stop()
                $samples += $sw.Elapsed.TotalMilliseconds
            }
        } catch {
            # Penalize failures heavily so unstable resolvers are never selected.
            $samples += 2500.0
        }
    }
    if ($samples.Count -eq 0) { return [double]::PositiveInfinity }
    return [math]::Round((($samples | Measure-Object -Average).Average), 2)
}

function Get-CurrentActiveDnsServers {
    $all = @()
    $activeAdapters = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq "Up" }
    foreach ($ifc in $activeAdapters) {
        try {
            $dnsInfo = Get-DnsClientServerAddress -InterfaceIndex $ifc.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop
            if ($null -ne $dnsInfo -and $dnsInfo.ServerAddresses) {
                foreach ($s in $dnsInfo.ServerAddresses) {
                    if (Test-IPv4String $s -and $all -notcontains $s) {
                        $all += $s
                    }
                }
            }
        } catch {}
    }
    return $all
}

function Resolve-DnsSelection {
    $presets = Get-DnsPresets
    $dnsMode = ("" + $Dns).Trim()

    if ($DnsServers -and $DnsServers.Count -gt 0) {
        $valid = @()
        foreach ($s in $DnsServers) {
            $v = $s.Trim()
            if (Test-IPv4String $v) { $valid += $v }
        }
        if ($valid.Count -eq 0) {
            throw "No valid IPv4 entries were provided in -DnsServers."
        }
        return @{ Label = "Custom"; Servers = $valid }
    }

    if ($dnsMode -ieq "Auto") {
        if (-not (Test-CanAnimate)) {
            Write-Host (Paint "Benchmarking DNS providers..." $S.Gray)
        }
        $candidateMap = @{}
        foreach ($k in $presets.Keys) {
            $candidateMap[$k] = $presets[$k]
        }
        $currentDns = Get-CurrentActiveDnsServers
        if ($currentDns.Count -gt 0) {
            $candidateMap["CurrentAdapterDNS"] = $currentDns
        }

        $rows = @()
        $orderedKeys = @($candidateMap.Keys | Sort-Object)
        $providerIndex = 0
        $spinnerTick = 0
        foreach ($k in $orderedKeys) {
            $providerIndex++
            $detailPrefix = ("dns benchmark [{0}/{1}] {2}" -f $providerIndex, $orderedKeys.Count, $k)
            if (Test-CanAnimate) {
                Update-SectionSpinner -Detail $detailPrefix -Tick $spinnerTick
                $spinnerTick++
            } elseif (-not $VerboseOutput) {
                Write-Host (Paint $detailPrefix $S.Gray)
            }
            $servers = $candidateMap[$k]
            $lat = @()
            foreach ($server in $servers) {
                $lat += (Measure-DnsServerLatencyMs -Server $server -DetailPrefix $detailPrefix -TickRef ([ref]$spinnerTick))
            }
            if ($lat.Count -eq 0) { continue }
            $score = [math]::Round((($lat | Measure-Object -Average).Average), 2)
            $rows += [PSCustomObject]@{
                Provider = $k
                PrimaryMs = $lat[0]
                SecondaryMs = $(if ($lat.Count -gt 1) { $lat[1] } else { $null })
                ScoreMs = $score
            }
        }
        if ($rows.Count -eq 0) {
            throw "DNS auto benchmark failed to score candidates. Check network connectivity or use -DnsServers."
        }
        $validRows = @($rows | Where-Object { $_.ScoreMs -lt 2500 })
        if ($validRows.Count -eq 0) {
            if ($candidateMap.ContainsKey("CurrentAdapterDNS")) {
                Write-Host (Paint "[WARN] DNS auto benchmark was inconclusive; keeping current adapter DNS." $S.Yellow)
                if ($VerboseOutput) {
                    Write-Host ""
                    Write-Host (Paint "[DNS BENCHMARK]" $S.NeonBlue)
                    ($rows | Sort-Object ScoreMs,Provider | Format-Table -AutoSize | Out-String) | Write-Host
                }
                return @{ Label = "CurrentAdapterDNS"; Servers = $candidateMap["CurrentAdapterDNS"] }
            }
            throw "DNS auto benchmark could not reach any candidate. Use -DnsServers or check outbound DNS/UDP filtering."
        }

        $best = $validRows | Sort-Object ScoreMs,Provider | Select-Object -First 1
        Write-Detail ("DNS Auto benchmark winner: " + $best.Provider + " (" + $best.ScoreMs + "ms)")
        if ($VerboseOutput) {
            Write-Host ""
            Write-Host (Paint "[DNS BENCHMARK]" $S.NeonBlue)
            ($rows | Sort-Object ScoreMs,Provider | Format-Table -AutoSize | Out-String) | Write-Host
        }
        return @{ Label = $best.Provider; Servers = $candidateMap[$best.Provider] }
    }

    foreach ($k in $presets.Keys) {
        if ($dnsMode -ieq $k) {
            return @{ Label = $k; Servers = $presets[$k] }
        }
    }

    # Support multi-provider or mixed list:
    # -Dns "Cloudflare,Google"
    # -Dns "Cloudflare,8.8.8.8,9.9.9.9"
    $tokens = $dnsMode -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    if ($tokens.Count -gt 0) {
        $servers = @()
        foreach ($t in $tokens) {
            $presetName = $null
            foreach ($k in $presets.Keys) {
                if ($t -ieq $k) {
                    $presetName = $k
                    break
                }
            }
            if ($presetName) {
                $servers += $presets[$presetName]
                continue
            }
            if (Test-IPv4String $t) {
                $servers += $t
                continue
            }
            throw "Unsupported DNS token '$t'. Use provider names (Cloudflare|Google|Quad9|OpenDNS|AdGuard|ControlD|DNSSB|Comodo) or IPv4 addresses."
        }
        $uniqueServers = @()
        foreach ($s in $servers) {
            if ($uniqueServers -notcontains $s) {
                $uniqueServers += $s
            }
        }
        if ($uniqueServers.Count -gt 0) {
            return @{ Label = "CustomMix"; Servers = $uniqueServers }
        }
    }

    throw "Unsupported -Dns value '$Dns'. Use Auto|Cloudflare|Google|Quad9|OpenDNS|AdGuard|ControlD|DNSSB|Comodo, or provide -DnsServers."
}

function Set-DnsOnActiveAdapters([string[]]$Servers, [string]$Label) {
    $activeAdapters = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq "Up" }
    foreach ($ifc in $activeAdapters) {
        try {
            Set-DnsClientServerAddress -InterfaceIndex $ifc.InterfaceIndex -ServerAddresses $Servers -ErrorAction Stop
            Write-Host ("DNS set " + $Label + ": " + $ifc.InterfaceAlias) -ForegroundColor Yellow
        } catch {
            Write-Host "DNS set failed: $($ifc.InterfaceAlias)" -ForegroundColor DarkYellow
        }
    }
    ipconfig /flushdns | Out-Null
    $script:DnsSelection = ($Label + " => " + ($Servers -join ", "))
    if (-not (Test-Path $script:StateRoot)) {
        New-Item -Path $script:StateRoot -Force | Out-Null
    }
    Set-ItemProperty -Path $script:StateRoot -Name DnsApplied -Type String -Value $script:DnsSelection
}

function Clear-PathPattern([string]$Pattern) {
    try {
        Remove-Item -Path $Pattern -Recurse -Force -ErrorAction SilentlyContinue
        Write-Detail ("Cleared cache pattern: " + $Pattern)
    } catch {}
}

function Clear-TempAndCache([string]$CurrentProfile) {
    $basePatterns = @(
        "$env:TEMP\*",
        "$env:LOCALAPPDATA\Temp\*",
        "C:\Windows\Temp\*",
        "$env:LOCALAPPDATA\D3DSCache\*",
        "$env:LOCALAPPDATA\NVIDIA\DXCache\*",
        "$env:LOCALAPPDATA\NVIDIA\GLCache\*",
        "$env:LOCALAPPDATA\AMD\DxCache\*",
        "$env:LOCALAPPDATA\AMD\GLCache\*",
        "$env:LOCALAPPDATA\AMD\DxcCache\*",
        "$env:LOCALAPPDATA\Microsoft\Windows\INetCache\*",
        "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\thumbcache_*.db",
        "$env:ProgramData\NVIDIA Corporation\NV_Cache\*"
    )

    $cacheTick = 0
    $baseCount = $basePatterns.Count
    foreach ($p in $basePatterns) {
        $cacheTick++
        if (Test-CanAnimate) {
            Update-SectionSpinner -Detail ("cleaning cache [{0}/{1}]" -f $cacheTick, $baseCount) -Tick $cacheTick
        }
        Clear-PathPattern $p
    }

    # Optional deeper cleanup for aggressive one-shot pass.
    if ($CurrentProfile -eq "Extreme") {
        $deepPatterns = @(
            "C:\ProgramData\Microsoft\Windows\WER\ReportQueue\*",
            "C:\ProgramData\Microsoft\Windows\WER\ReportArchive\*",
            "C:\Windows\SoftwareDistribution\Download\*",
            "C:\Windows\SoftwareDistribution\DeliveryOptimization\*"
        )
        $deepCount = $deepPatterns.Count
        $deepTick = 0
        foreach ($p in $deepPatterns) {
            $deepTick++
            if (Test-CanAnimate) {
                Update-SectionSpinner -Detail ("deep cleaning [{0}/{1}]" -f $deepTick, $deepCount) -Tick ($cacheTick + $deepTick)
            }
            Clear-PathPattern $p
        }

        # Winutil-aligned component cleanup; may take longer on first run.
        Write-Host (Paint "Running component cleanup (DISM). This can take several minutes..." $S.Yellow)
        Start-Process -FilePath cleanmgr.exe -ArgumentList "/d C: /VERYLOWDISK" -WindowStyle Hidden -ErrorAction SilentlyContinue
        $null = Invoke-ProcessWithSpinner -FilePath "dism.exe" -ArgumentList @("/online","/Cleanup-Image","/StartComponentCleanup") -Label "DISM component cleanup in progress..." -AccentColor $S.NeonYellow
    }
}

function Get-DirectorySizeBytes([string]$Path) {
    if (-not (Test-Path $Path)) { return 0 }
    $sum = 0
    try {
        $items = Get-ChildItem $Path -Force -Recurse -ErrorAction SilentlyContinue
        if ($null -ne $items) {
            $measure = $items | Measure-Object -Property Length -Sum
            if ($null -ne $measure -and $null -ne $measure.Sum) {
                $sum = [double]$measure.Sum
            }
        }
    } catch {}
    return $sum
}

function Get-ServiceStateRows([string[]]$Names) {
    $rows = @()
    foreach ($name in $Names) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($null -eq $svc) {
            $rows += [PSCustomObject]@{
                Name = $name
                Status = "Missing"
                StartType = "N/A"
            }
            continue
        }
        $cim = Get-CimInstance Win32_Service -Filter ("Name='" + $name + "'") -ErrorAction SilentlyContinue
        $startType = if ($null -ne $cim -and $cim.StartMode) { $cim.StartMode } else { "" + $svc.StartType }
        $rows += [PSCustomObject]@{
            Name = $name
            Status = "" + $svc.Status
            StartType = $startType
        }
    }
    return $rows
}

function Get-ActiveAdapterDnsStatus {
    $rows = @()
    $activeAdapters = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq "Up" }
    foreach ($ifc in $activeAdapters) {
        $dnsList = @()
        try {
            $dnsInfo = Get-DnsClientServerAddress -InterfaceIndex $ifc.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop
            if ($null -ne $dnsInfo -and $dnsInfo.ServerAddresses) {
                $dnsList = $dnsInfo.ServerAddresses
            }
        } catch {}
        $rows += [PSCustomObject]@{
            Adapter = $ifc.InterfaceAlias
            Dns     = if ($dnsList.Count -gt 0) { ($dnsList -join ", ") } else { "<auto/dhcp>" }
        }
    }
    return $rows
}

function Verify-Section([string]$Title) {
    $script:CheckNo++
    $id = "{0:d2}" -f $script:CheckNo
    if (-not $VerboseOutput) {
        Complete-SectionSpinner
        Clear-Host
        Show-Banner
    } elseif ($script:CheckNo -eq 1) {
        Write-Host ""
    }
    Show-SectionHeader -Kind "CHECK" -Id $id -Message $Title -AccentColor $S.NeonMint
}

function Invoke-InternalVerify {
    $script:CheckNo = 0

    Verify-Section "Power"
    $activeSchemeLine = (powercfg /GETACTIVESCHEME | Out-String).Trim()
    Write-Host $activeSchemeLine
    $activeGuid = ([regex]::Match($activeSchemeLine, "[0-9a-fA-F\-]{36}")).Value
    if ($activeGuid) {
        $pmin = Get-PowerCfgAcSettingIndex -PlanGuid $activeGuid -SubGroup "SUB_PROCESSOR" -Setting "PROCTHROTTLEMIN"
        $pmax = Get-PowerCfgAcSettingIndex -PlanGuid $activeGuid -SubGroup "SUB_PROCESSOR" -Setting "PROCTHROTTLEMAX"
        $idle = Get-PowerCfgAcSettingIndex -PlanGuid $activeGuid -SubGroup "SUB_PROCESSOR" -Setting "IDLEDISABLE"
        $boost = Get-PowerCfgAcSettingIndex -PlanGuid $activeGuid -SubGroup "SUB_PROCESSOR" -Setting "PERFBOOSTMODE"
        $epp = Get-PowerCfgAcSettingIndex -PlanGuid $activeGuid -SubGroup "SUB_PROCESSOR" -Setting "PERFEPP"
        Write-Host "AC MinProcessorState: $pmin%"
        Write-Host "AC MaxProcessorState: $pmax%"
        Write-Host "AC IdleDisable: $idle"
        Write-Host "AC PerfBoostMode: $boost"
        Write-Host "AC EPP: $epp"
    }
    $null = schtasks /Query /TN "\WinLagFix\ForcePowerOnLogon" 2>$null
    $logonTaskPresent = ($LASTEXITCODE -eq 0)
    $null = schtasks /Query /TN "\WinLagFix\ForcePowerOnStartup" 2>$null
    $startupTaskPresent = ($LASTEXITCODE -eq 0)
    $null = schtasks /Query /TN "\WinLagFix\ForcePowerEveryMinute" 2>$null
    $minuteTaskPresent = ($LASTEXITCODE -eq 0)
    Print-Result "LegacyForcePowerOnLogonTask" $(if ($logonTaskPresent) { "Present" } else { "Missing" }) $(if ($logonTaskPresent) { "WARN" } else { "OK" })
    Print-Result "LegacyForcePowerOnStartupTask" $(if ($startupTaskPresent) { "Present" } else { "Missing" }) $(if ($startupTaskPresent) { "WARN" } else { "OK" })
    Print-Result "LegacyForcePowerEveryMinuteTask" $(if ($minuteTaskPresent) { "Present" } else { "Missing" }) $(if ($minuteTaskPresent) { "WARN" } else { "OK" })

    Verify-Section "Hypervisor / VBS"
    $hyper = (Get-CimInstance Win32_ComputerSystem).HypervisorPresent
    $dg = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard
    Write-Host "HypervisorPresent: $hyper"
    Write-Host "VBS Status: $($dg.VirtualizationBasedSecurityStatus)"
    $optFeatures = Get-CimInstance Win32_OptionalFeature |
        Where-Object { $_.Name -in @("VirtualMachinePlatform","Microsoft-Windows-Subsystem-Linux","HypervisorPlatform","Microsoft-Hyper-V-All") } |
        Select-Object Name,InstallState
    if ($VerboseOutput) {
        $optFeatures | Format-Table -AutoSize
    } else {
        foreach ($f in $optFeatures) {
            Write-Host ("{0}: {1}" -f $f.Name, $f.InstallState)
        }
    }

    Verify-Section "Network / DNS"
    $statusRows = Get-ActiveAdapterDnsStatus
    $profileKey = Get-ItemProperty $script:StateRoot -ErrorAction SilentlyContinue
    $dnsMarker = if ($null -ne $profileKey -and $profileKey.PSObject.Properties.Name -contains "DnsApplied") { $profileKey.DnsApplied } else { "<not set>" }
    Write-Host "DnsApplied(marker): $dnsMarker"
    if ($VerboseOutput) {
        $statusRows | Format-Table -AutoSize
    } else {
        foreach ($row in $statusRows) {
            Write-Host ("{0}: {1}" -f $row.Adapter, $row.Dns)
        }
    }

    Verify-Section "Lag-prone Registry Values"
    $overlay = "<not set>"
    $dwmKey = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\Dwm" -ErrorAction SilentlyContinue
    if ($null -ne $dwmKey -and $dwmKey.PSObject.Properties.Name -contains "OverlayTestMode") {
        $overlay = $dwmKey.OverlayTestMode
    }
    $ipv6 = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters" -Name DisabledComponents -ErrorAction SilentlyContinue).DisabledComponents
    $kbd = Get-ItemProperty "HKCU:\Control Panel\Accessibility\Keyboard Response" -ErrorAction SilentlyContinue
    $kbd2 = Get-ItemProperty "HKCU:\Control Panel\Keyboard" -ErrorAction SilentlyContinue
    Write-Host "OverlayTestMode: $overlay"
    Write-Host "DisabledComponents: $ipv6"
    Write-Host "Keyboard Flags: $($kbd.Flags)"
    Write-Host "DelayBeforeAcceptance: $($kbd.DelayBeforeAcceptance)"
    Write-Host "KeyboardDelay: $($kbd2.KeyboardDelay)"
    Write-Host "KeyboardSpeed: $($kbd2.KeyboardSpeed)"

    Verify-Section "Profile Markers (Safe vs Extreme)"
    $adv = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -ErrorAction SilentlyContinue
    $vfxKey = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -ErrorAction SilentlyContinue
    $notifPol = Get-ItemProperty "HKCU:\Software\Policies\Microsoft\Windows\Explorer" -ErrorAction SilentlyContinue
    $toastKey = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications" -ErrorAction SilentlyContinue
    $desktopKey = Get-ItemProperty "HKCU:\Control Panel\Desktop" -ErrorAction SilentlyContinue
    $metricsKey = Get-ItemProperty "HKCU:\Control Panel\Desktop\WindowMetrics" -ErrorAction SilentlyContinue
    $dwmUXKey = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\DWM" -ErrorAction SilentlyContinue
    $serializeKey = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize" -ErrorAction SilentlyContinue
    $personalizeKey = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -ErrorAction SilentlyContinue
    $profileKey = Get-ItemProperty $script:StateRoot -ErrorAction SilentlyContinue

    $taskbarAnim = if ($null -ne $adv -and $adv.PSObject.Properties.Name -contains "TaskbarAnimations") { $adv.TaskbarAnimations } else { $null }
    $listviewAlpha = if ($null -ne $adv -and $adv.PSObject.Properties.Name -contains "ListviewAlphaSelect") { $adv.ListviewAlphaSelect } else { $null }
    $listviewShadow = if ($null -ne $adv -and $adv.PSObject.Properties.Name -contains "ListviewShadow") { $adv.ListviewShadow } else { $null }
    $taskbarMn = if ($null -ne $adv -and $adv.PSObject.Properties.Name -contains "TaskbarMn") { $adv.TaskbarMn } else { $null }
    $vfx = if ($null -ne $vfxKey -and $vfxKey.PSObject.Properties.Name -contains "VisualFXSetting") { $vfxKey.VisualFXSetting } else { $null }
    $notifCenter = if ($null -ne $notifPol -and $notifPol.PSObject.Properties.Name -contains "DisableNotificationCenter") { $notifPol.DisableNotificationCenter } else { $null }
    $toast = if ($null -ne $toastKey -and $toastKey.PSObject.Properties.Name -contains "ToastEnabled") { $toastKey.ToastEnabled } else { $null }
    $menuShowDelay = if ($null -ne $desktopKey -and $desktopKey.PSObject.Properties.Name -contains "MenuShowDelay") { $desktopKey.MenuShowDelay } else { $null }
    $minAnimate = if ($null -ne $metricsKey -and $metricsKey.PSObject.Properties.Name -contains "MinAnimate") { $metricsKey.MinAnimate } else { $null }
    $aeroPeek = if ($null -ne $dwmUXKey -and $dwmUXKey.PSObject.Properties.Name -contains "EnableAeroPeek") { $dwmUXKey.EnableAeroPeek } else { $null }
    $dwmAnimations = if ($null -ne $dwmUXKey -and $dwmUXKey.PSObject.Properties.Name -contains "Animations") { $dwmUXKey.Animations } else { $null }
    $cursorBlink = if ($null -ne $desktopKey -and $desktopKey.PSObject.Properties.Name -contains "CursorBlinkRate") { $desktopKey.CursorBlinkRate } else { $null }
    $startupDelay = if ($null -ne $serializeKey -and $serializeKey.PSObject.Properties.Name -contains "StartupDelayInMSec") { $serializeKey.StartupDelayInMSec } else { $null }
    $transparency = if ($null -ne $personalizeKey -and $personalizeKey.PSObject.Properties.Name -contains "EnableTransparency") { $personalizeKey.EnableTransparency } else { $null }
    $profileMarker = if ($null -ne $profileKey -and $profileKey.PSObject.Properties.Name -contains "Profile") { $profileKey.Profile } else { "<not set>" }
    $lastApplied = if ($null -ne $profileKey -and $profileKey.PSObject.Properties.Name -contains "LastAppliedAt") { $profileKey.LastAppliedAt } else { "<not set>" }

    Write-Host "TaskbarAnimations: $taskbarAnim"
    Write-Host "ListviewAlphaSelect: $listviewAlpha"
    Write-Host "ListviewShadow: $listviewShadow"
    Write-Host "TaskbarMn: $taskbarMn"
    Write-Host "VisualFXSetting: $vfx"
    Write-Host "DisableNotificationCenter: $notifCenter"
    Write-Host "ToastEnabled: $toast"
    Write-Host "EnableAeroPeek: $aeroPeek"
    Write-Host "DwmAnimations: $(if ($null -eq $dwmAnimations) { '<not set>' } else { $dwmAnimations })"
    Write-Host "CursorBlinkRate: $(if ($null -eq $cursorBlink) { '<not set>' } else { $cursorBlink })"
    Write-Host "StartupDelayInMSec: $(if ($null -eq $startupDelay) { '<not set>' } else { $startupDelay })"
    Write-Host "EnableTransparency: $(if ($null -eq $transparency) { '<not set>' } else { $transparency })"
    Write-Host "MenuShowDelay: $(if ($null -eq $menuShowDelay) { '<not set>' } else { $menuShowDelay })"
    Write-Host "MinAnimate: $(if ($null -eq $minAnimate) { '<not set>' } else { $minAnimate })"
    $autoEnd = if ($null -ne $desktopKey -and $desktopKey.PSObject.Properties.Name -contains "AutoEndTasks") { $desktopKey.AutoEndTasks } else { $null }
    $hungApp = if ($null -ne $desktopKey -and $desktopKey.PSObject.Properties.Name -contains "HungAppTimeout") { $desktopKey.HungAppTimeout } else { $null }
    $waitKill = if ($null -ne $desktopKey -and $desktopKey.PSObject.Properties.Name -contains "WaitToKillAppTimeout") { $desktopKey.WaitToKillAppTimeout } else { $null }
    $svcKill = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control" -Name WaitToKillServiceTimeout -ErrorAction SilentlyContinue).WaitToKillServiceTimeout
    Write-Host "AutoEndTasks: $(if ($null -eq $autoEnd) { '<not set>' } else { $autoEnd })"
    Write-Host "HungAppTimeout: $(if ($null -eq $hungApp) { '<not set>' } else { $hungApp })"
    Write-Host "WaitToKillAppTimeout: $(if ($null -eq $waitKill) { '<not set>' } else { $waitKill })"
    Write-Host "WaitToKillServiceTimeout: $(if ($null -eq $svcKill) { '<not set>' } else { $svcKill })"
    Write-Host "ProfileMarker: $profileMarker"
    Write-Host "LastAppliedAt: $lastApplied"
    if ($profileMarker -in @("Safe","Extreme")) {
        $hint = $profileMarker + " (marker)"
        $lvl = if ($profileMarker -eq "Extreme") { "WARN" } else { "OK" }
    } else {
        $looksExtreme = (
            $taskbarAnim -eq 0 -and
            $listviewAlpha -eq 0 -and
            $listviewShadow -eq 0 -and
            $taskbarMn -eq 0 -and
            $vfx -in @(2,3) -and
            $notifCenter -eq 1 -and
            $toast -eq 0 -and
            $aeroPeek -eq 0 -and
            $dwmAnimations -eq 0 -and
            $startupDelay -eq 0 -and
            $transparency -eq 0 -and
            $minAnimate -eq "0"
        )
        $hint = if ($looksExtreme) { "Extreme-like (heuristic)" } else { "Safe-like (heuristic)" }
        $lvl = if ($looksExtreme) { "WARN" } else { "OK" }
    }
    Print-Result "DetectedProfileHint" $hint $lvl

    Verify-Section "GPU / Game Tweaks"
    $hags = "<not set>"
    $gfx = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -ErrorAction SilentlyContinue
    if ($null -ne $gfx -and $gfx.PSObject.Properties.Name -contains "HwSchMode") {
        $hags = $gfx.HwSchMode
    }
    $gb = Get-ItemProperty "HKCU:\Software\Microsoft\GameBar" -ErrorAction SilentlyContinue
    $gcd = Get-ItemProperty "HKCU:\System\GameConfigStore" -ErrorAction SilentlyContinue
    $gdvr = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR" -ErrorAction SilentlyContinue
    $dotaPath = "C:\Program Files (x86)\Steam\steamapps\common\dota 2 beta\game\bin\win64\dota2.exe"
    $gpuPrefs = Get-ItemProperty "HKCU:\Software\Microsoft\DirectX\UserGpuPreferences" -ErrorAction SilentlyContinue
    Write-Host "HwSchMode(HAGS): $hags"
    Write-Host "AutoGameModeEnabled: $($gb.AutoGameModeEnabled)"
    Write-Host "GameBar GameDVR_Enabled: $($gb.GameDVR_Enabled)"
    Write-Host "GameDVR AppCaptureEnabled: $($gdvr.AppCaptureEnabled)"
    Write-Host "GameConfigStore GameDVR_Enabled: $($gcd.GameDVR_Enabled)"
    if ($null -ne $gpuPrefs -and $gpuPrefs.PSObject.Properties.Name -contains $dotaPath) {
        Write-Host "Dota GpuPreference: $($gpuPrefs.$dotaPath)"
    } else {
        Write-Host "Dota GpuPreference: <not set>"
    }

    Verify-Section "Latency Stack / Memory"
    $mmcss = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -ErrorAction SilentlyContinue
    $gamesTask = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" -ErrorAction SilentlyContinue
    $prioCtl = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl" -ErrorAction SilentlyContinue
    $mma = Get-MMAgent -ErrorAction SilentlyContinue
    Write-Host "SystemResponsiveness: $($mmcss.SystemResponsiveness)"
    Write-Host "NetworkThrottlingIndex: $($mmcss.NetworkThrottlingIndex)"
    Write-Host "Games GPU Priority: $($gamesTask.'GPU Priority')"
    Write-Host "Games Priority: $($gamesTask.Priority)"
    Write-Host "Games Scheduling Category: $($gamesTask.'Scheduling Category')"
    Write-Host "Win32PrioritySeparation: $($prioCtl.Win32PrioritySeparation)"
    if ($null -ne $mma) {
        Write-Host "MemoryCompression: $($mma.MemoryCompression)"
        Write-Host "PageCombining: $($mma.PageCombining)"
    } else {
        Write-Host "MemoryCompression: <unknown>"
        Write-Host "PageCombining: <unknown>"
    }
    if ($VerboseOutput) {
        Write-Host ""
        netsh int tcp show global
    } else {
        $tcpGlobal = (netsh int tcp show global | Out-String)
        $interesting = @(
            "Receive-Side Scaling State",
            "Receive Window Auto-Tuning Level",
            "Add-On Congestion Control Provider",
            "ECN Capability",
            "RFC 1323 Timestamps",
            "Receive Segment Coalescing State"
        )
        foreach ($line in ($tcpGlobal -split "`r?`n")) {
            foreach ($needle in $interesting) {
                if ($line -match [regex]::Escape($needle)) {
                    Write-Host $line.Trim()
                }
            }
        }
    }

    Verify-Section "HPET Device"
    $hpet = Get-PnpDevice -InstanceId "ACPI\PNP0103\0" -ErrorAction SilentlyContinue |
        Select-Object Class,FriendlyName,Status,Problem,InstanceId
    if ($VerboseOutput) {
        $hpet | Format-Table -AutoSize
    } else {
        if ($null -eq $hpet) {
            Write-Host "HPET: <not found>"
        } else {
            Write-Host ("HPET Status: {0} / Problem: {1}" -f $hpet.Status, $hpet.Problem)
        }
    }

    Verify-Section "Core Services"
    $coreServiceNames = @(
        "BITS","wuauserv","UsoSvc","WaaSMedicSvc","TrustedInstaller","Dnscache","DPS","EventLog",
        "SysMain","WSearch","DiagTrack","dmwappushservice","DoSvc","WerSvc",
        "TermService","NlaSvc","netprofm","Tailscale","sshd"
    )
    $coreServices = Get-ServiceStateRows -Names $coreServiceNames
    if ($VerboseOutput) {
        $coreServices | Format-Table -AutoSize
    } else {
        foreach ($svc in $coreServices) {
            Write-Host ("{0}: {1} / {2}" -f $svc.Name, $svc.Status, $svc.StartType)
        }
    }

    Verify-Section "Temp / Disk"
    $tempUser = Get-DirectorySizeBytes $env:TEMP
    $tempWin  = Get-DirectorySizeBytes "C:\Windows\Temp"
    Get-Volume -DriveLetter C | Select-Object DriveLetter,@{n="FreeGB";e={[math]::Round($_.SizeRemaining/1GB,1)}},@{n="TotalGB";e={[math]::Round($_.Size/1GB,1)}},HealthStatus | Format-Table -AutoSize
    Write-Host ("User Temp GB: " + [math]::Round($tempUser/1GB,3))
    Write-Host ("Windows Temp GB: " + [math]::Round($tempWin/1GB,3))

    Verify-Section "Performance Snapshot"
    Write-Host (Paint "Skipped by default. Use -v and run benchmark manually if needed." $S.Yellow)
    Complete-SectionSpinner
}

if ($Manual) {
    Show-Banner
    Show-Manual
    exit 0
}

if ($RazerStatus) {
    Show-Banner
    Show-RazerStatus
    exit 0
}

if ($Temp) {
    Show-Banner
    Show-ThermalReadout
    Write-Host ""
    Write-Host (Paint "   Tip: run -Boost for the safe max-perf posture + undervolt/overclock playbook." $S.Slate)
    exit 0
}

if ($Startup) {
    Show-Banner
    Show-StartupApps
    exit 0
}

Assert-Admin
$dnsServersText = ""
if ($DnsServers -and $DnsServers.Count -gt 0) {
    $dnsServersText = (($DnsServers | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() }) -join ",")
}
Write-Detail ("Selected mode: " + $script:RunProfile + ", Dns=" + $Dns + ", DnsServers=" + $dnsServersText + ", KeepWSL=" + $KeepWSL + ", SkipVerify=" + $SkipVerify + ", VerifyOnly=" + $VerifyOnly + ", NoRestore=" + $NoRestore + ", RemoteFix=" + $RemoteFix)

if ($Restore) {
    Step "Find latest ushie backup"
    $backupDir = Get-LatestUshieBackup
    if ([string]::IsNullOrWhiteSpace($backupDir)) {
        Print-Result "BackupFound" "None on Desktop (ushie_oneshot_backup_*)" "WARN"
    } else {
        Print-Result "BackupFolder" $backupDir "OK"
        Step "Restore registry from backup"
        $res = Restore-FromBackup -BackupDir $backupDir
        Print-Result "RegFilesImported" (("" + $res.Imported) + " / " + $res.Total) $(if ($res.Imported -gt 0) { "OK" } else { "WARN" })
    }

    Step "List System Restore points (deeper rollback)"
    $rps = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue | Sort-Object SequenceNumber -Descending | Select-Object -First 5)

    Complete-SectionSpinner
    if (-not $VerboseOutput) {
        Clear-Host
        Show-Banner
    }
    Write-Host ""
    if ($rps.Count -gt 0) {
        Write-Host (Paint "   System Restore points (newest first):" $S.NeonBlue)
        foreach ($rp in $rps) {
            Write-Host ("     #" + $rp.SequenceNumber + "  " + $rp.Description)
        }
        Write-Host (Paint "   For a full OS-level rollback, run:  rstrui.exe" $S.Slate)
    } else {
        Write-Host (Paint "   No System Restore points found (enable System Protection for deeper rollback)." $S.Gray)
    }
    Write-Host ""
    if ([string]::IsNullOrWhiteSpace($backupDir)) {
        Write-Host (Paint "   No ushie registry backup found to undo from. Use a System Restore point above if needed." $S.Yellow)
    } else {
        Write-Host (Paint "   Registry restored from latest backup (reverts changed values)." $S.Green)
        Write-Host (Paint "   For a COMPLETE undo (incl. newly-added keys), use a 'Before-Ushie' System Restore point above via rstrui.exe." $S.Slate)
    }
    exit 0
}

if ($Net) {
    Step "Backup registry (safety)"
    $catBackup = New-UshieBackup
    Write-Detail ("Backup folder: " + $catBackup)
    Step "Optimize network / connections / packets"
    Optimize-Network
    Write-Detail "Applied: NetworkThrottlingIndex max, SystemResponsiveness=10, TCP autotuning normal, RSS on, timestamps off, DNS flushed."
    Complete-StandaloneRun "Network optimized (focused). Some changes apply after reboot." $S.Green
    Write-Host (Paint ("   Undo anytime:  -Restore   (backup: " + $catBackup + ")") $S.Slate)
    exit 0
}

if ($Memory) {
    Step "Backup registry (safety)"
    $catBackup = New-UshieBackup
    Write-Detail ("Backup folder: " + $catBackup)
    Step "Optimize memory"
    Optimize-Memory
    Write-Detail "Applied: MMAgent memory compression/combining, ClearPageFileAtShutdown off, DisablePagingExecutive on (16GB RAM safe)."
    Complete-StandaloneRun "Memory optimized (focused)." $S.Green
    Write-Host (Paint ("   Undo anytime:  -Restore   (backup: " + $catBackup + ")") $S.Slate)
    exit 0
}

if ($Gpu) {
    Step "Backup registry (safety)"
    $catBackup = New-UshieBackup
    Write-Detail ("Backup folder: " + $catBackup)
    Step "Optimize GPU"
    Optimize-Gpu
    Write-Detail "Applied: Hardware-Accelerated GPU Scheduling (HAGS) on, GameDVR / Game Bar capture off. Reboot to apply HAGS."
    Complete-StandaloneRun "GPU optimized (focused). Reboot to apply HAGS." $S.Green
    Write-Host (Paint ("   Undo anytime:  -Restore   (backup: " + $catBackup + ")") $S.Slate)
    exit 0
}

if ($Storage) {
    Step "Backup registry (safety)"
    $catBackup = New-UshieBackup
    Write-Detail ("Backup folder: " + $catBackup)
    Step "Optimize storage + clear caches"
    Optimize-Storage
    Write-Detail "Applied: NTFS last-access off, 8dot3 off, temp/cache cleanup."
    Complete-StandaloneRun "Storage optimized + caches cleared (focused)." $S.Green
    Write-Host (Paint ("   Undo anytime:  -Restore   (backup: " + $catBackup + ")") $S.Slate)
    exit 0
}

if ($Cpu) {
    Step "Backup registry (safety)"
    $catBackup = New-UshieBackup
    Write-Detail ("Backup folder: " + $catBackup)
    Step "Optimize CPU responsiveness"
    Optimize-Cpu
    Write-Detail "Applied: CPU power throttling off, foreground priority boost (Win32PrioritySeparation=38), core unparking (100% min cores), SystemResponsiveness=10."
    Complete-StandaloneRun "CPU optimized (focused). Reboot recommended for full effect." $S.Green
    Write-Host (Paint ("   Undo anytime:  -Restore   (backup: " + $catBackup + ")") $S.Slate)
    exit 0
}

if ($Boost) {
    Step "Backup registry (safety)"
    $catBackup = New-UshieBackup
    Write-Detail ("Backup folder: " + $catBackup)
    Step "Apply safe max-performance posture (no hardware risk)"
    $boostPlan = Set-MaxPerformancePlan
    Optimize-Cpu
    Optimize-Latency
    Write-Detail ("Applied: max-performance power plan (" + $boostPlan + "), CPU power throttling off, core unparking, foreground priority boost, USB selective suspend off, PCIe ASPM off, Game Mode on.")
    Step "Thermal / performance readout"
    Show-ThermalReadout
    Complete-StandaloneRun "Safe performance boost applied. Undervolt/overclock is MANUAL - see playbook below." $S.Green
    Show-UndervoltPlaybook
    Write-Host ""
    Write-Host (Paint ("   Undo the safe tweaks anytime:  -Restore   (backup: " + $catBackup + ")") $S.Slate)
    exit 0
}

if ($RiskyBoost) {
    Step "Backup registry + System Restore point (safety)"
    $catBackup = New-UshieBackup
    Write-Detail ("Backup folder: " + $catBackup)
    Step "Disable VBS / Memory Integrity + latency tweaks (RISKY)"
    Disable-VBS
    Optimize-Latency
    Write-Detail "Disabled Virtualization-Based Security + HVCI Memory Integrity; applied USB/PCIe latency + Game Mode. Reboot required."
    Complete-StandaloneRun "RISKY BOOST applied: VBS / Memory Integrity OFF. Reboot to take effect." $S.Yellow
    Write-Host (Paint "   WARNING: this lowers a Windows security layer (Core Isolation). Only worth it for gaming FPS." $S.NeonPink)
    Write-Host (Paint "   Re-enable via Windows Security > Core Isolation, OR a 'Before-Ushie' System Restore point." $S.Slate)
    Write-Host (Paint ("   Undo (safe tweaks):  -Restore   (backup: " + $catBackup + ")") $S.Slate)
    exit 0
}

if ($Services) {
    Step "Backup registry + System Restore point (safety)"
    $catBackup = New-UshieBackup
    Write-Detail ("Backup folder: " + $catBackup)
    Step "Debloat non-essential Windows services (conservative, RDP-safe)"
    Optimize-Services
    Write-Detail "Disabled: DiagTrack, dmwappushservice, RetailDemo, RemoteRegistry. Set to Manual: MapsBroker, Fax, WMPNetworkSvc, WerSvc, lfsvc, PcaSvc, DusmSvc. Network/RDP/audio/search/security/input services left untouched."
    Complete-StandaloneRun "Services debloated (conservative + reversible). Reboot to fully apply." $S.Green
    Write-Host (Paint "   Undo: a 'Before-Ushie' System Restore point (restores service start types), or re-enable in services.msc." $S.Slate)
    exit 0
}

if ($RemoteFix) {
    Step "Repair remote access stack (RDP/Tailscale/SSH)"
    Repair-RemoteAccessStack
    Write-Detail "Re-enabled RDP, firewall, core remote-access services, and Tailscale/sshd auto-start if installed."

    Step "Verify remote access"
    $remoteSnapshot = Get-RemoteAccessSnapshot
    Show-RemoteAccessSnapshot -Snapshot $remoteSnapshot

    Complete-SectionSpinner
    if (-not $VerboseOutput) {
        Clear-Host
        Show-Banner
    }
    Write-Host ""
    if ($remoteSnapshot.Port3389) {
        Write-Host (Paint "   Remote access repaired. RDP should work now." $S.Green)
    } else {
        Write-Host (Paint "   Remote access repair applied, but RDP is still not listening." $S.Yellow)
    }
    if (-not [string]::IsNullOrWhiteSpace($remoteSnapshot.TailscaleIp)) {
        Write-Host ((Paint "   Tailscale IP: " $S.Cyan) + $remoteSnapshot.TailscaleIp)
    }
    exit 0
}

if ($FixRazer) {
    Step "Inspect Razer Synapse processes"
    $beforeRazer = Get-RazerSnapshot
    Show-RazerSnapshot -Snapshot $beforeRazer

    Step "Repair Razer Synapse (clear runaway processes, relaunch clean)"
    $relaunched = Repair-RazerSynapse
    Write-Detail "Stopped duplicate RazerAppEngine/RzEngineMon front-end processes; left Game Manager + Elevation services running so macros are preserved; relaunched a single clean Synapse instance."

    Step "Verify Razer Synapse"
    Start-Sleep -Seconds 3
    $afterRazer = Get-RazerSnapshot
    Show-RazerSnapshot -Snapshot $afterRazer

    Complete-SectionSpinner
    if (-not $VerboseOutput) {
        Clear-Host
        Show-Banner
    }
    Write-Host ""
    Write-Host ((Paint "   RazerAppEngine processes: " $S.Cyan) + $beforeRazer.EngineCount + (Paint " -> " $S.Gray) + $afterRazer.EngineCount)
    Write-Host ((Paint "   Synapse memory (MB):      " $S.Cyan) + $beforeRazer.EngineMemMB + (Paint " -> " $S.Gray) + $afterRazer.EngineMemMB)
    if ($relaunched) {
        Write-Host (Paint "   Razer Synapse relaunched clean. Your macros and lighting stay intact." $S.Green)
    } else {
        Write-Host (Paint "   Cleared runaway processes, but could not auto-relaunch Synapse. Open Razer Synapse from the Start menu." $S.Yellow)
    }
    exit 0
}

if ($RazerGaming) {
    Step "Inspect Razer Synapse (before gaming mode)"
    $beforeRazer = Get-RazerSnapshot
    Show-RazerSnapshot -Snapshot $beforeRazer

    Step "Apply Razer GAMING mode (lighting off + blocked, macros kept)"
    $relaunched = Set-RazerGamingMode
    Write-Detail "Disabled + stopped Razer Chroma lighting services so they cannot consume CPU/RAM or respawn; set autostart to synapse-only; killed lighting + front-end processes; kept Game Manager + Elevation running for macros; relaunched a minimal Synapse."

    Step "Verify Razer (gaming mode)"
    Start-Sleep -Seconds 3
    $afterRazer = Get-RazerSnapshot
    Show-RazerSnapshot -Snapshot $afterRazer

    Complete-SectionSpinner
    if (-not $VerboseOutput) {
        Clear-Host
        Show-Banner
    }
    Write-Host ""
    Write-Host ((Paint "   RazerAppEngine processes: " $S.Cyan) + $beforeRazer.EngineCount + (Paint " -> " $S.Gray) + $afterRazer.EngineCount)
    Write-Host ((Paint "   Synapse memory (MB):      " $S.Cyan) + $beforeRazer.EngineMemMB + (Paint " -> " $S.Gray) + $afterRazer.EngineMemMB)
    Write-Host (Paint "   GAMING mode ON: lighting off + blocked (no CPU/RAM/disk use), macros still working." $S.Green)
    Write-Host (Paint "   Run  -RazerOn  to bring lighting back." $S.Slate)
    exit 0
}

if ($RazerOn) {
    Step "Restore Razer Synapse (full: lighting + macros)"
    $relaunched = Set-RazerFullMode
    Write-Detail "Re-enabled + started Razer Chroma lighting services; restored full autostart (synapse + chroma); relaunched full Synapse so lighting and macros both work."

    Step "Verify Razer (full mode)"
    Start-Sleep -Seconds 3
    $afterRazer = Get-RazerSnapshot
    Show-RazerSnapshot -Snapshot $afterRazer

    Complete-SectionSpinner
    if (-not $VerboseOutput) {
        Clear-Host
        Show-Banner
    }
    Write-Host ""
    if ($relaunched) {
        Write-Host (Paint "   Razer fully restored: lighting + macros are back." $S.Green)
    } else {
        Write-Host (Paint "   Re-enabled Razer services, but could not auto-relaunch Synapse. Open it from the Start menu." $S.Yellow)
    }
    exit 0
}

if ($VerifyOnly) {
    Step "Verify only"
    Invoke-InternalVerify
    exit 0
}

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backupDir = Join-Path $env:USERPROFILE "Desktop\ushie_oneshot_backup_$stamp"
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

if ($script:RunProfile -eq "Extreme") {
    Step "Create system restore point (Extreme safety)"
    if ($NoRestore) {
        Print-Result "RestorePointCreated" "Skipped by -NoRestore" "WARN"
    } else {
        Ensure-ExtremeRestorePoint
    }
}

Step "Backup registry snapshots"
Backup-Registry -BackupDir $backupDir
Write-Detail ("Backup folder ready: " + $backupDir)
Write-Detail "Exported rollback snapshots for DWM, IPv6/TCPIP, desktop, explorer, keyboard, notifications, and search keys."

Step "Clean old persistent legacy tasks (one-shot mode)"
Remove-LegacyWinLagTasks
Write-Detail "Removed old WinLagFix scheduled tasks and legacy helper script if they existed."

Step "Apply lag / debloat registry baseline"
cmd /c "reg delete \"HKLM\SOFTWARE\Microsoft\Windows\Dwm\" /v OverlayTestMode /f >nul 2>&1" | Out-Null
reg add "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters" /v DisabledComponents /t REG_DWORD /d 0 /f | Out-Null
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching" /v SearchOrderConfig /t REG_DWORD /d 1 /f | Out-Null
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Installer" /v DisableCoInstallers /t REG_DWORD /d 0 /f | Out-Null

reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" /v EnableActivityFeed /t REG_DWORD /d 0 /f | Out-Null
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" /v PublishUserActivities /t REG_DWORD /d 0 /f | Out-Null
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" /v UploadUserActivities /t REG_DWORD /d 0 /f | Out-Null
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" /v TurnOffWindowsCopilot /t REG_DWORD /d 1 /f | Out-Null
reg add "HKCU\Software\Policies\Microsoft\Windows\WindowsCopilot" /v TurnOffWindowsCopilot /t REG_DWORD /d 1 /f | Out-Null
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v ShowCopilotButton /t REG_DWORD /d 0 /f | Out-Null
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications" /v GlobalUserDisabled /t REG_DWORD /d 1 /f | Out-Null
reg add "HKCU\System\GameConfigStore" /v GameDVR_DXGIHonorFSEWindowsCompatible /t REG_DWORD /d 1 /f | Out-Null
reg add "HKLM\System\CurrentControlSet\Control\Session Manager\Power" /v HibernateEnabled /t REG_DWORD /d 0 /f | Out-Null
# Prevent Windows from silently auto-installing Store games / sponsored apps.
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent" /v DisableWindowsConsumerFeatures /t REG_DWORD /d 1 /f | Out-Null
Write-Detail "Applied baseline debloat: activity feed off, Copilot off, background apps off, hibernate off, sponsored Store installs off."

Step "Shell responsiveness baseline (both profiles)"
# Instant menus + explorer startup - applies to Safe and Extreme.
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize" /v StartupDelayInMSec /t REG_DWORD /d 0 /f | Out-Null
# App hang / kill timeouts - huge impact on how responsive the desktop feels.
# Default HungAppTimeout=5000, WaitToKillAppTimeout=20000. These are way too long.
reg add "HKCU\Control Panel\Desktop" /v AutoEndTasks /t REG_SZ /d 1 /f | Out-Null
reg add "HKCU\Control Panel\Desktop" /v HungAppTimeout /t REG_SZ /d 2000 /f | Out-Null
reg add "HKCU\Control Panel\Desktop" /v WaitToKillAppTimeout /t REG_SZ /d 5000 /f | Out-Null
reg add "HKLM\SYSTEM\CurrentControlSet\Control" /v WaitToKillServiceTimeout /t REG_SZ /d 3000 /f | Out-Null
# NTFS: stop writing last-access timestamps on every file read (big SSD write reduction).
fsutil behavior set disablelastaccess 1 | Out-Null
# NTFS: disable legacy 8.3 filename generation (less work on every file create/delete).
fsutil behavior set disable8dot3 1 | Out-Null
Write-Detail "Applied shell responsiveness baseline: instant Explorer startup, faster hung-app timeout, faster shutdown kill timeouts, reduced NTFS metadata overhead."

if ($script:RunProfile -eq "Extreme") {
    Step "Apply EXTREME visual + shell performance tweaks"
    Apply-ExtremeProfile
    Write-Detail "Applied EXTREME visual profile: animations off, transparency off, taskbar effects off, mouse acceleration off, cursor blink off."
    Step "Apply EXTREME system-wide responsiveness tweaks"
    Apply-ExtremeSystemWide
    Write-Detail "Applied EXTREME system-wide shell trim: desktop preview off and extra shell overhead disabled."
    Step "Apply EXTREME latency stack (CPU/GPU/Network)"
    Apply-ExtremeLatencyStack
    Write-Detail "Applied EXTREME latency stack: MMCSS game priorities, Win32 scheduler bias, no Nagle delay, lower-latency TCP globals, BCD timer policy."
    Step "Apply EXTREME telemetry and debloat"
    Apply-ExtremeTelemetry
    Write-Detail "Applied EXTREME telemetry trim: CEIP tasks off, advertising/privacy tracking off, IPv4 preference, Delivery Optimization local-only."
} else {
    Step "Apply SAFE visual + shell defaults"
    Apply-SafeProfile
    Write-Detail "Applied SAFE visual profile: Windows animations off, taskbar effects off, transparency off, ClearType retained, default mouse feel preserved."
}

# ClearType always on regardless of profile.
reg add "HKCU\Control Panel\Desktop" /v FontSmoothing /t REG_SZ /d 2 /f | Out-Null
reg add "HKCU\Control Panel\Desktop" /v FontSmoothingType /t REG_DWORD /d 2 /f | Out-Null
reg add "HKCU\Control Panel\Desktop" /v FontSmoothingGamma /t REG_DWORD /d 1000 /f | Out-Null
Write-Detail "Locked ClearType on so fonts stay readable after visual effects changes."

Step "Tune memory policy"
Apply-MemoryPolicy -CurrentProfile $script:RunProfile
if ($script:RunProfile -eq "Extreme") {
    Write-Detail "Memory policy set for low-latency gaming: Memory Compression and Page Combining disabled."
} else {
    Write-Detail "Memory policy set for daily-use stability: Memory Compression and Page Combining enabled."
}

Step "Write profile marker"
Set-ProfileMarker
Write-Detail ("Profile marker written to " + $script:StateRoot)

Step "GPU / Dota gaming optimization"
if ($script:RunProfile -eq "Extreme") {
    reg add "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" /v HwSchMode /t REG_DWORD /d 2 /f | Out-Null
    Write-Detail "Extreme GPU path enabled: HAGS requested (restart-class) plus high-performance game preference markers."
} else {
    Write-Detail "Safe mode skips HAGS because it is a restart-class change."
}
reg add "HKCU\Software\Microsoft\GameBar" /v AutoGameModeEnabled /t REG_DWORD /d 1 /f | Out-Null
reg add "HKCU\Software\Microsoft\GameBar" /v GameDVR_Enabled /t REG_DWORD /d 0 /f | Out-Null
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR" /v AppCaptureEnabled /t REG_DWORD /d 0 /f | Out-Null
reg add "HKCU\System\GameConfigStore" /v GameDVR_Enabled /t REG_DWORD /d 0 /f | Out-Null
reg add "HKCU\System\GameConfigStore" /v GameDVR_FSEBehavior /t REG_DWORD /d 2 /f | Out-Null
reg add "HKCU\System\GameConfigStore" /v GameDVR_HonorUserFSEBehaviorMode /t REG_DWORD /d 1 /f | Out-Null
$dotaPath = "C:\Program Files (x86)\Steam\steamapps\common\dota 2 beta\game\bin\win64\dota2.exe"
if (Test-Path $dotaPath) {
    reg add "HKCU\Software\Microsoft\DirectX\UserGpuPreferences" /v "$dotaPath" /t REG_SZ /d "GpuPreference=2;" /f | Out-Null
    Write-Detail ("Pinned Dota GPU preference to high performance: " + $dotaPath)
} else {
    Write-Detail "Dota executable was not found, so per-app GPU preference was skipped."
}

Step "Restore keyboard responsiveness"
reg add "HKCU\Control Panel\Accessibility\Keyboard Response" /v Flags /t REG_SZ /d 0 /f | Out-Null
reg add "HKCU\Control Panel\Accessibility\Keyboard Response" /v DelayBeforeAcceptance /t REG_SZ /d 0 /f | Out-Null
reg add "HKCU\Control Panel\Accessibility\Keyboard Response" /v AutoRepeatDelay /t REG_SZ /d 500 /f | Out-Null
reg add "HKCU\Control Panel\Accessibility\Keyboard Response" /v AutoRepeatRate /t REG_SZ /d 31 /f | Out-Null
reg add "HKCU\Control Panel\Accessibility\Keyboard Response" /v BounceTime /t REG_SZ /d 0 /f | Out-Null
reg add "HKCU\Control Panel\Keyboard" /v KeyboardDelay /t REG_SZ /d 0 /f | Out-Null
reg add "HKCU\Control Panel\Keyboard" /v KeyboardSpeed /t REG_SZ /d 31 /f | Out-Null
rundll32.exe user32.dll,UpdatePerUserSystemParameters
Write-Detail "Restored low-latency keyboard settings: no filter-key delay, fastest repeat rate, zero keyboard delay."

Step "Set DNS + clean temp/cache"
try {
    $dnsTarget = Resolve-DnsSelection
    Set-DnsOnActiveAdapters -Servers $dnsTarget.Servers -Label $dnsTarget.Label
} catch {
    Print-Result "DNSSelection" ("Failed: " + $_.Exception.Message) "WARN"
}
Clear-TempAndCache -CurrentProfile $script:RunProfile

Step "Restore core services needed for stable system"
sc.exe config BITS start= delayed-auto | Out-Null
sc.exe config wuauserv start= demand | Out-Null
sc.exe config UsoSvc start= demand | Out-Null
sc.exe config WaaSMedicSvc start= demand | Out-Null
sc.exe config TrustedInstaller start= demand | Out-Null
Start-Service BITS -ErrorAction SilentlyContinue
Write-Detail "Restored core servicing stack defaults for BITS, Windows Update, Update Orchestrator, Medic Service, and TrustedInstaller."

Step "Set selected debloat service startup defaults"
sc.exe config RemoteRegistry start= disabled | Out-Null
sc.exe config ssh-agent start= disabled | Out-Null
sc.exe config tzautoupdate start= disabled | Out-Null
sc.exe config shpamsvc start= disabled | Out-Null
if ($script:RunProfile -eq "Extreme") {
    sc.exe config SysMain start= disabled | Out-Null
    sc.exe config WSearch start= demand | Out-Null
    sc.exe config DiagTrack start= disabled | Out-Null
    sc.exe config dmwappushservice start= disabled | Out-Null
    sc.exe config DoSvc start= disabled | Out-Null
    sc.exe config WerSvc start= disabled | Out-Null
    # Additional bloat services not needed on a gaming/performance PC.
    sc.exe config MapsBroker start= disabled | Out-Null
    sc.exe config WMPNetworkSvc start= disabled | Out-Null
    sc.exe config RetailDemo start= disabled | Out-Null
    sc.exe config PhoneSvc start= disabled | Out-Null
    Stop-Service SysMain -Force -ErrorAction SilentlyContinue
    Stop-Service DiagTrack -Force -ErrorAction SilentlyContinue
    Stop-Service dmwappushservice -Force -ErrorAction SilentlyContinue
    Stop-Service DoSvc -Force -ErrorAction SilentlyContinue
    Stop-Service WerSvc -Force -ErrorAction SilentlyContinue
    Stop-Service MapsBroker -Force -ErrorAction SilentlyContinue
    Stop-Service WMPNetworkSvc -Force -ErrorAction SilentlyContinue
    Stop-Service RetailDemo -Force -ErrorAction SilentlyContinue
    Stop-Service PhoneSvc -Force -ErrorAction SilentlyContinue
} else {
    sc.exe config SysMain start= auto | Out-Null
    sc.exe config WSearch start= delayed-auto | Out-Null
    sc.exe config DoSvc start= demand | Out-Null
    sc.exe config WerSvc start= demand | Out-Null
    sc.exe config MapsBroker start= delayed-auto | Out-Null
    sc.exe config WMPNetworkSvc start= demand | Out-Null
    sc.exe config RetailDemo start= demand | Out-Null
    sc.exe config PhoneSvc start= demand | Out-Null
}
sc.exe config XblAuthManager start= demand | Out-Null
sc.exe config XblGameSave start= demand | Out-Null
sc.exe config XboxNetApiSvc start= demand | Out-Null
sc.exe config XboxGipSvc start= demand | Out-Null
if ($script:RunProfile -eq "Extreme") {
    Write-Detail "Extreme service policy applied: SysMain, telemetry, Delivery Optimization, WER, Maps, WMP sharing, RetailDemo, and Phone services disabled."
} else {
    Write-Detail "Safe service policy applied: SysMain/Search restored, optional services left on-demand, and background bloat kept restrained."
}

Step "Restore remote access stack (Tailscale/RDP/SSH)"
Repair-RemoteAccessStack
Write-Detail "Restored remote access stack: RDP allowed, firewall rule enabled, network-awareness services running, and Tailscale/sshd auto-start if installed."

if ($script:RunProfile -eq "Extreme") {
    Step "Enable HPET"
    pnputil /enable-device "ACPI\PNP0103\0" | Out-Null
    Write-Detail "Requested HPET device enable for the Extreme profile."

    Step "Disable hypervisor/VBS for low-latency"
    Invoke-BcdSet "hypervisorlaunchtype" "off"
    reg add "HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard" /v EnableVirtualizationBasedSecurity /t REG_DWORD /d 0 /f | Out-Null
    reg add "HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" /v Enabled /t REG_DWORD /d 0 /f | Out-Null
    reg add "HKLM\SYSTEM\CurrentControlSet\Control\Lsa" /v LsaCfgFlags /t REG_DWORD /d 0 /f | Out-Null
    Write-Detail "Requested Extreme boot-level latency changes: hypervisor off, VBS off, HVCI off, LSA protection off."

    if (-not $KeepWSL) {
        Step "Disable WSL / VirtualMachinePlatform"
        dism /online /disable-feature /featurename:VirtualMachinePlatform /norestart | Out-Null
        dism /online /disable-feature /featurename:Microsoft-Windows-Subsystem-Linux /norestart | Out-Null
        Write-Detail "Requested WSL and VirtualMachinePlatform disable for the Extreme profile."
    }
} else {
    Write-Detail "Safe mode skips HPET, HAGS, hypervisor/VBS, and WSL changes so it stays no-restart."
}

Step "Set max performance power policy (one-time)"
$planGuid = Set-MaxPerformancePlan
if ($script:RunProfile -eq "Extreme") {
    Apply-ExtremeCpuPowerPolicy -PlanGuid $planGuid
    Write-Detail "Applied Extreme CPU power policy on top of Ultimate Performance: idle disable, aggressive boost, and zero EPP."
} else {
    Write-Detail "Activated Ultimate Performance and locked processor min/max to 100%."
}
$activeSchemeLine = (powercfg /GETACTIVESCHEME | Out-String).Trim()
Write-Host $activeSchemeLine

if ($script:RunProfile -eq "Extreme") {
    Step "Apply extra CPU responsiveness tweaks"
    Optimize-Cpu
    Optimize-Latency
    Write-Detail "Applied: CPU power throttling off, foreground priority boost (Win32PrioritySeparation=38), core unparking (100% min cores), USB selective suspend off, PCIe ASPM off, Game Mode on."
    Step "Debloat non-essential services (conservative, RDP-safe)"
    Optimize-Services
    Write-Detail "Disabled telemetry/remote services; set unused ones to Manual. Network/RDP/audio/search/security untouched."
}

if ($script:RunProfile -eq "Extreme") {
    $razerPresent = ($null -ne (Get-Service -Name 'Razer Game Manager Service 3' -ErrorAction SilentlyContinue)) -or (@(Get-Process -Name RazerAppEngine -ErrorAction SilentlyContinue).Count -gt 0)
    if ($razerPresent) {
        Step "Clean up runaway Razer Synapse (clear duplicates, keep macros + lighting)"
        $rzBefore = Get-RazerSnapshot
        $null = Repair-RazerSynapse
        Start-Sleep -Seconds 2
        $rzAfter = Get-RazerSnapshot
        Write-Detail ("Cleared duplicate RazerAppEngine hosts and relaunched one clean Synapse. Game Manager + Elevation (macros) and lighting left intact. Engine processes " + $rzBefore.EngineCount + " -> " + $rzAfter.EngineCount + ", memory " + $rzBefore.EngineMemMB + " -> " + $rzAfter.EngineMemMB + " MB.")
    }
}

Step "Final snapshot"
$overlay = "<not set>"
$dwmKey = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\Dwm" -ErrorAction SilentlyContinue
if ($null -ne $dwmKey -and $dwmKey.PSObject.Properties.Name -contains "OverlayTestMode") {
    $overlay = $dwmKey.OverlayTestMode
}
$ipv6 = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters" -Name DisabledComponents -ErrorAction SilentlyContinue).DisabledComponents
$hyper = (Get-CimInstance Win32_ComputerSystem).HypervisorPresent
Print-Result "OverlayTestMode" $overlay "OK"
Print-Result "DisabledComponents" $ipv6 "OK"
Print-Result "HypervisorPresent" $hyper "OK"
Print-Result "PlanGuidApplied" $planGuid "OK"
Print-Result "ProfileApplied" $script:RunProfile "OK"
$dnsLevel = if ($script:DnsSelection -eq "<not set>") { "WARN" } else { "OK" }
Print-Result "DNSApplied" $script:DnsSelection $dnsLevel
$hags = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name HwSchMode -ErrorAction SilentlyContinue).HwSchMode
if ($script:RunProfile -eq "Safe" -and $null -eq $hags) {
    Print-Result "HwSchMode(HAGS)" "Skipped in Safe (no-restart profile)" "OK"
} else {
    Print-Result "HwSchMode(HAGS)" $hags "OK"
}
$mmcss = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -ErrorAction SilentlyContinue
Print-Result "NetworkThrottlingIndex" $mmcss.NetworkThrottlingIndex "OK"
$mma = Get-MMAgent -ErrorAction SilentlyContinue
if ($null -ne $mma) {
    Print-Result "MemoryCompression" $mma.MemoryCompression "OK"
}

if (-not $SkipVerify) {
    Step "Auto verify (same run)"
    Invoke-InternalVerify
}

Complete-SectionSpinner
if (-not $VerboseOutput) {
    Clear-Host
    Show-Banner
}
Write-Host ""
Write-Host ((Paint "   Backup path: " $S.Cyan) + $backupDir)
if ($script:RunProfile -eq "Extreme") {
    Write-Host (Paint "   Extreme applied. Restart to lock in boot-level tweaks." $S.Yellow)
    Prompt-RestartNow
} else {
    Write-Host (Paint "   Safe applied live. No restart required." $S.Green)
}

