# Talos
## Prequisites

* You need talhelper installed on your workstation (of course), head over to the Installation page for more detail.
* You also need sops installed and configured with your preferred encryption tool (age, pgp, etc).
* You also need talosctl installed on your workstation to apply the generated machine config files.


## Create Env File (optional)
an optional env file can be created to store variables that can be subsituted in
the talconfig.yaml on manifest generation

```
touch talenv.sops.yaml
sops -e -i talenv.sops.yaml
```
## Create Talos Secrets

```
talhelper gensecret > talsecret.sops.yaml
sops -e -i talsecret.sops.yaml
talhelper genconfig
export TALOSCONFIG=~/k8s-HomeOps/talos/clusterconfig/talosconfig
```

## Boostrap
* load the Talos image onto a usb and boot your device from it
* either statically set ip addresses in the KVM or use DHCP reservations to obtain
  an IP address
* run the bootstrap script
```
bootstrap.sh
```


## Updates

if you need to make a change to your talos config run `generate.sh` to generate a
new config with your added changes then run `apply.sh` to apply them
