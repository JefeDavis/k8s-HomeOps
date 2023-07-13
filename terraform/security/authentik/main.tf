terraform {
  required_providers {
    authentik = {
      source  = "goauthentik/authentik"
      version = "2023.6.0"
    }
    curl = {
      source  = "marcofranssen/curl"
      version = "0.2.2"
    }
  }
  cloud {
    organization = "davishaus"
    workspaces {
      name = "authentik-provisioner"
    }
  }
}
