# Guía rápida del Makefile — tochallenge-belo

> Todos los comandos se corren desde la **raíz de este repo** (donde está el `Makefile`).
> Variable central: `ENV` (default: `dev`). Pasala como `make <target> ENV=staging`.

---

## Flujo completo — primera vez

```bash
# 1. Copiar y editar archivos de configuración
cp terraform/bootstrap/terraform.tfvars.example terraform/bootstrap/terraform.tfvars
cp terraform/envs/dev/backend.hcl.example       terraform/envs/dev/backend.hcl
cp terraform/envs/dev/terraform.tfvars.example  terraform/envs/dev/terraform.tfvars
# Editar los tres archivos (ver Variables a editar en ROADMAP.md)

# 2. Crear bucket S3 + tabla DynamoDB para el remote state (UNA SOLA VEZ por cuenta)
make tf-bootstrap

# 3. Inicializar backend y crear la infra
make tf-init ENV=dev
make tf-plan ENV=dev
make tf-apply ENV=dev    # tarda 15-20 min por EKS

# 4. Configurar kubectl
make kubeconfig ENV=dev

# 5. Instalar todos los addons del cluster
make addons ENV=dev

# 6. Aplicar NodePool y EC2NodeClass de Karpenter
make addons-karpenter ENV=dev

# 7. Bootstrap ArgoCD (apuntar al repo gitops-files)
make argocd-bootstrap
```

---

## Re-deploy desde cero (después de destroy)

```bash
make tf-reinit ENV=dev   # limpia caché y re-inicializa
make tf-plan ENV=dev
make tf-apply ENV=dev
make kubeconfig ENV=dev
make addons ENV=dev
make addons-karpenter ENV=dev
make argocd-bootstrap
```

---

## Referencia rápida de targets

| Target | Qué hace | Cuándo usarlo |
|--------|----------|---------------|
| `make help` | Lista todos los targets con descripción | Siempre que no recuerdes algún target |
| `make tf-bootstrap` | Crea bucket S3 + DynamoDB para state remoto | Una sola vez por cuenta AWS |
| `make tf-init ENV=<env>` | Inicializa el backend de Terraform | Primera vez o después de `tf-reinit` |
| `make tf-reinit ENV=<env>` | Borra caché y re-inicializa | Después de `tf-destroy` |
| `make tf-plan ENV=<env>` | Genera el plan de cambios | Antes de cualquier apply |
| `make tf-apply ENV=<env>` | Aplica la infra | Después de revisar el plan |
| `make tf-destroy ENV=<env>` | Destruye toda la infra del ambiente (llama a `pre-destroy` automáticamente) | Demo/teardown — irreversible |
| `make pre-destroy ENV=<env>` | Borra LBs y ENIs huérfanas creados por Kubernetes antes del destroy | Se llama automáticamente desde `tf-destroy` |
| `make cleanup-vpc-deps VPC_ID=<id>` | Limpia dependencias de una VPC específica sin necesitar state de Terraform | Usar si el destroy ya falló y el state no puede leer el vpc_id |
| `make tf-output ENV=<env>` | Muestra los outputs de Terraform | Para ver ARNs, endpoints, etc. |
| `make kubeconfig ENV=<env>` | Configura kubectl para el cluster | Después de tf-apply |
| `make addons ENV=<env>` | Instala todos los addons vía Helm | Después de kubeconfig |
| `make addons-karpenter ENV=<env>` | Aplica NodePool + EC2NodeClass | Después de addons |
| `make argocd-bootstrap` | Aplica el App-of-Apps raíz | Después de addons |
| `make tekton-apply` | Aplica manifests de Tekton | Después de argocd-bootstrap |
| `make port-forward` | Port-forward a ArgoCD/Grafana/Kibana/Headlamp | Para acceso local a las UIs |
| `make ebs-mount-check` | Verifica que el EBS del nodo statefull esté montado | Debug post-apply |
| `make tf-fmt` | Formatea todos los .tf | Antes de commitear cambios de Terraform |
| `make clean` | Borra archivos temporales (tfplan, lock) | Limpieza general |
| `make cost-estimate` | Estima costo con infracost | Requiere infracost instalado |

---

## Variables override-ables

| Variable | Default | Ejemplo |
|----------|---------|---------|
| `ENV` | `dev` | `make tf-plan ENV=staging` |
| `REGION` | `us-east-1` | `make kubeconfig REGION=us-west-2` |
| `CLUSTER` | `belo-challenge-$(ENV)` | Se deriva automáticamente de ENV |

---

## Acceso a las UIs (después de `make port-forward`)

| Servicio | URL | Credenciales |
|----------|-----|--------------|
| ArgoCD | http://localhost:8080 | `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d` |
| Headlamp | http://localhost:8081 | `kubectl -n kube-system create token headlamp --duration=24h` |
| Grafana | http://localhost:8082 | admin / belo-challenge |
| Kibana | http://localhost:8083 | sin auth por defecto |
