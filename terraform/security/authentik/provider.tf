provider "authentik" {
  url   = var.authentik_url
  token = var.authentik_token
  # Optionally set insecure to ignore TLS Certificates
  insecure = true
}
