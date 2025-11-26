terraform {
  required_providers {
    prowlarr = {
      source  = "devopsarr/prowlarr"
      version = "3.1.0"
    }
  }

  cloud {
    organization = "davishaus"
    workspaces {
      name = "prowlarr-provisioner"
    }
  }
}
