# Roadmap de despliegue

Esta es la guía que seguís para levantar todo el stack de cero. Está pensada
para ejecutar a mano fase por fase la primera vez (así verificás que todo
funciona y entendés qué quedó desplegado), y después automatizado vía el
`Makefile` cuando lo conozcas.

> **Antes de arrancar:** todos los comandos `make` se corren desde la **raíz
> del repo** (donde está el `Makefile`), nunca desde adentro de
> `terraform/envs/dev` ni de un subdirectorio. Si ves un `cd` en algún paso,
> es para entrar a otro repo o para validar algo a mano — los `make` siempre
> arrancan desde root.

> Cada fase tiene **prerrequisitos**, **pasos**, **verificación** y un
> apartado de **rollback** cuando aplica. Los checkboxes son para que vayas
> tildando lo que ya validaste.

---

## Prerrequisitos generales

- [ ] Cuenta de AWS con permisos de Administrator (o al menos los de IAM, EC2,
      EKS, VPC, ELB, EBS y S3). Si la cuenta es compartida, usar un
      perfil dedicado en `~/.aws/credentials`.
- [ ] AWS CLI configurada: `aws sts get-caller-identity` te tiene que devolver
      tu identidad.
- [ ] Bucket de S3 + tabla DynamoDB para el remote state de Terraform. Si no
      existen, los crea el target `make tf-bootstrap`. **Importante:** este
      bucket no se destruye nunca con `tf destroy` para evitar perder estado.
- [ ] Cuenta de Docker Hub con un access token para que Tekton/Kaniko pushee
      imágenes. Guardar el token en SSM Parameter Store, no en el repo.
- [ ] Una clave SSH agregada a tu cuenta de GitHub (para webhooks y para que
      Tekton clone los repos privados si los hacés privados).
- [ ] Dominio (opcional para esta etapa). Si no tenés, dejá los hosts apuntando
      al DNS público del ALB hasta que se integre Route53/Cloudflare.

> Si vas a hacer **solo la versión local con k3d**, saltá a la **Fase 8**.
> Igual leete los Prerrequisitos de allá.

---

## Fase 1 — Infra base con Terraform

Salida: VPC, subnets, NAT, ALB shell (lo crea el ALB Controller después),
EKS, node group con un nodo `statefulls`, Karpenter, EBS de 20GB para el
nodo statefull.

### Prerrequisitos

- [ ] Terraform 1.6+
- [ ] Variables completadas en `terraform/envs/dev/terraform.tfvars`
      (region, cluster name, account id, dockerhub user, etc.)

### Pasos

> **Importante:** todos los `make` se corren desde **la raíz del repo**
> (donde está el `Makefile`), no desde dentro de `terraform/envs/dev`.
> Cada target ya hace el `cd` interno al directorio que necesita.

```bash
# Desde la raíz del repo:

# 1. Copiar y editar los archivos de configuración
cp terraform/bootstrap/terraform.tfvars.example terraform/bootstrap/terraform.tfvars
cp terraform/envs/dev/backend.hcl.example       terraform/envs/dev/backend.hcl
cp terraform/envs/dev/terraform.tfvars.example  terraform/envs/dev/terraform.tfvars
# Editar los tres archivos (ver "Variables a editar" abajo)

# 2. Crear bucket S3 + tabla DynamoDB para el state remoto (UNA SOLA VEZ por cuenta)
make tf-bootstrap

# 3. Inicializar el backend del ambiente dev
make tf-init

# 4. Ver qué se va a crear
make tf-plan

# 5. Aplicar (toma 15-20 minutos por EKS)
make tf-apply
```

### Variables a editar antes del paso 2

| Archivo | Qué editar |
|---|---|
| `terraform/bootstrap/terraform.tfvars` | `state_bucket_name` — tiene que ser único en TODO AWS. Recomendado: `belo-challenge-tfstate-<tu-account-id>` |
| `terraform/envs/dev/backend.hcl` | `bucket` — el mismo nombre que arriba |
| `terraform/envs/dev/terraform.tfvars` | (opcional) cambiar región, restringir CIDR de la API, etc.

