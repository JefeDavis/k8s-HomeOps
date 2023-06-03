variable "authentik_url" {
  type        = string
  description = "authentik url used to connect"
  default     = "http://authentik.security.svc.cluster.local:80"
}

variable "AUTHENTIK_BOOTSTRAP_TOKEN" {
  type        = string
  description = "authentik token used for authentication to api"
  sensitive   = true
}

variable "AUTHENTIK_PLEX_CLIENT_ID" {
  type        = string
  description = "client id to use for plex source authentication"
  sensitive   = true
}

variable "AUTHENTIK_PLEX_TOKEN" {
  type        = string
  description = "token to use for plex source authentication"
  sensitive   = true
}

variable "authentik_host" {
  type        = string
  description = "public url for authentik"
}

variable "applications" {
  type = map(object({
    url             = string
    group           = string
    skip_path_regex = optional(string)
  }))
}


# variable "user_details" {
#   type = object({
#     "name" : string,
#     "email" : string,
#     "username" : string,
#   })
# }
