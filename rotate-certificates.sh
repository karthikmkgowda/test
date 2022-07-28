#!/usr/bin/env bash
# Copyright (c) 2022 VMware, Inc.  All rights reserved.
# VMware Confidential

# Remove this for less verbosity
set -x

# Helper script to rotate all certificates of a Supervisor cluster
# when certificates have expired

# Check certificates expiration only
CHECK=

# Rotate. Use an explicit rotate argument to prevent running this
# script by mistake.
ROTATE=

# Only rotate certs on 7.0.1
U1_CERTS=

# Certificates directory
TLS_DIR=/etc/vmware/wcp/tls
CERT_PRIVATE_KEY_DIR=/dev/shm/wcp_decrypted_data

# List of all certs signed by k8s CA (in TLS_DIR)
CERTS=(authproxy.crt authproxy.cert docker-reg.crt mgmt.crt)
# List of private key files for each certificate (in CERT_PRIVATE_KEY_DIR)
# - SAME ORDER as CERTS array above!
CERT_PRIVATE_KEYS=(wcp-authproxy-key wcp-authproxy-key wcp-docker-reg-key wcp-mgmt-fip-key)

# SSL conf file (might not be there in older versions)
OPENSSL_CONF_FILE="/etc/vmware/wcp/openssl.conf"

# Print usage and exit with 1
usage() {
    cat << EOF
Usage: $0 -r [-c] [-h] [-d] [-u]

Will rotate all Supervisor certificates, i.e. the certificates signed by the Kubernetes CA.

Arguments:
-r                              rotate all certificates
-u                              rotate only certs on 7.0.1

Optional arguments:
-h help                         show this message
-c check                        only gives certificates status, do not rotate

EOF
    exit 1
}

# Check certificates expiration
# Usage: check_certificates
function check_certificates() {
  echo "Checking certificates status..."

  for i in "${!CERTS[@]}"; do
    c="${TLS_DIR}/${CERTS[i]}"
    if [ ! -f "${c}" ]; then
        echo "This setup does not have ${c}, skipping verification."
        continue
    fi

    echo
    echo "*** Displaying $c expiration/issuer/subject"
    openssl x509 -in "${c}" -noout -issuer -subject -dates

    echo
    echo -n "Validate keys match..."
    sha256_in_cert=$(openssl x509 -noout -modulus -in "${c}" | openssl sha256)
    sha256_key=$(openssl rsa -noout -modulus -in "$CERT_PRIVATE_KEY_DIR/${CERT_PRIVATE_KEYS[i]}" | openssl sha256)
    if [ "x${sha256_in_cert}" != "x${sha256_key}" ]; then
        echo "no"
        echo "!!! ERROR: certificate private keys do not match: certificate=$c key=$CERT_PRIVATE_KEY_DIR/${CERT_PRIVATE_KEYS[i]}"
    else
        echo "ok"
    fi
  done
}

