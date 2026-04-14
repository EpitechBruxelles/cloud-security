[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$RemoveLockFile,
    [switch]$RemoveStateFiles,
    [switch]$StopTerraformProcesses,
    [int]$RetryCount = 3,
    [int]$RetryDelayMs = 400
)

$ErrorActionPreference = 'Stop'

function Stop-TerraformRelatedProcesses {
    $patterns = @('terraform', 'terraform-provider-')
    $stopped = @()

    foreach ($proc in Get-Process -ErrorAction SilentlyContinue) {
        $name = [string]$proc.ProcessName
        $path = ''

        try {
            $path = [string]$proc.Path
        }
        catch {
            $path = ''
        }

        $matches = $false
        foreach ($pattern in $patterns) {
            if ($name -like "*$pattern*" -or $path -like "*$pattern*") {
                $matches = $true
                break
            }
        }

        if ($matches) {
            try {
                Stop-Process -Id $proc.Id -Force -ErrorAction Stop
                $stopped += "$name($($proc.Id))"
            }
            catch {
                Write-Warning "Impossible d'arreter le processus $name($($proc.Id)): $($_.Exception.Message)"
            }
        }
    }

    if ($stopped.Count -gt 0) {
        Write-Host "Processus arretes: $($stopped -join ', ')"
    }
    else {
        Write-Host 'Aucun processus Terraform/provider en cours detecte.'
    }
}

function Remove-TargetWithRetry {
    param(
        [Parameter(Mandatory = $true)]$Target,
        [Parameter(Mandatory = $true)][bool]$IsDirectory,
        [Parameter(Mandatory = $true)][int]$Attempts,
        [Parameter(Mandatory = $true)][int]$DelayMs
    )

    $lastError = $null

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            if ($IsDirectory) {
                Remove-Item -LiteralPath $Target.FullName -Recurse -Force -ErrorAction Stop
            }
            else {
                Remove-Item -LiteralPath $Target.FullName -Force -ErrorAction Stop
            }
            return $true
        }
        catch {
            $lastError = $_

            # Some provider binaries are read-only/locked; clear attributes before retry.
            try {
                if ($IsDirectory -and (Test-Path -LiteralPath $Target.FullName)) {
                    Get-ChildItem -LiteralPath $Target.FullName -Recurse -Force -File -ErrorAction SilentlyContinue |
                        ForEach-Object { $_.Attributes = 'Normal' }
                }
                elseif (Test-Path -LiteralPath $Target.FullName) {
                    $item = Get-Item -LiteralPath $Target.FullName -Force -ErrorAction SilentlyContinue
                    if ($item) {
                        $item.Attributes = 'Normal'
                    }
                }
            }
            catch {
                # Keep original deletion error as main signal.
            }

            if ($attempt -lt $Attempts) {
                Start-Sleep -Milliseconds $DelayMs
            }
        }
    }

    throw $lastError
}

$root = Split-Path -Parent $PSScriptRoot
$targets = @()

Write-Host "Terraform clean-up root: $root"

$targets += Get-ChildItem -Path $root -Recurse -Force -Directory -Filter '.terraform' -ErrorAction SilentlyContinue
$targets += Get-ChildItem -Path $root -Recurse -Force -File -Filter 'tfplan' -ErrorAction SilentlyContinue
$targets += Get-ChildItem -Path $root -Recurse -Force -File -Filter 'crash.log' -ErrorAction SilentlyContinue

if ($RemoveLockFile) {
    $targets += Get-ChildItem -Path $root -Recurse -Force -File -Filter '.terraform.lock.hcl' -ErrorAction SilentlyContinue
}

if ($RemoveStateFiles) {
    $targets += Get-ChildItem -Path $root -Recurse -Force -File -Include '*.tfstate', '*.tfstate.backup', '.terraform.tfstate.lock.info' -ErrorAction SilentlyContinue
}

$targets = $targets | Sort-Object FullName -Unique

if (-not $targets) {
    Write-Host 'No Terraform build artifacts found.'
    return
}

if ($StopTerraformProcesses) {
    Write-Host 'Stopping Terraform-related processes before cleanup...'
    Stop-TerraformRelatedProcesses
}

$failures = @()

foreach ($target in $targets) {
    try {
        if ($target.PSIsContainer) {
            Write-Host "Removing directory: $($target.FullName)"
            if ($PSCmdlet.ShouldProcess($target.FullName, 'Remove directory')) {
                Remove-TargetWithRetry -Target $target -IsDirectory $true -Attempts $RetryCount -DelayMs $RetryDelayMs
            }
        }
        else {
            Write-Host "Removing file: $($target.FullName)"
            if ($PSCmdlet.ShouldProcess($target.FullName, 'Remove file')) {
                Remove-TargetWithRetry -Target $target -IsDirectory $false -Attempts $RetryCount -DelayMs $RetryDelayMs
            }
        }
    }
    catch {
        $failures += [PSCustomObject]@{
            Path  = $target.FullName
            Error = $_.Exception.Message
        }
        Write-Warning "Suppression echouee: $($target.FullName)"
        Write-Warning "Detail: $($_.Exception.Message)"
    }
}

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host 'Cleanup completed with errors:'
    $failures | Format-Table -AutoSize
    exit 1
}

Write-Host 'Terraform cleanup complete.'