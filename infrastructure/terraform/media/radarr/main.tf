terraform {
  required_providers {
    radarr = {
      source  = "devopsarr/radarr"
      version = "2.3.4"
    }
  }

  cloud {
    organization = "davishaus"
    workspaces {
      name = "radarr-provisioner"
    }
  }
}
