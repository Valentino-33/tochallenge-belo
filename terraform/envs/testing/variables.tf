variable "region" {
  type    = string
  default = "us-east-1"
}

variable "cluster_name" {
  type    = string
  default = "belo-challenge-testing"
}

variable "kubernetes_version" {
  type = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.1.0.0/16"
}

variable "azs" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b"]
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.1.0.0/24", "10.1.1.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.1.16.0/20", "10.1.32.0/20"]
}

variable "endpoint_public_access_cidrs" {
  description = "CIDRs autorizados a hablar con la API de EKS. Restringir en producción real."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ami_id" {
  description = "AMI ID fija para los nodos Ubuntu 24.04 EKS. Obtener con: aws ec2 describe-images --owners 099720109477 --filters 'Name=name,Values=ubuntu-eks/k8s_1.35/images/hvm-ssd/ubuntu-noble-24.04-amd64-server-*' 'Name=state,Values=available' --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text --region us-east-1"
  type        = string
  default     = null
}

variable "ssh_key_name" {
  description = "Optional. SSH key para los nodos. Si null, solo se accede por SSM."
  type        = string
  default     = null
}

variable "dockerhub_user" {
  description = "User de Docker Hub. Solo para tagging y referencia."
  type        = string
  default     = "valentinobruno"
}
