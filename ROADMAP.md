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

## Convención de ambientes y comandos

Todos los targets del `Makefile` aceptan `ENV=<ambiente>` para apuntar al
directorio correcto. Los ambientes disponibles son:

| ENV | Propósito | State key en S3 |
|---|---|---|
| `dev` | Desarrollo activo, ciclos de apply/destroy frecuentes | `envs/dev/terraform.tfstate` |
| `testing` | CI de features, smoke tests de extremo a extremo | `envs/testing/terraform.tfstate` |
| `lab` | Investigación de nuevas features de infra | `envs/lab/terraform.tfstate` |
| `staging` | Validación pre-producción, config idéntica a prod | `envs/staging/terraform.tfstate` |
| `production` | Datos reales — apply con change management | `envs/production/terraform.tfstate` |

```bash
# Ejemplos:
make tf-plan ENV=dev        # plan para dev
make tf-apply ENV=staging   # apply para staging
make addons ENV=dev         # instalar addons en dev
```

> Si no pasás `ENV`, el default es `dev`. Todos los ejemplos del ROADMAP usan
> `ENV=dev` explícitamente para que sea claro — en la práctica podés omitirlo
> cuando estás en dev.

> **Después de un destroy:** siempre correr `make tf-reinit ENV=<env>` antes
> del próximo `make tf-plan`. El destroy invalida el `tfplan` binario y puede
> dejar el caché local de providers en un estado inconsistente.

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

---

## Fase 1 — Infra base con Terraform

> **Repo:** `tochallenge-belo/` | **Ejecutar desde:** raíz del repo (donde está el `Makefile`)
> **Comandos:** `make tf-* ENV=dev`

Salida: VPC, subnets, NAT, ALB shell (lo crea el ALB Controller después),
EKS con 3 nodos (stateless, statefulls, cicd), Karpenter IAM, EBS 20GB para
el nodo statefull.

### Prerrequisitos

- [ ] Terraform 1.6+
- [ ] Variables completadas en `terraform/envs/dev/terraform.tfvars`
      (region, cluster name, account id, dockerhub user, etc.)

### Pasos

```bash
# Todo desde la raíz de tochallenge-belo/ (donde está el Makefile).

# 1. Copiar y editar los archivos de configuración para el ambiente dev
cp terraform/bootstrap/terraform.tfvars.example terraform/bootstrap/terraform.tfvars
cp terraform/envs/dev/backend.hcl.example       terraform/envs/dev/backend.hcl
cp terraform/envs/dev/terraform.tfvars.example  terraform/envs/dev/terraform.tfvars
# Editar los tres archivos (ver "Variables a editar" abajo)

# 2. Crear bucket S3 + tabla DynamoDB para el state remoto — UNA SOLA VEZ por cuenta
#    (El bucket persiste entre destroy/apply y guarda el state de todos los ambientes)
make tf-bootstrap

# 3. Inicializar el backend del ambiente dev
make tf-init ENV=dev

# 4. Ver qué se va a crear
make tf-plan ENV=dev

# 5. Aplicar (toma 15-20 min por EKS)
make tf-apply ENV=dev

# ── Si ya aplicaste antes y destruiste (ciclo de demo) ──────────────────────
# El tfplan previo quedó inválido. Reiniciar antes de planear de nuevo:
make tf-reinit ENV=dev
make tf-plan ENV=dev
make tf-apply ENV=dev
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
# ip-10-0-...      Ready    <none>   3m    1.35      statefulls
# ip-10-0-...      Ready    <none>   3m    1.35      stateless
# ip-10-0-...      Ready    <none>   3m    1.35      cicd
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

> **Repo:** `users-managment-aws/` | **Ejecutar desde:** raíz de ese repo (donde está su `Makefile`)
> **Comandos:** `make iam-apply`, `make rbac-apply`, `make verify-developer`, `make verify-infra`

Salida: dos grupos (`develop` e `infra`), dos usuarios IAM de ejemplo, el
`aws-auth` configmap actualizado con `merge-aws-auth.sh` (no pisado directo),
`RBACDefinition` con rbac-manager para permisos diferenciados por namespace.

Todo este código vive en el repo
[users-managment-aws](https://github.com/Valentino-33/users-managment-aws).

### Prerrequisito de Fase 2

El cluster de la Fase 1 tiene que estar ACTIVE y kubeconfig configurado:

```bash
# Desde tochallenge-belo/
make kubeconfig ENV=dev
kubectl get nodes   # tiene que mostrar los 3 nodos Ready
```

### Pasos

```bash
# Clonar (o entrar si ya está clonado) al repo de auth
cd ../users-managment-aws    # desde belochallenge/ si los repos son hermanos

# 1. Crear usuarios IAM, grupos y roles en AWS
make iam-apply

