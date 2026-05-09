variable "cluster_name" {
  type = string
}

variable "oidc_provider_arn" {
  type = string
}

variable "oidc_provider_url" {
  type = string
}

variable "policy_file_path" {
  description = "Ruta al archivo iam_policy.json del ALB Controller. Lo baja el Makefile vía `make alb-policy`."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
