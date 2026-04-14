[CmdletBinding()]
param(
    [string]$EnvironmentDir = (Join-Path (Split-Path -Parent $PSScriptRoot) "dev"),
    [string]$AwsProfile,
    [string]$AwsRegion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Add-Result {
    param(
        [Parameter(Mandatory = $true)][string]$Check,
        [Parameter(Mandatory = $true)][ValidateSet("OK", "WARN", "FAIL")][string]$Status,
        [Parameter(Mandatory = $true)][string]$Detail
    )

    $script:Results += [PSCustomObject]@{
        Check  = $Check
        Status = $Status
        Detail = $Detail
    }
}

function Get-TfvarsBool {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Key
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $content = Get-Content -LiteralPath $Path -Raw
    $match = [regex]::Match($content, "(?m)^\s*$([regex]::Escape($Key))\s*=\s*(true|false)\s*$")
    if (-not $match.Success) {
        return $null
    }

    return $match.Groups[1].Value -eq "true"
}

function Invoke-AwsJson {
    param(
        [Parameter(Mandatory = $true)][string[]]$Args
    )

    $fullArgs = @()
    if ($AwsProfile) {
        $fullArgs += @("--profile", $AwsProfile)
    }
    if ($AwsRegion) {
        $fullArgs += @("--region", $AwsRegion)
    }
    $fullArgs += $Args

    $raw = & aws @fullArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ($raw -join [Environment]::NewLine)
    }

    if (-not $raw) {
        return $null
    }

    return ($raw -join [Environment]::NewLine) | ConvertFrom-Json
}

