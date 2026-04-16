# CloudRuplets AWS Free Tier Terraform

Cette stack Terraform implémente l'architecture du schema Draw.io avec les contraintes:

- runnable
- zero console clicks
- encrypted by default
- least privilege IAM
- scan-friendly (Checkov/tfsec)

## Structure des dossiers

- shared: ressources globales (CloudTrail, bucket de logs, SNS, KMS, policy IAM compte)
- dev: stack environnement dev
- staging: stack environnement staging
- prod: stack environnement prod
- modules/environment: module reutilisable applique par chaque environnement
- modules/ssm-environment: module reutilisable pour les parametres SSM par environnement

## Ressources deployees

- 3 environnements isoles: dev, staging, prod
- VPC par environnement avec subnets public, app, db (2 AZ pour RDS)
- EC2 public (Nginx reverse proxy) + EC2 app prive (IMDSv2 obligatoire)
- CloudFront devant l'instance publique
- WAFv2 de base associe a CloudFront (AWS managed rules)
- RDS chiffre KMS, non public, backups automatiques
- S3 chiffre KMS, versioning, blocage public, policy TLS only
- SSM Parameter Store (SecureString) pour secrets DB, via un module commun par environnement
- VPC endpoints: S3 gateway + SSM/EC2Messages/SSMMessages interface
- VPC Flow Logs vers CloudWatch Logs chiffre KMS
- Services partages securite: CloudTrail multi-region, CloudWatch, SNS alerting, password policy IAM

Note CloudFront/WAF:

- La region primaire de l'infra reste `eu-west-3`.
- Le WAF scope `CLOUDFRONT` est cree via un provider alias en `us-east-1` (contrainte AWS).

## Prerequis

- Terraform >= 1.6
- AWS CLI configuree (profil IAM avec droits admin pour le bootstrap)

Important Free Tier EC2:

- Utiliser `t3.micro` par defaut (plus compatible que `t2.micro` sur les comptes AWS recents).
- Si votre compte/region differe, verifier les types eligibles:

```powershell
aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true --query "InstanceTypes[].InstanceType" --output text
```

Depannage credentials AWS:

- Si Terraform affiche "No valid credential sources found", verifier que AWS CLI est installee et disponible dans le PATH.
- Sous Windows, installer AWS CLI puis ouvrir un nouveau terminal.
- Configurer les credentials avec `aws configure` ou `aws configure sso`.
- Verifier l'acces avec `aws sts get-caller-identity` avant `terraform plan`.

Cas specifique `login_session` (AWS CLI recent):

- Si `aws sts get-caller-identity` fonctionne mais Terraform echoue, injecter un token de session dans le shell courant avant `terraform plan`.
- Exemple PowerShell:

```powershell
$creds = aws configure export-credentials --format process | ConvertFrom-Json
$env:AWS_ACCESS_KEY_ID = $creds.AccessKeyId
$env:AWS_SECRET_ACCESS_KEY = $creds.SecretAccessKey
$env:AWS_SESSION_TOKEN = $creds.SessionToken
$env:AWS_DEFAULT_REGION = "eu-west-3"
```

## Execution (stacks separees)

Toutes les commandes ci-dessous sont en PowerShell.

1. Deployer d'abord les ressources partagees (`shared`):

```powershell
Set-Location .\shared
Copy-Item .\terraform.tfvars.example .\terraform.tfvars
# editer .\terraform.tfvars et renseigner admin_email
terraform init
terraform fmt -recursive
terraform validate
terraform plan -out tfplan
terraform apply tfplan
```

2. Deployer ensuite `dev`:

```powershell
Set-Location ..\dev
terraform init
terraform fmt -recursive
terraform validate
terraform plan -out tfplan
terraform apply tfplan
```

3. Deployer ensuite `staging`:

```powershell
Set-Location ..\staging
terraform init
terraform fmt -recursive
terraform validate
terraform plan -out tfplan
terraform apply tfplan
```

4. Deployer ensuite `prod`:

```powershell
Set-Location ..\prod
terraform init
terraform fmt -recursive
terraform validate
terraform plan -out tfplan
terraform apply tfplan
```

Les stacks dev, staging et prod lisent les outputs de shared via terraform_remote_state local (`../shared/terraform.tfstate`).

### Script de deploiement (shared + VPC independants)

Script disponible:

- `scripts/deploy-stacks.ps1`

Exemples:

```powershell
Set-Location .\terraform

# Deployer uniquement shared (plan + apply)
.\scripts\deploy-stacks.ps1 -Target shared -Action apply

# Deployer uniquement dev (plan + apply)
.\scripts\deploy-stacks.ps1 -Target dev -Action apply

# Deployer staging en mode demo
.\scripts\deploy-stacks.ps1 -Target staging -Action apply -Demo

# Deployer shared + dev + staging + prod dans l'ordre
.\scripts\deploy-stacks.ps1 -Target all -Action apply

# Plan seulement (sans apply)
.\scripts\deploy-stacks.ps1 -Target prod -Action plan

# Simulation PowerShell (WhatIf)
.\scripts\deploy-stacks.ps1 -Target dev -Action apply -WhatIf
```

Notes:

- `-Target dev|staging|prod` permet de lancer un seul VPC independamment.
- `-Target shared` permet de lancer uniquement la couche partagee.
- `-Target all` execute `shared`, puis `dev`, `staging`, `prod`.
- En mode `-Demo`, le script attend `terraform.demo.tfvars` dans chaque dossier cible.

## Mode demo (objectif: cout proche de 0 EUR)

Le mode demo permet de conserver la structure de l'architecture (VPC, subnet public/app/db, EC2 public, S3, IAM) en coupant les briques les plus facturees:

