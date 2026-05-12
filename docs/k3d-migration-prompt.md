# Prompt para nueva sesión Claude — Migración del pipeline a k3d

Copiá todo el bloque de abajo y pegalo como primer mensaje en una nueva sesión de Claude Code.

---

## CONTEXTO: plataforma GitOps/CI-CD en EKS — quiero adaptarla a k3d

Tenemos una plataforma CI/CD GitOps completamente implementada para EKS. Quiero crear una versión k3d (Kubernetes in Docker) para desarrollo local y POC.

### Estructura del repo `belo-helm-charts` (ya implementado):

```
belo-helm-charts/
├── charts-core/
│   └── pythonapps/              ← Helm chart
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
│           ├── rollout.yaml     ← ArgoRollouts (bluegreen|canary|rollingupdate)
│           ├── service.yaml     ← siempre stable+preview (topología invariante)
│           ├── ingress.yaml     ← siempre stable+preview
│           ├── hpa.yaml
│           ├── servicemonitor.yaml
│           └── pipeline-templates/
│               ├── tekton-sa.yaml
│               ├── event-listener.yaml
│               ├── trigger-binding.yaml
│               ├── trigger-template.yaml
│               ├── task-clone.yaml
│               ├── task-build-kaniko.yaml
│               ├── task-bump-gitops.yaml
│               ├── task-wait-argocd.yaml
│               ├── task-load-test.yaml
│               ├── task-promote-rollback.yaml
│               └── pipeline-pythonapps.yaml
└── values-apps-files/
    ├── webserver-api01/
    │   ├── build-time/app-values.yaml
    │   ├── values-dev-webserver-api01.yaml
    │   ├── values-staging-webserver-api01.yaml
    │   ├── values-prod-webserver-api01.yaml
    │   ├── values-lab-webserver-api01.yaml
    │   └── values-testing-webserver-api01.yaml
    └── webserver-api02/
        └── (misma estructura)
```

### Flujo del pipeline (6 stages, DEBE QUEDAR IDÉNTICO):

```
git tag <env>/<strategy>/<semver>  →  GitHub webhook  →  Tekton EventListener (CEL)
  →  TriggerTemplate  →  PipelineRun

Stage 1: clone         — git clone --depth 1 del repo de la app
Stage 2: build-push    — Kaniko build + push a Docker Hub (o registry local)
Stage 3: bump-gitops   — yq: image.tag + rollout.strategy en
                          values-apps-files/<app>/values-<env>-<app>.yaml
                          git commit + push a belo-helm-charts
Stage 4: wait-argocd   — polling: ArgoCD Synced+Healthy + Rollout Paused|Healthy (600s timeout)
Stage 5: load-test     — k6 contra preview o stable service;
                          emite Tekton result outcome=passed|failed; siempre exit 0
Stage 6: promote-rollback — BlueGreen: promote/abort
                            Canary: 25%→k6→50%→k6→100% o abort
                            RollingUpdate: no-op o undo
```

### Convención de tag (CEL requiere exactamente 5 segmentos):

```bash
git tag prod/bluegreen/v1.4.0
git tag staging/canary/v1.4.0
git tag dev/rollingupdate/v1.4.0-rc1
git push origin dev/rollingupdate/v1.4.0-rc1
```

### Decisiones de diseño a preservar:

- Strategy por deploy (del tag), NO fija por app
- `bump-gitops` commitea a `belo-helm-charts` (no a `gitops-files`)
- Services e Ingresses stable+preview SIEMPRE existen (topología invariante)
- `gitops-files` solo contiene Application CRs de ArgoCD (bootstrap una vez)
- ArgoCD lee de `belo-helm-charts` — el commit del pipeline dispara el sync

### Lo que es específico de EKS y necesita adaptarse para k3d:

| Componente EKS | Adaptación k3d |
|---|---|
| StorageClass `gp3` (EBS) | k3d local-path provisioner |
| ALB Controller | No aplica |
| Ingress nginx | Mismo, debería funcionar |
| Node taints/labels role=cicd/stateless/statefulls | k3d node labels |
| IAM/IRSA | No aplica |
| PVCs 2Gi gp3 source + 1Gi gp3 gitops | Local-path PVCs |
| EventListener expuesto vía ALB | Port-forward o NodePort local |

### Repos involucrados:

- `belo-helm-charts`: https://github.com/Valentino-33/belo-helm-charts (chart + values + pipeline tasks)
- `gitops-files`: https://github.com/Valentino-33/gitops-files (Application CRs de ArgoCD)
- `webserver-api01`: https://github.com/Valentino-33/webserver-api01 (Python FastAPI)
- `webserver-api02`: https://github.com/Valentino-33/webserver-api02 (Python FastAPI)

### Workspace local:

