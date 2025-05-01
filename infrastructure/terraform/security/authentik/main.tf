terraform {
  required_providers {
    authentik = {
      source  = "goauthentik/authentik"
      version = "2025.4.0"
    }
  }
  cloud {
    organization = "davishaus"
    workspaces {
      name = "authentik-provisioner"
    }
  }
}
