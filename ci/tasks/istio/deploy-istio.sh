#!/bin/bash

set -euo pipefail

# ENV
: "${KUBECONFIG_CONTEXT:?}"
: "${SHARED_DNS_ZONE_NAME:?}"
: "${DNS_DOMAIN:?}"
: "${GCP_DNS_SERVICE_ACCOUNT_KEY:?}"
: "${GCP_PROJECT_ID:?}"

function install_istio() {
  workspace=${PWD}
  export KUBECONFIG="${PWD}/kubeconfig/config"

  pushd istio > /dev/null
    kubectl config use-context ${KUBECONFIG_CONTEXT}
    kubectl create namespace istio-system || true

    # Install Istio CRDs
    helm template install/kubernetes/helm/istio-init --name istio-init --namespace istio-system | kubectl apply -f -
    sleep 5

    # Install Istio
    istio_value_overrides="${workspace}/cf-k8s-networking/ci/istio-config/enable-sidecar-access-logs.yml"
    helm template install/kubernetes/helm/istio --name istio --namespace istio-system --values ${istio_value_overrides} | kubectl apply -f -
  popd
}

function configure_dns() {
  tmp_dir="$(mktemp -d /tmp/deploy-istio.XXXXXXXX)"
  service_key_path="${tmp_dir}/gcp.json"

  echo "${GCP_DNS_SERVICE_ACCOUNT_KEY}" > "${service_key_path}"
  gcloud auth activate-service-account --key-file="${service_key_path}"
  gcloud config set project "${GCP_PROJECT_ID}"

  echo "Discovering Istio Gateway LB IP"
  external_static_ip=""
  while [ -z $external_static_ip ]; do
      sleep 10
      external_static_ip=$(kubectl get services/istio-ingressgateway -n istio-system --output="jsonpath={.status.loadBalancer.ingress[0].ip}")
  done

  echo "Configuring DNS for external IP: ${external_static_ip}"
  gcloud dns record-sets transaction start --zone="${SHARED_DNS_ZONE_NAME}"
  gcp_records_json="$( gcloud dns record-sets list --zone "${SHARED_DNS_ZONE_NAME}" --name "*.${DNS_DOMAIN}" --format=json )"
  record_count="$( echo "${gcp_records_json}" | jq 'length' )"
  if [ "${record_count}" != "0" ]; then
    existing_record_ip="$( echo "${gcp_records_json}" | jq -r '.[0].rrdatas | join(" ")' )"
    gcloud dns record-sets transaction remove --name "*.${DNS_DOMAIN}" --type=A --zone="${SHARED_DNS_ZONE_NAME}" --ttl=300 "${existing_record_ip}" --verbosity=debug
  fi
  gcloud dns record-sets transaction add --name "*.${DNS_DOMAIN}" --type=A --zone="${SHARED_DNS_ZONE_NAME}" --ttl=300 "${external_static_ip}" --verbosity=debug

  echo "Contents of transaction.yaml:"
  cat transaction.yaml
  gcloud dns record-sets transaction execute --zone="${SHARED_DNS_ZONE_NAME}" --verbosity=debug
}

function main() {
  install_istio
  configure_dns
}

main
