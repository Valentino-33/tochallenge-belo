# Project Handoff — Belo Challenge

> Documento para retomar este proyecto en una nueva sesión (Claude Code, otro
> chat, o vos volviendo en una semana). Tiene todo el contexto necesario para
> que cualquiera arranque sin preguntar.

> **Workspace local:** `C:\Users\tadeo\OneDrive\Escritorio\belochallenge\`.
> Los 6 repos del proyecto viven todos como hermanos dentro de esa carpeta,
> así Claude Code los ve juntos al abrir el workspace.

---

## Qué es esto

Challenge técnico para una vacante en Belo. El alcance es armar una
plataforma completa sobre EKS con CI/CD GitOps, observabilidad, load
testing, dos APIs con estrategias de deployment Blue/Green y Canary, y una
versión paralela en k3d para correr local.

El challenge lo pensó el dueño (Valentino) en términos de arquitectura;
Claude está ayudando a materializarlo en código y documentación.

**Foco importante:** Valentino fue instruido por el equipo de Belo a
**pensar la solución con foco a llegar a producción en algún momento**. No
es solo una demo throwaway. Eso significa que cada vez que se toma un atajo
por costo o por tiempo, hay que dejarlo documentado como deuda técnica
explícita, no ocultarlo. Ver sección **"Path to production"** más abajo.

**Requisito tonal:** los entregables tienen que leerse como trabajo humano.
Documentación con asides, decisiones argumentadas, deuda técnica explícita.
Nada de listas-de-bullets-de-marketing.

---

## Repos del proyecto

| Repo | Estado | Contenido |
|---|---|---|
| [tochallenge-belo](https://github.com/Valentino-33/tochallenge-belo) | **Fase 1 mergeada + fixes locales del dueño** | Terraform: VPC, EKS, node groups, Karpenter IAM, ALB IRSA. Makefile, ROADMAP, COSTS, docs. **El dueño aplicó cambios locales** de versión de K8s y AMIs durante la ejecución exitosa — esos cambios son válidos y deben preservarse, no revertirse. |
| [users-managment-aws](https://github.com/Valentino-33/users-managment-aws) | **Fase 2 entregada y commiteada** | IAM users/groups/roles, RBAC, aws-auth merge script, templates, OIDC preparado. Probado con éxito en cluster levantado. |
| [webserver-api01](https://github.com/Valentino-33/webserver-api01) | Vacío | Próxima fase. API Python para Blue/Green |
| [webserver-api02](https://github.com/Valentino-33/webserver-api02) | Vacío | Próxima fase. API Python para Canary |
| [belo-helm-charts](https://github.com/Valentino-33/belo-helm-charts) | Vacío, sin diseñar todavía | **NUEVO repo agregado**. Chart maestro `pythonapps` reutilizable + `apps/<app>/app.yaml` build-time |
| [gitops-files](https://github.com/Valentino-33/gitops-files) | Vacío | Apps de ArgoCD por ambiente + values runtime por ambiente |

---

## Jerarquía de documentación (para no duplicar y no contradecirse)

```
tochallenge-belo/
├── ROADMAP.md              ← LA GUÍA PASO A PASO. Cualquier operador la sigue
│                              de arriba a abajo para replicar la implementación
│                              completa. Referencia a otros repos cuando llega
│                              el momento de tocarlos.
├── README.md               ← QUÉ ES el proyecto, mapa de repos, quick start.
│                              No tiene los pasos detallados — esos están en
│                              el ROADMAP.
└── docs/
    ├── architecture.md     ← LA FOTO TÉCNICA. Diagramas, decisiones, trade-offs.
    │                          Es para "entender", no para "ejecutar".
    ├── dns-tls-future.md   ← Doc específica por temática (caminos para DNS/TLS)
    └── path-to-production.md  ← (Fase 10) Capítulo de promoción a prod

