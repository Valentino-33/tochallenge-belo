# Costos de AWS

Todos los precios son de la región **us-east-1 (N. Virginia)**, en
**On-Demand Linux**, verificados durante la primera semana de mayo de 2026.
AWS cambia precios sin aviso, así que antes de hacer un compromiso largo
revisar la calculadora oficial.

---

## ¿Por qué us-east-1?

Tres motivos, en orden:

1. **Es la región más barata de AWS.** Los precios de cómputo, networking y
   storage en us-east-1 son la "tarifa de referencia" — el resto del mundo
   suele estar 5-30% arriba. Para un challenge donde el costo importa,
   us-east-1 es la opción default razonable.
2. **Catálogo completo y add-ons maduros.** Todos los servicios y todas las
   integraciones de EKS aparecen primero acá.
3. **Documentación abundante.** Si algo se rompe, la chance de encontrar el
   issue exacto en GitHub o StackOverflow es máxima en esta región.

Trade-off conocido: la **latencia desde Argentina** ronda 130-180ms, contra
~30ms si estuviera en sa-east-1 (São Paulo). Para una demo donde no hay
usuarios reales, no importa. Si esto pasara a producción para clientes
sudamericanos, se evalúa el cambio — pero sa-east-1 cuesta ~30% más.

---

## Componentes y precios unitarios

