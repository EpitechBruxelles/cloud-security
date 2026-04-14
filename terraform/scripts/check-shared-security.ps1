[CmdletBinding()]
param(
    [string]$SharedDir = (Join-Path (Split-Path -Parent $PSScriptRoot) "shared"),
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

function Get-TfOutputJson {
    $raw = & terraform output -json 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ($raw -join [Environment]::NewLine)
    }

    return ($raw -join [Environment]::NewLine) | ConvertFrom-Json
}

$Results = @()

if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
    throw "terraform n'est pas disponible dans le PATH."
}

if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    throw "aws CLI n'est pas disponible dans le PATH."
}

if (-not (Test-Path -LiteralPath $SharedDir)) {
    throw "Dossier shared introuvable: $SharedDir"
}

$tfvarsPath = Join-Path $SharedDir "terraform.demo.tfvars"
$expectCloudTrail = Get-TfvarsBool -Path $tfvarsPath -Key "enable_cloudtrail"
$expectCustomerKms = Get-TfvarsBool -Path $tfvarsPath -Key "use_customer_managed_kms"
$expectEmailSub = Get-TfvarsBool -Path $tfvarsPath -Key "enable_security_email_subscription"

if ($null -eq $expectCloudTrail) { $expectCloudTrail = $true }
if ($null -eq $expectCustomerKms) { $expectCustomerKms = $true }
if ($null -eq $expectEmailSub) { $expectEmailSub = $true }