cada-repo-secundario/
├── README.md               ← QUÉ HACE este repo, cómo se usa, cómo se conecta
│                              con el resto. NO repite el ROADMAP global.
└── subcarpetas/README.md   ← Cómo usar piezas específicas (templates, oidc)
```

**Regla:** si un comando aparece en el ROADMAP global, no debe repetirse
textual en el README del repo correspondiente — el README puede
contextualizarlo, pero el "paso a paso oficial" vive una sola vez, en el
ROADMAP global.

---

## Decisiones técnicas tomadas

### Stack y región
- **AWS region:** us-east-1 (más barata, catálogo completo)
- **Kubernetes:** EKS **1.35** (bump aplicado en commit `18460ea`).
  La decisión original era 1.30, el dueño lo subió durante la ejecución
  de Fase 1 — preservar.
- **Cuenta AWS:** account ID `650790810564`. Era Free Plan, se upgradeó a
  Paid Plan para poder lanzar t3.medium/t3.large.
- **Créditos disponibles:** $138 USD al 9 de mayo 2026, vencen 17 oct 2026.

### Apps
- **Lenguaje:** Python (FastAPI + uvicorn + structlog + prometheus_client).
- **Logs:** estructurados JSON, 5 niveles (trace, debug, info, warn, error)
  configurable por `LOG_LEVEL` env var.
- **Endpoint de métricas:** `/api01/metrics` y `/api02/metrics` (prefijados
  porque van detrás de un mismo Ingress).
- **Build:** Docker Hub user `valentinobruno`. Imágenes públicas.

### Infra
- **Nodos:** 2 × t3.medium stateless + 1 × t3.large statefulls
- **EBS:** 20GB gp3 dedicado al nodo `statefulls`, con script de bootstrap
  que lo attachea y monta en `/mnt/statefull` + symlinks a
  `/var/lib/elasticsearch`, `/var/lib/prometheus`.
- **NAT:** uno solo (single-AZ) para abaratar la demo. Trade-off documentado.
- **Karpenter:** controller + node IAM listos en Terraform; falta crear los
  CRDs `NodePool` y `EC2NodeClass` (eso va en Fase 3).
- **Ingress dual:** ALB Controller (TLS, entry point) + nginx Ingress
  (routing canary fino, annotations nativas para ArgoRollouts).
- **Cluster name:** `belo-challenge-dev`.
- **AMIs:** pin de AMI aplicado en commit `18460ea` —
  preservar lo que está en el repo, no revertir.

### CI/CD
- **Pipelines:** Tekton + Triggers, disparados por **tag annotated** con
  formato `deploy:<env>` y mensaje `strategy:<BlueGreen|Canary|RollingUpdate>`.
- **Build:** Kaniko en pod (sin daemon Docker).
- **Estrategias de deployment:** ArgoRollouts. BlueGreen para api01, Canary
  para api02, RollingUpdate como default.
- **GitOps:** ArgoCD apuntando a `gitops-files`, apps-of-apps pattern.
- **Load testing:** k6 vía TestKube. Scripts en `loadtest/` del repo de cada
  app. Integrados como stage del pipeline, distintos según strategy:
  - BlueGreen: k6 contra el preview Service antes del switch
  - Canary: k6 después de cada step de promoción (5% → 25% → 50% → 100%)
  - RollingUpdate: smoke test al final

### Observabilidad
- **Logs:** EFK (Elasticsearch + Fluent-bit + Kibana). Elastic pinneado al
  nodo `statefulls`.
- **Métricas:** Prometheus + Grafana. Prometheus pinneado al nodo
  `statefulls`.
- **Dashboard cluster:** Headlamp.

### Auth
- **Modelo:** IAM users → IAM groups → AssumeRole → aws-auth → K8s Groups → RBAC.
- **Dos roles:** `belo-challenge-dev-eks-developer` (read-only sin secrets)
  y `belo-challenge-dev-eks-infra` (cluster-admin).
- **OIDC:** preparado pero deshabilitado. Archivos `.disabled` en
  `users-managment-aws/oidc/`. Cuando se active, los grupos llegan con
  prefijo `oidc:` y los bindings paralelos ya están listos.

---

## Estado actual (al cerrar este chat)

### Fase 1 — Infra base — ✅ **VALIDADA**

Ciclo completo `apply → destroy` ejecutado exitosamente. La infra base está
probada y se levanta limpio en ~15-20 min con `make tf-apply`.

El dueño aplicó **cambios locales** durante la ejecución. Historial de
commits del repo `tochallenge-belo` al momento del handoff:

```
18460ea (HEAD, origin/main)  fix amis y version 1.35
e0a1b9a                       push base changes, infra ready
78ea66a                       Initial commit
```

**Interpretación:**
- `78ea66a` — primera entrega de Claude (base del repo).
- `e0a1b9a` — base de infra después del primer ciclo de iteración con
  Claude, lista para ejecutar.
- `18460ea` — **fixes aplicados por el dueño** durante la ejecución
  exitosa: pin de AMIs y **bump de versión de Kubernetes a 1.35**.

> **Atención al cambio de versión:** este HANDOFF y los docs previos
> mencionaban EKS 1.30 como decisión inicial. La versión vigente en el
> repo es **1.35** (commit `18460ea`). Si hay contradicción entre este
> doc y el código, **gana el código**. La fuente de verdad es lo que
> está commiteado en `main`. Verificar con:
> ```bash
> grep -r "kubernetes_version\|cluster_version\|1\.30\|1\.35" \
>   tochallenge-belo/terraform/
> ```

**Estos cambios son válidos y deben preservarse.** Si en futuras
iteraciones un Claude bien intencionado pretende "limpiar" o
"homogeneizar" ese código contra los archivos originales, **NO hacerlo
sin confirmar con el dueño primero**.

> Implicación práctica del bump a K8s 1.35: si algún manifesto futuro
> (Karpenter NodePool, ArgoRollouts, etc.) requiere una versión mínima
> de K8s, recordar que estamos en 1.35, no en 1.30. La mayoría de los
> addons actuales están bien con 1.30+; el cambio es transparente.
> El único cuidado real es la **fecha de fin de standard support**:
> 1.35 extiende el horizonte de upgrade obligatorio bastante más allá
> de nov 2026.

**Aprendizajes capturados durante esta fase:**

1. **Cuenta nueva de AWS:** Free Plan restringe a instancias free-tier-eligible
   (t2/t3.micro). Para correr t3.medium/large hay que upgradear a Paid Plan;
   los créditos siguen aplicándose.
2. **Bug en eks-nodes:** se quitó la línea `instance_type` del launch
   template del nodo statefull. EKS no permite tenerla en LT y en el node
   group simultáneamente. **Ya fixeado.**
3. **`prevent_destroy = true` en el EBS:** la flag bloqueaba el destroy
   entero. **Ya cambiado a `false`.**
4. **Ctrl+C doble es veneno con Terraform.** Usar uno solo y esperar el
   graceful shutdown.
5. **Windows + GnuWin32 make:** la línea `$(MAKE) tf-plan` rompe por las
   paréntesis del path `Program Files (x86)`. Fix: comillas `"$(MAKE)" tf-plan`.

### Fase 2 — Auth, RBAC, IAM — ✅ **ENTREGADA Y APLICADA EXITOSAMENTE**

Repo `users-managment-aws` listo y commiteado. Historial al momento del
handoff:

```
6aff2bd (HEAD, origin/main)  fase 2 testeada v2
a40d4cb                       fase 2 testeada v1
bf767a4                       fase 2 testeada
e3d9ade                       Push fase 2 concluida
a90573a                       Initial commit
```

**Interpretación:**
- `a90573a` — primera entrega de Claude (base del repo, generada en el
  chat).
- `e3d9ade` — push inicial al remoto después de validar la estructura.
- `bf767a4`, `a40d4cb`, `6aff2bd` — **tres iteraciones de fixes durante
  el testeo en cluster real**. La nomenclatura "testeada" + "v1" + "v2"
  indica que el dueño encontró ajustes necesarios al ejecutar contra el
  cluster levantado y los fue commiteando hasta que `make
  verify-developer` y `make verify-infra` corrieron OK.

> **Importante para Claude Code:** **los commits `bf767a4` → `a40d4cb` →
> `6aff2bd` contienen los fixes que hicieron funcionar la Fase 2 en la
> práctica**. La versión que entregó Claude originalmente (en `a90573a`)
> es buena pero **no es la que funciona** — la que funciona es `6aff2bd`.
> Antes de regenerar cualquier archivo de este repo en una sesión
> futura, hacer:
>
> ```bash
> cd users-managment-aws
> git log --all --oneline
> git diff a90573a 6aff2bd -- <archivo>
> ```
>
> Y leer qué fue lo que cambió. Esos diffs son el conocimiento operativo
> que se ganó probando en vivo.

**Cambios funcionales aplicados durante esos tres commits** (lo que el
dueño recuerda con trazo gordo, validar contra los diffs reales antes de
modificar nada):

1. **Adopción de `RBACDefinition` de ReactiveOps (Fairwinds rbac-manager).**
   En lugar de manejar `ClusterRoleBinding` y `RoleBinding` sueltos, se
   migró a un único CRD `rbacdefinitions.rbacmanager.reactiveops.io` que
   declara usuarios, grupos y subjects en un solo manifest. Beneficios:
   un solo recurso por equipo en lugar de N bindings, soporte nativo de
   "este grupo tiene rol X en namespace A y rol Y en namespace B", y
   eliminación automática de bindings huérfanos cuando se borra el RBAC
   Definition. Requiere instalar `rbac-manager` como addon (Helm chart).
2. **Logica multi-ambiente / multi-namespace para developers.** El grupo
   `develop` no recibe `cluster-admin` ni un único ClusterRoleBinding —
   se mapean permisos diferenciados por namespace (ej. read-only sobre
   `kube-system` y `monitoring`, edit sobre `apps-dev`, sin acceso a
   `apps-production`). Esto vive dentro del manifest de `RBACDefinition`.
3. **Ajustes al script `scripts/merge-aws-auth.sh`.** Probablemente
   relacionados con el comportamiento real del ConfigMap en cluster vivo
   (parsing del YAML embebido, manejo de entradas existentes, idempotencia
   real). Validar diff específico de ese archivo entre `a90573a` y
   `6aff2bd` antes de tocarlo.

> **Implicación para Fase 3 (addons):** `rbac-manager` se debe incluir
> en la lista de addons a instalar antes de aplicar los `RBACDefinition`.
> Sin el operator instalado, el CRD no existe y `kubectl apply` falla.
> Asegurarse de que el `helm install rbac-manager` quede ANTES del
> `kubectl apply` de los manifests de auth en el orden del ROADMAP global.

> **Implicación para el capítulo "Path to production":** este patrón con
> rbac-manager + RBACDefinition es **mejor que el original que entregó
> Claude** (ClusterRoleBindings sueltos). El doc de path-to-production
> NO debe listarlo como "atajo a mejorar" — al contrario, es uno de los
> aciertos a destacar. La sección "OIDC preparado" sigue siendo válida
> como mejora futura encima de esto.

Estructura final commiteada:

```
users-managment-aws/
├── README.md (diagrama de cómo se conectan las capas)
├── Makefile (iam-apply, rbac-apply, verify-developer, verify-infra)
├── iam/ (Terraform: groups, roles, users, access keys, outputs)
├── rbac/
│   ├── clusterroles/viewer-no-secrets.yaml
│   └── bindings/{develop,infra}-binding.yaml
├── scripts/merge-aws-auth.sh (merge seguro, idempotente, con backup)
├── templates/ (3 plantillas: new-user, new-clusterrole, new-group-binding)
└── oidc/ (preparado y documentado, .disabled hasta activación)
```

Probada con éxito sobre cluster levantado. Las verificaciones
`make verify-developer` y `make verify-infra` corren OK en el HEAD actual
(`6aff2bd`).

---

## Cambio de arquitectura conversado pero NO implementado todavía

Después de entregar Fase 2, surgió un refinamiento importante sobre cómo
estructurar los Helm charts. La propuesta original (chart adentro del repo
de cada app) **se descarta**. La nueva arquitectura es:

### Repo `belo-helm-charts` (NUEVO)

```
belo-helm-charts/
└── pythonapps/                          ← chart maestro reutilizable
    ├── Chart.yaml
    ├── values.yaml                      ← defaults para que funcione standalone
    ├── templates/
    │   ├── rollout.yaml                 ← ArgoRollout (no Deployment)
    │   ├── service.yaml
    │   ├── ingress.yaml
    │   ├── servicemonitor.yaml
    │   └── hpa.yaml
    └── apps/
        ├── webserver-api01/
        │   └── app.yaml                 ← build-time: registry, image_name, repo_url
        └── webserver-api02/
            └── app.yaml
