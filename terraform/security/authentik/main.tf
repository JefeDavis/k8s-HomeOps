terraform {
  required_providers {
    authentik = {
      source  = "goauthentik/authentik"
      version = "2023.5.0"
    }
  }
  cloud {
    organization = "davishaus"
    workspaces {
      name = "authentik-provisioner"
    }
  }
}

