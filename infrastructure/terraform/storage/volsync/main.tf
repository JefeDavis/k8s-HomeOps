terraform {
  required_providers {
    b2 = {
      source  = "Backblaze/b2"
      version = "~> 0.12.0"
    }
  }
  cloud {
    organization = "davishaus"
    workspaces {
      name = "volsync-provisioner"
    }
  }
}
