terraform {
  required_providers {
    b2 = {
      source  = "Backblaze/b2"
      version = "~> 0.10.0"
    }
  }
  cloud {
    organization = "davishaus"
    workspaces {
      name = "volsync-provisioner"
    }
  }
}
