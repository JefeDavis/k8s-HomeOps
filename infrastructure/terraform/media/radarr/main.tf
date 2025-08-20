terraform {
  required_providers {
    radarr = {
      source  = "devopsarr/radarr"
      version = "2.3.3"
    }
  }

  cloud {
    organization = "davishaus"
    workspaces {
      name = "radarr-provisioner"
    }
  }
}
