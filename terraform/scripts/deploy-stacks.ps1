[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet("shared", "dev", "staging", "prod", "all")]
    [string]$Target = "all",

    [ValidateSet("plan", "apply")]
    [string]$Action = "apply",

    [string]$TerraformRoot,
    [string]$VarFile,
    [string]$PlanOut = "tfplan",

    [switch]$Demo,
    [switch]$Init,
    [switch]$NoFmt,
    [switch]$NoValidate
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($TerraformRoot)) {
    $TerraformRoot = Split-Path -Parent $PSScriptRoot
}

function Assert-CommandAvailable {
    param([Parameter(Mandatory = $true)][string]$CommandName)

    if (-not (Get-Command $CommandName -ErrorAction SilentlyContinue)) {
        throw "Commande introuvable dans le PATH: $CommandName"
    }
}

function Get-StackOrder {
    param([Parameter(Mandatory = $true)][string]$RequestedTarget)

    if ($RequestedTarget -eq "all") {
        return @("shared", "dev", "staging", "prod")
    }

    return @($RequestedTarget)
}

function Resolve-VarFileForStack {
    param(
        [Parameter(Mandatory = $true)][string]$StackDir,
        [Parameter(Mandatory = $true)][string]$StackName
    )

    if ($VarFile) {
        if ([System.IO.Path]::IsPathRooted($VarFile)) {
            if (-not (Test-Path -LiteralPath $VarFile)) {
                throw "Var-file introuvable: $VarFile"
            }
            return $VarFile
        }

        $stackRelativePath = Join-Path $StackDir $VarFile
        if (Test-Path -LiteralPath $stackRelativePath) {
            return $stackRelativePath
        }

        $rootRelativePath = Join-Path $TerraformRoot $VarFile
        if (Test-Path -LiteralPath $rootRelativePath) {
            return $rootRelativePath
        }

        throw "Var-file introuvable pour ${StackName}: $VarFile"
    }

    if ($Demo) {
        $demoPath = Join-Path $StackDir "terraform.demo.tfvars"
        if (-not (Test-Path -LiteralPath $demoPath)) {
            throw "Mode demo active, mais fichier absent pour ${StackName}: $demoPath"
        }
        return $demoPath
    }

    return $null
}

function Invoke-TerraformForStack {
    param(
        [Parameter(Mandatory = $true)][string]$StackName,
        [Parameter(Mandatory = $true)][string]$StackDir,
        [Parameter()][string]$ResolvedVarFile
    )

    if (-not (Test-Path -LiteralPath $StackDir)) {
        throw "Dossier stack introuvable: $StackDir"
    }

    Write-Host ""
    Write-Host "=== Stack: $StackName ==="

    Push-Location $StackDir
    try {
        $needInit = $Init -or -not (Test-Path -LiteralPath (Join-Path $StackDir ".terraform"))
        if ($needInit) {
            if ($PSCmdlet.ShouldProcess($StackName, "terraform init")) {
                & terraform init -input=false
                if ($LASTEXITCODE -ne 0) {
                    throw "terraform init a echoue pour $StackName"
                }
            }
        }

        if (-not $NoFmt) {
            if ($PSCmdlet.ShouldProcess($StackName, "terraform fmt -recursive")) {
                & terraform fmt -recursive
                if ($LASTEXITCODE -ne 0) {
                    throw "terraform fmt a echoue pour $StackName"
                }
            }
        }

        if (-not $NoValidate) {
            if ($PSCmdlet.ShouldProcess($StackName, "terraform validate")) {
                & terraform validate
                if ($LASTEXITCODE -ne 0) {
                    throw "terraform validate a echoue pour $StackName"
                }
            }
        }

        $planArgs = @("plan", "-out", $PlanOut)
        if ($ResolvedVarFile) {
            $planArgs += @("-var-file", $ResolvedVarFile)
        }

        if ($PSCmdlet.ShouldProcess($StackName, "terraform plan")) {
            & terraform @planArgs
            if ($LASTEXITCODE -ne 0) {
                throw "terraform plan a echoue pour $StackName"
            }
        }

        if ($Action -eq "apply") {
            $applyArgs = @("apply", $PlanOut)
            if ($PSCmdlet.ShouldProcess($StackName, "terraform apply")) {
                & terraform @applyArgs
                if ($LASTEXITCODE -ne 0) {
                    throw "terraform apply a echoue pour $StackName"
                }
            }
        }
    }
    finally {
        Pop-Location
    }
}

Assert-CommandAvailable -CommandName "terraform"

$stacks = Get-StackOrder -RequestedTarget $Target

if ($stacks.Count -eq 0) {
    throw "Aucune stack selectionnee."
}

if ($stacks.Count -eq 1 -and $stacks[0] -ne "shared") {
    $sharedState = Join-Path $TerraformRoot "shared\terraform.tfstate"
    if (-not (Test-Path -LiteralPath $sharedState)) {
        Write-Warning "Le state shared est absent: $sharedState"
        Write-Warning "Le deploiement de $($stacks[0]) peut echouer si les outputs shared sont requis."
    }
}

foreach ($stack in $stacks) {
    $stackDir = Join-Path $TerraformRoot $stack
    $resolvedVarFile = Resolve-VarFileForStack -StackDir $stackDir -StackName $stack
    Invoke-TerraformForStack -StackName $stack -StackDir $stackDir -ResolvedVarFile $resolvedVarFile
}

Write-Host ""
Write-Host "Execution terminee."