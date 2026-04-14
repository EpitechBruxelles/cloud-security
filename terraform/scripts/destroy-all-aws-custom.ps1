[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$TerraformRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$ProjectPrefix = "cloudruplets",
    [string]$ProjectTagValue = "CloudRuplets",
    [string]$PrimaryRegion = "eu-west-3",
    [string]$GlobalRegion = "us-east-1",
    [switch]$SkipAwsCleanup,
    [switch]$SkipTerraformDestroy
)

$ErrorActionPreference = "Stop"

function Invoke-AwsJson {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [string]$Region = $PrimaryRegion,
        [switch]$AllowFailure
    )

    $full = "$Command --region $Region --output json"
    try {
        $raw = Invoke-Expression $full
        if (-not $raw) {
            return $null
        }
        return $raw | ConvertFrom-Json
    }
    catch {
        if ($AllowFailure) {
            Write-Warning "Commande AWS ignoree: $full"
            Write-Warning $_.Exception.Message
            return $null
        }
        throw
    }
}

function Invoke-TerraformDestroy {
    param(
        [Parameter(Mandatory = $true)][string]$StackDir
    )

    if (-not (Test-Path -LiteralPath $StackDir)) {
        Write-Host "Stack absente, skip: $StackDir"
        return
    }

    $stackName = Split-Path -Leaf $StackDir
    Write-Host "\n=== Terraform destroy: $stackName ==="

    $varCandidates = @(
        "terraform.demo.tfvars",
        "terraform.auto.tfvars",
        "terraform.tfvars"
    )

    $varFile = $null
    foreach ($candidate in $varCandidates) {
        $path = Join-Path $StackDir $candidate
        if (Test-Path -LiteralPath $path) {
            $varFile = $path
            break
        }
    }

    $initCmd = "terraform -chdir=`"$StackDir`" init -input=false"
    if ($PSCmdlet.ShouldProcess($stackName, "terraform init")) {
        Invoke-Expression $initCmd | Out-Host
    }

    $destroyCmd = "terraform -chdir=`"$StackDir`" destroy -auto-approve"
    if ($varFile) {
        $destroyCmd += " -var-file=`"$varFile`""
    }

    if ($PSCmdlet.ShouldProcess($stackName, "terraform destroy")) {
        Invoke-Expression $destroyCmd | Out-Host
    }
}

function Remove-VersionedS3Bucket {
    param(
        [Parameter(Mandatory = $true)][string]$BucketName
    )

    Write-Host "\nPurge du bucket versionne: $BucketName"

    $keyMarker = $null
    $versionMarker = $null

    do {
        $cmd = "aws s3api list-object-versions --bucket `"$BucketName`""
        if ($keyMarker) {
            $cmd += " --key-marker `"$keyMarker`""
        }
        if ($versionMarker) {
            $cmd += " --version-id-marker `"$versionMarker`""
        }

        $listed = Invoke-AwsJson -Command $cmd -AllowFailure
        if (-not $listed) {
            break
        }

        $items = @()
        if ($listed.Versions) { $items += $listed.Versions }
        if ($listed.DeleteMarkers) { $items += $listed.DeleteMarkers }

        foreach ($item in $items) {
            $deleteCmd = "aws s3api delete-object --bucket `"$BucketName`" --key `"$($item.Key)`" --version-id `"$($item.VersionId)`" --region $PrimaryRegion"
            if ($PSCmdlet.ShouldProcess("$BucketName/$($item.Key):$($item.VersionId)", "delete versioned object")) {
                Invoke-Expression $deleteCmd | Out-Null
            }
        }

        if ($listed.IsTruncated) {
            $keyMarker = $listed.NextKeyMarker
            $versionMarker = $listed.NextVersionIdMarker
        }
        else {
            $keyMarker = $null
            $versionMarker = $null
        }
    } while ($keyMarker)

    $deleteBucketCmd = "aws s3api delete-bucket --bucket `"$BucketName`" --region $PrimaryRegion"
    if ($PSCmdlet.ShouldProcess($BucketName, "delete bucket")) {
        Invoke-Expression $deleteBucketCmd | Out-Host
    }
}

function Remove-ByNameContains {
    param(
        [Parameter(Mandatory = $true)][array]$Items,
        [Parameter(Mandatory = $true)][string]$NameProperty,
        [Parameter(Mandatory = $true)][scriptblock]$DeleteAction,
        [string]$Label = "ressource"
    )

    foreach ($item in $Items) {
        $name = [string]$item.$NameProperty
        if (-not $name) { continue }
        if ($name.ToLower().Contains($ProjectPrefix.ToLower())) {
            if ($PSCmdlet.ShouldProcess($name, "delete $Label")) {
                & $DeleteAction $item
            }
        }
    }
}

function Cleanup-AwsLeftovers {
    Write-Host "\n=== Nettoyage des reliquats AWS '$ProjectPrefix' ==="

    # S3 buckets (dont logs versionnes)
    $buckets = Invoke-AwsJson -Command "aws s3api list-buckets"
    if ($buckets -and $buckets.Buckets) {
        foreach ($bucket in $buckets.Buckets) {
            if ($bucket.Name.ToLower().Contains($ProjectPrefix.ToLower())) {
                Remove-VersionedS3Bucket -BucketName $bucket.Name
            }
        }
    }

    # CloudWatch Log Groups
    $logGroups = Invoke-AwsJson -Command "aws logs describe-log-groups" -AllowFailure
    if ($logGroups -and $logGroups.logGroups) {
        Remove-ByNameContains -Items $logGroups.logGroups -NameProperty "logGroupName" -Label "log group" -DeleteAction {
            param($lg)
            Invoke-Expression "aws logs delete-log-group --log-group-name `"$($lg.logGroupName)`" --region $PrimaryRegion" | Out-Host
        }
    }

    # CloudWatch Alarms
    $alarms = Invoke-AwsJson -Command "aws cloudwatch describe-alarms" -AllowFailure
    if ($alarms -and $alarms.MetricAlarms) {
        $alarmNames = @($alarms.MetricAlarms | Where-Object { $_.AlarmName -and $_.AlarmName.ToLower().Contains($ProjectPrefix.ToLower()) } | ForEach-Object { $_.AlarmName })
        if ($alarmNames.Count -gt 0) {
            if ($PSCmdlet.ShouldProcess(($alarmNames -join ", "), "delete alarms")) {
                $quoted = $alarmNames | ForEach-Object { '"' + $_ + '"' }
                Invoke-Expression ("aws cloudwatch delete-alarms --alarm-names " + ($quoted -join " ") + " --region $PrimaryRegion") | Out-Host
            }
        }
    }

    # SNS Topics
    $topics = Invoke-AwsJson -Command "aws sns list-topics" -AllowFailure
    if ($topics -and $topics.Topics) {
        foreach ($topic in $topics.Topics) {
            if ($topic.TopicArn.ToLower().Contains($ProjectPrefix.ToLower())) {
                if ($PSCmdlet.ShouldProcess($topic.TopicArn, "delete sns topic")) {
                    Invoke-Expression "aws sns delete-topic --topic-arn `"$($topic.TopicArn)`" --region $PrimaryRegion" | Out-Host
                }
            }
        }
    }

    # CloudTrail trails
    $trails = Invoke-AwsJson -Command "aws cloudtrail describe-trails --include-shadow-trails"
    if ($trails -and $trails.trailList) {
        foreach ($trail in $trails.trailList) {
            if ($trail.Name -and $trail.Name.ToLower().Contains($ProjectPrefix.ToLower())) {
                if ($PSCmdlet.ShouldProcess($trail.Name, "delete cloudtrail trail")) {
                    Invoke-Expression "aws cloudtrail delete-trail --name `"$($trail.Name)`" --region $PrimaryRegion" | Out-Host
                }
            }
        }
    }

    # SSM parameters
    $params = Invoke-AwsJson -Command "aws ssm describe-parameters --max-results 50" -AllowFailure
    if ($params -and $params.Parameters) {
        foreach ($param in $params.Parameters) {
            if ($param.Name.ToLower().Contains($ProjectPrefix.ToLower()) -or $param.Name.ToLower().Contains($ProjectTagValue.ToLower())) {
                if ($PSCmdlet.ShouldProcess($param.Name, "delete ssm parameter")) {
                    Invoke-Expression "aws ssm delete-parameter --name `"$($param.Name)`" --region $PrimaryRegion" | Out-Host
                }
            }
        }
    }

    # IAM roles/policies du projet
    $roles = Invoke-AwsJson -Command "aws iam list-roles" -Region $PrimaryRegion -AllowFailure
    if ($roles -and $roles.Roles) {
        foreach ($role in $roles.Roles) {
            if (-not $role.RoleName.ToLower().Contains($ProjectPrefix.ToLower())) { continue }

            $attached = Invoke-AwsJson -Command "aws iam list-attached-role-policies --role-name `"$($role.RoleName)`"" -Region $PrimaryRegion -AllowFailure
            if ($attached -and $attached.AttachedPolicies) {
                foreach ($policy in $attached.AttachedPolicies) {
                    if ($PSCmdlet.ShouldProcess("$($role.RoleName) -> $($policy.PolicyArn)", "detach policy")) {
                        Invoke-Expression "aws iam detach-role-policy --role-name `"$($role.RoleName)`" --policy-arn `"$($policy.PolicyArn)`"" | Out-Host
                    }
                }
            }

            $inline = Invoke-AwsJson -Command "aws iam list-role-policies --role-name `"$($role.RoleName)`"" -Region $PrimaryRegion -AllowFailure
            if ($inline -and $inline.PolicyNames) {
                foreach ($policyName in $inline.PolicyNames) {
                    if ($PSCmdlet.ShouldProcess("$($role.RoleName) -> $policyName", "delete inline role policy")) {
                        Invoke-Expression "aws iam delete-role-policy --role-name `"$($role.RoleName)`" --policy-name `"$policyName`"" | Out-Host
                    }
                }
            }

            if ($PSCmdlet.ShouldProcess($role.RoleName, "delete iam role")) {
                Invoke-Expression "aws iam delete-role --role-name `"$($role.RoleName)`"" | Out-Host
            }
        }
    }

    # WAFv2 CloudFront scope (region us-east-1)
    $webAcls = Invoke-AwsJson -Command "aws wafv2 list-web-acls --scope CLOUDFRONT" -Region $GlobalRegion -AllowFailure
    if ($webAcls -and $webAcls.WebACLs) {
        foreach ($acl in $webAcls.WebACLs) {
            if (-not $acl.Name.ToLower().Contains($ProjectPrefix.ToLower())) { continue }
            if ($PSCmdlet.ShouldProcess($acl.Name, "delete waf web acl")) {
                Invoke-Expression "aws wafv2 delete-web-acl --scope CLOUDFRONT --id `"$($acl.Id)`" --name `"$($acl.Name)`" --lock-token `"$($acl.LockToken)`" --region $GlobalRegion" | Out-Host
            }
        }
    }
}

Write-Host "Destruction globale Terraform + nettoyage AWS"
Write-Host "Terraform root: $TerraformRoot"
Write-Host "Project prefix: $ProjectPrefix"

if (-not $SkipTerraformDestroy) {
    $destroyOrder = @("prod", "staging", "dev", "shared")
    foreach ($stack in $destroyOrder) {
        $stackDir = Join-Path $TerraformRoot $stack
        try {
            Invoke-TerraformDestroy -StackDir $stackDir
        }
        catch {
            Write-Warning "Destroy Terraform en echec pour ${stack}: $($_.Exception.Message)"
            if ($stack -ne "shared") {
                throw
            }
        }
    }
}

if (-not $SkipAwsCleanup) {
    Cleanup-AwsLeftovers
}

Write-Host "\nTermine. Verifie dans AWS si des ressources manuelles hors prefixe '$ProjectPrefix' subsistent."