# 2. Actualizar el aws-auth ConfigMap (merge seguro, no pisa lo existente)
make rbac-apply   # incluye el merge-aws-auth.sh y kubectl apply de los RBACDefinition

# 3. Verificar que los permisos están bien
make verify-developer   # debe listar pods pero fallar al pedir secrets
make verify-infra       # debe tener acceso completo
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

> **Repo:** `tochallenge-belo/` | **Ejecutar desde:** raíz del repo (donde está el `Makefile`)
> **Comandos:** `make addons ENV=dev` (o los `helm upgrade` individuales que se detallan abajo)
> **Prerequisito:** kubeconfig apuntando al cluster (`make kubeconfig ENV=dev`)

Salida: ALB Controller, nginx Ingress, Karpenter (su parte de software, ya
que el rol IAM lo crea Terraform), **rbac-manager** (operator necesario para
los `RBACDefinition` de la Fase 2), ArgoCD, ArgoRollouts, Tekton + Triggers,
TestKube, EFK, Prometheus, Grafana, Headlamp, Metrics Server (para HPA), VPA.

> **rbac-manager va PRIMERO.** Los `RBACDefinition` de la Fase 2 son CRDs que
> necesitan el operator instalado para existir. Si instalás los otros addons
> antes de rbac-manager, el `kubectl apply` de los bindings de la Fase 2 falla.

Todos los addons se instalan vía Helm. La lista completa y sus values están en
`helm/addons/`. La instalación está scripteada en `make addons ENV=dev`, pero
para entenderla (y poder correr pasos individualmente), esto es lo que hace
por debajo. Los repos de Helm se agregan una sola vez:

```bash
# Agregar repos de Helm (una sola vez en la máquina)
helm repo add fairwinds-stable  https://charts.fairwinds.com/stable
helm repo add metrics-server    https://kubernetes-sigs.github.io/metrics-server/
helm repo add eks               https://aws.github.io/eks-charts
helm repo add ingress-nginx     https://kubernetes.github.io/ingress-nginx
helm repo add argo              https://argoproj.github.io/argo-helm
helm repo add testkube          https://kubeshop.github.io/helm-charts
helm repo add elastic           https://helm.elastic.co
helm repo add fluent            https://fluent.github.io/helm-charts
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add headlamp          https://headlamp-k8s.github.io/headlamp/
helm repo update

# ── 1. rbac-manager (PRIMERO — los RBACDefinition de la Fase 2 necesitan este operator) ──
helm upgrade --install rbac-manager fairwinds-stable/rbac-manager \
  -n rbac-manager --create-namespace

# Esperar a que el operator esté Ready antes de continuar
kubectl -n rbac-manager rollout status deployment rbac-manager

# Aplicar los RBACDefinition de la Fase 2 (si el cluster se recreó)
# Ejecutar desde el repo users-managment-aws/
cd ../users-managment-aws && make rbac-apply && cd -

# ── 2. Resto de addons (desde tochallenge-belo/) ─────────────────────────────

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

## Fase 4 — Helm charts maestros (belo-helm-charts)

> **Repo:** `belo-helm-charts/` | **Ejecutar desde:** raíz de ese repo
> **Comandos:** `helm lint`, `helm template --dry-run`

Salida: repo `belo-helm-charts` con el chart `pythonapps` completamente
armado, verificado con `helm lint` y `helm template --dry-run`. Este chart
es el contrato entre el CI/CD y el GitOps — define qué templates usa cada
app y separa claramente qué es build-time de qué es runtime por ambiente.

El código vive en [belo-helm-charts](https://github.com/Valentino-33/belo-helm-charts).

### Estructura del repo

```
belo-helm-charts/
└── pythonapps/                          ← chart maestro, replicable (javaapps, goapps…)
    ├── Chart.yaml
    ├── values.yaml                      ← defaults para que el chart funcione standalone
    ├── templates/
    │   ├── rollout.yaml                 ← ArgoRollout parametrizado por strategy
    │   ├── service.yaml
    │   ├── ingress.yaml
    │   ├── servicemonitor.yaml
    │   ├── hpa.yaml
    │   └── pipeline-templates/          ← Tasks y Pipeline de Tekton para el stack Python
    │       ├── task-clone.yaml
    │       ├── task-build-kaniko.yaml
    │       ├── task-push-gitops.yaml
    │       ├── task-load-test.yaml      ← verifica si existen scripts k6; warning si no, nunca falla
    │       └── pipeline-pythonapps.yaml
    └── apps/
        ├── webserver-api01/
        │   ├── build-time/
        │   │   └── app.yaml             ← image_name, registry, repo_url, owner
        │   ├── dev/
        │   │   └── values-api01-dev.yaml
        │   ├── testing/
        │   │   └── values-api01-testing.yaml
        │   ├── lab/
        │   │   └── values-api01-lab.yaml
        │   ├── staging/
        │   │   └── values-api01-staging.yaml
        │   └── production/
        │       └── values-api01-production.yaml
        └── webserver-api02/
            └── (misma estructura)