# Create the open SSL conf as in: https://gitlab.eng.vmware.com/core-build/cayman_photon/-/blob/vmware-wcp/support/install/config/openssl.conf
# See https://gitlab.eng.vmware.com/core-build/cayman_photon/-/merge_requests/1712
# Usage: create_openssl_conf
function create_openssl_conf() {
   echo "Creating ${OPENSSL_CONF_FILE} as it does not exist (older version)"

  /usr/bin/mkdir -p /etc/vmware/wcp/tls/ca
  /usr/bin/touch /etc/vmware/wcp/tls/ca/index.txt
  /usr/bin/touch /etc/vmware/wcp/tls/ca/index.txt.attr
  /usr/bin/echo 00 > /etc/vmware/wcp/tls/ca/serial.txt

  /usr/bin/cat <<EOF > ${OPENSSL_CONF_FILE}
[ kubernetes_ca ]
certificate   = /etc/kubernetes/pki/ca.crt
private_key   = /etc/kubernetes/pki/ca.key
new_certs_dir = /etc/vmware/wcp/tls/ca
database      = /etc/vmware/wcp/tls/ca/index.txt
serial        = /etc/vmware/wcp/tls/ca/serial.txt

copy_extensions = copy          # Required to copy SANs from CSR to cert
unique_subject = no
default_md = sha256


# Copied from /etc/ssl/openssl.cnf, will sign anything present in the CSR.
[ server_cert_policy ]
countryName             = optional
stateOrProvinceName     = optional
localityName            = optional
organizationName        = optional
organizationalUnitName  = optional
commonName              = supplied
emailAddress            = optional

[ server_cert_ext ]
basicConstraints       = critical,CA:FALSE
subjectKeyIdentifier   = hash
# Key Identifier might be missing from a CA certificate generated by kubeadm
# pre-1.19 so it's important for authorityKeyIdentifier not to be mandatory
# as it'd break clusters upgraded from an old version.
authorityKeyIdentifier = keyid
keyUsage               = digitalSignature,keyEncipherment
extendedKeyUsage       = serverAuth

[ req ]
default_bits       = 2048
distinguished_name = req_distinguished_name
x509_extensions    = server_cert_req
req_extensions     = server_cert_req
extendedKeyUsage   = serverAuth

[ req_distinguished_name ]

[ server_cert_req ]
subjectKeyIdentifier = hash
keyUsage             = digitalSignature,keyEncipherment
extendedKeyUsage     = serverAuth

subjectAltName = @alt_names

[ alt_names ]
IP.1 = 127.0.0.1
EOF
}

function rotate_wcpagent_cert {
    echo "rotating wcpagent cert"
    echo "NOTE: if this process is taking too long, restart wcpsvc to trigger reconciliation"

    # Delete the wcpagent.cert. wcpsvc should detect the cert is missing if it is
    # reconciling and generate a new certificate by talking to VECS.
    wcpagent_cert="${TLS_DIR}/wcpagent.cert"
    local tmp="/tmp/certs-$(date +%s)"
    mkdir -p "${tmp}"
    mv "${wcpagent_cert}" "${tmp}"

    until [ -f "${wcpagent_cert}" ]; do echo "waiting for wcpsvc to generate new wcpagent.cert" && sleep 10; done

    echo "rotating wcpagent cert ... done"
}