function Get-TfStateList {
    $raw = & terraform state list 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ($raw -join [Environment]::NewLine)
    }

    return @($raw | ForEach-Object { "$_".Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-TfStateShow {
    param(
        [Parameter(Mandatory = $true)][string]$Address
    )

    $raw = & terraform state show -no-color $Address 2>&1
    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    return ($raw -join [Environment]::NewLine)
}

function Get-StateAttr {
    param(
        [Parameter(Mandatory = $true)][string]$StateText,
        [Parameter(Mandatory = $true)][string]$AttrName
    )

    $match = [regex]::Match($StateText, "(?m)^\s*$([regex]::Escape($AttrName))\s*=\s*(.+)\s*$")
    if (-not $match.Success) {
        return $null
    }

    return $match.Groups[1].Value.Trim().Trim('"')
}

function Test-StateResource {
    param(
        [Parameter(Mandatory = $true)][string]$Address,
        [Parameter(Mandatory = $true)][bool]$Expected,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $exists = $script:StateAddresses -contains $Address

    if ($Expected -and $exists) {
        Add-Result -Check "State - $Label" -Status "OK" -Detail "Present dans terraform state."
    }
    elseif ($Expected -and -not $exists) {
        Add-Result -Check "State - $Label" -Status "FAIL" -Detail "Absent du terraform state."
    }
    elseif (-not $Expected -and $exists) {
        Add-Result -Check "State - $Label" -Status "WARN" -Detail "Present alors qu'il est desactive dans tfvars."
    }
    else {
        Add-Result -Check "State - $Label" -Status "OK" -Detail "Desactive et absent (attendu)."
    }

    return $exists
}

function Test-AwsExists {
    param(
        [Parameter(Mandatory = $true)][string]$Check,
        [Parameter(Mandatory = $true)][scriptblock]$Query,
        [Parameter(Mandatory = $true)][string]$OkDetail,
        [Parameter(Mandatory = $true)][string]$FailDetail
    )

    try {
        & $Query | Out-Null
        Add-Result -Check $Check -Status "OK" -Detail $OkDetail
        return $true
    }
    catch {
        Add-Result -Check $Check -Status "FAIL" -Detail "$FailDetail Erreur: $_"
        return $false
    }
}

$Results = @()

if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
    throw "terraform n'est pas disponible dans le PATH."
}

if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    throw "aws CLI n'est pas disponible dans le PATH."
}

if (-not (Test-Path -LiteralPath $EnvironmentDir)) {
    throw "Dossier environment introuvable: $EnvironmentDir"
}

$tfvarsPath = Join-Path $EnvironmentDir "terraform.demo.tfvars"
$expectPrivateApp = Get-TfvarsBool -Path $tfvarsPath -Key "enable_private_app_tier"
$expectRds = Get-TfvarsBool -Path $tfvarsPath -Key "enable_rds"
$expectInterfaceEndpoints = Get-TfvarsBool -Path $tfvarsPath -Key "enable_interface_endpoints"

if ($null -eq $expectPrivateApp) { $expectPrivateApp = $true }
if ($null -eq $expectRds) { $expectRds = $true }
if ($null -eq $expectInterfaceEndpoints) { $expectInterfaceEndpoints = $true }

$envName = Split-Path -Leaf $EnvironmentDir

Push-Location $EnvironmentDir
try {
    $identity = Invoke-AwsJson -Args @("sts", "get-caller-identity", "--output", "json")
    Add-Result -Check "AWS identity" -Status "OK" -Detail "Compte $($identity.Account), ARN $($identity.Arn)"

    $script:StateAddresses = Get-TfStateList
    Add-Result -Check "Terraform state" -Status "OK" -Detail "$($script:StateAddresses.Count) ressources detectees dans state."

    $addr = @{
        Vpc         = "module.environment.aws_vpc.this"
        Igw         = "module.environment.aws_internet_gateway.this"
        SubPublic   = "module.environment.aws_subnet.public"
        SubApp      = "module.environment.aws_subnet.app"
        SubDbA      = "module.environment.aws_subnet.db_a"
        SubDbB      = "module.environment.aws_subnet.db_b"
        RtPublic    = "module.environment.aws_route_table.public"
        RtApp       = "module.environment.aws_route_table.app"
        RtDb        = "module.environment.aws_route_table.db"
        AssocPublic = "module.environment.aws_route_table_association.public"
        AssocApp    = "module.environment.aws_route_table_association.app"
        AssocDbA    = "module.environment.aws_route_table_association.db_a"
        AssocDbB    = "module.environment.aws_route_table_association.db_b"
        VpceS3      = "module.environment.aws_vpc_endpoint.s3"
        SgPublic    = "module.environment.aws_security_group.public"
        SgApp       = "module.environment.aws_security_group.app"
        Ec2Public   = "module.environment.aws_instance.public"
        Ec2App      = "module.environment.aws_instance.app[0]"
        SgDb        = "module.environment.aws_security_group.db[0]"
        RdsSubnet   = "module.environment.aws_db_subnet_group.this[0]"
        RdsMain     = "module.environment.aws_db_instance.main[0]"
        SgVpce      = "module.environment.aws_security_group.vpce[0]"
        VpceSsm     = "module.environment.aws_vpc_endpoint.ssm[0]"
        VpceEc2Msg  = "module.environment.aws_vpc_endpoint.ec2messages[0]"
        VpceSsmMsg  = "module.environment.aws_vpc_endpoint.ssmmessages[0]"
    }

    # Ressources VPC de base (toujours attendues)
    $vpcInState = Test-StateResource -Address $addr.Vpc -Expected $true -Label "VPC"
    $igwInState = Test-StateResource -Address $addr.Igw -Expected $true -Label "Internet Gateway"

    $subPublicInState = Test-StateResource -Address $addr.SubPublic -Expected $true -Label "Subnet public"
    $subAppInState = Test-StateResource -Address $addr.SubApp -Expected $true -Label "Subnet app"
    $subDbAInState = Test-StateResource -Address $addr.SubDbA -Expected $true -Label "Subnet db_a"
    $subDbBInState = Test-StateResource -Address $addr.SubDbB -Expected $true -Label "Subnet db_b"

    $rtPublicInState = Test-StateResource -Address $addr.RtPublic -Expected $true -Label "Route table public"
    $rtAppInState = Test-StateResource -Address $addr.RtApp -Expected $true -Label "Route table app"
    $rtDbInState = Test-StateResource -Address $addr.RtDb -Expected $true -Label "Route table db"

    $assocPublicInState = Test-StateResource -Address $addr.AssocPublic -Expected $true -Label "Association RT public"
    $assocAppInState = Test-StateResource -Address $addr.AssocApp -Expected $true -Label "Association RT app"
    $assocDbAInState = Test-StateResource -Address $addr.AssocDbA -Expected $true -Label "Association RT db_a"
    $assocDbBInState = Test-StateResource -Address $addr.AssocDbB -Expected $true -Label "Association RT db_b"

    $vpceS3InState = Test-StateResource -Address $addr.VpceS3 -Expected $true -Label "VPC Endpoint S3"
    $sgPublicInState = Test-StateResource -Address $addr.SgPublic -Expected $true -Label "SG public"
    $sgAppInState = Test-StateResource -Address $addr.SgApp -Expected $true -Label "SG app"
    $ec2PublicInState = Test-StateResource -Address $addr.Ec2Public -Expected $true -Label "EC2 public"

    # Ressources conditionnelles
    $ec2AppInState = Test-StateResource -Address $addr.Ec2App -Expected $expectPrivateApp -Label "EC2 app"

    $sgDbInState = Test-StateResource -Address $addr.SgDb -Expected $expectRds -Label "SG db"
    $rdsSubnetInState = Test-StateResource -Address $addr.RdsSubnet -Expected $expectRds -Label "DB subnet group"
    $rdsMainInState = Test-StateResource -Address $addr.RdsMain -Expected $expectRds -Label "RDS instance"

    $sgVpceInState = Test-StateResource -Address $addr.SgVpce -Expected $expectInterfaceEndpoints -Label "SG VPC endpoints"
    $vpceSsmInState = Test-StateResource -Address $addr.VpceSsm -Expected $expectInterfaceEndpoints -Label "VPCE SSM"
    $vpceEc2MsgInState = Test-StateResource -Address $addr.VpceEc2Msg -Expected $expectInterfaceEndpoints -Label "VPCE EC2Messages"
    $vpceSsmMsgInState = Test-StateResource -Address $addr.VpceSsmMsg -Expected $expectInterfaceEndpoints -Label "VPCE SSMMessages"

    # Verification de presence AWS pour les ressources de base
    if ($vpcInState) {
        $vpcState = Get-TfStateShow -Address $addr.Vpc
        $vpcId = if ($vpcState) { Get-StateAttr -StateText $vpcState -AttrName "id" } else { $null }
        if ($vpcId) {
            $null = Test-AwsExists -Check "AWS - VPC" -Query { Invoke-AwsJson -Args @("ec2", "describe-vpcs", "--vpc-ids", $vpcId, "--output", "json") } -OkDetail "VPC $vpcId trouvee." -FailDetail "VPC introuvable."
        }
    }

    if ($igwInState) {
        $igwState = Get-TfStateShow -Address $addr.Igw
        $igwId = if ($igwState) { Get-StateAttr -StateText $igwState -AttrName "id" } else { $null }
        if ($igwId) {
            $null = Test-AwsExists -Check "AWS - IGW" -Query { Invoke-AwsJson -Args @("ec2", "describe-internet-gateways", "--internet-gateway-ids", $igwId, "--output", "json") } -OkDetail "IGW $igwId trouvee." -FailDetail "Internet Gateway introuvable."
        }
    }

    foreach ($sub in @(
        @{ State = $subPublicInState; Address = $addr.SubPublic; Label = "Subnet public" },
        @{ State = $subAppInState; Address = $addr.SubApp; Label = "Subnet app" },
        @{ State = $subDbAInState; Address = $addr.SubDbA; Label = "Subnet db_a" },
        @{ State = $subDbBInState; Address = $addr.SubDbB; Label = "Subnet db_b" }
    )) {
        if ($sub.State) {
            $subState = Get-TfStateShow -Address $sub.Address
            $subId = if ($subState) { Get-StateAttr -StateText $subState -AttrName "id" } else { $null }
            if ($subId) {
                $null = Test-AwsExists -Check "AWS - $($sub.Label)" -Query { Invoke-AwsJson -Args @("ec2", "describe-subnets", "--subnet-ids", $subId, "--output", "json") } -OkDetail "$($sub.Label) $subId trouvee." -FailDetail "$($sub.Label) introuvable."
            }
        }
    }

    foreach ($rt in @(
        @{ State = $rtPublicInState; Address = $addr.RtPublic; Label = "Route table public" },
        @{ State = $rtAppInState; Address = $addr.RtApp; Label = "Route table app" },
        @{ State = $rtDbInState; Address = $addr.RtDb; Label = "Route table db" }
    )) {
        if ($rt.State) {
            $rtState = Get-TfStateShow -Address $rt.Address
            $rtId = if ($rtState) { Get-StateAttr -StateText $rtState -AttrName "id" } else { $null }
            if ($rtId) {
                $null = Test-AwsExists -Check "AWS - $($rt.Label)" -Query { Invoke-AwsJson -Args @("ec2", "describe-route-tables", "--route-table-ids", $rtId, "--output", "json") } -OkDetail "$($rt.Label) $rtId trouvee." -FailDetail "$($rt.Label) introuvable."
            }
        }
    }

    if ($vpceS3InState) {
        $vpceState = Get-TfStateShow -Address $addr.VpceS3
        $vpceId = if ($vpceState) { Get-StateAttr -StateText $vpceState -AttrName "id" } else { $null }
        if ($vpceId) {
            $null = Test-AwsExists -Check "AWS - VPC Endpoint S3" -Query { Invoke-AwsJson -Args @("ec2", "describe-vpc-endpoints", "--vpc-endpoint-ids", $vpceId, "--output", "json") } -OkDetail "Endpoint S3 $vpceId trouve." -FailDetail "Endpoint S3 introuvable."
        }
    }

    if ($sgPublicInState) {
        $sgPublicState = Get-TfStateShow -Address $addr.SgPublic
        $sgPublicId = if ($sgPublicState) { Get-StateAttr -StateText $sgPublicState -AttrName "id" } else { $null }
        if ($sgPublicId) {
            $null = Test-AwsExists -Check "AWS - SG public" -Query { Invoke-AwsJson -Args @("ec2", "describe-security-groups", "--group-ids", $sgPublicId, "--output", "json") } -OkDetail "SG public $sgPublicId trouve." -FailDetail "SG public introuvable."
        }
    }

    if ($sgAppInState) {
        $sgAppState = Get-TfStateShow -Address $addr.SgApp
        $sgAppId = if ($sgAppState) { Get-StateAttr -StateText $sgAppState -AttrName "id" } else { $null }
        if ($sgAppId) {
            $null = Test-AwsExists -Check "AWS - SG app" -Query { Invoke-AwsJson -Args @("ec2", "describe-security-groups", "--group-ids", $sgAppId, "--output", "json") } -OkDetail "SG app $sgAppId trouve." -FailDetail "SG app introuvable."
        }
    }

    if ($ec2PublicInState) {
        $ec2PublicState = Get-TfStateShow -Address $addr.Ec2Public
        $ec2PublicId = if ($ec2PublicState) { Get-StateAttr -StateText $ec2PublicState -AttrName "id" } else { $null }
        if ($ec2PublicId) {
            $null = Test-AwsExists -Check "AWS - EC2 public" -Query { Invoke-AwsJson -Args @("ec2", "describe-instances", "--instance-ids", $ec2PublicId, "--output", "json") } -OkDetail "EC2 public $ec2PublicId trouvee." -FailDetail "EC2 public introuvable."
        }
    }

    if ($ec2AppInState) {
        $ec2AppState = Get-TfStateShow -Address $addr.Ec2App
        $ec2AppId = if ($ec2AppState) { Get-StateAttr -StateText $ec2AppState -AttrName "id" } else { $null }
        if ($ec2AppId) {
            $null = Test-AwsExists -Check "AWS - EC2 app" -Query { Invoke-AwsJson -Args @("ec2", "describe-instances", "--instance-ids", $ec2AppId, "--output", "json") } -OkDetail "EC2 app $ec2AppId trouvee." -FailDetail "EC2 app introuvable."
        }
    }

    if ($sgDbInState) {
        $sgDbState = Get-TfStateShow -Address $addr.SgDb
        $sgDbId = if ($sgDbState) { Get-StateAttr -StateText $sgDbState -AttrName "id" } else { $null }
        if ($sgDbId) {
            $null = Test-AwsExists -Check "AWS - SG db" -Query { Invoke-AwsJson -Args @("ec2", "describe-security-groups", "--group-ids", $sgDbId, "--output", "json") } -OkDetail "SG db $sgDbId trouve." -FailDetail "SG db introuvable."
        }
    }

    if ($rdsSubnetInState) {
        $rdsSubnetState = Get-TfStateShow -Address $addr.RdsSubnet
        $rdsSubnetName = if ($rdsSubnetState) { Get-StateAttr -StateText $rdsSubnetState -AttrName "name" } else { $null }
        if ($rdsSubnetName) {
            $null = Test-AwsExists -Check "AWS - DB subnet group" -Query { Invoke-AwsJson -Args @("rds", "describe-db-subnet-groups", "--db-subnet-group-name", $rdsSubnetName, "--output", "json") } -OkDetail "DB subnet group $rdsSubnetName trouve." -FailDetail "DB subnet group introuvable."
        }
    }

    if ($rdsMainInState) {
        $rdsState = Get-TfStateShow -Address $addr.RdsMain
        $rdsIdentifier = if ($rdsState) { Get-StateAttr -StateText $rdsState -AttrName "identifier" } else { $null }
        if ($rdsIdentifier) {
            $null = Test-AwsExists -Check "AWS - RDS" -Query { Invoke-AwsJson -Args @("rds", "describe-db-instances", "--db-instance-identifier", $rdsIdentifier, "--output", "json") } -OkDetail "RDS $rdsIdentifier trouvee." -FailDetail "RDS introuvable."
        }
    }

    foreach ($vpce in @(
        @{ Enabled = $sgVpceInState; Address = $addr.SgVpce; Kind = "sg"; Label = "SG endpoints" },
        @{ Enabled = $vpceSsmInState; Address = $addr.VpceSsm; Kind = "vpce"; Label = "VPCE SSM" },
        @{ Enabled = $vpceEc2MsgInState; Address = $addr.VpceEc2Msg; Kind = "vpce"; Label = "VPCE EC2Messages" },
        @{ Enabled = $vpceSsmMsgInState; Address = $addr.VpceSsmMsg; Kind = "vpce"; Label = "VPCE SSMMessages" }
    )) {
        if ($vpce.Enabled) {
            $stateText = Get-TfStateShow -Address $vpce.Address
            $id = if ($stateText) { Get-StateAttr -StateText $stateText -AttrName "id" } else { $null }
            if ($id) {
                if ($vpce.Kind -eq "sg") {
                    $null = Test-AwsExists -Check "AWS - $($vpce.Label)" -Query { Invoke-AwsJson -Args @("ec2", "describe-security-groups", "--group-ids", $id, "--output", "json") } -OkDetail "$($vpce.Label) $id trouve." -FailDetail "$($vpce.Label) introuvable."
                }
                else {
                    $null = Test-AwsExists -Check "AWS - $($vpce.Label)" -Query { Invoke-AwsJson -Args @("ec2", "describe-vpc-endpoints", "--vpc-endpoint-ids", $id, "--output", "json") } -OkDetail "$($vpce.Label) $id trouve." -FailDetail "$($vpce.Label) introuvable."
                }
            }
        }
    }

    # Schema ASCII de l'infrastructure
    $lineApp = if ($expectPrivateApp) { "[EC2 App]" } else { "[EC2 App disabled, subnet active]" }
    $lineRds = if ($expectRds) { "[RDS + DB SG + DB Subnet Group]" } else { "[RDS disabled]" }
    $lineVpce = if ($expectInterfaceEndpoints) { "[VPCE: SSM, EC2Messages, SSMMessages + SG]" } else { "[Interface Endpoints disabled]" }

    Write-Host ""
    Write-Host "Schema ASCII - infra VPC ($envName)"
    Write-Host "--------------------------------------------"
    Write-Host "Internet"
    Write-Host "   |"
    Write-Host "[Internet Gateway]"
    Write-Host "   |"
    Write-Host "[VPC]"
    Write-Host " |-- [Public Subnet] -- [EC2 Public]"
    Write-Host " |"
    Write-Host " |-- [App Subnet] ---- $lineApp"
    Write-Host " |"
    Write-Host " |-- [DB Subnet A]"
    Write-Host " |-- [DB Subnet B] ---- $lineRds"
    Write-Host " |"
    Write-Host " |-- [Route Tables: public/app/db]"
    Write-Host " |-- [Gateway Endpoint S3]"
    Write-Host " |-- $lineVpce"
    Write-Host "--------------------------------------------"
}
finally {
    Pop-Location
}

$Results | Format-Table -AutoSize

$failCount = @($Results | Where-Object { $_.Status -eq "FAIL" }).Count
$warnCount = @($Results | Where-Object { $_.Status -eq "WARN" }).Count
$okCount = @($Results | Where-Object { $_.Status -eq "OK" }).Count

Write-Host ""
Write-Host "Summary: OK=$okCount WARN=$warnCount FAIL=$failCount"

if ($failCount -gt 0) {
    exit 2
}

exit 0
