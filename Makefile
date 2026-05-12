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
tf-init: alb-policy  ## terraform init con backend remoto (ENV=$(ENV))
	@echo "$(YELLOW)→ Inicializando Terraform para ambiente '$(ENV)' — dir: $(TF_DIR)$(NC)"
	@if [ ! -f $(TF_DIR)/backend.hcl ]; then \
		echo "$(RED)Falta $(TF_DIR)/backend.hcl$(NC)"; \
		echo "Copiá $(TF_DIR)/backend.hcl.example y editá el bucket name."; \
		exit 1; \
	fi
	@if [ ! -f $(TF_DIR)/terraform.tfvars ]; then \
		echo "$(RED)Falta $(TF_DIR)/terraform.tfvars$(NC)"; \
		echo "Copiá $(TF_DIR)/terraform.tfvars.example y editá los valores."; \
		exit 1; \
	fi
	cd $(TF_DIR) && terraform init -backend-config=backend.hcl
	@echo "$(GREEN)✓ Init OK — ambiente: $(ENV)$(NC)"

.PHONY: tf-reinit
tf-reinit:  ## Re-init limpio: borra caché local y vuelve a inicializar (usar después de destroy o si el state quedó roto)
	@echo "$(YELLOW)→ Limpiando caché local de Terraform para '$(ENV)'...$(NC)"
	rm -f $(TF_DIR)/tfplan
	rm -rf $(TF_DIR)/.terraform
	rm -f $(TF_DIR)/.terraform.lock.hcl
	"$(MAKE)" tf-init ENV=$(ENV)
	@echo "$(GREEN)✓ Re-init OK — listo para 'make tf-plan ENV=$(ENV)'$(NC)"

.PHONY: tf-plan
tf-plan:  ## Generar plan fresco de infra para ENV=$(ENV) — descarta cualquier plan previo
	@echo "$(YELLOW)→ Generando plan para ambiente '$(ENV)' — dir: $(TF_DIR)$(NC)"
	@if [ ! -f $(TF_DIR)/terraform.tfvars ]; then \
		echo "$(RED)Falta $(TF_DIR)/terraform.tfvars$(NC)"; \
		echo "Copiá $(TF_DIR)/terraform.tfvars.example y editá los valores."; \
		exit 1; \
	fi
	@if [ ! -d $(TF_DIR)/.terraform ]; then \
		echo "$(YELLOW)→ .terraform/ no existe, corriendo tf-init primero...$(NC)"; \
		"$(MAKE)" tf-init ENV=$(ENV); \
	fi
	@rm -f $(TF_DIR)/tfplan
	cd $(TF_DIR) && terraform plan -out=tfplan
	@echo ""
	@echo "$(GREEN)✓ Plan listo en $(TF_DIR)/tfplan$(NC)"
	@echo "$(YELLOW)Revisá el diff y después: make tf-apply ENV=$(ENV)$(NC)"

.PHONY: tf-apply
tf-apply:  ## Aplicar la infra de ENV=$(ENV) — toma 15-20 min por EKS
	@if [ ! -f $(TF_DIR)/tfplan ]; then \
		echo "$(YELLOW)→ No hay plan generado, corriendo tf-plan primero...$(NC)"; \
		"$(MAKE)" tf-plan ENV=$(ENV); \
	fi
	cd $(TF_DIR) && terraform apply tfplan
	@rm -f $(TF_DIR)/tfplan
	@echo ""
	@echo "$(GREEN)✓ Infra desplegada — ambiente: $(ENV)$(NC)"
	@echo "$(YELLOW)Próximo: make kubeconfig ENV=$(ENV) — después: make addons ENV=$(ENV)$(NC)"