```

### build-time vs. runtime — por qué separados

- **build-time** (`build-time/app.yaml`): registry, nombre de imagen, repo_url y
  owner. Cambia raramente — solo cuando se migra el registry o se hace un fork.
  Es metadata de la app, no del ambiente.
- **runtime por ambiente** (`<env>/values-<app>-<env>.yaml`): réplicas, recursos,
  strategy de deployment, hostname de Ingress, límites del HPA. Cambia seguido
  y de forma independiente por ambiente.

Los **pipeline-templates/** viven en `pythonapps/` porque son específicos del
stack tecnológico. Una app Java usaría `javaapps/pipeline-templates/` con un
task de Maven en lugar de pip. Los templates no son intercambiables entre stacks.

### Composición en el pipeline

```bash
helm template api01 belo-helm-charts/pythonapps/ \
  -f belo-helm-charts/pythonapps/apps/webserver-api01/build-time/app.yaml \
  -f belo-helm-charts/pythonapps/apps/webserver-api01/dev/values-api01-dev.yaml \
  --set image.tag=v1.4.0
```

### Verificación (dry-run antes de aplicar)

```bash
git clone https://github.com/Valentino-33/belo-helm-charts
cd belo-helm-charts

helm lint pythonapps/ \
  -f pythonapps/apps/webserver-api01/build-time/app.yaml \
  -f pythonapps/apps/webserver-api01/dev/values-api01-dev.yaml

helm template api01 pythonapps/ \
  -f pythonapps/apps/webserver-api01/build-time/app.yaml \
  -f pythonapps/apps/webserver-api01/dev/values-api01-dev.yaml \
  --set image.tag=v0.1.0 | kubectl apply --dry-run=client -f -
```

---

## Fase 5 — Apps Python (webserver-api01 y webserver-api02)

> **Repos:** `webserver-api01/` y `webserver-api02/` | **Ejecutar desde:** raíz de cada uno
> **Comandos:** `docker build`, `docker push`

Salida: código de las dos apps con Dockerfile, scripts de k6 en `loadtest/`,
y el template de PipelineRun en `.tekton/`. **No hay `chart/` adentro** —
los charts y templates de Tekton viven en `belo-helm-charts`.

Repos: [webserver-api01](https://github.com/Valentino-33/webserver-api01) y
[webserver-api02](https://github.com/Valentino-33/webserver-api02).

### Estructura de cada repo

```
webserver-apiNN/
├── Dockerfile
├── pyproject.toml          ← FastAPI + uvicorn + structlog + prometheus_client
├── app/
│   ├── main.py             ← endpoints /, /health, /version, /metrics
│   ├── logging_config.py   ← 5 niveles: trace, debug, info, warn, error
│   └── ...
├── loadtest/               ← scripts k6 opcionales; si no existen el pipeline sigue con warning
│   ├── smoke.js
│   ├── load-bluegreen.js   ← solo en api01 (BlueGreen pre-switch)
│   ├── load-canary.js      ← solo en api02 (después de cada step de promoción)
│   └── README.md
└── .tekton/
    └── pipelinerun.yaml    ← template del PipelineRun que dispara Tekton
```

> La presencia de `loadtest/` es opcional — el stage de load-test del Pipeline
> verifica si los archivos k6 existen antes de correrlos. Si no están, escribe
> un warning en el log del PipelineRun y continúa sin fallar. Esto permite que
> el pipeline funcione desde el primer commit sin tener tests de carga listos.

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

Una vez para tener imagen base; Tekton/Kaniko lo automatiza a partir de acá.

```bash
docker tag local/api01:test docker.io/valentinobruno/api01:0.0.1
docker push docker.io/valentinobruno/api01:0.0.1
```

---

## Fase 6 — GitOps por ambiente (gitops-files)

> **Repo:** `gitops-files/` | **Ejecutar desde:** raíz de ese repo para editar manifests;
> el bootstrap se aplica desde cualquier lugar con kubeconfig configurado
> **Comando de bootstrap:** `kubectl apply -f manifests/argocd/bootstrap.yaml` (desde `tochallenge-belo/`)

Salida: repo `gitops-files` con estructura apps-of-apps separada por ambiente.
Cada ambiente tiene su propio "core" de ArgoCD que apunta a los values en
`belo-helm-charts`. Los values no viven en `gitops-files` — ese repo solo
contiene Application resources de ArgoCD.

Repo: [gitops-files](https://github.com/Valentino-33/gitops-files).

### Estructura del repo

```
gitops-files/
├── apps-of-apps.yaml               ← Application raíz — bootstrap de ArgoCD
├── gitops-core-dev/
│   ├── webserver-api01.yaml        ← Application de ArgoCD para api01 en dev
│   └── webserver-api02.yaml
├── gitops-core-testing/
│   ├── webserver-api01.yaml
│   └── webserver-api02.yaml
├── gitops-core-lab/
│   └── ...
├── gitops-core-staging/
│   └── ...
└── gitops-core-production/
    └── ...