`C:\Users\tadeo\OneDrive\Escritorio\belochallenge\` — todos los repos viven ahí como hermanos.

---

## LO QUE NECESITO QUE IMPLEMENTES

### 1. Script de creación del cluster k3d

Comando `k3d cluster create` con:
- 3 nodos que simulen la topología: cicd (con taint `workload=cicd:NoSchedule`), stateless, statefulls
- Port mappings para acceder al EventListener localmente (webhook desde GitHub necesita URL pública)
- Configuración del load balancer interno de k3d

### 2. StorageClass y PVCs

- Reemplazar `gp3` con `local-path` (k3d incluye rancher/local-path-provisioner por defecto)
- Actualizar `trigger-template.yaml`: los dos PVCs (`source` 2Gi y `gitops` 1Gi) deben usar `local-path`
- Verificar que el local-path provisioner está activo

### 3. Registry (elegir una opción y justificar)

**Opción A:** Mantener Docker Hub (funciona sin cambios si hay internet)
**Opción B:** k3d registry local (`k3d registry create`) para builds offline más rápidos

Si elegís registry local: actualizar la construcción de `image-full` en `trigger-template.yaml`
y el destino en `task-build-kaniko.yaml`.

### 4. Exposición del EventListener para webhooks de GitHub

En EKS el EventListener llega vía ALB. En local necesito:
- Elegir entre: NodePort del Service, port-forward, o tool de tunnel (ngrok / smee.io)
- Si ngrok/smee: cómo configurar la GitHub webhook URL temporal
- El EventListener Service ya existe en `event-listener.yaml` — ver cómo está definido
  y proponer el cambio mínimo

### 5. Namespaces

Crear: `dev`, `staging`, `prod`, `testing`, `lab` (apps), `tekton-pipelines` (Tekton),
`argocd` (ArgoCD), `argo-rollouts` (Rollouts)

### 6. Instalación de componentes (en orden)

```
kubectl apply  →  Tekton Pipelines + Triggers + Interceptors
helm install   →  ArgoCD
helm install   →  ArgoRollouts
helm install   →  nginx Ingress
```

Proporcionar los comandos exactos con las versiones o channels estables.

### 7. Application CRs de ArgoCD (gitops-files)

Verificar que los `valueFiles` con paths relativos funcionen con la estructura actual:

```yaml
path: charts-core/pythonapps
helm:
  valueFiles:
    - ../../values-apps-files/webserver-api01/build-time/app-values.yaml
    - ../../values-apps-files/webserver-api01/values-dev-webserver-api01.yaml
```

Si hay algún problema con el path relativo en el contexto de ArgoCD local, proponer fix.

### 8. Secretos

Comandos para crear en k3d (namespace `tekton-pipelines`):

```bash
# Docker Hub
kubectl create secret generic dockerhub-credentials \
  --from-file=.dockerconfigjson=$HOME/.docker/config.json \
  -n tekton-pipelines

# GitHub PAT con write access a belo-helm-charts
kubectl create secret generic gitops-github-token \
  --from-literal=token=<PAT> \
  -n tekton-pipelines
```

### 9. Desplegar el chart pythonapps en k3d

Comando para que ArgoCD sincronice la app `webserver-api01-dev` desde `belo-helm-charts`.
Incluir el Application CR de ejemplo adaptado para k3d (sin ALB, sin hostname real).

### 10. Checklist de validación end-to-end

Pasos para verificar que el pipeline completo funciona:

```
[ ] k3d cluster running con 3 nodos (labels y taint correctos)
[ ] Tekton Pipelines + Triggers instalados
[ ] ArgoCD instalado y apuntando a belo-helm-charts
[ ] ArgoRollouts instalado
[ ] nginx Ingress instalado
[ ] Secretos creados
[ ] helm install del chart pythonapps (o ArgoCD sync)
[ ] EventListener escuchando (kubectl get el -n tekton-pipelines)
[ ] Webhook de GitHub configurado apuntando al tunnel
[ ] git tag dev/rollingupdate/v0.1.0 && git push origin dev/rollingupdate/v0.1.0
[ ] PipelineRun creado automáticamente
[ ] Stage 1 (clone) ✓
[ ] Stage 2 (build-push) ✓
[ ] Stage 3 (bump-gitops) ✓ — commit visible en belo-helm-charts
[ ] Stage 4 (wait-argocd) ✓ — ArgoCD sincronizó
[ ] Stage 5 (load-test) ✓ — outcome emitido
[ ] Stage 6 (promote-rollback) ✓ — rollout completado
```

---

## RESTRICCIONES

- La lógica de los 6 stages NO cambia — solo cambia la capa de infraestructura
- `bump-gitops` debe seguir commiteando a `belo-helm-charts` con el path exacto:
  `values-apps-files/<app>/values-<env>-<app>.yaml`
- La topología invariante (stable+preview siempre) debe preservarse
- La strategy-per-deploy (del tag) debe preservarse

## ENTREGABLES ESPERADOS

1. Script o Makefile targets para crear el cluster k3d
2. `trigger-template.yaml` actualizado con StorageClass `local-path`
3. Decisión y setup del registry (Docker Hub vs local)
4. Método de exposición del EventListener con instrucciones
5. Comandos de instalación de todos los componentes en orden
6. Application CR de ejemplo adaptado para k3d
7. Checklist de validación paso a paso
8. Tabla clara de qué cambia vs. qué queda igual respecto al modelo EKS