.PHONY: pre-destroy
pre-destroy:  ## Limpiar recursos AWS creados por K8s antes del destroy (LBs, ENIs) — evita DependencyViolation
	@echo "$(YELLOW)→ Limpieza pre-destroy: borrando LoadBalancers creados por Kubernetes...$(NC)"
	@VPC_ID=$$(cd $(TF_DIR) && terraform output -raw vpc_id 2>/dev/null || echo ""); \
	if [ -z "$$VPC_ID" ]; then \
		echo "$(YELLOW)  No se pudo obtener vpc_id del state — saltando limpieza automática$(NC)"; \
		echo "$(YELLOW)  Si el destroy falla, corré: make cleanup-vpc-deps VPC_ID=<id>$(NC)"; \
	else \
		echo "$(YELLOW)  VPC: $$VPC_ID$(NC)"; \
		echo "$(YELLOW)  1/4 Borrando ALBs/NLBs en la VPC...$(NC)"; \
		for arn in $$(aws elbv2 describe-load-balancers --region $(REGION) \
		  --query "LoadBalancers[?VpcId=='$$VPC_ID'].LoadBalancerArn" --output text 2>/dev/null); do \
			echo "    Borrando ELBv2: $$arn"; \
			aws elbv2 delete-load-balancer --region $(REGION) --load-balancer-arn $$arn; \
		done; \
		echo "$(YELLOW)  2/4 Borrando Classic ELBs en la VPC...$(NC)"; \
		for name in $$(aws elb describe-load-balancers --region $(REGION) \
		  --query "LoadBalancerDescriptions[?VPCId=='$$VPC_ID'].LoadBalancerName" --output text 2>/dev/null); do \
			echo "    Borrando ELB classic: $$name"; \
			aws elb delete-load-balancer --region $(REGION) --load-balancer-name $$name; \
		done; \
		echo "$(YELLOW)  Esperando 20s...$(NC)"; sleep 20; \
		echo "$(YELLOW)  3/4 Borrando NAT Gateways y liberando EIPs...$(NC)"; \
		for ngw in $$(aws ec2 describe-nat-gateways --region $(REGION) \
		  --filter "Name=vpc-id,Values=$$VPC_ID" "Name=state,Values=available,pending" \
		  --query 'NatGateways[*].NatGatewayId' --output text 2>/dev/null); do \
			echo "    Borrando NAT Gateway: $$ngw"; \
			aws ec2 delete-nat-gateway --region $(REGION) --nat-gateway-id $$ngw; \
		done; \
		echo "$(YELLOW)  Esperando 30s para que los NAT GWs terminen...$(NC)"; sleep 30; \
		for eip in $$(aws ec2 describe-addresses --region $(REGION) \
		  --filters "Name=domain,Values=vpc" \
		  --query 'Addresses[?AssociationId==null].AllocationId' --output text 2>/dev/null); do \
			echo "    Liberando EIP: $$eip"; \
			aws ec2 release-address --region $(REGION) --allocation-id $$eip 2>/dev/null || true; \
		done; \
		echo "$(YELLOW)  4/4 Borrando ENIs huérfanas (status=available)...$(NC)"; \
		for eni in $$(aws ec2 describe-network-interfaces --region $(REGION) \
		  --filters "Name=vpc-id,Values=$$VPC_ID" "Name=status,Values=available" \
		  --query 'NetworkInterfaces[*].NetworkInterfaceId' --output text 2>/dev/null); do \
			echo "    Borrando ENI: $$eni"; \
			aws ec2 delete-network-interface --region $(REGION) --network-interface-id $$eni; \
		done; \
		echo "$(GREEN)✓ Limpieza pre-destroy OK$(NC)"; \
	fi

