terraform {
  required_providers {
    prowlarr = {
      source  = "devopsarr/prowlarr"
      version = "3.2.1"
    }
  }

  cloud {
    organization = "davishaus"
    workspaces {
      name = "prowlarr-provisioner"
    }
  }
}