```

Mañana se sumarían `javaapps/`, `goapps/`, etc.

### Repo `gitops-files`

```
gitops-files/
├── dev/
│   ├── webserver-api01/values.yaml      ← runtime: replicas, resources, strategy
│   └── webserver-api02/values.yaml
├── staging/...
└── production/...
```

### Composición final en el pipeline

```bash
helm template api01 belo-helm-charts/pythonapps/ \
  -f belo-helm-charts/pythonapps/apps/webserver-api01/app.yaml \
  -f gitops-files/dev/webserver-api01/values.yaml \
  --set image.tag=v1.4.0
```

### Por qué se separa build-time de runtime

- Build-time (cómo se compila, dónde se pushea, quién es dueño): cambia
  **raramente**. Vive en `belo-helm-charts/apps/<app>/app.yaml`.
- Runtime (replicas, recursos, strategy, hpa, ingress hostname): cambia
  **seguido y por ambiente**. Vive en `gitops-files/<env>/<app>/values.yaml`.

### Decisiones pendientes (preguntadas pero no respondidas todavía por Valentino)

1. **¿Un solo chart `pythonapps` parametrizado con `strategy:
   bluegreen|canary|rollingupdate`, o dos charts separados (`pythonapps-bg`
   y `pythonapps-canary`)?** Recomendación de Claude: uno solo.
2. **¿Carpeta `loadtest/` queda en el repo de cada app?** Asumido confirmado
   salvo nuevo input.
3. **¿La capa "build-time" la dejamos en `belo-helm-charts/apps/`?**
   Recomendado por Claude. Pendiente confirmación final.

---

## Roadmap actualizado (post-cambio de arquitectura)

| Fase | Estado | Repos involucrados |
|---|---|---|
| 1 — Infra Terraform | ✅ Mergeado, validado, con fixes locales del dueño | tochallenge-belo |
| 2 — Auth/RBAC/IAM | ✅ Entregado, aplicado con éxito | users-managment-aws |
| 3 — Addons cluster | ⏳ Próxima | tochallenge-belo (Helm values) + gitops-files (apps-of-apps) |
| 4 — Helm charts maestros | ⏳ Próxima (re-diseñada) | belo-helm-charts |
| 5 — Apps Python | ⏳ | webserver-api01, webserver-api02 |
| 6 — Pipelines Tekton | ⏳ | tochallenge-belo (manifests/tekton) + repos de apps (.tekton/) |
| 7 — GitOps por ambiente | ⏳ | gitops-files |
| 8 — Observabilidad (validación) | ⏳ | Dashboards Grafana, validación EFK |
| 9 — Versión k3d | ⏳ | tochallenge-belo (k3d/ folder) |
| 10 — READMEs finales + roadmap final + capítulo "Path to production" | ⏳ | tochallenge-belo |

> **Nota sobre orden:** Fase 4 antes que Fase 5 porque el chart maestro
> define la interfaz de qué espera Helm de cada app.

---

## Path to production (deuda técnica explícita)

Esta sección es **importante**. El dueño fue instruido a pensar la
solución con foco a producción. Hoy se tomaron varios atajos por costo y
por tiempo de demo. **No esconderlos** — el evaluador los va a buscar.

Cuando se llegue a la Fase 10 (READMEs finales), escribir un capítulo
`docs/path-to-production.md` que liste:

| Atajo de demo | Qué cambia para prod |
|---|---|
| NAT único en una AZ | 1 NAT por AZ (+$33/mes pero HA real) |
| Instancias On-Demand | Stateless en Spot (Karpenter ya configurado para preferir Spot) — ahorro ~70% |
| EBS sin snapshot policy | DLM (Data Lifecycle Manager) con snapshots diarios + retención 7 días |
| Sin VPC endpoints | Gateway endpoints a S3 y DynamoDB (gratis, saca tráfico del NAT) |
| Sin WAF | AWS WAF asociado al ALB (~$5/mes + reglas) |
| Imagen Python sin hardening | Imagen distroless o Chainguard para reducir CVEs y tamaño |
| IAM users con access keys | IAM Identity Center (ex SSO) — sin keys de larga vida |
| Single-region | Multi-region con replicación cross-region (Route53 failover) |
| Sin Pod Security Standards | PSS `restricted` en todos los namespaces salvo system |
| Sin Network Policies | Network Policies default-deny por namespace |
| Secrets en K8s Secrets | AWS Secrets Manager + External Secrets Operator |
| Sin rate limiting en Ingress | Annotations de rate limit en nginx Ingress |
| Logs solo en EFK interno | CloudWatch Logs para retención larga + EFK para queries en vivo |
| ArgoCD self-hosted, sin RBAC | RBAC granular en ArgoCD + SSO con OIDC |
| Tekton sin signature verification | cosign para firmar imágenes + admission controller que valida |
| Sin DR plan | Velero + S3 cross-region para backup de etcd y PVCs |
| Tags básicos | Cost allocation tags por team/environment para FinOps |
| Cluster autoscaler básico | Karpenter con multiple NodePools por workload (compute-intensive, memory-intensive, gpu) |
| Sin chaos engineering | Litmus o Chaos Mesh para validar resilencia |
| Sin SLOs definidos | SLO/SLI definidos en Grafana SLO + alertas en error budget |

Cada una de estas filas debe expandirse en el doc final con: **qué es, por
qué importa para producción, cómo se implementa, qué cuesta**.

---

## Convenciones para mantener al continuar

### Estilo de código y docs

- **Idioma:** español rioplatense ("vos", "tenés", "querés"). Comentarios
  técnicos también en español salvo nombres de variables.
- **Markdown:** prosa con asides ocasionales en `>`, mínimo de listas, headers
  solo cuando hay secciones genuinamente separadas. **Evitar formato
  típicamente AI**: emojis, listas-de-todo, headers cada 3 párrafos.
- **Comentarios en código:** explicar el *por qué*, no el *qué*. Especialmente
  en decisiones contraintuitivas (ej. "single-NAT a propósito por costo,
  trade-off de HA documentado en COSTS.md").
- **Trade-offs explícitos:** cuando se toma una decisión donde había
  alternativas, dejar la otra opción mencionada en el doc.
- **Diagramas:** Mermaid embebido en `.md` (GitHub lo renderiza nativamente).
  No PNGs. Estilo "human pretty pero técnico" — sin colores chillones, con
  labels claros, agrupando por contexto (subgraphs).

### Terraform

- Módulos en `terraform/modules/<nombre>/` con `main.tf`, `variables.tf`,
  `outputs.tf`. IAM en archivos separados (`iam.tf`).
- Recursos únicos dentro de un módulo se llaman `this` (convención de la
  comunidad). Recursos múltiples se nombran descriptivamente.
- Tags estándar via `default_tags` del provider.
- Backend S3 con backend-config en `backend.hcl` (no hardcoded).
- Templates de archivos `.tfvars.example` y `.hcl.example` versionados, los
  reales en `.gitignore`.

### Kubernetes manifests

- YAMLs separados por archivo, agrupados por tipo (`clusterroles/`,
  `bindings/`, etc.).
- Labels estándar: `app.kubernetes.io/managed-by: <repo-name>`.
- Cada manifest empieza con un comentario explicando qué hace y a qué se
  relaciona.

### Makefiles

- Cada repo tiene su `Makefile` en raíz con targets agrupados por fase.
- `make help` siempre disponible (parsea las descripciones `## ...`).
- Variables override-ables (`ENV`, `REGION`, etc.).
- Confirmación obligatoria en operaciones destructivas (`read -p`).