```

### Por qué gitops-core-$env en lugar de una carpeta plana

Tres motivos concretos:
1. **Disaster recovery selectivo**: si production explota, revertís solo el core
   de production sin tocar dev ni staging.
2. **RBAC granular en ArgoCD**: distintos equipos o bots de deploy pueden tener
   permiso de sync sobre distintos cores sin acceso cruzado.
3. **Auditoría por ambiente**: el historial de `gitops-core-production/` es el
   registro de cambios de producción — diff limpio y trazable.

### Cómo se ve cada Application

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: webserver-api01-dev
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/Valentino-33/belo-helm-charts
    targetRevision: main
    path: pythonapps
    helm:
      valueFiles:
        - apps/webserver-api01/build-time/app.yaml
        - apps/webserver-api01/dev/values-api01-dev.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: apps-dev
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

ArgoCD sincroniza directamente contra `belo-helm-charts`. El pipeline de Tekton
solo necesita commitear el nuevo tag de imagen en el values del ambiente
después de pushear la imagen a Docker Hub.

### Bootstrap en el cluster

```bash
# Apuntar ArgoCD al repo gitops-files (la primera vez)
kubectl apply -f manifests/argocd/bootstrap.yaml

# Validar que los cores se sincronizaron
kubectl -n argocd get applications
```

A partir de acá, **todo cambio de imagen, réplicas o config va por commit a
`belo-helm-charts/pythonapps/apps/<app>/<env>/`**, no por kubectl.

---

## Fase 7 — CI/CD con Tekton

> **Manifests de pipeline:** `belo-helm-charts/pythonapps/templates/pipeline-templates/`
> **Template de PipelineRun:** `.tekton/pipelinerun.yaml` en cada repo de app
> **Comandos de operación:** `tkn` CLI con kubeconfig del cluster activo
> **Disparo:** `git tag -a deploy:<env> -m "strategy:<BlueGreen|Canary|RollingUpdate>" <version>`

Salida: EventListener escuchando webhooks de GitHub, Pipeline que cubre
Blue/Green, Canary y RollingUpdate según el `tag annotated`, y los stages
de k6 integrados.

> **Nodo dedicado:** todos los PipelineRuns corren en el nodo con label
> `role=cicd` mediante toleration `workload=cicd:NoSchedule`. Los
> manifests en `pipeline-templates/` ya incluyen ese toleration — no hay
> que setearlo a mano. El nodo cicd es un t3.medium separado de los workers
> de aplicación, así un build pesado no impacta en la latencia de las apps.

> **Load tests opcionales:** el stage `load-test` verifica si los scripts
> k6 existen en `loadtest/` del repo de la app antes de correrlos. Si no
> están, loguea `WARN: no k6 scripts found, skipping load test stage` y
> continúa. El PipelineRun nunca falla por ausencia de scripts de carga.

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

## Fase 8 — Observabilidad

> **Ejecutar desde:** cualquier lugar con kubeconfig del cluster activo
> **Comandos:** `kubectl port-forward`, importación de dashboards en Grafana/Kibana

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

## Apéndice A — Troubleshooting frecuente

> **Referencia de fases:** Fase 1 Infra → Fase 2 Auth → Fase 3 Addons
> → Fase 4 Helm charts maestros → Fase 5 Apps Python → Fase 6 GitOps →
> Fase 7 Tekton CI/CD → Fase 8 Observabilidad.

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
| Fase 1 (infra base) | ~$210 | EKS + 3 nodos (1×t3.large + 2×t3.medium) + NAT + ALB + EBS + IPs |
| Fases 2-9 (software) | $0 | Todo es OSS y corre dentro del cluster |
| **Total** | **~$210** | Ver [COSTS.md](./COSTS.md) para el detalle |

> Los 3 nodos son ahora: `statefulls` (t3.large), `stateless` (t3.medium) y
> `cicd` (t3.medium). Un t3.medium extra vs. el setup anterior de 2×t3.medium
> resulta en el mismo costo — la diferencia es que ahora hay 1 worker de apps
> y 1 worker de CI/CD en lugar de 2 workers mixtos.

Si destruyas con `make tf-destroy` cuando no estás trabajando, el costo
real puede bajar a $20-40 USD/mes según el tiempo activo.
