terraform {
  required_providers {
    prowlarr = {
      source  = "devopsarr/prowlarr"
      version = "3.0.2"
    }
  }

  cloud {
    organization = "davishaus"
    workspaces {
      name = "prowlarr-provisioner"
    }
  }
}
