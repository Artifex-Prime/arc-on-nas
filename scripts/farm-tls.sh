#!/usr/bin/env bash
# farm-tls.sh: the build farm's certificates (README, "Tenant namespaces", "The build farm's
# network"). The frontend speaks TLS with a key pair signed by a CA of the farm's own, which its
# clients trust; nothing else is signed by it.
#
#   scripts/farm-tls.sh ca DIR
#       makes the CA: DIR/ca.key (mode 600) and DIR/ca.crt, in a new directory DIR. Move the key
#       into a secret store and delete the file; ca.crt is public, and is what clients trust.
#   scripts/farm-tls.sh server --ca-cert FILE --ca-key FILE [NAME...]
#       signs a new key pair for the frontend and prints it as the Secret frontend-tls (JSON) on
#       standard output, for `kubectl -n build-farm apply -f -`. The frontend reads the renewed
#       files by itself within about two minutes. The key is made in a temporary directory that is
#       removed again, and is in nothing but the Secret.
# Options:
#   --days N         validity in days (default: 1825 for the CA, 90 for the frontend)
#   --secret NAME    the Secret's name (default frontend-tls)
#
# The frontend's certificate always names the frontend as the cluster's clients reach it
# (frontend, frontend.build-farm, frontend.build-farm.svc, frontend.build-farm.svc.cluster.local)
# and as the forwarder's clients do (build-farm, farm-forward.yml). Each NAME, a DNS name or an
# IPv4 address, is added: the name another route reaches it by. Keep private host names out of
# this repository: pass them here.
# Needs openssl and jq. The CA key may be a pipe: --ca-key <(secret-store get farm-ca-key).
set -euo pipefail

days=""
secret=frontend-tls
ca_cert=""
ca_key=""
args=()

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --days) days=${2:?--days needs a value}; shift 2 ;;
    --secret) secret=${2:?--secret needs a value}; shift 2 ;;
    --ca-cert) ca_cert=${2:?--ca-cert needs a value}; shift 2 ;;
    --ca-key) ca_key=${2:?--ca-key needs a value}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
[ "${#args[@]}" -ge 1 ] || { usage >&2; exit 2; }
command=${args[0]}
args=("${args[@]:1}")
if [ -n "$days" ]; then
  [[ "$days" =~ ^[0-9]+$ ]] && [ "$days" -ge 1 ] || { echo "--days must be a positive number" >&2; exit 2; }
fi

case "$command" in
  ca)
    [ "${#args[@]}" -eq 1 ] || { usage >&2; exit 2; }
    dir=${args[0]}
    [ ! -e "$dir" ] || { echo "$dir exists: the CA goes into a new directory" >&2; exit 2; }
    (umask 077 && mkdir -p "$dir")
    (umask 077 && openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$dir/ca.key")
    # A CA for server certificates only, with no CA below it.
    openssl req -new -x509 -key "$dir/ca.key" -sha256 -days "${days:-1825}" \
      -subj "/O=arc-on-nas/CN=build farm CA $(date -u +%Y-%m-%d)" \
      -addext "basicConstraints=critical,CA:true,pathlen:0" \
      -addext "keyUsage=critical,keyCertSign,cRLSign" \
      -addext "subjectKeyIdentifier=hash" \
      -out "$dir/ca.crt"
    openssl x509 -in "$dir/ca.crt" -noout -subject -enddate -fingerprint -sha256 >&2
    ;;

  server)
    [ -n "$ca_cert" ] && [ -n "$ca_key" ] || { echo "server needs --ca-cert and --ca-key" >&2; exit 2; }
    [[ "$secret" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { echo "--secret must be a DNS label: $secret" >&2; exit 2; }
    names=(frontend frontend.build-farm frontend.build-farm.svc frontend.build-farm.svc.cluster.local build-farm)
    names+=("${args[@]}")
    san=""
    dns_re='^([a-z0-9]([-a-z0-9]*[a-z0-9])?)(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$'
    ip_re='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    for n in "${names[@]}"; do
      if [[ "$n" =~ $ip_re ]]; then san+=",IP:$n"
      elif [[ "$n" =~ $dns_re ]]; then san+=",DNS:$n"
      else echo "not a DNS name or an IPv4 address: $n" >&2; exit 2
      fi
    done
    san=${san#,}

    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    # Read once: the key may come from a pipe.
    (umask 077 && cat "$ca_key" > "$tmp/ca.key")
    [ "$(openssl x509 -in "$ca_cert" -noout -pubkey)" = "$(openssl pkey -in "$tmp/ca.key" -pubout)" ] \
      || { echo "the CA key is not $ca_cert's" >&2; exit 1; }
    leaf_days=${days:-90}
    openssl x509 -in "$ca_cert" -noout -checkend $(( leaf_days * 86400 )) > /dev/null \
      || { echo "$ca_cert expires within $leaf_days days: make a new CA first (README)" >&2; exit 1; }
    (umask 077 && openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$tmp/tls.key")
    cat > "$tmp/ext.cnf" <<EOF
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = serverAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
subjectAltName = $san
EOF
    openssl req -new -key "$tmp/tls.key" -subj "/O=arc-on-nas/CN=frontend.build-farm" -out "$tmp/tls.csr"
    # A random positive serial of 120 bits.
    openssl x509 -req -in "$tmp/tls.csr" -CA "$ca_cert" -CAkey "$tmp/ca.key" -sha256 \
      -set_serial "0x7$(openssl rand -hex 15)" -days "$leaf_days" -extfile "$tmp/ext.cnf" \
      -out "$tmp/tls.crt" 2> /dev/null
    openssl verify -CAfile "$ca_cert" -purpose sslserver "$tmp/tls.crt" > /dev/null
    openssl x509 -in "$tmp/tls.crt" -noout -serial -enddate -ext subjectAltName >&2
    jq -n --arg name "$secret" --rawfile crt "$tmp/tls.crt" --rawfile key "$tmp/tls.key" --rawfile ca "$ca_cert" '
      {apiVersion: "v1", kind: "Secret", type: "kubernetes.io/tls",
       metadata: {name: $name, labels: {"app.kubernetes.io/name": "frontend", "app.kubernetes.io/part-of": "arc-on-nas"}},
       data: {"tls.crt": ($crt | @base64), "tls.key": ($key | @base64), "ca.crt": ($ca | @base64)}}'
    ;;

  *) usage >&2; exit 2 ;;
esac
