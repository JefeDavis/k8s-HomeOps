#!/bin/bash


# trap "exit" INT TERM
# trap "kill 0" EXIT

export REPO_ROOT=$(git rev-parse --show-toplevel)
export REPLIACS="0 1 2"

need() {
    if ! command -v "$1" &> /dev/null
    then
        echo "Binary '$1' is missing but required"
        exit 1
    fi
}

need "vault"
need "kubectl"
need "sed"
need "jq"

. "$REPO_ROOT"/setup/.env

message() {
  echo -e "\n######################################################################"
  echo "# $1"
  echo "######################################################################"
}

kvault() {
  name="secrets/$(dirname "$@")/$(basename -s .txt "$@")"
  echo "Writing $name to vault"
  if output=$(envsubst < "$REPO_ROOT/$*"); then
    printf '%s' "$output" | vault kv put "$name" values.yaml=-
  fi
}


kvault-env() {
  name="secrets/$(dirname "$@")/$(basename -s .txt "$@")"
  echo "Writing $name to vault"
  if output=$(envsubst < "$REPO_ROOT/$*"); then
    for line in $output
    do
      submit="$submit $line"
    done
      vault kv put "$name" $submit
  fi
}

kvault-tpl() {
  name="secrets/$(dirname "$@")/$(basename -s .tpl "$@")"
  echo "Writing $name to vault"
  if output=$(envsubst < "$REPO_ROOT/$*"); then
    for line in $output
    do
      submit="$submit $line"
    done
      vault kv put "$name" $submit
  fi
}


initVault() {
  message "initializing and unsealing vault (if necesary)"
  VAULT_READY=1
  while [ $VAULT_READY != 0 ]; do
    kubectl -n vault wait --for condition=Initialized pod/vault-0 > /dev/null 2>&1
    VAULT_READY="$?"
    if [ $VAULT_READY != 0 ]; then
      echo "waiting for vault pod to be somewhat ready..."
      sleep 10;
    fi
  done
  sleep 2

  VAULT_READY=1
  while [ $VAULT_READY != 0 ]; do
    init_status=$(kubectl -n vault exec "vault-0" -- vault status -format=json 2>/dev/null | jq -r '.initialized')
    if [ "$init_status" == "false" ] || [ "$init_status" == "true" ]; then
      VAULT_READY=0
    else
      echo "vault pod is almost ready, waiting for it to report status"
      sleep 5
    fi
  done

  sealed_status=$(kubectl -n vault exec "vault-0" -- vault status -format=json 2>/dev/null | jq -r '.sealed')
  init_status=$(kubectl -n vault exec "vault-0" -- vault status -format=json 2>/dev/null | jq -r '.initialized')

  if [ "$init_status" == "false" ]; then
    echo "initializing vault"
    vault_init=$(kubectl -n vault exec "vault-0" -- vault operator init -format json -recovery-shares=1 -recovery-threshold=1) || exit 1
    export VAULT_RECOVERY_TOKEN=$(echo $vault_init | jq -r '.recovery_keys_b64[0]')
    export VAULT_ROOT_TOKEN=$(echo $vault_init | jq -r '.root_token')
    echo "VAULT_RECOVERY_TOKEN is: $VAULT_RECOVERY_TOKEN"
    echo "VAULT_ROOT_TOKEN is: $VAULT_ROOT_TOKEN"

    # sed -i operates differently in OSX vs linux
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "darwin system"
        sed -i '' "s~VAULT_ROOT_TOKEN=\".*\"~VAULT_ROOT_TOKEN=\"$VAULT_ROOT_TOKEN\"~" "$REPO_ROOT"/setup/.env
        sed -i '' "s~VAULT_RECOVERY_TOKEN=\".*\"~VAULT_RECOVERY_TOKEN=\"$VAULT_RECOVERY_TOKEN\"~" "$REPO_ROOT"/setup/.env
    else
        echo "non-darwin (linux?) system"
        sed -i'' "s~VAULT_ROOT_TOKEN=\".*\"~VAULT_ROOT_TOKEN=\"$VAULT_ROOT_TOKEN\"~" "$REPO_ROOT"/setup/.env
        sed -i'' "s~VAULT_RECOVERY_TOKEN=\".*\"~VAULT_RECOVERY_TOKEN=\"$VAULT_RECOVERY_TOKEN\"~" "$REPO_ROOT"/setup/.env
    fi
    echo "SAVE THESE VALUES!"

    REPLIACS_LIST=($REPLIACS)
    echo "sleeping 10 seconds to allow first vault to be ready"
    sleep 10
    for replica in "${REPLIACS_LIST[@]:1}"; do
      echo "joining pod vault-${replica} to raft cluster"
      kubectl -n vault exec "vault-${replica}" -- vault operator raft join http://vault-0.vault-internal:8200 || exit 1
    done

    FIRST_RUN=0
  fi

  if [ "$sealed_status" == "true" ]; then
    echo "unsealing vault"
    for replica in $REPLIACS; do
      echo "unsealing vault-${replica}"
      kubectl -n vault exec "vault-${replica}" -- vault operator unseal "$VAULT_RECOVERY_TOKEN" || exit 1
    done
  fi
}

