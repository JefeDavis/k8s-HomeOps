terraform {
  required_providers {
    radarr = {
      source  = "devopsarr/radarr"
      version = "1.8.0"
    }
  }

  cloud {
    organization = "davishaus"
    workspaces {
      name = "radarr-provisioner"
    }
  }
}
