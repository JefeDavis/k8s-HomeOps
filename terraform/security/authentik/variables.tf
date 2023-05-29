variable "authentik_url" {
  type        = string
  description = "authentik url used to connect"
  default     = "http://authentik.security.svc.cluster.local:80"
}

variable "authentik_token" {
  type        = string
  description = "authentik token used for authentication to api"
  sensitive   = true
}