portForwardVault() {
  message "port-forwarding vault"
  kubectl -n vault port-forward svc/vault 8200:8200 >/dev/null 2>&1 &
  export VAULT_FWD_PID=$!

  sleep 5
}

loginVault() {
  message "logging into vault"
  if [ -z "$VAULT_ROOT_TOKEN" ]; then
    echo "VAULT_ROOT_TOKEN is not set! Check $REPO_ROOT/setup/.env"
    exit 1
  fi

  vault login -no-print "$VAULT_ROOT_TOKEN" || exit 1

  vault auth list >/dev/null 2>&1
  if [[ "$?" -ne 0 ]]; then
    echo "not logged into vault!"
    echo "1. port-forward the vault service (e.g. 'kubectl -n vault port-forward svc/vault 8200:8200 &')"
    echo "2. set VAULT_ADDR (e.g. 'export VAULT_ADDR=http://localhost:8200')"
    echo "3. login: (e.g. 'vault login <some token>')"
    exit 1
  fi
}

setupVaultSecretsOperator() {
  message "configuring vault for vault-secrets-operator"
  vault secrets enable -path=secrets -version=2 kv

  # create read-only policy for kubernetes
  cat <<EOF | vault policy write vault-secrets-operator -
  path "secrets/data/*" {
    capabilities = ["read"]
  }
EOF

  export VAULT_SECRETS_OPERATOR_NAMESPACE=$(kubectl -n vault get sa vault-secrets-operator -o jsonpath="{.metadata.namespace}")
  export VAULT_SECRET_NAME=$(kubectl -n vault get sa vault-secrets-operator -o jsonpath="{.secrets[*]['name']}")
  export SA_JWT_TOKEN=$(kubectl -n vault get secret $VAULT_SECRET_NAME -o jsonpath="{.data.token}" | base64 --decode; echo)
  export SA_CA_CRT=$(kubectl -n vault get secret $VAULT_SECRET_NAME -o jsonpath="{.data['ca\.crt']}" | base64 --decode; echo)
  export K8S_HOST=$(kubectl -n vault config view --minify -o jsonpath='{.clusters[0].cluster.server}')

  # Verify the environment variables
  # env | grep -E 'VAULT_SECRETS_OPERATOR_NAMESPACE|VAULT_SECRET_NAME|SA_JWT_TOKEN|SA_CA_CRT|K8S_HOST'

  vault auth enable kubernetes

  # Tell Vault how to communicate with the Kubernetes cluster
  vault write auth/kubernetes/config \
    token_reviewer_jwt="$SA_JWT_TOKEN" \
    kubernetes_host="$K8S_HOST" \
    kubernetes_ca_cert="$SA_CA_CRT"

  # Create a role named, 'vault-secrets-operator' to map Kubernetes Service Account to Vault policies and default token TTL
  vault write auth/kubernetes/role/vault-secrets-operator \
    bound_service_account_names="vault-secrets-operator" \
    bound_service_account_namespaces="$VAULT_SECRETS_OPERATOR_NAMESPACE" \
    policies=vault-secrets-operator \
    ttl=24h
}

