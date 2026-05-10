#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# Bootstrap del nodo statefull
# ──────────────────────────────────────────────────────────────────────────────
# 1. Atacha el EBS pre-creado por Terraform (busca por tag).
# 2. Lo formatea solo si está vacío.
# 3. Lo monta en /mnt/statefull y lo agrega a /etc/fstab.
# 4. Crea los symlinks que esperan Elasticsearch y Prometheus.
# 5. Después corre el bootstrap normal de EKS.
# ──────────────────────────────────────────────────────────────────────────────

set -e
set -o pipefail

CLUSTER_NAME="${cluster_name}"
EBS_TAG_KEY="${cluster_name}-statefull"
MOUNT_POINT="/mnt/statefull"
DEVICE_NAME="/dev/sdf"   # AWS lo va a mapear a /dev/nvme1n1 o similar

# Esperar a que el metadata service esté disponible.
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
INSTANCE_ID=$(curl -sH "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -sH "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)

echo "[bootstrap] Instance: $INSTANCE_ID  Region: $REGION"

# 1. Buscar el EBS por tag y atacharlo.
VOLUME_ID=$(aws ec2 describe-volumes \
  --region "$REGION" \
  --filters "Name=tag:$EBS_TAG_KEY,Values=true" "Name=availability-zone,Values=$(curl -sH "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)" \
  --query 'Volumes[0].VolumeId' \
  --output text)

if [ "$VOLUME_ID" = "None" ] || [ -z "$VOLUME_ID" ]; then
  echo "[bootstrap] ERROR: no encontré EBS con tag $EBS_TAG_KEY=true"
  exit 1
fi
echo "[bootstrap] Volume: $VOLUME_ID"

# Esperar si el volume está en un estado de transición.
for i in $(seq 1 30); do
  STATE=$(aws ec2 describe-volumes --region "$REGION" --volume-ids "$VOLUME_ID" --query 'Volumes[0].State' --output text)
  if [ "$STATE" = "available" ]; then break; fi
  if [ "$STATE" = "in-use" ]; then
    # Está atacheado a otro nodo (probablemente el viejo, en proceso de baja). Esperar.
    echo "[bootstrap] Volume in-use, esperando..."
    sleep 10
    continue
  fi
  sleep 5
done

# Atachar.
aws ec2 attach-volume \
  --region "$REGION" \
  --volume-id "$VOLUME_ID" \
  --instance-id "$INSTANCE_ID" \
  --device "$DEVICE_NAME"

# Esperar a que el OS lo vea y detectar el device correcto.
# El root volume es siempre /dev/nvme0n1; nuestro EBS attached es el primer
# nvme!=0 que aparezca con el tamaño esperado.
DEVICE=""
for i in $(seq 1 30); do
  for d in /dev/nvme[1-9]n1; do
    if [ -b "$d" ]; then
      # Confirmar que sea de nuestro tamaño (en KB lo que reporta blockdev)
      SIZE_BYTES=$(blockdev --getsize64 "$d" 2>/dev/null || echo 0)
      EXPECTED_BYTES=$(( ${ebs_size_gb} * 1024 * 1024 * 1024 ))
      # Tolerancia del 1% por overhead
      if [ "$SIZE_BYTES" -ge $(( EXPECTED_BYTES * 99 / 100 )) ] && \
         [ "$SIZE_BYTES" -le $(( EXPECTED_BYTES * 101 / 100 )) ]; then
        DEVICE="$d"
        break 2
      fi
    fi
  done
  sleep 2
done

if [ -z "$DEVICE" ]; then
  echo "[bootstrap] ERROR: no detecté un dispositivo NVMe attached de ~${ebs_size_gb}G"
  lsblk
  exit 1
fi
echo "[bootstrap] Device: $DEVICE"

# 2. Formatear si está vacío.
if ! blkid "$DEVICE" >/dev/null 2>&1; then
  echo "[bootstrap] Filesystem vacío, formateando con xfs..."
  mkfs -t xfs "$DEVICE"
fi

# 3. Montar y persistir en fstab.
mkdir -p "$MOUNT_POINT"
mount "$DEVICE" "$MOUNT_POINT"

UUID=$(blkid -s UUID -o value "$DEVICE")
if ! grep -q "$UUID" /etc/fstab; then
  echo "UUID=$UUID $MOUNT_POINT xfs defaults,nofail 0 2" >> /etc/fstab
fi

# 4. Symlinks para apps statefull.
mkdir -p "$MOUNT_POINT/elasticsearch" "$MOUNT_POINT/prometheus" "$MOUNT_POINT/grafana"
chown -R 1000:1000 "$MOUNT_POINT/elasticsearch"
chown -R 65534:65534 "$MOUNT_POINT/prometheus"
chown -R 472:472     "$MOUNT_POINT/grafana"

# Symlinks (idempotentes).
ln -sfn "$MOUNT_POINT/elasticsearch" /var/lib/elasticsearch
ln -sfn "$MOUNT_POINT/prometheus"    /var/lib/prometheus
ln -sfn "$MOUNT_POINT/grafana"       /var/lib/grafana

echo "[bootstrap] EBS listo en $MOUNT_POINT"
# El registro del nodo contra el control plane lo gestiona EKS vía nodeadm (AL2023).
# Labels y taints se definen en el aws_eks_node_group resource, no acá.
