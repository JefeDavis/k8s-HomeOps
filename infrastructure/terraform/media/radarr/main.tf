terraform {
  required_providers {
    radarr = {
      source  = "devopsarr/radarr"
      version = "2.3.1"
    }
  }

  cloud {
    organization = "davishaus"
    workspaces {
      name = "radarr-provisioner"
    }
  }
}
