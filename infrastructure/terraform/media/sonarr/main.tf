terraform {
  required_providers {
    sonarr = {
      source  = "devopsarr/sonarr"
      version = "3.4.2"
    }
  }

  cloud {
    organization = "davishaus"
    workspaces {
      name = "sonarr-provisioner"
    }
  }
}