# Rotate certificates
# Usage: rotate_certificates
function rotate_certificates() {
  echo "Rotating certificates status..."

  if [ ! -f ${OPENSSL_CONF_FILE} ] || ! grep -q 'kubernetes_ca' ${OPENSSL_CONF_FILE} 2>&1 > /dev/null; then
    create_openssl_conf
  else
    echo "${OPENSSL_CONF_FILE} exists and defines kubernetes_ca, using existing file."
  fi

  # Set our required various variables
  . /usr/lib/vmware-wcp/common-configure.sh
  mgmt_ip="$(get_mgmt_ip)"
  floating_ip="$(get_floating_ip)"
  ip="$(get_ip_address)"

  echo "========================="
  echo "IP:            ${ip}"
  echo "Floating IP:   ${floating_ip}"
  echo "Management IP: ${mgmt_ip}"
  echo "========================="
  echo

  for c in "${CERTS[@]}"; do
      if [ ! -f "${TLS_DIR}/${c}" ]; then
          echo "This setup does not have ${c}, skipping rotation."
          continue
      fi

      local skip_cert_generation=
      local cert_ext="crt"

      # For each cert, we have a different SAN to give.
      # For now, just do this case...
      case "${c}" in
        authproxy.crt)
            config_file_name="null"
            file_name="authproxy"
            cert_name="authproxy"

            san=$(generate_san "DNS" "localhost kube-apiserver-authproxy-svc \
                kube-apiserver-authproxy-svc.kube-system \
                kube-apiserver-authproxy-svc.kube-system.svc \
                kube-apiserver-authproxy-svc.kube-system.svc.cluster.local")
           ;;
        authproxy.cert)
           cert_ext="cert"
           config_file_name="null"
           file_name="authproxy"
           cert_name="authproxy"

           san=$(generate_san "DNS" "localhost kube-apiserver-authproxy-svc \
               kube-apiserver-authproxy-svc.kube-system \
               kube-apiserver-authproxy-svc.kube-system.svc \
               kube-apiserver-authproxy-svc.kube-system.svc.cluster.local")
           ;;
        docker-reg.crt)
            config_file_name="20-registry.conf"
            file_name="docker-reg"
            cert_name="docker-registry"

            san="IP.2=${ip}\nIP.3=${floating_ip}\nDNS.1=docker-registry.kube-system.svc\nDNS.2=localhost\nDNS.3=127.0.0.1\nDNS.4=${ip}"
            ;;
        mgmt.crt)
            config_file_name="10-mgmt.conf"
            file_name="mgmt"
            cert_name="mgmt-fip-$(hostname)"

            san=$(generate_san IP "${floating_ip} ${mgmt_ip}")
            ;;
        wcpagent.cert)
            echo "Skip generating wcpagent.cert via openssl"
            skip_cert_generation=1
            ;;
        *)
            echo "Unknown cert: $c"
            exit 1
            ;;
      esac

      if [ -z "${skip_cert_generation}" ]; then
          echo
          echo "*** Rotating $c..."
          echo

          echo "Generating CSR in /tmp/${c}-csr.txt ..."
          /usr/bin/openssl req -nodes -new -key "${TLS_DIR}/${file_name}.key" -subj "/C=US/ST=CA/L=Palo Alto/O=VMware/OU=VMware Engineering/CN=${cert_name}" -config <(cat ${OPENSSL_CONF_FILE} <(echo -e ${san})) > /tmp/${c}-csr.txt

          echo "Generating K8s certificate in ${TLS_DIR}/${file_name}.crt ..."
          /usr/bin/openssl ca -config ${OPENSSL_CONF_FILE} -name kubernetes_ca -extensions server_cert_ext -policy server_cert_policy -batch -days 730 -out "${TLS_DIR}/${file_name}.${cert_ext}" -in /tmp/${c}-csr.txt
      fi
  done

  generate_schedext_keypair

  # Should be required for most of the certificates
  stop_container "kubectl-plugin-vsphere"
}

function generate_schedext_keypair() {
  /usr/bin/openssl req -x509 -nodes -keyout "${TLS_DIR}/schedext.key" \
    -out "${TLS_DIR}/schedext.cert" -config "${WCP_CONFIG_DIR}/openssl.conf" \
    -subj "/C=US/ST=CA/L=Palo Alto/O=VMware/OU=WCP/CN=schedext" -days 730
}

# Backup all certificates
# Usage: backup_certificates
function backup_certificates() {
  local tmpDir=${1:-/tmp}

  local backupDir="${tmpDir}/backup"
  echo "Backup certificates into ${backupDir}..."

  /usr/bin/mkdir -p ${backupDir}
  /usr/bin/cp -rfp /dev/shm/wcp_decrypted_data/* ${backupDir}
  /usr/bin/cp -rfp /etc/vmware/wcp/tls/* ${backupDir}
}

while getopts "hcru" opt; do
    case "${opt}" in
        c)
            CHECK=1 ;;
        r)
            ROTATE=1 ;;
        u)
            U1_CERTS=1; CERTS+=(wcpagent.cert); CERT_PRIVATE_KEYS+=(wcp-agent-key) ;;
        h | *)
            usage ;;
    esac
done
shift $((OPTIND-1))

if [[ -z "$CHECK" ]] && [[ -z "$ROTATE" ]]; then
    usage
fi

if [[ -n "$CHECK" ]]; then
    check_certificates
fi

if [[ -n "$ROTATE" ]]; then
    backup_certificates
    rotate_certificates

    if [ -n "${U1_CERTS}" ]; then
        rotate_wcpagent_cert
    fi

    check_certificates
fi
