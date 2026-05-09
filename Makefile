# ──────────────────────────────────────────────────────────────────────────────
# Belo Challenge — Makefile
# ──────────────────────────────────────────────────────────────────────────────
# Targets agrupados por fase del ROADMAP. Cada uno hace lo mínimo necesario
# para ese paso y verifica prerrequisitos antes de avanzar.
# Ejecutar `make help` para ver todos los targets con su descripción.
# ──────────────────────────────────────────────────────────────────────────────

SHELL := /bin/bash
.DEFAULT_GOAL := help

# Variables — se pueden override desde la línea: `make tf-apply ENV=dev`
ENV         ?= dev
REGION      ?= us-east-1
CLUSTER     ?= belo-challenge-$(ENV)

TF_DIR      := terraform/envs/$(ENV)
TF_BOOTSTRAP_DIR := terraform/bootstrap
ALB_POLICY_PATH  := terraform/modules/alb-controller-irsa/iam_policy.json
ALB_POLICY_VERSION := v2.7.2

# Colores para que se lea más fácil.
GREEN  := \033[0;32m
YELLOW := \033[0;33m
RED    := \033[0;31m
NC     := \033[0m

# ──────────────────────────────────────────────────────────────────────────────
# Help
# ──────────────────────────────────────────────────────────────────────────────

.PHONY: help
help:  ## Mostrar targets disponibles
	@echo ""
	@echo "$(GREEN)Belo Challenge — Makefile$(NC)"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | sort \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-22s$(NC) %s\n", $$1, $$2}'
	@echo ""
	@echo "Variables override-ables: ENV (default: $(ENV)), REGION ($(REGION))"
	@echo ""

# ──────────────────────────────────────────────────────────────────────────────
# Fase 0 — Bootstrap del backend remoto (correr UNA SOLA vez por cuenta)
# ──────────────────────────────────────────────────────────────────────────────

.PHONY: tf-bootstrap
tf-bootstrap:  ## Crear el bucket S3 + DynamoDB lock para el state remoto (una sola vez)
	@echo "$(YELLOW)→ Bootstrap del backend Terraform...$(NC)"
	@if [ ! -f $(TF_BOOTSTRAP_DIR)/terraform.tfvars ]; then \
		echo "$(RED)Falta $(TF_BOOTSTRAP_DIR)/terraform.tfvars$(NC)"; \
		echo "Copialo de terraform.tfvars.example y editá el bucket name (tiene que ser único)."; \
		exit 1; \
	fi
	cd $(TF_BOOTSTRAP_DIR) && terraform init && terraform apply

# ──────────────────────────────────────────────────────────────────────────────
# Fase 1 — Infra base
# ──────────────────────────────────────────────────────────────────────────────

.PHONY: alb-policy
alb-policy:  ## Bajar el iam_policy.json del ALB Controller (versión $(ALB_POLICY_VERSION))
	@echo "$(YELLOW)→ Descargando IAM policy del ALB Controller...$(NC)"
	curl -fsSL -o $(ALB_POLICY_PATH) \
	  https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/$(ALB_POLICY_VERSION)/docs/install/iam_policy.json
	@echo "$(GREEN)✓ Guardado en $(ALB_POLICY_PATH)$(NC)"

.PHONY: tf-init
tf-init: alb-policy  ## terraform init con backend remoto
	@if [ ! -f $(TF_DIR)/backend.hcl ]; then \
		echo "$(RED)Falta $(TF_DIR)/backend.hcl$(NC)"; \
		echo "Copialo de backend.hcl.example y editá el bucket name."; \
		exit 1; \
	fi
	cd $(TF_DIR) && terraform init -backend-config=backend.hcl

.PHONY: tf-plan
tf-plan:  ## terraform plan de la infra del ambiente $(ENV)
	@if [ ! -f $(TF_DIR)/terraform.tfvars ]; then \
		echo "$(RED)Falta $(TF_DIR)/terraform.tfvars$(NC)"; \
		echo "Copialo de terraform.tfvars.example."; \
		exit 1; \
	fi
	cd $(TF_DIR) && terraform plan -out=tfplan

.PHONY: tf-apply
tf-apply:  ## Aplicar la infra (toma 15-20 min por EKS)
	@if [ ! -f $(TF_DIR)/tfplan ]; then \
		echo "$(YELLOW)No hay tfplan, corriendo plan primero...$(NC)"; \
		"$(MAKE)" tf-plan; \
	fi
	cd $(TF_DIR) && terraform apply tfplan
	@echo ""
	@echo "$(GREEN)✓ Infra desplegada$(NC)"
	@echo "$(YELLOW)Próximo: 'make kubeconfig' y después 'make addons'$(NC)"

.PHONY: tf-destroy
tf-destroy:  ## Destruir TODA la infra del ambiente $(ENV)
	@echo "$(RED)⚠  Esto va a destruir toda la infra de '$(ENV)'.$(NC)"
	@echo "$(RED)   El bucket de tfstate y el EBS statefull NO se destruyen (prevent_destroy).$(NC)"
	@read -p "Escribí '$(ENV)' para confirmar: " confirm; \
	if [ "$$confirm" != "$(ENV)" ]; then \
		echo "Cancelado."; exit 1; \
	fi
	cd $(TF_DIR) && terraform destroy

.PHONY: tf-output
tf-output:  ## Mostrar todos los outputs (kubeconfig cmd, ARNs de IRSA, etc.)
	cd $(TF_DIR) && terraform output

# ──────────────────────────────────────────────────────────────────────────────
# Fase 2 — Acceso al cluster
# ──────────────────────────────────────────────────────────────────────────────

.PHONY: kubeconfig
kubeconfig:  ## Bajar kubeconfig del cluster a ~/.kube/config
	@echo "$(YELLOW)→ Configurando kubectl para $(CLUSTER) en $(REGION)$(NC)"
	aws eks update-kubeconfig \
	  --name $(CLUSTER) \
	  --region $(REGION) \
	  --alias $(CLUSTER)
	@kubectl --context $(CLUSTER) get nodes -L role
	@echo "$(GREEN)✓ kubectl listo. Context: $(CLUSTER)$(NC)"

.PHONY: ebs-mount-check
ebs-mount-check:  ## Verificar que el EBS del nodo statefull esté montado (vía SSM)
	@NODE_ID=$$(aws ec2 describe-instances \
	  --filters "Name=tag:role,Values=statefulls" "Name=instance-state-name,Values=running" \
	  --region $(REGION) \
	  --query 'Reservations[0].Instances[0].InstanceId' --output text); \
	if [ "$$NODE_ID" = "None" ]; then echo "$(RED)No encontré nodo statefull$(NC)"; exit 1; fi; \
	echo "$(YELLOW)→ Conectándose al nodo $$NODE_ID por SSM...$(NC)"; \
	aws ssm start-session --target $$NODE_ID --region $(REGION) \
	  --document-name AWS-StartNonInteractiveCommand \
	  --parameters 'command="lsblk && echo --- && df -h /mnt/statefull && echo --- && ls -la /var/lib/elasticsearch /var/lib/prometheus"'

# ──────────────────────────────────────────────────────────────────────────────
# Fase 3 — Addons (placeholder, se llena en la siguiente entrega)
# ──────────────────────────────────────────────────────────────────────────────

.PHONY: addons
addons:  ## (Placeholder) Instalar todos los addons del cluster
	@echo "$(YELLOW)Este target se completa en la Fase 3 del roadmap.$(NC)"
	@echo "Va a instalar: ALB Controller, nginx, Karpenter, ArgoCD, ArgoRollouts,"
	@echo "Tekton + Triggers, TestKube, EFK, Prometheus + Grafana, Headlamp."

# ──────────────────────────────────────────────────────────────────────────────
# Fase 8 — k3d local (placeholder)
# ──────────────────────────────────────────────────────────────────────────────

.PHONY: k3d-up
k3d-up:  ## (Placeholder) Levantar el stack en k3d local
	@echo "$(YELLOW)Este target se completa en la Fase 8 del roadmap.$(NC)"

.PHONY: k3d-down
k3d-down:  ## (Placeholder) Bajar el cluster k3d
	@echo "$(YELLOW)Este target se completa en la Fase 8 del roadmap.$(NC)"

# ──────────────────────────────────────────────────────────────────────────────
# Utilidades
# ──────────────────────────────────────────────────────────────────────────────

.PHONY: clean
clean:  ## Limpiar archivos temporales (tfplan, etc.) — no toca state ni cloud
	find . -name 'tfplan' -delete
	find . -name '.terraform.lock.hcl' -delete
	@echo "$(GREEN)✓ Limpio$(NC)"

.PHONY: tf-fmt
tf-fmt:  ## Formatear todos los .tf en estilo canónico
	terraform fmt -recursive terraform/

.PHONY: tf-validate
tf-validate: tf-init  ## Validar la sintaxis de Terraform
	cd $(TF_DIR) && terraform validate

.PHONY: cost-estimate
cost-estimate:  ## Estimar costo del plan actual con infracost (si está instalado)
	@if ! command -v infracost >/dev/null 2>&1; then \
		echo "$(RED)Instalar infracost: https://www.infracost.io/docs/$(NC)"; exit 1; \
	fi
	cd $(TF_DIR) && infracost breakdown --path .
