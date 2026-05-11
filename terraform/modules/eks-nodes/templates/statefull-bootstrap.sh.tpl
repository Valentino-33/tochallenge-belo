#!/bin/bash
# Bootstrap del nodo statefull.
# 1. Atacha el EBS pre-creado por Terraform (busca por tag).
# 2. Lo formatea solo si está vacío.
# 3. Lo monta en /mnt/statefull y lo agrega a /etc/fstab.
# 4. Crea los symlinks que esperan Elasticsearch y Prometheus.
# 5. Corre el bootstrap de EKS — SIEMPRE, incluso si el EBS falla.

set -o pipefail

CLUSTER_NAME="${cluster_name}"
EBS_TAG_KEY="${cluster_name}-statefull"
MOUNT_POINT="/mnt/statefull"
DEVICE_NAME="/dev/sdf"

log() { echo "[bootstrap] $*"; }

# ── Metadata service ────────────────────────────────────────────────────────
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
INSTANCE_ID=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region)
AZ=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/availability-zone)

log "Instance: $INSTANCE_ID  Region: $REGION  AZ: $AZ"

# ── Función principal del EBS (no fatal si falla) ───────────────────────────
setup_ebs() {
  set -e

  # Buscar el EBS. Reintentar hasta 5 min para absorber el race con Terraform.
  VOLUME_ID=""
  for i in $(seq 1 30); do
    VOLUME_ID=$(aws ec2 describe-volumes \
      --region "$REGION" \
      --filters \
        "Name=tag:$EBS_TAG_KEY,Values=true" \
        "Name=availability-zone,Values=$AZ" \
      --query 'Volumes[0].VolumeId' \
      --output text 2>/dev/null || true)

    if [ -n "$VOLUME_ID" ] && [ "$VOLUME_ID" != "None" ]; then
      break
    fi
    log "Esperando EBS con tag $EBS_TAG_KEY=true en $AZ (intento $i/30)..."
    sleep 10
  done

  if [ -z "$VOLUME_ID" ] || [ "$VOLUME_ID" = "None" ]; then
    log "ERROR: no encontré EBS con tag $EBS_TAG_KEY=true en $AZ"
    return 1
  fi
  log "Volume: $VOLUME_ID"

  # Esperar si el volume está en transición.
  for i in $(seq 1 30); do
    STATE=$(aws ec2 describe-volumes --region "$REGION" --volume-ids "$VOLUME_ID" \
      --query 'Volumes[0].State' --output text)
    [ "$STATE" = "available" ] && break
    log "Volume state: $STATE — esperando..."
    sleep 10
  done

  # Atachar (idempotente: ignorar si ya está attached a esta instancia).
  CURRENT_ATTACH=$(aws ec2 describe-volumes --region "$REGION" --volume-ids "$VOLUME_ID" \
    --query 'Volumes[0].Attachments[0].InstanceId' --output text 2>/dev/null || echo "None")

  if [ "$CURRENT_ATTACH" != "$INSTANCE_ID" ]; then
    aws ec2 attach-volume \
      --region "$REGION" \
      --volume-id "$VOLUME_ID" \
      --instance-id "$INSTANCE_ID" \
      --device "$DEVICE_NAME"
  fi

  # Detectar el device NVMe correspondiente al EBS attached.
  DEVICE=""
  EXPECTED_BYTES=$(( ${ebs_size_gb} * 1024 * 1024 * 1024 ))
  for i in $(seq 1 30); do
    for d in /dev/nvme[1-9]n1; do
      [ -b "$d" ] || continue
      SIZE_BYTES=$(blockdev --getsize64 "$d" 2>/dev/null || echo 0)
      if [ "$SIZE_BYTES" -ge $(( EXPECTED_BYTES * 99 / 100 )) ] && \
         [ "$SIZE_BYTES" -le $(( EXPECTED_BYTES * 101 / 100 )) ]; then
        DEVICE="$d"
        break 2
      fi
    done
    sleep 2
  done

  if [ -z "$DEVICE" ]; then
    log "ERROR: no detecté dispositivo NVMe de ~${ebs_size_gb}G"
    lsblk
    return 1
  fi
  log "Device: $DEVICE"

  # Formatear solo si está vacío.
  if ! blkid "$DEVICE" >/dev/null 2>&1; then
    log "Formateando con xfs..."
    mkfs -t xfs "$DEVICE"
  fi

  # Montar y persistir en fstab.
  mkdir -p "$MOUNT_POINT"
  mount "$DEVICE" "$MOUNT_POINT"

  UUID=$(blkid -s UUID -o value "$DEVICE")
  grep -q "$UUID" /etc/fstab || \
    echo "UUID=$UUID $MOUNT_POINT xfs defaults,nofail 0 2" >> /etc/fstab

  # Symlinks y permisos para apps statefull.
  mkdir -p "$MOUNT_POINT/elasticsearch" "$MOUNT_POINT/prometheus" "$MOUNT_POINT/grafana"
  chown -R 1000:1000  "$MOUNT_POINT/elasticsearch"
  chown -R 65534:65534 "$MOUNT_POINT/prometheus"
  chown -R 472:472     "$MOUNT_POINT/grafana"

  ln -sfn "$MOUNT_POINT/elasticsearch" /var/lib/elasticsearch
  ln -sfn "$MOUNT_POINT/prometheus"    /var/lib/prometheus
  ln -sfn "$MOUNT_POINT/grafana"       /var/lib/grafana

  log "EBS listo en $MOUNT_POINT"
}

# Ejecutar setup EBS. Si falla, loguear pero NO abortar el bootstrap de EKS.
if ! setup_ebs; then
  log "WARN: setup EBS falló — el nodo se une al cluster igualmente."
  log "WARN: las apps statefull no arrancarán hasta que se resuelva el EBS."
fi

# ── Join al cluster EKS ─────────────────────────────────────────────────────
# Ubuntu usa /etc/eks/bootstrap.sh (igual que AL2). Labels y taints van en el node group.
log "Iniciando bootstrap EKS..."
/etc/eks/bootstrap.sh "${cluster_name}" \
  --b64-cluster-ca "${cluster_ca}" \
  --apiserver-endpoint "${cluster_endpoint}"
