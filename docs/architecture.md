# Arquitectura

Este doc tiene tres diagramas: la **infra de AWS**, los **componentes
internos del cluster**, y el **flujo CI/CD**. GitHub renderiza Mermaid
nativamente, así que los diagramas se ven al abrir este archivo en la web.

---

## 1. Infraestructura AWS

```mermaid
flowchart TB
    Internet((Internet))
    Dev[/Developers/]
    GH[GitHub]
    DH[Docker Hub]

    Dev -->|push code / git tag| GH

    subgraph AWS["AWS region us-east-1"]
        IGW[Internet Gateway]

        subgraph VPC["VPC 10.0.0.0/16"]
            subgraph PUB["Public subnets - 10.0.0.0/24 + 10.0.1.0/24 (AZ-a, AZ-b)"]
                ALB[Application Load Balancer]
                NAT[NAT Gateway]
            end

            subgraph PRIV["Private subnets - 10.0.16.0/20 + 10.0.32.0/20"]
                subgraph NODES["EKS worker nodes"]
                    SF["Node 'statefulls' - t3.large<br/>label: role=statefulls"]
                    SL1["Node 'stateless' - t3.medium<br/>label: role=stateless"]
                    CI["Node 'cicd' - t3.medium<br/>label: role=cicd<br/>taint: workload=cicd:NoSchedule"]
                end
                EBS[("EBS gp3 20GB<br/>mounted /mnt/statefull")]
            end
        end

        CP[EKS Control Plane<br/>managed by AWS]
    end

    Internet <--> IGW
    IGW <--> ALB
    ALB --> SL1
    SL1 -.outbound.-> NAT
    CI  -.outbound.-> NAT
    SF  -.outbound.-> NAT
    NAT --> IGW
    GH  -.webhook.-> ALB
    NAT -.pull images.-> DH
    NAT -.git clone.-> GH
    NAT -.pip/deps.-> Internet
    SF --- EBS

    CP -.manages.-> SF
    CP -.manages.-> SL1
    CP -.manages.-> CI

    classDef public fill:#fef3c7,stroke:#f59e0b,color:#000
    classDef private fill:#dbeafe,stroke:#3b82f6,color:#000
    classDef external fill:#f3f4f6,stroke:#6b7280,color:#000
    class PUB,ALB,NAT public
    class PRIV,NODES,SF,SL1,CI,EBS private
    class GH,DH,Dev,Internet external
```

### Plan de CIDRs y disponibilidad de IPs

| Subnet | CIDR | IPs totales | IPs usables (AWS reserva 5) | Uso |
|---|---|---|---|---|
| public-a | 10.0.0.0/24 | 256 | **251** | ALB + NAT |
| public-b | 10.0.1.0/24 | 256 | **251** | ALB (HA) |
| private-a | 10.0.16.0/20 | 4096 | **4091** | Nodos EKS + pods |
| private-b | 10.0.32.0/20 | 4096 | **4091** | Nodos EKS + pods |
| **Total VPC** | 10.0.0.0/16 | 65 536 | **8 684 (las definidas)** | |

> Las privadas con /20 le dejan margen amplio a Karpenter para escalar.
> Cada pod toma una IP del VPC con AWS VPC CNI; con 4091 IPs útiles por
> AZ, el techo práctico está en cantidad de pods por nodo (depende del
> instance type — t3.medium soporta hasta 17 pods por defecto, t3.large
> hasta 35).

### Accesos de red (matriz simplificada)

| Origen | Destino | Por qué | Mecanismo |
|---|---|---|---|
| Internet | ALB:443 | Tráfico de usuarios a las apps | SG del ALB con 0.0.0.0/0 en 443 |
| ALB | nodos:80 (NodePort) | Llega tráfico a las apps | SG entre ALB y nodos |
| nodos EKS | NAT GW | Salida a internet | Route table de la subnet privada |
| nodos EKS | github.com:443 | Clone y webhooks | Vía NAT |
| nodos EKS | registry-1.docker.io:443 | Docker pulls | Vía NAT |
| nodos EKS | pypi.org, files.pythonhosted.org | Build de Kaniko | Vía NAT |
| nodos EKS | api.eks.us-east-1.amazonaws.com | kubelet → control plane | Endpoint privado del cluster |
| nodos EKS | kubernetes.svc | Comunicación entre pods | DNS y CNI internos |

---

## 2. Componentes internos del cluster

