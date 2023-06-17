#!/usr/bin/env bash

# Deploy the configuration to the nodes
talosctl apply-config -n 10.77.0.11 -f ./clusterconfig/jsdyb-k8s-001-jsdyb-nuc-001.internal.davishaus.dev.yaml
talosctl apply-config -n 10.77.0.12 -f ./clusterconfig/jsdyb-k8s-001-jsdyb-nuc-002.internal.davishaus.dev.yaml
talosctl apply-config -n 10.77.0.13 -f ./clusterconfig/jsdyb-k8s-001-jsdyb-nuc-003.internal.davishaus.dev.yaml