> **Fuente principal:** [AWS Pricing pages](https://aws.amazon.com/pricing/services/)
> (EKS, EC2, VPC/NAT, EBS, ELB).
> Cuando uso un agregador de terceros lo cito explícitamente.

### EKS Control Plane

| Concepto | Precio | Mensual (730 h) |
|----------|--------|-----------------|
| EKS standard support (K8s 1.30) | $0.10 / hr | **$73.00** |
| EKS extended support (>14 meses sin upgradear) | $0.60 / hr | $438.00 |

> Fuente: [AWS EKS Pricing](https://aws.amazon.com/eks/pricing/) y la nota de
> AWS sobre [extended support pricing](https://aws.amazon.com/blogs/containers/amazon-eks-extended-support-for-kubernetes-versions-pricing/).
> El cluster nuevo arranca siempre en standard.

> **Heads-up:** la trampa más típica de EKS es dejar el cluster en una
> versión vieja y caer en extended support. **6× más caro** y se activa solo.
> Por eso definimos K8s 1.30 (vence noviembre 2026) y dejamos un recordatorio
> en el calendario para upgradear antes.

### Nodos EC2 (worker nodes)

Se eligieron tres instancias t3 para mantener el costo bajo y porque la
naturaleza burstable de t3 le sienta bien a un cluster de demo donde el
trabajo viene en picos (build de Tekton, load test).

| Instancia | vCPU / RAM | Precio por hora | Mensual (730 h) | Rol |
|-----------|------------|-----------------|-----------------|-----|
| t3.medium | 2 / 4 GiB  | $0.0416         | $30.37          | stateless |
| t3.medium | 2 / 4 GiB  | $0.0416         | $30.37          | stateless |
| t3.large  | 2 / 8 GiB  | $0.0832         | $60.74          | statefulls |
| **Subtotal nodos**                          | | **$121.48**     | |

> Fuente: [Finout — Understanding AWS Pricing](https://www.finout.io/blog/understanding-aws-pricing)
> reproduce los precios oficiales que también aparecen en [aws.amazon.com/ec2/pricing/on-demand](https://aws.amazon.com/ec2/pricing/on-demand/).

> **Por qué t3.large para el statefull:** Elasticsearch + Prometheus
> juntos demandan ~3-4 GiB de RAM solo para arrancar cómodos.
> Con t3.medium (4 GiB) vivirían al borde y hacen OOM al primer pico.

### EBS

| Concepto | Precio | Cantidad | Mensual |
|----------|--------|----------|---------|
| gp3 root volume por nodo (20 GB) | $0.08 / GB-mes | 3 × 20 GB = 60 GB | $4.80 |
| gp3 dedicado al nodo statefull (20 GB) | $0.08 / GB-mes | 20 GB | $1.60 |
| **Subtotal EBS** | | | **$6.40** |

> Fuente: [AWS EBS Pricing](https://aws.amazon.com/ebs/pricing/).
> gp3 incluye 3000 IOPS y 125 MB/s gratis, no necesitamos provisionar más.

### NAT Gateway

| Concepto | Precio | Mensual |
|----------|--------|---------|
| NAT Gateway hour (1 AZ) | $0.045 / hr | $32.85 |
| Data processing | $0.045 / GB | ~$2.25 (estimado 50 GB) |
| **Subtotal NAT** | | **~$35.10** |

> Fuente: [AWS VPC Pricing](https://aws.amazon.com/vpc/pricing/).
> El challenge pide HA en las subnets pero **no necesariamente NAT redundante**.
> Para reducir costo, **vamos con un solo NAT en una AZ** y aceptamos que si esa
> AZ cae, las pods en la otra AZ pierden internet hasta que se cree otro.
> Para producción real, sería 1 NAT por AZ (×2 → ~$66/mes solo de horas).

### Application Load Balancer

| Concepto | Precio | Mensual |
|----------|--------|---------|
| ALB hour | $0.0225 / hr | $16.43 |
| LCU-hour (estimado 1 LCU promedio) | $0.008 / LCU-hr | $5.84 |
| **Subtotal ALB** | | **$22.27** |

> Fuente: [AWS ELB Pricing](https://aws.amazon.com/elasticloadbalancing/pricing/).
> 1 LCU promedio cubre hasta 25 conexiones nuevas/seg, 3000 conexiones activas
> o 1 GB/h, lo que sea más alto. Para una demo es más que suficiente.

> Si una app necesitara su propio ALB en lugar de compartir, sumar otro
> bloque de ~$22/mes. Por eso vale la pena usar nginx Ingress por debajo y
> hacer **un solo ALB** con routing por path o host.

### Direcciones IPv4 públicas

Desde **febrero de 2024**, AWS cobra **$0.005/h por cada IPv4 pública**,
incluyendo las que están attacheadas a recursos en uso (antes solo cobraba
las EIP no usadas).

| Recurso | Cantidad | Mensual |
|---------|----------|---------|
| EIP del NAT Gateway | 1 | $3.65 |
| IPs del ALB | 2 (una por AZ) | $7.30 |
| **Subtotal IPv4** | | **$10.95** |

> Fuente: [AWS Public IPv4 charge](https://aws.amazon.com/blogs/aws/new-aws-public-ipv4-address-charge-public-ip-insights/),
> también desglosado en [AWS Costs Explained — abril 2026](https://computingforgeeks.com/aws-costs-explained-real-numbers/).

### Data transfer

| Concepto | Precio | Estimado mensual |
|----------|--------|------------------|
| Salida a internet vía ALB | $0.09 / GB después de los primeros 100 GB gratis | ~$5 (con 50 GB total saliendo) |
| Cross-AZ traffic | $0.01 / GB en cada dirección | ~$2 (mínimo realista) |
| **Subtotal DT** | | **~$7** |

> Fuentes: [AWS EC2 Data Transfer](https://aws.amazon.com/ec2/pricing/on-demand/#Data_Transfer),
> y el análisis cruzado de [costgoat / NAT Gateway pricing](https://costgoat.com/pricing/aws-nat-gateway).
> Esto es la línea más volátil de la factura — si arrancan a correr load tests
> pesados o backups grandes a S3, esto puede subir 5×.

---

## Total mensual

| Componente | Mensual (USD) |
|------------|---------------|
| EKS control plane | $73.00 |
| Nodos EC2 (3 nodos t3) | $121.48 |
| EBS volumes | $6.40 |
| NAT Gateway | $35.10 |
| ALB | $22.27 |
| IPv4 públicas | $10.95 |
| Data transfer | $7.00 |
| **Total estimado** | **~$276** |

Es **una estimación realista para uso de demo continuo**. Para una empresa
que corra esto 24/7 todo el mes, el rango en producción real estaría entre
**$280 y $400** según volumen de tráfico y data transfer.

---

## Cómo bajar la factura

Tres palancas, ordenadas por impacto.

### 1. Apagar la infra cuando no estás trabajando (el truco más obvio y más ignorado)

`make tf-destroy` y `make tf-apply` están justamente para esto. Si la corrés
**solo durante 8 horas hábiles, 22 días al mes** (~176 h vs 730 h totales),
el costo cae a aproximadamente **$67/mes**:

| Componente | Always-on | 24% utilization | Notas |
|---|---|---|---|
| EKS control plane | $73.00 | $17.60 | Solo cobra si el cluster existe |
| Nodos EC2 | $121.48 | $29.30 | Idem |
| NAT Gateway | $35.10 | $8.45 | Idem |
| ALB | $22.27 | $5.40 | Idem |
| IPv4 | $10.95 | $2.65 | Idem |
| EBS | $6.40 | $6.40 | **No baja** — el storage persiste igual |
| Data transfer | $7.00 | $2.00 | Aprox proporcional |
| **Total** | **~$276** | **~$72** | |

> El EBS no se elimina con `tf destroy` por default si tiene la flag
> `prevent_destroy = true` (lo activé en el módulo para no perder el
> `/mnt/statefull` con datos de Elasticsearch entre sesiones). Si querés
> destruir realmente todo, comentar esa flag y volver a aplicar antes del destroy.

### 2. Spot instances para los nodos stateless

Los pods stateless toleran reinicios. Reemplazar los dos t3.medium On-Demand
por **t3.medium Spot** baja **~70%** ese ítem:

- 2 × t3.medium On-Demand: $60.74/mes
- 2 × t3.medium Spot (~$0.013/hr): ~$19/mes
- **Ahorro: ~$42/mes**

> Fuente: [AWS EC2 Spot pricing](https://aws.amazon.com/ec2/spot/pricing/),
> precio histórico promedio de t3.medium en us-east-1 ~$0.0125/h.
> El nodo `statefulls` se queda On-Demand para no perder datos en interrupciones.

Karpenter ya está configurado en `helm/addons/karpenter/values.yaml` para
preferir Spot en stateless workloads.

### 3. ARM/Graviton (t4g) en vez de Intel (t3)

Si las apps en Python compilan limpio en ARM (FastAPI lo hace), un
t4g.medium cuesta ~$0.0336/hr (20% menos que t3.medium). Implica rebuildar
las imágenes con `--platform=linux/arm64` en el Dockerfile o usar buildx.

Lo dejo como **mejora de fase 2** porque requiere cambiar el Dockerfile y
testear que todas las dependencias (incluyendo prometheus_client) funcionen
en ARM.

---

## Free Tier (cuenta nueva, primeros meses)

Para cuentas creadas **después del 15 de julio de 2025**, AWS dio vuelta el
modelo: en lugar del Free Tier histórico de 12 meses, ahora dan **$200 en
créditos** aplicables durante 6 meses. Eso cubre **~75% del primer mes** de
este stack.

> Fuente: [AWS Free Tier 2025+](https://aws.amazon.com/free/).
> Para cuentas viejas (antes del 15-jul-2025) sigue aplicando el viejo modelo
> con 750h gratis de t2/t3.micro y 30 GB de EBS por 12 meses, pero estos no
> alcanzan para correr este stack — solo para validar la primera VPC.

---

## Servicios que **no estamos pagando** (y conviene saber por qué)

| Servicio | Por qué no cuesta acá | Cuándo cuesta |
|---|---|---|
| **Karpenter** | Es OSS, corre en el cluster | El IAM role y los nodos que provisiona sí cuestan, pero eso ya lo contamos |
| **ArgoCD** | Self-hosted en el cluster | Si usaras EKS Capabilities (managed ArgoCD de AWS, GA nov 2025), $0.04/h por la capability + $0.001/h por app. Una stack típica puede agregar **$200/mes** |
| **Tekton, ArgoRollouts, EFK, Prometheus, Grafana, Headlamp** | Todo OSS | Solo cuestan los nodos donde corren (ya contados) |
| **Docker Hub** | Plan free para repos públicos | Si necesitás privados hay que pagar el plan Pro de Docker (~$5/mes), o moverlo a ECR ($0.10/GB-mes de imagen) |
| **Cloudwatch** | El básico está incluido | Custom metrics y logs largos cuestan; estamos usando Prometheus self-hosted para evitar esto |

---

## Costo de la versión local (k3d)

**$0**. Solo corre la luz de tu PC. Por eso vale la pena tenerla — para
iterar pipelines, validar manifiestos y hacer demos sin tener que prender
el clúster real.

La única consideración es la **RAM**: el stack completo en k3d toma
**6-8 GiB**. En una notebook con 16 GiB de RAM corre cómodo si cerrás
Chrome con muchas pestañas. Con 8 GiB se puede levantar una versión
recortada (sin EFK ni Prometheus) que pesa ~3 GiB.

---

## Resumen ejecutivo (para si te lo preguntan en una reunión)

> **"¿Cuánto sale esto por mes?"**
>
> Around 280 USD si lo dejás prendido todo el mes. Si lo apagás cuando no
> trabajás, baja a 70-80 USD. Si pasamos los stateless a Spot, otro 40
> menos. La factura se concentra en tres lugares: control plane EKS (73),
> nodos EC2 (120) y NAT + ALB + IPs (70). El resto son centavos.

---

> Última verificación de precios: **2026-05-09**.
> Si el costo real difiere más de 10% del estimado, revisar primero **NAT
> data processing**, **data transfer** y **horas de cluster encendido**;
> son los tres ítems con más varianza.