```mermaid
flowchart LR
    subgraph ns_ing["namespace: kube-system / ingress-nginx"]
        ALBC[ALB Controller]
        NGX[nginx Ingress]
        MS[Metrics Server]
        VPA[VPA]
        KARP[Karpenter]
        HL[Headlamp dashboard]
    end

    subgraph ns_argo["namespace: argocd"]
        AC[ArgoCD]
    end

    subgraph ns_rollouts["namespace: argo-rollouts"]
        AR[ArgoRollouts<br/>controller]
    end

    subgraph ns_tekton["namespace: tekton-pipelines + tekton-triggers<br/>(corre en nodo cicd)"]
        TK[Tekton Pipelines]
        TT[Tekton Triggers<br/>EventListener]
        TKB[TestKube]
    end

    subgraph ns_apps["namespace: apps"]
        A1[webserver-api01<br/>Rollout BlueGreen]
        A2[webserver-api02<br/>Rollout Canary]
    end

    subgraph ns_log["namespace: logging<br/>(pinned to statefulls node)"]
        ES[(Elasticsearch<br/>StatefulSet)]
        FB[Fluent-bit<br/>DaemonSet]
        KB[Kibana]
    end

    subgraph ns_mon["namespace: monitoring<br/>(pinned to statefulls node)"]
        PR[(Prometheus<br/>StatefulSet)]
        GR[Grafana]
    end

    AC -- sync --> A1
    AC -- sync --> A2
    AR -- traffic split --> A1
    AR -- traffic split --> A2
    TT -- creates --> TK
    TK -- triggers --> TKB
    NGX --> A1
    NGX --> A2
    FB -- logs --> ES
    KB --- ES
    PR -- scrape /metrics --> A1
    PR -- scrape /metrics --> A2
    GR --- PR
```

### Pinneo de pods statefull al nodo correcto

Tres recursos terminan en el nodo `statefulls`:

- **Elasticsearch** (`logging` namespace) — necesita el disco para shards.
- **Prometheus** (`monitoring` namespace) — TSDB persistente.
- (Opcional) **ArgoCD repo-server cache** si el cluster crece.

Los manifestos lo logran con un `nodeSelector + toleration`:

```yaml
nodeSelector:
  role: statefulls
tolerations:
- key: workload
  operator: Equal
  value: statefulls
  effect: NoSchedule
```

Y los nodos stateless tienen un **anti-affinity** para que las apps **no**
caigan ahí, dejándole CPU al statefull.

### HPA y VPA

- **HPA** (Horizontal Pod Autoscaler) — escala las **apps** (api01, api02)
  según CPU > 70% o requests/sec personalizado vía Prometheus Adapter.
- **VPA** (Vertical Pod Autoscaler) — corre en modo `recommendation` para
  todas las pods. **No en `auto`** porque colisiona con los rollouts de
  ArgoCD (modificaría el spec entre syncs).
- **Karpenter** — ve los pods Pending del HPA y levanta nodos nuevos.
  Configurado para preferir Spot en pods con label `workload-class=stateless`.

---

## 3. Flujo CI/CD

```mermaid
sequenceDiagram
    autonumber
    actor Dev
    participant GH as GitHub<br/>(repo de la app)
    participant EL as Tekton<br/>EventListener
    participant TR as Tekton<br/>PipelineRun
    participant DH as Docker Hub
    participant GO as gitops-files<br/>(GitHub)
    participant AC as ArgoCD
    participant AR as ArgoRollouts
    participant K6 as TestKube + k6
    participant USR as Usuarios

    Dev->>GH: git tag -a deploy:production -m "strategy:BlueGreen" v1.4.0
    GH->>EL: webhook (push tag annotated)
    EL->>EL: Interceptor parsea tag<br/>extrae environment + strategy
    EL->>TR: crea PipelineRun con params
    TR->>GH: clone repo
    TR->>TR: Kaniko build + push
    TR->>DH: image:v1.4.0
    TR->>GO: commit "bump api01 to v1.4.0"
    GO->>AC: webhook (commit a gitops-files)
    AC->>AR: aplica nueva spec del Rollout
    AR->>AR: deploy versión "GREEN" / "Canary"
    AR->>K6: spawn TestKube test
    K6->>AR: pass/fail (HTTP 200 ratio, p95, p99, vusers)

    alt Tests OK
        AR->>AR: switch traffic 100%<br/>(BlueGreen) o aumentar peso (Canary)
        AR-->>USR: nueva versión activa
        AR-->>TR: status: succeeded
    else Tests fallan
        AR->>AR: rollback automático<br/>destruye GREEN / vuelve a 0% canary
        AR-->>TR: status: failed
        TR-->>Dev: notification (Slack opcional)
    end
```

### Detalle del Pipeline Tekton

Stages, en orden:

1. **clone-repo** — `git-clone` task estándar de Tekton Catalog.
2. **build-image** — Kaniko, sin Docker daemon, monta workspace de 1 GiB
   efímero. Args: `--destination=docker.io/<user>/<app>:<version>`.
3. **push-to-dockerhub** — implícito en Kaniko, pero hay un task
   separado de `cosign sign` para firmar la imagen (opcional, si
   activamos supply-chain).
