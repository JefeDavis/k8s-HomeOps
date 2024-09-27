terraform {
  required_providers {
    authentik = {
      source  = "goauthentik/authentik"
      version = "2024.8.4"
    }
  }
  cloud {
    organization = "davishaus"
    workspaces {
      name = "authentik-provisioner"
    }
  }
}
