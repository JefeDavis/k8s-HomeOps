terraform {
  required_providers {
    sonarr = {
      source  = "devopsarr/sonarr"
      version = "3.0.0"
    }
  }

  cloud {
    organization = "davishaus"
    workspaces {
      name = "sonarr-provisioner"
    }
  }
}
