# Plataforma EKS + GitOps + CI/CD

Stack completo para correr dos APIs en Kubernetes con estrategias de deployment
**Blue/Green** y **Canary**, pipelines CI/CD con Tekton + ArgoCD + ArgoRollouts,
observabilidad con EFK y Prometheus/Grafana, y autenticación contra IAM.

Este repo concentra la infraestructura como código (Terraform), los manifiestos
de cluster y la documentación.

## Mapa de repos

| Repo | Contenido |
|------|-----------|
| **tochallenge-belo** *(este)* | Terraform, addons, Makefile, docs |
| [webserver-api01](https://github.com/Valentino-33/webserver-api01) | API en Python, scripts k6 (`src/loadtest/`) |
| [webserver-api02](https://github.com/Valentino-33/webserver-api02) | API en Python, scripts k6 (`src/loadtest/`) |
| [belo-helm-charts](https://github.com/Valentino-33/belo-helm-charts) | Chart `pythonapps` + tasks Tekton + values por app/ambiente |
| [gitops-files](https://github.com/Valentino-33/gitops-files) | Applications de ArgoCD por ambiente |
| [users-managment-aws](https://github.com/Valentino-33/users-managment-aws) | aws-auth, RBAC, IRSA, templates de usuarios y grupos, archivos OIDC |

## Documentación

- **[ROADMAP.md](./ROADMAP.md)** — guía paso a paso del despliegue completo en AWS.
- **[COSTS.md](./COSTS.md)** — desglose de costos en AWS, fuentes de precios y tácticas para bajar la factura.
- **[docs/architecture.md](./docs/architecture.md)** — diagramas de la infra, del cluster y del pipeline CI/CD.
- **[docs/dns-tls-future.md](./docs/dns-tls-future.md)** — integración futura de Route53 / Cloudflare y certificados ACM.

## Tooling esperado

| Herramienta | Versión mínima | Para qué |
|-------------|----------------|----------|
| Terraform   | 1.6.x          | IaC de toda la infra AWS |
| AWS CLI     | v2             | Auth y operaciones puntuales |
| kubectl     | 1.30           | Misma minor que el cluster EKS |
| Helm        | 3.14+          | Instalar addons |
| eksctl      | 0.180+         | Solo para asociar OIDC provider rápido |
| Docker      | 24+            | Build de imágenes en local |
| jq, yq      | recientes      | Procesar JSON/YAML en scripts |

## Quick start

### En AWS

```bash
make tf-init          # init del backend Terraform
make tf-plan          # ver qué se va a crear
make tf-apply         # crear la infra (toma ~15-20 min por EKS)
make kubeconfig       # bajar kubeconfig al ~/.kube/config
make addons           # instalar ALB Controller, nginx, ArgoCD, Tekton...
make tf-destroy       # bajar TODO (importante para no acumular costos)
```

Para entender qué hace cada uno de esos targets internamente, leer el
[ROADMAP.md](./ROADMAP.md) — está armado de modo que cada `make`
corresponde a una fase reproducible a mano si se quiere validar paso a paso.

## Estado del entregable

Este repo se desarrolla en fases. El estado actual de cada componente queda
trackeado en el `ROADMAP.md` con checkboxes. Antes de tocar Terraform, leer al
menos las secciones de "Prerrequisitos" y "Fase 1" del roadmap para evitar
levantar costo accidentalmente.

## Decisiones de diseño relevantes

- **Región:** `us-east-1`. Es la más barata de AWS, tiene catálogo completo de
  servicios y los add-ons más maduros. Si después se decide moverlo más cerca
  (sa-east-1 desde Argentina), el cambio es una variable de Terraform.
- **Versión EKS:** 1.30. Está en standard support hasta noviembre 2026, lo que
  evita el costo de "extended support" ($0.10/h vs $0.60/h, 6× más caro).
- **Karpenter en lugar de Cluster Autoscaler:** decisión del challenge.
  Karpenter elige instance type según las pods pendientes y consolida nodos
  más agresivamente, lo que baja costo en escenarios spiky.
- **Ingress Controller dual:** ALB Controller para servicios públicos
  (TLS terminación en ALB de AWS) + nginx Ingress para tráfico interno y para
  routing canary fino — nginx soporta `nginx.ingress.kubernetes.io/canary` que
  ArgoRollouts usa nativamente para estrategia Canary.
- **Imágenes:** Docker Hub. Si después se quiere mover a ECR, es cambiar
  registry en los pipelines y agregar IRSA para pull. Los Dockerfiles no cambian.
- **Strategy por tag, no por app:** la misma app puede desplegarse con BlueGreen
  a production, Canary a staging y RollingUpdate a dev. La strategy se codifica
  en el tag Git (`<env>/<strategy>/<semver>`) y el pipeline la escribe en el
  values file del ambiente antes de que ArgoCD sincronice. Ver `ROADMAP.md §7`
  y `belo-helm-charts/README.md` para el detalle completo.
- **Topología de red invariante:** los Services e Ingresses `stable` y `preview`
  existen siempre para cada app, independientemente de la strategy activa. Esto
  evita que cambiar de BlueGreen a RollingUpdate entre deploys destruya los
  Services y genere downtime transitorio.