setupExternalSecrets() {
  message "configuring vault for external-secrets"
  vault secrets enable -path=secrets -version=2 kv

  # create read-only policy for kubernetes
  cat <<EOF | vault policy write external-secrets -
  path "secrets/data/*" {
    capabilities = ["read"]
  }
EOF

  export EXTERNAL_SECRETS_NAMESPACE=$(kubectl -n external-secrets get sa external-secrets -o jsonpath="{.metadata.namespace}")
  export K8S_HOST=$(kubectl -n external-secrets config view --minify -o jsonpath='{.clusters[0].cluster.server}')

  # Verify the environment variables
  # env | grep -E 'VAULT_SECRETS_OPERATOR_NAMESPACE|VAULT_SECRET_NAME|SA_JWT_TOKEN|SA_CA_CRT|K8S_HOST'

  vault auth enable kubernetes

  # Tell Vault how to communicate with the Kubernetes cluster
  vault write auth/kubernetes/config \
    kubernetes_host="$K8S_HOST" \

  # Create a role named, 'vault-secrets-operator' to map Kubernetes Service Account to Vault policies and default token TTL
  vault write auth/kubernetes/role/external-secrets \
    bound_service_account_names="external-secrets" \
    bound_service_account_namespaces="$EXTERNAL_SECRETS_NAMESPACE" \
    policies=external-secrets \
    ttl=24h
}

loadSecretsToVault() {
  message "writing secrets to vault"
  vault kv put secrets/flux-system/discord-webhook address="$DISCORD_FLUX_WEBHOOK_URL"
  vault kv put secrets/media/plex/claim-token claimToken="$PLEX_CLAIM_TOKEN"

  ####################
  # helm chart values
  ####################
  kvault-tpl "apps/system/kured/secret/kured.tpl"
  kvault-tpl "apps/security/authentik/secret/authentik.tpl"
  kvault-tpl "apps/network/external-dns/secret/external-dns.tpl"
  kvault-tpl "apps/storage/synology-csi/secret/synology-secret.tpl"
  kvault-tpl "apps/media/common/secret/starr-apps-secret.tpl"
  kvault-tpl "apps/home/emqx/secret/emqx.tpl"
  kvault-tpl "apps/home/zigbee2mqtt/secret/zigbee2mqtt.tpl"
  kvault-tpl "apps/home/home-assistant/secret/home-assistant.tpl"

  kvault "/grafana/chart/grafana-helm-values.txt"
  kvault "/kube-prometheus-stack/chart/kube-prometheus-stack-helm-values.txt"
  kvault "vpn-gateway/chart/vpn-gateway-helm-values.txt"
  kvault-env "vaultwarden/vaultwarden-secret.txt"
}

loadSecretsToVault-oneoff() {
  message "writing secrets to vault"
  kvault "/kube-prometheus-stack/chart/kube-prometheus-stack-helm-values.txt"
  kvault "/grafana/chart/grafana-helm-values.txt"
  kvault "external-dns/chart/external-dns-helm-values.txt"
  kvault "auth/oauth2-proxy/chart/oauth2-proxy-helm-values.txt"
  kvault "auth/authentik/chart/authentik-helm-values.txt"
  kvault "mqtt/emqx/chart/emqx-helm-values.txt"
  kvault "home-assistant/chart/home-assistant-helm-values.txt"
  kvault "zigbee/zigbee2mqtt/chart/zigbee2mqtt-helm-values.txt"
  # kvault "media/plex/chart/plex-helm-values.txt"
  # kvault "logs/loki/loki-helm-values.txt"
  kvault "vpn-gateway/chart/vpn-gateway-helm-values.txt"
  kvault-env "vaultwarden/vaultwarden-secret.txt"
  kvault-env "vpn/starr-apps-secret.txt"
}


FIRST_RUN=1
export KUBECONFIG="$REPO_ROOT/setup/kubeconfig"
export VAULT_ADDR='http://127.0.0.1:8200'

initVault
portForwardVault
loginVault
if [ $FIRST_RUN == 0 ]; then
  setupVaultSecretsOperator
  setupExternalSecrets
fi

loadSecretsToVault

kill $VAULT_FWD_PID
