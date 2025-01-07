#!/bin/bash

export APP=$1
export NAMESPACE1=$2
export NAMESPACE2=$3

export REPO_ROOT=$(git rev-parse --show-toplevel)
export APPS_ROOT="$REPO_ROOT/./kubernetes/jsdyb-k8s-001/apps"

need() {
    if ! command -v "$1" &> /dev/null
    then
        echo "Binary '$1' is missing but required"
        exit 1
    fi
}

need "kubectl"
need "yot"

message() {
  echo -e "\n######################################################################"
  echo "# $1"
  echo "######################################################################"
}

move-folder() {
  if [ -d $APPS_ROOT/$NAMESPACE1/$APP ]
  then
    if [ -d $APPS_ROOT/$NAMESPACE2 ]
    then
      mv $APPS_ROOT/$NAMESPACE1/$APP $APPS_ROOT/$NAMESPACE2
    else
      echo "unable to find new namespace folder"
      exit 1
    fi
  else
    echo "unable to find app folder"
    exit 1
  fi
}

scale-dp() {
  DP="$(kubectl get deployment -n $2 -l app.kubernetes.io/name=$1 -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}')"
  if [ -z "$DP" ]
  then
    echo "no deployments found"
    exit 1
  fi

  REPLICAS="$(kubectl get deployment $DP -n $2 -o jsonpath='{.spec.replicas}')"
  kubectl scale --replicas=0 deployment $DP -n $2
}

move-pvcs() {
  PVCS="$(kubectl get pvc -n $NAMESPACE1 -l app.kubernetes.io/name=$APP -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}')"
  if [ -z "$PVCS" ]
  then
    echo "no controlled pvcs found, skipping pvc migration"
    return
  fi

  for PVC in $PVCS
  do
    FOLDER="$APPS_ROOT/$NAMESPACE2/$APP"
    kubectl get pvc -n $NAMESPACE1 $PVC -o yaml > "$FOLDER/pvc-$PVC.yaml"

    cat > $FOLDER/instructions.yot <<- EOF
    commonOverlays:
    yamlFiles:
      - path: ./pvc-$PVC.yaml
        overlays:
          - query:
              - metadata.annotations['pv.kubernetes.io/bind-completed']
              - metadata.annotations['pv.kubernetes.io/bound-by-controller']
            action: Delete
          - query: 
              - metadata.labels['helm.toolkit.fluxcd.io/namespace']
              - metadata.namespace
              - metadata.annotations['meta.helm.sh/release-namespace']
            value: $NAMESPACE2
          - query:
              - metadata.resourceVersion
              - metadata.uid
              - metadata.selfLink
            action: Delete
EOF

    yot -i $FOLDER/instructions.yot -o $FOLDER

    rm $FOLDER/instructions.yot

    PV=$(kubectl get pvc $PVC -n $NAMESPACE1 -o jsonpath='{.spec.volumeName}')

    RECLAIM_POLICY="$(kubectl get pv  $PV -o jsonpath='{.spec.persistentVolumeReclaimPolicy}')"
    if [[ $RECLAIM_POLICY == 'Delete' ]]
    then
      kubectl patch pv $PV -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
    fi

    kubectl delete pvc $PVC -n $NAMESPACE1

    kubectl patch pv $PV -p '{"spec":{"claimRef":{"namespace":"'$NAMESPACE2'","name":"'$PVC'","uid":null}}}'

    kubectl apply -f $FOLDER/pvc-$PVC.yaml

    PVCUID="$(kubectl get pvc $PVC -n $NAMESPACE2 -o jsonpath='{.metadata.uid}')"

    kubectl patch pv $PV -p '{"spec":{"claimRef":{"uid":"'$PVCUID'","name":null}}}'

    if [[ $RECLAIM_POLICY == 'Delete' ]]
    then
      kubectl patch pv $PV -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}'
    fi

  done
}

update-resources() {
  FOLDER="$APPS_ROOT/$NAMESPACE2/$APP"
  cat > $FOLDER/instructions.yot <<- EOF
      commonOverlays:
        - query: ..*[?(@.storageClass)]
          value:
            existingClaim: $PVC
        - query: ..*[?(@.storageClass)].size
          action: Delete
        - query: ..*[?(@.storageClass)].storageClass
          action: Delete
        - query: .metadata.namespace
          value: $NAMESPACE2
        - query: .status
          action: Delete
      yamlFiles:
        - path: ./
EOF
  yot -i $FOLDER/instructions.yot -o $FOLDER

  rm $FOLDER/instructions.yot
}

commit-and-push() {
  git add $APPS_ROOT/$NAMESPACE1/$APP
  git add $APPS_ROOT/$NAMESPACE2/$APP
  git commit -s -m "refactor($APP): move to $NAMESPACE2 namespace"
  git pull && git push

  flux reconcile source git flux-system && flux reconcile kustomization flux-system
}

move-folder
scale-dp $APP $NAMESPACE1
move-pvcs
# update-resources
# commit-and-push

message "all done!"
