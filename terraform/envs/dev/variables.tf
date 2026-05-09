variable "region" {
  type    = string
  default = "us-east-1"
}

variable "cluster_name" {
  type    = string
  default = "belo-challenge-dev"
}

variable "kubernetes_version" {
  type    = string
  default = "1.30"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "azs" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b"]
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.0.0/24", "10.0.1.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.16.0/20", "10.0.32.0/20"]
}

variable "endpoint_public_access_cidrs" {
  description = "CIDRs autorizados a hablar con la API de EKS. Restringir en producción real."
  type        = list(string)
  default     = ["0.0.0.0/0"]
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