.PHONY: cleanup-vpc-deps
cleanup-vpc-deps:  ## Limpiar deps de una VPC específica: make cleanup-vpc-deps VPC_ID=vpc-xxxx
	@if [ -z "$(VPC_ID)" ]; then echo "$(RED)Falta VPC_ID. Uso: make cleanup-vpc-deps VPC_ID=vpc-xxxx$(NC)"; exit 1; fi
	@echo "$(YELLOW)→ Limpiando dependencias de VPC $(VPC_ID)...$(NC)"
	@echo "$(YELLOW)  1/4 Borrando ALBs/NLBs...$(NC)"
	@for arn in $$(aws elbv2 describe-load-balancers --region $(REGION) \
	  --query "LoadBalancers[?VpcId=='$(VPC_ID)'].LoadBalancerArn" --output text 2>/dev/null); do \
		echo "    Borrando ELBv2: $$arn"; \
		aws elbv2 delete-load-balancer --region $(REGION) --load-balancer-arn $$arn; \
	done
	@echo "$(YELLOW)  2/4 Borrando Classic ELBs...$(NC)"
	@for name in $$(aws elb describe-load-balancers --region $(REGION) \
	  --query "LoadBalancerDescriptions[?VPCId=='$(VPC_ID)'].LoadBalancerName" --output text 2>/dev/null); do \
		echo "    Borrando ELB classic: $$name"; \
		aws elb delete-load-balancer --region $(REGION) --load-balancer-name $$name; \
	done
	@echo "$(YELLOW)  Esperando 20s para que AWS libere recursos de LBs...$(NC)"; sleep 20
	@echo "$(YELLOW)  3/4 Borrando NAT Gateways y liberando sus EIPs...$(NC)"
	@for ngw in $$(aws ec2 describe-nat-gateways --region $(REGION) \
	  --filter "Name=vpc-id,Values=$(VPC_ID)" "Name=state,Values=available,pending" \
	  --query 'NatGateways[*].NatGatewayId' --output text 2>/dev/null); do \
		echo "    Borrando NAT Gateway: $$ngw"; \
		aws ec2 delete-nat-gateway --region $(REGION) --nat-gateway-id $$ngw; \
	done; \
	echo "$(YELLOW)  Esperando 30s para que los NAT GWs terminen de borrarse...$(NC)"; sleep 30; \
	for eip in $$(aws ec2 describe-addresses --region $(REGION) \
	  --filters "Name=domain,Values=vpc" \
	  --query 'Addresses[?AssociationId==null].AllocationId' --output text 2>/dev/null); do \
		echo "    Liberando EIP: $$eip"; \
		aws ec2 release-address --region $(REGION) --allocation-id $$eip 2>/dev/null || true; \
	done
	@echo "$(YELLOW)  4/4 Borrando ENIs huérfanas (status=available)...$(NC)"
	@for eni in $$(aws ec2 describe-network-interfaces --region $(REGION) \
	  --filters "Name=vpc-id,Values=$(VPC_ID)" "Name=status,Values=available" \
	  --query 'NetworkInterfaces[*].NetworkInterfaceId' --output text 2>/dev/null); do \
		echo "    Borrando ENI: $$eni"; \
		aws ec2 delete-network-interface --region $(REGION) --network-interface-id $$eni; \
	done
	@echo "$(GREEN)✓ VPC $(VPC_ID) limpia — podés reintentar make tf-destroy$(NC)"

.PHONY: tf-destroy
tf-destroy: pre-destroy  ## Destruir TODA la infra de ENV=$(ENV) — IRREVERSIBLE
	@echo "$(RED)⚠  Esto va a destruir toda la infra de '$(ENV)'.$(NC)"
	@echo "$(RED)   El bucket de tfstate NO se destruye (contiene el state de todos los envs).$(NC)"
	@read -p "Escribí '$(ENV)' para confirmar: " confirm; \
	if [ "$$confirm" != "$(ENV)" ]; then \
		echo "Cancelado."; exit 1; \
	fi
	cd $(TF_DIR) && terraform destroy
	@rm -f $(TF_DIR)/tfplan
	@echo "$(YELLOW)Después de destroy: 'make tf-reinit ENV=$(ENV)' antes del próximo plan/apply.$(NC)"

.PHONY: tf-output
tf-output:  ## Mostrar todos los outputs de ENV=$(ENV) (kubeconfig cmd, ARNs de IRSA, etc.)
	cd $(TF_DIR) && terraform output

.PHONY: tf-state-list
tf-state-list:  ## Listar recursos en el state de ENV=$(ENV) — útil para debug post-destroy
	cd $(TF_DIR) && terraform state list

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
# Fase 3 — Repos Helm
# ──────────────────────────────────────────────────────────────────────────────

