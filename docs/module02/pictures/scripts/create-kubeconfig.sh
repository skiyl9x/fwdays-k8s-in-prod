#!/usr/bin/env bash
set -euo pipefail

if ! command -v kubectl >/dev/null 2>&1; then
  echo "Error: kubectl is required." >&2
  exit 1
fi

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 SERVICE_ACCOUNT NAMESPACE [OUTPUT_FILE]" >&2
  exit 1
fi

service_account="$1"
namespace="$2"
output_file="${3:-${HOME}/.kube/${namespace}-${service_account}-config}"
output_dir="$(dirname "$output_file")"
mkdir -p "$output_dir"
umask 077
tmp_file="$(mktemp "${output_file}.tmp.XXXXXX")"
trap 'rm -f "$tmp_file"' EXIT

server="$(kubectl config view --minify --flatten --raw -o jsonpath='{.clusters[0].cluster.server}')"
ca_data="$(kubectl config view --minify --flatten --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
token="$(kubectl create token "$service_account" --namespace "$namespace")"

if [[ -z "$server" ]]; then
  echo "Error: could not read the API server from the current kubectl context." >&2
  exit 1
fi

if [[ -z "$ca_data" ]]; then
  echo "Error: current cluster has no embedded CA data; refusing to create an insecure kubeconfig." >&2
  exit 1
fi

if [[ -z "$token" ]]; then
  echo "Error: kubectl returned an empty ServiceAccount token." >&2
  exit 1
fi

cat >"$tmp_file" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: ${namespace}-cluster
  cluster:
    server: "${server}"
    certificate-authority-data: ${ca_data}
users:
- name: ${namespace}-${service_account}
  user:
    token: ${token}
contexts:
- name: ${service_account}@${namespace}-cluster
  context:
    cluster: ${namespace}-cluster
    namespace: ${namespace}
    user: ${namespace}-${service_account}
current-context: ${service_account}@${namespace}-cluster
EOF

chmod 600 "$tmp_file"
mv -f "$tmp_file" "$output_file"
trap - EXIT
echo "Wrote kubeconfig to: $output_file"
echo "The ServiceAccount token is time-limited; rerun this script to renew it."
