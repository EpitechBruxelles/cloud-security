# Cool Delivery AWS Free Tier Terraform

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

## Ressources deployees

- 3 environnements isoles: dev, staging, prod
- VPC par environnement avec subnets public, app, db (2 AZ pour RDS)
- EC2 public (Nginx HTTPS reverse proxy) + EC2 app prive (IMDSv2 obligatoire)
- RDS chiffre KMS, non public, backups automatiques
- S3 chiffre KMS, versioning, blocage public, policy TLS only
- SSM Parameter Store (SecureString) pour secrets DB
- VPC endpoints: S3 gateway + SSM/EC2Messages/SSMMessages interface
- VPC Flow Logs vers CloudWatch Logs chiffre KMS
- Services partages securite: CloudTrail multi-region, CloudWatch, SNS alerting, password policy IAM

## Prerequis

- Terraform >= 1.6
- AWS CLI configuree (profil IAM avec droits admin pour le bootstrap)

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

## Ordre de destruction

Pour detruire proprement, faire l'inverse de l'apply:

1. `prod`
2. `staging`
3. `dev`
4. `shared`

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