.PHONY: helm-repos
helm-repos:  ## Agregar y actualizar todos los repos Helm necesarios (idempotente)
	@echo "$(YELLOW)→ Agregando repos Helm...$(NC)"
	helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
	helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
	helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
	helm repo add elastic https://helm.elastic.co 2>/dev/null || true
	helm repo add fluent https://fluent.github.io/helm-charts 2>/dev/null || true
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
	helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ 2>/dev/null || true
	helm repo add kubeshop https://kubeshop.github.io/helm-charts 2>/dev/null || true
	helm repo update
	@echo "$(GREEN)✓ Repos Helm actualizados$(NC)"

# ──────────────────────────────────────────────────────────────────────────────
# Fase 3 — Addons AWS (EKS)
# ──────────────────────────────────────────────────────────────────────────────

.PHONY: addons
addons: helm-repos  ## Instalar todos los addons en el cluster EKS de ENV=$(ENV)
	@echo "$(YELLOW)→ Leyendo outputs de Terraform para '$(ENV)'...$(NC)"
	@CLUSTER_ENDPOINT=$$(cd $(TF_DIR) && terraform output -raw cluster_endpoint 2>/dev/null); \
	ALB_ROLE=$$(cd $(TF_DIR) && terraform output -raw alb_controller_role_arn 2>/dev/null); \
	KARPENTER_ROLE=$$(cd $(TF_DIR) && terraform output -raw karpenter_controller_role_arn 2>/dev/null); \
	KARPENTER_NODE_ROLE=$$(cd $(TF_DIR) && terraform output -raw karpenter_node_role_name 2>/dev/null); \
	KARPENTER_QUEUE=$$(cd $(TF_DIR) && terraform output -raw karpenter_interruption_queue 2>/dev/null); \
	ACCOUNT_ID=$$(cd $(TF_DIR) && terraform output -raw account_id 2>/dev/null); \
	CLUSTER_NAME=$$(cd $(TF_DIR) && terraform output -raw cluster_name 2>/dev/null); \
	helm_retry() { \
	  local label="$$1"; shift; \
	  local n=1; \
	  echo "$(YELLOW)→ $$label$(NC)"; \
	  while [ $$n -le 3 ]; do \
	    if "$$@"; then \
	      echo "$(GREEN)✓ $$label OK$(NC)"; \
	      return 0; \
	    fi; \
	    echo "$(RED)  intento $$n/3 falló$(NC)"; \
	    n=$$((n+1)); \
	    if [ $$n -le 3 ]; then \
	      echo "$(YELLOW)  reintentando en 30s...$(NC)"; \
	      sleep 30; \
	    fi; \
	  done; \
	  echo "$(RED)✗ $$label — falló tras 3 intentos$(NC)"; \
	  return 1; \
	}; \
	kubectl_retry() { \
	  local label="$$1" ns="$$2" deploy="$$3" timeout="$$4"; \
	  local n=1; \
	  echo "$(YELLOW)→ Esperando rollout: $$label$(NC)"; \
	  while [ $$n -le 3 ]; do \
	    if kubectl -n "$$ns" rollout status deployment/"$$deploy" --timeout="$$timeout"; then \
	      echo "$(GREEN)✓ $$label ready$(NC)"; \
	      return 0; \
	    fi; \
	    n=$$((n+1)); \
	    if [ $$n -le 3 ]; then \
	      echo "$(YELLOW)  reintentando en 30s...$(NC)"; \
	      sleep 30; \
	    fi; \
	  done; \
	  echo "$(RED)✗ $$label — rollout timeout tras 3 intentos$(NC)"; \
	  return 1; \
	}; \
	kubectl create namespace kube-system 2>/dev/null || true; \
	helm_retry "1/11 ALB Controller" helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
	  --namespace kube-system \
	  --values helm/addons/alb-controller/values.yaml \
	  --set clusterName=$$CLUSTER_NAME \
	  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$$ALB_ROLE \
	  --atomic --timeout 3m; \
	kubectl create namespace ingress-nginx 2>/dev/null || true; \
	helm_retry "2/11 nginx-ingress" helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
	  --namespace ingress-nginx \
	  --values helm/addons/nginx-ingress/values.yaml \
	  --atomic --timeout 3m; \
	kubectl create namespace karpenter 2>/dev/null || true; \
	helm_retry "3/11 Karpenter" helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
	  --namespace karpenter \
	  --values helm/addons/karpenter/values.yaml \
	  --set settings.clusterName=$$CLUSTER_NAME \
	  --set settings.clusterEndpoint=$$CLUSTER_ENDPOINT \
	  --set settings.interruptionQueue=$$KARPENTER_QUEUE \
	  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$$KARPENTER_ROLE \
	  --atomic --timeout 3m; \
	helm_retry "4/11 metrics-server" helm upgrade --install metrics-server metrics-server/metrics-server \
	  --namespace kube-system \
	  --atomic --timeout 3m; \
	kubectl create namespace argocd 2>/dev/null || true; \
	helm_retry "5/11 ArgoCD" helm upgrade --install argocd argo/argo-cd \
	  --namespace argocd \
	  --values helm/addons/argocd/values.yaml \
	  --atomic --timeout 8m; \
	kubectl create namespace argo-rollouts 2>/dev/null || true; \
	helm_retry "6/11 Argo Rollouts" helm upgrade --install argo-rollouts argo/argo-rollouts \
	  --namespace argo-rollouts \
	  --set replicaCount=1 \
	  --atomic --timeout 5m; \
	echo "$(YELLOW)→ 7/11 Tekton Pipelines + Triggers...$(NC)"; \
	kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml; \
	kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/release.yaml; \
	kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/interceptors.yaml; \
	kubectl_retry "tekton-pipelines-controller" tekton-pipelines tekton-pipelines-controller 5m; \
	kubectl create namespace logging 2>/dev/null || true; \
	helm_retry "8/11 Elasticsearch" helm upgrade --install elasticsearch elastic/elasticsearch \
	  --namespace logging \
	  --values helm/addons/elasticsearch/values.yaml \
	  --atomic --timeout 10m; \
	helm_retry "9/11 Fluent Bit" helm upgrade --install fluent-bit fluent/fluent-bit \
	  --namespace logging \
	  --values helm/addons/fluent-bit/values.yaml \
	  --atomic --timeout 3m; \
	helm_retry "10/11 Kibana" helm upgrade --install kibana elastic/kibana \
	  --namespace logging \
	  --values helm/addons/kibana/values.yaml \
	  --atomic --timeout 5m; \
	kubectl create namespace monitoring 2>/dev/null || true; \
	helm_retry "11/11 kube-prometheus-stack" helm upgrade --install kube-prometheus prometheus-community/kube-prometheus-stack \
	  --namespace monitoring \
	  --values helm/addons/kube-prometheus/values.yaml \
	  --atomic --timeout 10m; \
	echo "$(YELLOW)→ extras: Headlamp + Testkube...$(NC)"; \
	kubectl create namespace testkube 2>/dev/null || true; \
	helm_retry "extras: Headlamp" helm upgrade --install headlamp oci://ghcr.io/headlamp-k8s/charts/headlamp \
	  --namespace kube-system \
	  --values helm/addons/headlamp/values.yaml \
	  --atomic --timeout 3m \
	  || echo "$(YELLOW)  WARN: Headlamp falló (addon opcional, continúa)$(NC)"; \
	helm_retry "extras: Testkube" helm upgrade --install testkube kubeshop/testkube \
	  --namespace testkube \
	  --values helm/addons/testkube/values.yaml \
	  --atomic --timeout 10m \
	  || echo "$(YELLOW)  WARN: Testkube falló — verificar StorageClass gp3 y EBS CSI Driver$(NC)"; \
	echo "$(GREEN)✓ Addons instalados — ENV=$(ENV)$(NC)"; \
	echo "$(YELLOW)Re-ejecutar 'make addons ENV=$(ENV)' para reintentar fallidos (es idempotente).$(NC)"; \
	echo "$(YELLOW)Próximo: make addons-karpenter ENV=$(ENV) — después: make argocd-bootstrap$(NC)"

