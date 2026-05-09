# Integración futura: DNS y TLS

Hoy la demo expone los servicios por el DNS público del ALB
(`<algo>-<random>.us-east-1.elb.amazonaws.com`). Funciona, pero no es lo que
querés mostrarle a un cliente. Este doc deja preparados los dos caminos
posibles para integrar **DNS propio** y **certificados TLS** cuando se
decida activarlo.

---

## Camino A — Route53 + ACM (todo en AWS)

Es la opción más simple si el dominio ya lo manejás en Route53.

### 1. Crear la Hosted Zone (si todavía no existe)

```bash
aws route53 create-hosted-zone --name midominio.com --caller-reference $(date +%s)
```

Anotar los 4 NS que devuelve y configurarlos en el registrar (Namecheap,
GoDaddy, etc.).

### 2. Pedir certificado en ACM

```bash
aws acm request-certificate \
  --domain-name "*.midominio.com" \
  --validation-method DNS \
  --region us-east-1
```

ACM devuelve un CNAME de validación. Crearlo en Route53 (o dejarlo
automático con `--options`). En 5-10 min queda **ISSUED**.

> El cert tiene que estar en la **misma región** que el ALB.

### 3. Anotar el ARN del cert en los Ingress

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: api01
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:us-east-1:123456789012:certificate/abc-123
    alb.ingress.kubernetes.io/ssl-redirect: '443'
spec:
  rules:
    - host: api01.midominio.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: api01
                port:
                  number: 80
```

### 4. ExternalDNS para que cree los A records solo

```bash
helm upgrade --install external-dns bitnami/external-dns \
  -n kube-system \
  --set provider=aws \
  --set aws.region=us-east-1 \
  --set txtOwnerId=belo-challenge-dev \
  --set domainFilters[0]=midominio.com \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=arn:aws:iam::123456789012:role/ExternalDNSRole
```

ExternalDNS lee los Ingress, ve el `host:`, y crea automáticamente el A
record (alias al ALB) en Route53. El IRSA role que necesita está
preconfigurado en `terraform/modules/eks/iam.tf` pero comentado.

### Costos

- Route53 hosted zone: $0.50/mes
- Queries: $0.40 por millón (primeros 1B/mes)
- ACM cert: **gratis** mientras esté en uso por un servicio AWS
- **Total típico:** menos de $1/mes para una demo

---

## Camino B — Cloudflare (DNS allá, TLS terminado en ALB)

Si el dominio está en Cloudflare y no querés moverlo. Dos sub-caminos:

### B.1 — TLS termina en el ALB (Cloudflare como "DNS only")

Mismo cert ACM que el camino A, pero en lugar de Route53, los registros A se
crean a mano en el panel de Cloudflare (o vía cloudflare-operator si querés
GitOpsearlo).

> Importante: el registro tiene que estar en modo **"DNS only"** (nube gris),
> no proxied. Si lo proxieás, Cloudflare termina el TLS por su cuenta y se
> rompe el handshake con el ALB.

### B.2 — TLS termina en Cloudflare (recomendado para producción real)

Modo **"Proxied"** (nube naranja). Cloudflare usa su propio cert para el
cliente, y se conecta al ALB con un cert "Origin CA" gratis que da
Cloudflare. Beneficios:

- DDoS protection y WAF gratis (en plan Free).
- Cache de assets en el edge.
- Latencia menor para usuarios distribuidos.

Pasos:

1. En Cloudflare: SSL/TLS → Origin Server → Create Certificate. Bajar el
   cert y la key.
2. Crear secret en el cluster:

   ```bash
   kubectl create secret tls cf-origin-cert \
     --cert=cert.pem --key=key.pem -n apps
   ```

3. Apuntar el Ingress al secret:

   ```yaml
   spec:
     tls:
       - hosts:
           - api01.midominio.com
         secretName: cf-origin-cert
   ```

4. En el panel de Cloudflare, registro CNAME → `<dns-publico-del-alb>` con
   el switch en **proxied** (nube naranja).
5. SSL/TLS mode → **Full (strict)**. Esto fuerza a Cloudflare a validar el
   cert del origen.

### Costos

- Cloudflare DNS + Proxy: **gratis** en plan Free hasta cierto tráfico
- Origin cert: gratis
- Plan Pro (~$25/mes) si querés WAF avanzado, image optimization, etc.

---

## Camino C — cert-manager + Let's Encrypt (alternativa)

Útil si **no** querés depender de ACM (ej. multi-cloud, o por costo en
otras regiones donde ACM no es gratis).

```bash
helm upgrade --install cert-manager jetstack/cert-manager \
  -n cert-manager --create-namespace \
  --set crds.enabled=true
```

Después aplicar un `ClusterIssuer` para Let's Encrypt:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: tu-email@midominio.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
      - http01:
          ingress:
            class: nginx
```

Y en el Ingress:

```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  tls:
    - hosts: [api01.midominio.com]
      secretName: api01-tls
```

cert-manager pide el cert, lo valida vía HTTP-01 challenge, lo guarda en
ese secret y lo renueva 60 días antes del vencimiento.

> Para que el HTTP-01 challenge funcione, el host tiene que ser
> alcanzable desde internet, lo cual implica tener el DNS resolviéndo al
> ALB **antes** de pedir el cert. Es un orden que se respeta una vez y
> después es automático.

---

## Recomendación final

- **Demo con dominio interno o de prueba** → Camino A (Route53 + ACM).
  Es la integración más limpia con EKS.
- **Producción cara al público** → Camino B.2 (Cloudflare proxied).
  La protección DDoS y el cache valen el cambio.
- **Multi-cloud o sin AWS** → Camino C (cert-manager + LE).

Los archivos de Terraform para cada camino están preparados pero
**comentados** en `terraform/modules/dns-tls/`. Activarlos es descomentar
el módulo y correr `terraform apply`. Ningún recurso se crea hasta que
pase eso.