### Entregables (cuando se entrega un nuevo paquete)

- **Estructura:** un `.zip` por repo, no archivos sueltos (el archivado
  individual aplana la jerarquía y rompe).
- **Validación previa:** validar YAMLs con `python -c "import yaml"`, bash
  con `bash -n`, JSON con `python -c "import json"`. Si Terraform está
  disponible, `terraform fmt -recursive` y `terraform validate`.

---

## Cómo arrancar la próxima sesión

Si vos (o Claude Code) llegás a este punto y necesitás retomar:

### Paso 1 — Contexto

1. Leer este archivo entero (`HANDOFF.md`).
2. Leer los 3 archivos clave del repo principal:
   - `tochallenge-belo/README.md`
   - `tochallenge-belo/ROADMAP.md`
   - `tochallenge-belo/docs/architecture.md`
3. Hacer un `git log --oneline -20` en `tochallenge-belo` y en
   `users-managment-aws` para ver qué cambios commiteó el dueño después
   del último entregable de Claude. Commits clave al momento de este
   handoff:
   - `tochallenge-belo`: **`18460ea`** ("fix amis y version 1.35")
   - `users-managment-aws`: **`6aff2bd`** ("fase 2 testeada v2") —
     contiene los fixes de testing real, no usar `a90573a`
   Confirmar que ambos siguen siendo HEAD. Si hay commits posteriores,
   leer su mensaje y los archivos modificados antes de tocar código
   relacionado.

