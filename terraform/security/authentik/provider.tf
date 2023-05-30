provider "authentik" {
  url   = var.authentik_url
  token = var.AUTHENTIK_BOOTSTRAP_TOKEN
  # Optionally set insecure to ignore TLS Certificates
  insecure = true
}
