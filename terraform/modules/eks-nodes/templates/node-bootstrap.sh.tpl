#!/bin/bash
set -e

# Bootstrap del nodo Ubuntu para unirse al cluster EKS.
# Se usa en los node groups stateless y cicd, donde no hay EBS extra que montar.
# El script /etc/eks/bootstrap.sh está incluido en las AMIs Ubuntu de Canonical.
/etc/eks/bootstrap.sh "${cluster_name}" \
  --b64-cluster-ca "${cluster_ca}" \
  --apiserver-endpoint "${cluster_endpoint}"
