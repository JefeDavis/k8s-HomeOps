terraform {
  required_providers {
    authentik = {
      source  = "goauthentik/authentik"
      version = "2025.10.1"
    }
  }
  cloud {
    organization = "davishaus"
    workspaces {
      name = "authentik-provisioner"
    }
  }
}