> Si preferís correr Terraform a mano sin el Makefile (útil para debuggear),
> entrá a `terraform/envs/dev/` y corré `terraform init -backend-config=backend.hcl`,
> después `terraform plan` y `terraform apply`. El `Makefile` hace exactamente eso.

El apply tarda **15 a 20 minutos** porque EKS levanta su control plane y eso es
lo que más demora. Mientras corre podés ir leyendo la **Fase 2**.

### Verificación

```bash
# Confirmar que el cluster esté ACTIVE
aws eks describe-cluster --name belo-challenge-dev --query 'cluster.status'

# Bajar kubeconfig
aws eks update-kubeconfig --name belo-challenge-dev --region us-east-1

# Ver los 3 nodos
kubectl get nodes -L role
# Esperado:
# NAME             STATUS   ROLES    AGE   VERSION   ROLE
# ip-10-0-...      Ready    <none>   3m    1.30      statefulls
# ip-10-0-...      Ready    <none>   3m    1.30      stateless
# ip-10-0-...      Ready    <none>   3m    1.30      stateless
```

### Montar el EBS en el nodo statefull (paso a paso manual)

Terraform crea el volumen y lo attachea al nodo, pero **no lo monta** dentro
del filesystem. Esto se puede hacer de dos formas: con un user_data al lanzar
el nodo (automático, recomendado para prod) o a mano la primera vez (didáctico,
sirve para validar el procedimiento).

**A mano**, conectándose por SSM Session Manager:

```bash
# 1. Conectarse al nodo statefull
NODE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:role,Values=statefulls" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
aws ssm start-session --target $NODE_ID

# 2. Identificar el dispositivo (usualmente /dev/nvme1n1 en t3.large)
sudo lsblk

# 3. Formatear (solo la primera vez!)
sudo mkfs -t xfs /dev/nvme1n1

# 4. Crear punto de montaje y montar
sudo mkdir -p /mnt/statefull
sudo mount /dev/nvme1n1 /mnt/statefull

# 5. Persistir en /etc/fstab para que sobreviva reinicios
UUID=$(sudo blkid -s UUID -o value /dev/nvme1n1)
echo "UUID=$UUID /mnt/statefull xfs defaults,nofail 0 2" | sudo tee -a /etc/fstab

# 6. Symlink que esperan las apps statefull
sudo mkdir -p /var/lib/elasticsearch /var/lib/prometheus
sudo ln -s /mnt/statefull/elasticsearch /var/lib/elasticsearch
sudo ln -s /mnt/statefull/prometheus    /var/lib/prometheus
```

> **Para automatizar** este procedimiento, lo mismo va dentro del campo
> `user_data` del launch template del node group. Ver
> `terraform/modules/eks-nodes/templates/statefull-bootstrap.sh.tpl`.

### Rollback

```bash
# Si algo salió mal, destruir y volver a empezar
terraform destroy
```

> El destroy puede fallar si quedan ALB o ENI huérfanos creados por el ALB
> Controller. Si pasa, ir a EC2 → Network Interfaces y borrarlas a mano. Es
> un dolor conocido de EKS.

---

## Fase 2 — Acceso al cluster, RBAC e IAM

Salida: dos grupos (`develop` e `infra`), dos usuarios IAM de ejemplo, el
`aws-auth` configmap actualizado, ClusterRoles y ClusterRoleBindings para los
permisos descritos en el challenge, y los archivos plantilla para crear más
usuarios/grupos a futuro.