Push-Location $SharedDir
try {
    $identity = Invoke-AwsJson -Args @("sts", "get-caller-identity", "--output", "json")
    Add-Result -Check "AWS identity" -Status "OK" -Detail "Compte $($identity.Account), ARN $($identity.Arn)"

    $tfOutputs = Get-TfOutputJson
    $topicArn = $tfOutputs.security_alerts_topic_arn.value
    $bucketId = $tfOutputs.central_log_bucket_id.value

    if ([string]::IsNullOrWhiteSpace($topicArn) -or [string]::IsNullOrWhiteSpace($bucketId)) {
        Add-Result -Check "Terraform outputs shared" -Status "FAIL" -Detail "Outputs manquants (SNS topic ou bucket central)."
        throw "Outputs Terraform shared incomplets."
    }

    Add-Result -Check "Terraform outputs shared" -Status "OK" -Detail "Topic SNS et bucket central presents."

    $topicName = ($topicArn -split ":")[-1]
    $projectPrefix = $topicName
    if ($topicName -like "*-security-alerts") {
        $projectPrefix = $topicName.Substring(0, $topicName.Length - "-security-alerts".Length)
    }

    $sns = Invoke-AwsJson -Args @("sns", "get-topic-attributes", "--topic-arn", $topicArn, "--output", "json")
    $subsConfirmed = [int]$sns.Attributes.SubscriptionsConfirmed
    $subsPending = [int]$sns.Attributes.SubscriptionsPending
    $snsKms = [string]$sns.Attributes.KmsMasterKeyId

    if ([string]::IsNullOrWhiteSpace($snsKms)) {
        Add-Result -Check "SNS chiffrement" -Status "FAIL" -Detail "Aucune cle KMS sur le topic SNS."
    }
    else {
        Add-Result -Check "SNS chiffrement" -Status "OK" -Detail "KMS = $snsKms"
    }

    if ($expectEmailSub) {
        if ($subsConfirmed -ge 1) {
            Add-Result -Check "SNS abonnement email" -Status "OK" -Detail "Abonnements confirmes: $subsConfirmed"
        }
        elseif ($subsPending -ge 1) {
            Add-Result -Check "SNS abonnement email" -Status "WARN" -Detail "En attente de confirmation email ($subsPending)."
        }
        else {
            Add-Result -Check "SNS abonnement email" -Status "FAIL" -Detail "Aucun abonnement email configure."
        }
    }
    else {
        Add-Result -Check "SNS abonnement email" -Status "OK" -Detail "Desactive en mode demo (attendu)."
    }

    $pab = Invoke-AwsJson -Args @("s3api", "get-public-access-block", "--bucket", $bucketId, "--output", "json")
    $pabc = $pab.PublicAccessBlockConfiguration
    $allPublicBlocks = @(
        [bool]$pabc.BlockPublicAcls,
        [bool]$pabc.BlockPublicPolicy,
        [bool]$pabc.IgnorePublicAcls,
        [bool]$pabc.RestrictPublicBuckets
    )
    if ($allPublicBlocks -notcontains $false) {
        Add-Result -Check "S3 public access block" -Status "OK" -Detail "Les 4 protections sont actives."
    }
    else {
        Add-Result -Check "S3 public access block" -Status "FAIL" -Detail "Une ou plusieurs protections S3 publiques sont inactives."
    }

    $versioning = Invoke-AwsJson -Args @("s3api", "get-bucket-versioning", "--bucket", $bucketId, "--output", "json")
    if ($versioning.Status -eq "Enabled") {
        Add-Result -Check "S3 versioning" -Status "OK" -Detail "Versioning active."
    }
    else {
        Add-Result -Check "S3 versioning" -Status "FAIL" -Detail "Versioning non active."
    }

    try {
        $encryption = Invoke-AwsJson -Args @("s3api", "get-bucket-encryption", "--bucket", $bucketId, "--output", "json")
        $rule = $encryption.ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault
        $algo = [string]$rule.SSEAlgorithm
        if ($algo -eq "aws:kms") {
            Add-Result -Check "S3 chiffrement" -Status "OK" -Detail "SSE-KMS actif."
        }
        elseif ($algo -eq "AES256") {
            $status = if ($expectCustomerKms) { "WARN" } else { "OK" }
            $detail = if ($expectCustomerKms) { "SSE-S3 actif (AES256), attendu aws:kms hors demo." } else { "SSE-S3 actif (AES256), attendu en demo." }
            Add-Result -Check "S3 chiffrement" -Status $status -Detail $detail
        }
        else {
            Add-Result -Check "S3 chiffrement" -Status "WARN" -Detail "Algorithme inattendu: $algo"
        }
    }
    catch {
        Add-Result -Check "S3 chiffrement" -Status "FAIL" -Detail "Configuration de chiffrement bucket introuvable."
    }

    try {
        $pwd = Invoke-AwsJson -Args @("iam", "get-account-password-policy", "--output", "json")
        $pp = $pwd.PasswordPolicy
        $isStrong = (
            $pp.MinimumPasswordLength -ge 14 -and
            $pp.RequireUppercaseCharacters -and
            $pp.RequireLowercaseCharacters -and
            $pp.RequireNumbers -and
            $pp.RequireSymbols -and
            $pp.MaxPasswordAge -le 90 -and
            $pp.PasswordReusePrevention -ge 24
        )

        if ($isStrong) {
            Add-Result -Check "IAM password policy" -Status "OK" -Detail "Policy conforme au baseline strict."
        }
        else {
            Add-Result -Check "IAM password policy" -Status "WARN" -Detail "Policy presente mais partiellement differente du baseline."
        }
    }
    catch {
        Add-Result -Check "IAM password policy" -Status "FAIL" -Detail "Aucune policy IAM de compte trouvee."
    }

    $trails = Invoke-AwsJson -Args @("cloudtrail", "describe-trails", "--output", "json")
    $projectTrails = @($trails.trailList | Where-Object { $_.Name -like "$projectPrefix*" })

    if ($projectTrails.Count -eq 0) {
        if ($expectCloudTrail) {
            Add-Result -Check "CloudTrail" -Status "FAIL" -Detail "Aucun trail $projectPrefix trouve alors qu'il est attendu."
        }
        else {
            Add-Result -Check "CloudTrail" -Status "OK" -Detail "Desactive en mode demo (attendu)."
        }
    }
    else {
        $trail = $projectTrails[0]
        try {
            $trailStatus = Invoke-AwsJson -Args @("cloudtrail", "get-trail-status", "--name", $trail.Name, "--output", "json")
            if ($trailStatus.IsLogging) {
                $status = if ($expectCloudTrail) { "OK" } else { "WARN" }
                $detail = if ($expectCloudTrail) { "Trail actif: $($trail.Name)" } else { "Trail actif en mode demo (cout potentiel): $($trail.Name)" }
                Add-Result -Check "CloudTrail" -Status $status -Detail $detail
            }
            else {
                Add-Result -Check "CloudTrail" -Status "FAIL" -Detail "Trail trouve mais logging inactif: $($trail.Name)"
            }
        }
        catch {
            Add-Result -Check "CloudTrail" -Status "FAIL" -Detail "Trail trouve mais statut inaccessible: $($trail.Name)"
        }
    }

    $kmsAliasesResponse = Invoke-AwsJson -Args @("kms", "list-aliases", "--output", "json")
    $projectAliases = @($kmsAliasesResponse.Aliases | Where-Object { $_.AliasName -like "alias/$projectPrefix-*" })
    $envKmsMap = $tfOutputs.env_kms_key_arns.value
    $envKeyCount = 0
    if ($envKmsMap) {
        $envKeyCount = ($envKmsMap.PSObject.Properties | Measure-Object).Count
    }

    if ($expectCustomerKms) {
        if ($envKeyCount -ge 1) {
            Add-Result -Check "KMS cles environnement" -Status "OK" -Detail "$envKeyCount cle(s) KMS environnement exposee(s) par Terraform output."
        }
        else {
            Add-Result -Check "KMS cles environnement" -Status "FAIL" -Detail "Aucune cle KMS environnement dans les outputs Terraform."
        }
    }
    else {
        if ($envKeyCount -eq 0) {
            Add-Result -Check "KMS cles environnement" -Status "OK" -Detail "Desactive en mode demo (attendu)."
        }
        else {
            Add-Result -Check "KMS cles environnement" -Status "WARN" -Detail "Des cles KMS env existent alors que demo les desactive."
        }
    }

    if ($projectAliases.Count -gt 0 -and -not $expectCustomerKms) {
        Add-Result -Check "KMS aliases historiques" -Status "WARN" -Detail "$($projectAliases.Count) alias $projectPrefix detecte(s) dans le compte (residus possibles)."
    }
    else {
        Add-Result -Check "KMS aliases historiques" -Status "OK" -Detail "Aucun residu inattendu detecte."
    }

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