- RDS
- VPC interface endpoints
- VPC Flow Logs vers CloudWatch
- CloudTrail centralise
- KMS customer-managed keys
- EC2 detailed monitoring

Le profil demo est fourni dans:

- `shared/terraform.demo.tfvars.example`
- `dev/terraform.demo.tfvars.example`
- `staging/terraform.demo.tfvars.example`
- `prod/terraform.demo.tfvars.example`

### Execution demo recommandee

1. Deployer `shared` en mode demo (une seule fois):

```powershell
Set-Location .\shared
Copy-Item .\terraform.demo.tfvars.example .\terraform.demo.tfvars
# editer admin_email si besoin (Pour le SNS)
terraform init
terraform plan -var-file="terraform.demo.tfvars" -out tfplan
terraform apply tfplan
```

2. Deployer un seul environnement a la fois (exemple: `dev`):

```powershell
Set-Location ..\dev
Copy-Item .\terraform.demo.tfvars.example .\terraform.demo.tfvars
terraform init
terraform plan -var-file="terraform.demo.tfvars" -out tfplan
terraform apply tfplan
```

3. Fin de demo: detruire l'environnement actif immediatement:

```powershell
terraform destroy -var-file="terraform.demo.tfvars"
```

4. Changer d'environnement (staging/prod):

- Aller dans le dossier cible
- Utiliser le meme workflow `terraform.demo.tfvars`
- Appliquer

### Important

Pour viser un cout maximum de 0 EUR, il faut detruire l'environnement apres chaque demo. Tant qu'une ressource reste active, un cout peut apparaitre selon votre compte AWS et vos quotas free tier.

## Ordre de destruction

Pour detruire proprement, faire l'inverse de l'apply:

1. `prod`
2. `staging`
3. `dev`
4. `shared`

## Destruction globale + nettoyage AWS custom

Script disponible:

- `scripts/destroy-all-aws-custom.ps1`

Objectif:

- detruire `prod`, `staging`, `dev`, `shared` dans le bon ordre
- purger les reliquats AWS nommes avec le prefixe projet (`cloudruplets`) pour ne rien laisser de custom (buckets versionnes/logs, CloudTrail, SNS, CloudWatch, SSM, IAM, WAF CloudFront)

Simulation (recommandee):

```powershell
Set-Location .\terraform
.\scripts\destroy-all-aws-custom.ps1 -WhatIf
```

Execution reelle:

```powershell
Set-Location .\terraform
.\scripts\destroy-all-aws-custom.ps1
```

Options utiles:

```powershell
.\scripts\destroy-all-aws-custom.ps1 -SkipAwsCleanup
.\scripts\destroy-all-aws-custom.ps1 -SkipTerraformDestroy
```

## Verification securite IaC

Commandes recommandees:

- Checkov:

  checkov -d . --framework terraform

- tfsec:

  tfsec .

Verification Terraform rapide dans tous les dossiers:

```powershell
Set-Location ..
foreach ($stack in "shared", "dev", "staging", "prod") {
  Set-Location .\$stack
  terraform init -backend=false
  terraform fmt -recursive
  terraform validate
  Set-Location ..
}
```

## Verification des services de securite partages

Pour verifier rapidement que les services partages sont fonctionnels sur le compte AWS courant, lancer le script PowerShell suivant depuis le dossier `terraform`:

```powershell
.\scripts\check-shared-security.ps1
```

Le script controle notamment:

- le topic SNS de securite et son chiffrement
- le bucket central de logs et ses protections public access block
- la policy de mots de passe IAM du compte
- CloudTrail quand il est active
- les cles KMS partagees ou les residus historiques selon le mode deploiement

Lecture du resultat:

- `OK`: controle conforme
- `WARN`: service present mais attention au contexte demo ou a des residus historiques
- `FAIL`: configuration manquante ou incoherente

## Verification VPC (par environnement)

Script disponible:

- `scripts/check-vpc-resources.ps1`

Exemple (`dev`):

```powershell
Set-Location .\terraform
.\scripts\check-vpc-resources.ps1 -EnvironmentDir .\dev
```

Le script verifie la coherence Terraform state + AWS pour VPC, subnets, route tables, endpoint S3, SG, EC2 et RDS, puis affiche un schema ASCII de l'architecture.

## Nettoyage Terraform local

Script disponible:

- `scripts/clean-terraform.ps1`

Usage:

```powershell
Set-Location .\terraform
.\scripts\clean-terraform.ps1
```

Options utiles:

```powershell
.\scripts\clean-terraform.ps1 -RemoveLockFile
.\scripts\clean-terraform.ps1 -RemoveStateFiles
```

Le script supprime par defaut les dossiers `.terraform/`, les fichiers `tfplan` et les `crash.log` sur tout le workspace Terraform.

## CI/CD GitHub Actions

Workflow inclus: `Security CI`

- Scanners: Checkov + Trivy + Gitleaks
- Hard fail: le job echoue si un seul scanner remonte des findings
- Evidence: rapports SARIF + manifest de preuves publies en artifact

Le workflow est dans:

- ../.github/workflows/security-ci.yml

Preuves disponibles pour chaque execution:

- Artifact `security-scan-evidence` (rapports complets + checksums)
- Upload SARIF dans GitHub Code Scanning (categories checkov, gitleaks, trivy-config, trivy-fs)

## Notes

- L'abonnement email SNS doit etre confirme une fois par email (pas via console AWS).
- RDS est en `deletion_protection = true` et `skip_final_snapshot = false` pour la protection des donnees.
- Les mots de passe DB sont generes aleatoirement et stockes dans SSM Parameter Store.