4. **bump-helm-values** — task custom que abre un PR (o commit directo)
   al repo `gitops-files`, branch correspondiente al ambiente, modificando
   el `values.yaml` con el nuevo tag.
5. **wait-for-argocd-sync** — espera que ArgoCD reporte `Synced + Healthy`
   (timeout 5 min).
6. **load-test** — `testkube run k6 <script>`, donde el script se elige
   según `strategy`:
   - `bluegreen` → `loadtest/load-bluegreen.js` apuntado al `preview` Service.
   - `canary` → `loadtest/load-canary.js` apuntado al Service principal,
     ejecutado **después de cada step de promoción** del Rollout.
   - `rollingupdate` → `loadtest/smoke.js` al final.
7. **promote-or-rollback** — corre `kubectl argo rollouts promote` o `abort`
   según el resultado del step anterior.

### Cómo se interpreta el tag annotated

El interceptor de Tekton lee el cuerpo del tag y mapea a params:

| Tag annotated body | environment | strategy |
|---|---|---|
| `strategy:BlueGreen` | production | BlueGreen |
| `strategy:Canary` | production | Canary |
| (vacío o sin `strategy:`) | inferido del prefijo del tag | RollingUpdate |
| `strategy:RollingUpdate` | production | RollingUpdate |

El **prefijo del tag** decide el ambiente:

| Tag name | environment |
|---|---|
| `dev-vX.Y.Z` | develop |
| `staging-vX.Y.Z` | staging |
| `vX.Y.Z` (sin prefijo) | production |
| `test-vX.Y.Z` | test |

### Por qué nginx Ingress además del ALB Controller

ArgoRollouts soporta varios `trafficRouting`. El de **ALB** funciona pero
requiere TargetGroupBinding con dos TG (canary + stable) y mover pesos vía
API de AWS — es lento y a veces flaky. El de **nginx** usa annotations
estándar (`nginx.ingress.kubernetes.io/canary-weight: "5"`) y reacciona
en milisegundos.

Esquema final: **ALB termina TLS y entra al cluster**, nginx Ingress hace
el routing por Service y maneja el split de tráfico para Canary. Para
BlueGreen alcanza con ALB nomás (es un switch atómico de target group).

---

## 4. Mapa de qué corre dónde

| Componente | Dónde corre | Tipo | Notas |
|---|---|---|---|
| EKS Control Plane | AWS managed | managed | |
| Karpenter | stateless | kube-system Deployment | escala los nodos stateless |
| ALB Controller | stateless | kube-system Deployment | IRSA con rol Terraform |
| nginx Ingress | stateless | ingress-nginx Deployment | routing canary fino |
| ArgoCD | stateless | argocd Deployment | apunta a belo-helm-charts |
| ArgoRollouts | stateless | argo-rollouts Deployment | controla BlueGreen y Canary |
| rbac-manager | stateless | rbac-manager Deployment | operator de RBACDefinition |
| Grafana, Kibana, Headlamp | stateless | varios Deployment | |
| Apps (api01, api02) | stateless | apps Rollout | NO Deployment, ArgoRollout |
| Tekton controller | cicd | tekton-pipelines Deployment | toleration workload=cicd |
| Tekton EventListener | cicd | tekton-pipelines Deployment | webhook desde GitHub |
| TestKube | cicd | testkube Deployment | lanza los tests k6 |
| PipelineRuns (pods) | cicd | tekton-pipelines Pod efímero | PVC gp3 de 1 GiB, se borra al terminar |
| Elasticsearch | statefulls | logging StatefulSet | pinneado, datos en /mnt/statefull |
| Prometheus | statefulls | monitoring StatefulSet | pinneado, datos en /mnt/statefull |


---

## 6. Deuda técnica conocida (lo que dejamos para "después")

Vale más documentarla que esconderla:

- **Sin WAF** — el ALB no tiene AWS WAF asociado. Para una demo está bien;
  para prod habría que agregarlo (~$5/mes + reglas).
- **Sin VPC Endpoints** — todo el tráfico a S3, ECR (futuro), STS, etc.
  pasa por NAT. Agregar gateway endpoints a S3 y DynamoDB es **gratis** y
  saca tráfico del NAT. Si llega a producción, hacerlo.
- **Single-AZ NAT** — un NAT en una AZ. Si esa AZ cae, las pods de la
  otra AZ pierden internet. Para HA real, dos NATs (~$33/mes extra).
- **Sin secrets management externo** — los secrets de Tekton (token Docker
  Hub, deploy keys) están en Secrets de K8s. Migrar a AWS Secrets Manager
  + External Secrets Operator es la siguiente mejora.
- **Sin imagen base hardened** — el Dockerfile de las apps usa
  `python:3.12-slim` directo. Para prod, una imagen distroless o
  Chainguard reduce CVEs y tamaño.
- **Sin multi-region** — un cluster en us-east-1. La replicación
  cross-region quedaría para una segunda fase.