Todo este código vive en el repo
[users-managment-aws](https://github.com/Valentino-33/users-managment-aws).

### Pasos

```bash
git clone https://github.com/Valentino-33/users-managment-aws
cd users-managment-aws

# 1. Crear los usuarios IAM y los grupos
terraform -chdir=iam apply

# 2. Aplicar el aws-auth configmap (mapeo IAM → grupo K8s)
kubectl apply -f rbac/aws-auth.yaml

# 3. Aplicar los ClusterRoles y bindings
kubectl apply -f rbac/clusterroles/
kubectl apply -f rbac/bindings/
```

### Verificación

Loguearse como un usuario del grupo `develop`:

```bash
# Cambiar de profile en AWS CLI
export AWS_PROFILE=dev-user-01
aws eks update-kubeconfig --name belo-challenge-dev --region us-east-1 --alias dev

kubectl --context dev get pods -A          # debería listar todo
kubectl --context dev get secrets -A       # debería fallar con "forbidden"
```

Lo mismo con un usuario del grupo `infra` debería tener acceso completo.

### Para crear nuevos usuarios o grupos a futuro

Hay dos plantillas listas:

- `templates/new-user.tf.template` — copiar a `iam/users/<nombre>.tf` y completar
  los placeholders.
- `templates/new-group.yaml.template` — copiar a `rbac/clusterroles/<nombre>.yaml`
  y editar las reglas.

Cada vez que se agrega un usuario o grupo, actualizar `aws-auth.yaml` con el
nuevo mapeo y aplicarlo. **El `aws-auth` no se debe romper jamás** — antes de
aplicar, validar con `kubeval` y mantener un backup en otra branch.

### OIDC para futuro

Los archivos para integrar OIDC (con Cognito, Okta, Auth0 o Google) están en
`oidc/` con todo armado pero comentado. Cuando se quiera activar:

1. Crear el OIDC provider en AWS IAM (`aws iam create-open-id-connect-provider`).
2. Editar `oidc/cluster-config-patch.yaml` con el issuer y clientId reales.
3. Aplicar el patch al cluster: `eksctl utils associate-iam-oidc-provider`.
4. Modificar los ClusterRoleBindings para usar `Group: oidc:<grupo>` en lugar
   de `Group: <grupo>` (los archivos `*-oidc.yaml` ya tienen ese formato).

---

## Fase 3 — Addons del cluster

Salida: ALB Controller, nginx Ingress, Karpenter (su parte de software, ya
que el rol IAM lo crea Terraform), ArgoCD, ArgoRollouts, Tekton + Triggers,
TestKube, EFK, Prometheus, Grafana, Headlamp, Metrics Server (para HPA), VPA.

Todos los addons se instalan vía Helm. La lista completa y sus values están en
`helm/addons/`. La instalación está scripteada en `make addons`, pero para
entenderla, esto es lo que hace por debajo:

```bash
# Metrics server (necesario para HPA)
helm upgrade --install metrics-server metrics-server/metrics-server \
  -n kube-system

# VPA
helm upgrade --install vpa fairwinds-stable/vpa -n kube-system

# Karpenter
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  -n karpenter --create-namespace \
  -f helm/addons/karpenter/values.yaml

# ALB Controller
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  -f helm/addons/alb-controller/values.yaml

# nginx Ingress (interno y para canary routing)
helm upgrade --install nginx-ingress ingress-nginx/ingress-nginx \
  -n ingress-nginx --create-namespace \
  -f helm/addons/nginx-ingress/values.yaml

# ArgoCD
helm upgrade --install argocd argo/argo-cd \
  -n argocd --create-namespace \
  -f helm/addons/argocd/values.yaml

# ArgoRollouts
helm upgrade --install argo-rollouts argo/argo-rollouts \
  -n argo-rollouts --create-namespace

# Tekton Pipelines + Triggers
kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml
kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/release.yaml
kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/interceptors.yaml

# TestKube
helm upgrade --install testkube testkube/testkube \
  -n testkube --create-namespace \
  -f helm/addons/testkube/values.yaml

# EFK (Elasticsearch va al nodo statefulls vía nodeSelector)
helm upgrade --install elasticsearch elastic/elasticsearch \
  -n logging --create-namespace \
  -f helm/addons/elasticsearch/values.yaml
helm upgrade --install fluent-bit fluent/fluent-bit \
  -n logging \
  -f helm/addons/fluent-bit/values.yaml
helm upgrade --install kibana elastic/kibana \
  -n logging \
  -f helm/addons/kibana/values.yaml

# Prometheus + Grafana (también al nodo statefulls)
helm upgrade --install kube-prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  -f helm/addons/kube-prometheus/values.yaml

# Headlamp (UI dashboard)
helm upgrade --install headlamp headlamp/headlamp \
  -n kube-system \
  -f helm/addons/headlamp/values.yaml
```

### Acceso al dashboard Headlamp

Después de instalar, dos formas:

**Local (port-forward, lo más rápido):**
```bash
kubectl port-forward -n kube-system svc/headlamp 8080:80
# Abrir http://localhost:8080
```

**Expuesto vía Ingress (cuando ya haya DNS):**
```bash
kubectl apply -f manifests/headlamp/ingress.yaml
# Luego acceder a https://headlamp.<dominio>
```

Para loguearse, generar un token con la SA de Headlamp:

```bash
kubectl -n kube-system create token headlamp --duration=24h
```

Pegarlo en el formulario de login.

### Verificación de toda la fase

```bash
kubectl get pods -A | grep -v Running
# Idealmente: solo los Completed de Jobs
```

---

## Fase 4 — Apps (webserver-api01 y webserver-api02)

Salida: dos Helm charts publicados con las apps en Python, sus Dockerfiles,
y la carpeta `loadtest/` con los k6 scripts asociados a cada estrategia.

El código vive en los repos
[webserver-api01](https://github.com/Valentino-33/webserver-api01) y
[webserver-api02](https://github.com/Valentino-33/webserver-api02).

Estructura de cada repo:

```
webserver-apiNN/
├── Dockerfile
├── pyproject.toml          # FastAPI + uvicorn + structlog + prometheus_client
├── app/
│   ├── main.py             # endpoints /, /health, /version, /metrics
│   ├── logging_config.py   # 5 levels (info, debug, error, warn, trace)
│   └── ...
├── chart/                  # Helm chart de la app
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/
│       ├── rollout.yaml    # Rollout de ArgoCD (NO Deployment)
│       ├── service.yaml
│       ├── ingress.yaml
│       ├── servicemonitor.yaml
│       └── hpa.yaml
├── loadtest/
│   ├── smoke.js
│   ├── load-bluegreen.js   # solo en api01
│   ├── load-canary.js      # solo en api02
│   └── README.md
└── .tekton/
    └── pipelinerun.yaml    # template del PipelineRun que dispara Tekton
```

### Build local de la imagen (smoke test)

```bash
cd webserver-api01
docker build -t local/api01:test .
docker run --rm -p 8000:8000 local/api01:test

# En otra consola
curl localhost:8000/version
curl localhost:8000/api01/metrics
```

### Push manual a Docker Hub

Esto se hace una vez para tener una imagen base; después lo automatiza
Tekton/Kaniko en cada commit.

```bash
docker tag local/api01:test docker.io/<tu-user>/api01:0.0.1
docker push docker.io/<tu-user>/api01:0.0.1
```

---

## Fase 5 — GitOps (ArgoCD apps por ambiente)

Salida: cuatro repos GitOps (test, develop, staging, production), cada uno
con sus aplicaciones de ArgoCD apuntando a las charts de las apps.

Estructura del repo
[gitops-files](https://github.com/Valentino-33/gitops-files):

```
gitops-files/
├── core/
│   └── apps-of-apps.yaml       # ArgoCD Application root
├── test/
│   ├── api01/values.yaml
│   └── api02/values.yaml
├── develop/
│   ├── api01/values.yaml
│   └── api02/values.yaml
├── staging/
│   └── ...
└── production/
    └── ...
```

### Bootstrap en el cluster

```bash
# Apuntar ArgoCD al repo (la primera vez)
kubectl apply -f manifests/argocd/bootstrap.yaml

# Validar que ArgoCD se sincronizó
kubectl -n argocd get applications
```

A partir de acá, **todo cambio de imagen, replicas o config va por commit al
repo gitops-files**, no por kubectl. Es la regla del juego de GitOps.

---

## Fase 6 — CI/CD con Tekton

Salida: EventListener escuchando webhooks de GitHub, Pipeline que cubre
Blue/Green, Canary y RollingUpdate según el `tag annotated`, y los stages
de k6 integrados.

### El Pipeline en alto nivel

```
git tag (annotated) "deploy:<ambiente> strategy:<estrategia>"
        │
        ▼
GitHub webhook → Tekton EventListener
        │
        ▼
PipelineRun con PVC efímero de 1GB
        │
        ▼
┌─────────────────────────────────────┐
│ Stage 1: clone-repo                 │
├─────────────────────────────────────┤
│ Stage 2: build-image (Kaniko)       │
├─────────────────────────────────────┤
│ Stage 3: push-to-dockerhub          │
├─────────────────────────────────────┤
│ Stage 4: bump-helm-values           │
│   (commit al gitops-files)          │
├─────────────────────────────────────┤
│ Stage 5: wait-for-argocd-sync       │
├─────────────────────────────────────┤
│ Stage 6: load-test (TestKube + k6)  │
│   ┌───────────────────────────┐     │
│   │ Si BlueGreen:             │     │
│   │   k6 contra el preview    │     │
│   │   svc                     │     │
│   │ Si Canary:                │     │
│   │   k6 después del 5%       │     │
│   │   y después del 25%       │     │
│   │ Si RollingUpdate:         │     │
│   │   k6 smoke al final       │     │
│   └───────────────────────────┘     │
├─────────────────────────────────────┤
│ Stage 7: promote-or-rollback        │
│   (kubectl argo rollouts ...)       │
└─────────────────────────────────────┘
```

### Cómo se dispara

El developer hace:

```bash
git tag -a deploy:production -m "strategy:BlueGreen" v1.4.0
git push origin v1.4.0
```

El interceptor lee la annotation y setea las variables del Pipeline. Si solo
escribe `git tag v1.4.0` sin annotation, default = RollingUpdate.

Ver `manifests/tekton/` para los archivos completos. Los Pipelines son CRDs
reutilizables — la misma definición sirve para api01 y api02 cambiando solo
los params.

### Ramas según strategy (lógica del Pipeline)

| Strategy | Qué pasa |
|---|---|
| **BlueGreen** + production | Deploy de "green", k6 sobre green aislado, si pasa → switch traffic, si no → destruir green |
| **Canary** + production    | Deploy con 5% → k6 → 25% → k6 → 50% → k6 → 100%. Cualquier fallo dispara rollback automático |
| **RollingUpdate** (o tag sin strategy) | Default. Reemplazo progresivo, k6 smoke al final |

### Verificación

```bash
# Que el EventListener esté escuchando
kubectl -n tekton get el

# Disparar manualmente un PipelineRun (sin webhook) para testear
tkn pipeline start app-deploy-pipeline \
  -p git-url=https://github.com/Valentino-33/webserver-api01 \
  -p git-revision=main \
  -p strategy=Canary \
  -p environment=develop \
  -w name=workspace,emptyDir="size=1Gi"
```

---

## Fase 7 — Observabilidad

Ya quedó instalado en la Fase 3. Acá solo se agregan los dashboards y se
valida que los logs y métricas fluyan.

### Logs (EFK)

Fluent-bit corre como DaemonSet, mandando logs al pod de Elasticsearch que
está pinneado al nodo `statefulls`. Kibana se accede vía port-forward o
Ingress (mismo patrón que Headlamp).

```bash
kubectl port-forward -n logging svc/kibana 5601:5601
# http://localhost:5601
```

### Métricas (Prometheus + Grafana)

Las apps exponen `/api01/metrics` y `/api02/metrics`. Hay un `ServiceMonitor`
para que Prometheus las scrappee automáticamente.

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
# http://localhost:3000
# user: admin
# pass: kubectl get secret -n monitoring kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d
```

Dashboards a importar (los IDs son los públicos de Grafana):

- **315** — Kubernetes Cluster (CPU, memoria, network)
- **6417** — Kubernetes Cluster (alternativa más detallada)
- **15760** — ArgoCD overview
- Custom: `helm/addons/grafana/dashboards/apps-rollouts.json` (creado por nosotros, muestra tasa de error y p95/p99 por versión durante un rollout)

### Logs estructurados de las apps

Cada app loguea con structlog en formato JSON, con estos niveles:

- `trace` — debug ultra detallado, solo en dev
- `debug` — flujo interno
- `info` — eventos normales (request recibido, response enviado)
- `warn` — algo raro pero recuperable
- `error` — fallo

Configurable vía variable de entorno `LOG_LEVEL`.

---

## Fase 8 — Versión local con k3d

Para correr todo el stack en tu máquina sin AWS. Útil para iterar pipelines
sin gastar y para hacer la POC si el costo en AWS no es viable.

### Prerrequisitos

- [ ] Docker Desktop o Docker Engine
- [ ] k3d 5.6+
- [ ] kubectl, helm
- [ ] Al menos 8GB de RAM disponibles para los contenedores

### Pasos

```bash
make k3d-up
```

Ese target hace:

1. Crea un cluster k3d con 1 server + 3 agents.
2. Pone label `role=statefulls` en uno de los agents (el primero).
3. Crea un volumen Docker de 20GB y lo monta en ese nodo (equivalente al EBS).
4. Instala todos los addons con los mismos values que en AWS, salvo:
   - **ALB Controller:** se reemplaza por Traefik (que viene con k3d) +
     un Service NodePort.
   - **Karpenter:** se desactiva (no aplica fuera de AWS).
   - **NAT Gateway / VPC:** Docker network nativa.
5. Levanta ArgoCD apuntando al mismo repo gitops-files (sí, podés tener
   ambientes "local" además de los cuatro de AWS).
6. Levanta Tekton + TestKube igual que en AWS.
7. Hace port-forward a los servicios principales y los expone en:
   - ArgoCD → http://localhost:8080
   - Headlamp → http://localhost:8081
   - Grafana → http://localhost:8082
   - Kibana → http://localhost:8083

### Diferencias funcionales con AWS

| Componente | AWS | k3d |
|---|---|---|
| Ingress externo | ALB | Traefik (NodePort) |
| Storage statefull | EBS | Docker volume |
| DNS público | Route53 | /etc/hosts local |
| TLS | ACM cert | Self-signed con cert-manager |
| Logs externos | CloudWatch | Solo EFK interno |
| Autoscaling de nodos | Karpenter | Sin autoscaling, capacity fija |

Lo que **sí funciona idéntico:** los Helm charts de las apps, los manifestos
de Rollout, los Pipelines de Tekton, los scripts de k6, las queries de
Prometheus, los dashboards. Eso es justamente lo lindo de Kubernetes —
mismo manifiesto, distinta infra debajo.

### Bajar todo

```bash
make k3d-down
```

---

## Apéndice A — Troubleshooting frecuente

### "Terraform apply falla en el destroy del NAT Gateway"

Esperar 5 minutos y reintentar. Es un timing issue conocido entre el
release de la EIP y la baja del NAT.

### "El ALB Controller no crea el Load Balancer"

Casi siempre es un tema de IRSA mal configurado. Validar:

```bash
kubectl -n kube-system describe sa aws-load-balancer-controller
# El annotation eks.amazonaws.com/role-arn debe apuntar al rol que creó Terraform
```

### "Karpenter no levanta nodos cuando hay pods Pending"

Mirar los logs del controller:

```bash
kubectl -n karpenter logs -l app.kubernetes.io/name=karpenter
```

El error más común es que el `NodePool` o `EC2NodeClass` referencien un
subnet sin la tag correcta (`karpenter.sh/discovery=<cluster-name>`).

### "ArgoRollouts no respeta el peso del canary"

El `Rollout` tiene que apuntar a un `Service` que esté detrás del **nginx**
ingress, no del ALB. El ALB Controller no soporta canary nativo a este
nivel. Si cambiás el ingress, revisar también el `Rollout.spec.strategy.canary.trafficRouting`.

### "k6 dentro de TestKube no resuelve el endpoint de la app"

Asegurarse de pasarle el FQDN interno (`api01.apps.svc.cluster.local`) no
el dominio público. El k6 corre dentro del cluster.

---

## Apéndice B — Mapa de costos por fase

| Fase | Costo aproximado mensual (siempre prendido) | Notas |
|------|---------------------------------------------|-------|
| Fase 1 (infra base) | ~$200 | EKS + 3 nodos + NAT + ALB + EBS + IPs |
| Fases 2-7 (software) | $0 | Todo es OSS y corre dentro del cluster |
| **Total** | **~$200** | Ver [COSTS.md](./COSTS.md) para el detalle |

Si destruyas con `make tf-destroy` cuando no estás trabajando, el costo
real puede bajar a $20-40 USD/mes según el tiempo activo.
