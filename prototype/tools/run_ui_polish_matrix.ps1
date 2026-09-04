param(
    [string]$Godot = 'C:/Misc/Kitbash_Command/Godot_v4.7.1-stable_win64_console.exe',
    [switch]$Capture,
    [string]$OutputDirectory = '',
    [int]$TimeoutSeconds = 120
)
$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
if (!$OutputDirectory) { $OutputDirectory = Join-Path (Split-Path $project -Parent) 'playtest/task7' }
$output = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $output | Out-Null
$runs = @()
$failed = $false
foreach ($screen in @('menu', 'lab', 'setup')) {
    $modes = if ($Capture) { @('capture', 'headless') } else { @('headless') }
    foreach ($mode in $modes) {
        $destination = Join-Path $output $mode
        New-Item -ItemType Directory -Force -Path $destination | Out-Null
        $stdout = Join-Path $destination "$screen.stdout.log"
        $stderr = Join-Path $destination "$screen.stderr.log"
        $arguments = @('--path', "`"$project`"", '--script', 'res://tests/test_ui_polish_matrix.gd')
        if ($mode -eq 'headless') { $arguments += '--headless' }
        $arguments += @('--', '--screen', $screen, '--output-dir', "`"$destination`"")
        $process = Start-Process -FilePath $Godot -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        $timedOut = !$process.WaitForExit($TimeoutSeconds * 1000)
        if ($timedOut) { Stop-Process -Id $process.Id; $process.WaitForExit() }
        $process.Refresh()
        $code = $process.ExitCode
        $runs += @{ screen = $screen; mode = $mode; exit = $code; timeout = $timedOut; stdout = $stdout; stderr = $stderr }
        $runs | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $output 'runs.json')
        Write-Output "$screen/$mode exit=$code timeout=$timedOut"
        Get-Content -LiteralPath $stdout | Select-String '\[FAIL\]|\[ui-polish\]'
        if ($mode -eq 'headless' -and ($code -ne 0 -or $timedOut)) { $failed = $true }
    }
}
if ($failed) { exit 1 }
exit 0