.PHONY: addons-karpenter
addons-karpenter:  ## Aplicar NodePool y EC2NodeClass post-addons (requiere Karpenter instalado)
	@echo "$(YELLOW)→ Leyendo cluster name y node role desde Terraform...$(NC)"
	@CLUSTER_NAME=$$(cd $(TF_DIR) && terraform output -raw cluster_name 2>/dev/null); \
	KARPENTER_NODE_ROLE=$$(cd $(TF_DIR) && terraform output -raw karpenter_node_role_name 2>/dev/null); \
	echo "$(YELLOW)→ Aplicando NodePool (stateless)...$(NC)"; \
	sed -e "s/CLUSTER_NAME/$$CLUSTER_NAME/g" \
	    -e "s/KARPENTER_NODE_ROLE/$$KARPENTER_NODE_ROLE/g" \
	    manifests/karpenter/ec2-node-class.yaml | kubectl apply -f -; \
	kubectl apply -f manifests/karpenter/node-pool.yaml; \
	echo "$(GREEN)✓ Karpenter NodePool + EC2NodeClass aplicados$(NC)"

# ──────────────────────────────────────────────────────────────────────────────
# Fase 4 — ArgoCD Bootstrap
# ──────────────────────────────────────────────────────────────────────────────

.PHONY: argocd-bootstrap
argocd-bootstrap:  ## Aplicar el App-of-Apps raíz de ArgoCD (gitops-files)
	@echo "$(YELLOW)→ Aplicando bootstrap de ArgoCD...$(NC)"
	kubectl apply -f manifests/argocd/bootstrap.yaml
	@echo "$(GREEN)✓ App-of-Apps aplicado. ArgoCD sincronizará desde github.com/Valentino-33/gitops-files$(NC)"