### Paso 2 — Confirmar estado con el dueño

Preguntas a hacer antes de avanzar con código:
1. ¿Aplicaste Fase 1 y Fase 2 desde cero exitosamente en el último ciclo,
   o hay algo que ajustar?
2. ¿Confirmás las 3 preguntas pendientes de arquitectura de charts (un
   chart vs dos, loadtest en repo de app, build-time en
   `belo-helm-charts/apps/`)?
3. ¿Por dónde querés seguir: Fase 3 (addons del cluster) o Fase 4 (charts
   maestros)?

### Paso 3 — Producir según la fase elegida

**Si va a Fase 3 (addons):** el primer entregable es
`tochallenge-belo/terraform/modules/karpenter/` ampliado con los CRDs
`NodePool` y `EC2NodeClass`. Después los Helm values de cada addon con
IRSA cableado, después el bootstrap de ArgoCD (apps-of-apps en
`gitops-files`).

**Si va a Fase 4 (charts):** primer entregable es el chart maestro
`pythonapps` con templates parametrizados (rollout que sabe ser BlueGreen
o Canary según `strategy`). Validar la estructura con un dry-run de
`helm template` antes de pasar a las apps. Después agregar las dos apps
en `apps/webserver-api0{1,2}/app.yaml`.

### Paso 4 — Mantener calidad

