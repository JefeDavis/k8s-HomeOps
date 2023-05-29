terraform {
  required_providers {
    prowlarr = {
      source  = "devopsarr/prowlarr"
      version = "1.5.0"
    }
  }

  cloud {
    organization = "davishaus"
    workspaces {
      name = "prowlarr-provisioner"
    }
  }
}