# ──────────────────────────────────────────────────────────────────────────────
# Fase 5 — Tekton
# ──────────────────────────────────────────────────────────────────────────────

.PHONY: tekton-apply
tekton-apply:  ## Aplicar todos los manifests de Tekton (pipelines, tasks, triggers)
	@echo "$(YELLOW)→ Aplicando manifests/tekton/...$(NC)"
	kubectl apply -f manifests/tekton/
	@echo "$(GREEN)✓ Manifests de Tekton aplicados$(NC)"

# ──────────────────────────────────────────────────────────────────────────────
# Utilidades de acceso local
# ──────────────────────────────────────────────────────────────────────────────

.PHONY: port-forward
port-forward:  ## Port-forward a ArgoCD:8080, Headlamp:8081, Grafana:8082, Kibana:8083 (background)
	@echo "$(YELLOW)→ Iniciando port-forwards en background...$(NC)"
	kubectl -n argocd port-forward svc/argocd-server 8080:80 > /tmp/pf-argocd.log 2>&1 &
	@echo "  ArgoCD   → http://localhost:8080"
	kubectl -n kube-system port-forward svc/headlamp 8081:80 > /tmp/pf-headlamp.log 2>&1 &
	@echo "  Headlamp → http://localhost:8081"
	kubectl -n monitoring port-forward svc/kube-prometheus-grafana 8082:80 > /tmp/pf-grafana.log 2>&1 &
	@echo "  Grafana  → http://localhost:8082  (user: admin / pass: belo-challenge)"
	kubectl -n logging port-forward svc/kibana-kibana 8083:5601 > /tmp/pf-kibana.log 2>&1 &
	@echo "  Kibana   → http://localhost:8083"
	@echo ""
	@echo "$(GREEN)✓ Port-forwards activos. Para detenerlos: pkill -f 'kubectl.*port-forward'$(NC)"

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