Antes de cerrar la respuesta:
- ¿El código sigue las convenciones de este HANDOFF?
- ¿Los docs tienen tono humano (asides, trade-offs explícitos)?
- ¿Hay alguna decisión nueva que merezca actualizarse en el HANDOFF para
  futuras sesiones?

---

## Información sensible / a no perder

- **AWS account ID:** `650790810564`
- **Region:** us-east-1
- **Cluster name:** `belo-challenge-dev`
- **Bucket de tfstate:** definido en `backend.hcl` (no versionado). Convención
  sugerida: `belo-challenge-tfstate-650790810564`
- **Tabla DynamoDB de lock:** `belo-challenge-tflock`
- **Docker Hub user:** `valentinobruno`
- **GitHub user:** `Valentino-33`
- **Workspace local:** `C:\Users\tadeo\OneDrive\Escritorio\belochallenge\`

---

## Anti-patrones que ya cazamos (no repetir)

- ❌ Apply de Terraform sin haber configurado `backend.hcl` y `terraform.tfvars`
  → falla con error de "config files".
- ❌ Doble Ctrl+C en un `terraform apply` que está creando recursos lentos
  (EKS, NAT) → state inconsistente.
- ❌ `prevent_destroy = true` por default en recursos que se van a destruir
  en ciclos de demo → bloquea el destroy entero.
- ❌ Setear `instance_type` en launch template Y en `instance_types` del node
  group → InvalidRequestException de EKS.
- ❌ `make` invocando `$(MAKE)` sin comillas cuando el path tiene paréntesis
  (Windows GnuWin32) → syntax error de bash.
- ❌ Pisar `aws-auth` con `kubectl apply` → los nodos pierden acceso al
  cluster. Usar siempre el script `merge-aws-auth.sh`.
- ❌ Helm chart adentro del repo de la app → no reutilizable, no escala a
  varias apps Python.
- ❌ Mezclar build-time vars (registry, image_name) con runtime vars
  (replicas, resources) en el mismo values → ensucia el historial.
- ❌ Revertir cambios locales del dueño asumiendo que son "errores" → los
  fixes de versión K8s y AMI son intencionales y validados.
- ❌ Duplicar el ROADMAP en READMEs de subrepos → mantener la guía paso a
  paso una sola vez (en `tochallenge-belo/ROADMAP.md`); los READMEs solo
  referencian.
- ❌ Esconder los atajos de demo en lugar de documentarlos → ver capítulo
  "Path to production". Cada compromiso por costo o tiempo debe estar
  listado allí explícitamente.

---

*Última actualización: 10 de mayo de 2026 — cerrando este chat después de
entregar Fase 1 (validada y commiteada en `tochallenge-belo@18460ea` con
fixes del dueño: AMIs pinneadas y K8s 1.35) y Fase 2 (aplicada con éxito
y commiteada en `users-managment-aws@6aff2bd`, con tres iteraciones de
fix durante testing real). Próximo paso: retomar en Claude Code y
arrancar con Fase 3 o Fase 4 según elección del dueño.*
