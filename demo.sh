#!/bin/bash
set -e

# project and service name
project=vault
service=consul-vault
vault="${project}_${service}"
COMPOSE_FILE=${COMPOSE_FILE:-docker-compose.yml}

# TLS setup paths
openssl_config=/usr/local/etc/openssl/openssl.cnf
ca=secrets/CA

# formatting
fmt_rev=$(tput rev)
fmt_bold=$(tput bold)
fmt_reset=$(tput sgr0)

help() {
    cat << EOF

This demonstration of Autopilot Pattern Vault will create a 3-node Vault cluster
with RPC over TLS, including initializing the vault and unsealing it with GPG
keys. We'll then create new ACLs in Vault and launch an example application
exercising these ACLs. Usage:

./demo.sh [options]   run the demo (see below for options)
./demo.sh help        show this help text
./demo.sh clean       remove demo PGP keys and CA

${fmt_bold}You can either provide the demo with PGP keys and TLS certificates or allow the
script to generate them for you. Parameters:${fmt_reset}

 -p, --pgp-key        use this PGP key in lieu of creating a new one
 -k, --tls-key        use this TLS key file in lieu of creating a CA and cert
 -c, --tls-cert       use this TLS cert file in lieu of creating a CA and cert
 -f, --compose-file   use this Docker Compose manifest
EOF
}

# prints the argument bold and then resets the terminal colors
bold() {
    echo "${fmt_bold}${1}${fmt_reset}"
}

check_triton() {
    echo
    bold '* Checking your setup...'
    echo './setup.sh check'
    COMPOSE_FILE=${COMPOSE_FILE} ./setup.sh check
}

up() {
    echo
    bold '* Standing up the Vault cluster...'
    echo "docker-compose -f ${COMPOSE_FILE} up -d"
    docker-compose -f "${COMPOSE_FILE}" up -d
    echo "docker-compose -f ${COMPOSE_FILE} scale ${service}=3"
    docker-compose -f "${COMPOSE_FILE}" scale "${service}"=3
}

wait_for_consul() {
    echo
    bold '* Waiting for Consul to form raft...'
    while :
    do
        docker exec -it ${vault}_1 consul info | grep -q "num_peers = 2" && break
        echo -n '.'
        sleep 1
    done
    reset # something here is breaking the terminal
}


check_tls() {
    if [ -z "${TLS_CERT}" ] || [ -z "${TLS_KEY}" ]; then
        cat << EOF
${fmt_rev}${fmt_bold}You have not provided a value for --tls-cert or --tls-key. In the next step we
will create a temporary certificate authority in the secrets/ directory and use
it to issue a TLS certificate. The TLS cert and its key will be uploaded to the
Vault instances.${fmt_reset}
EOF
        echo
        read -rsp $'Press any key to continue or Ctrl-C to cancel...\n' -n1 key
        echo
        _ca
        _cert
    fi
}


_ca() {
    [ -f "${ca}/ca_key.pem" ] && echo 'CA exists' && return
    [ -f "${ca}/ca_cert.pem" ] && echo 'CA exists' && return

    bold '* Creating a certificate authority...'
    mkdir -p "${ca}"

    # create a cert we can use to sign other certs (a CA)
    openssl req -new -x509 -days 3650 -extensions v3_ca \
            -keyout "${ca}/ca_key.pem" -out "${ca}/ca_cert.pem" \
            -config "${openssl_config}"
}

_cert() {
    [ -f "secrets/consul-vault.key.pem" ] && echo 'TLS certificate exists!' && return
    [ -f "secrets/consul-vault.csr.pem" ] && echo 'TLS certificate exists!' && return
    [ -f "secrets/consul-vault.cert.pem" ] && echo 'TLS certificate exists!' && return

    bold '* Creating a private key for Consul and Vault...'
    openssl genrsa -out "secrets/consul-vault.key.pem" 2048

    bold '* Generating a Certificate Signing Request for Consul and Vault...'
    openssl req -config ${openssl_config} \
            -key "secrets/consul-vault.key.pem" \
            -new -sha256 -out "secrets/consul-vault.csr.pem"

    bold '* Generating a TLS certificate for Consul and Vault...'
    openssl x509 -req -days 365 -sha256 \
            -CA "${ca}/ca_cert.pem" \
            -CAkey "${ca}/ca_key.pem" \
            -CAcreateserial \
            -in "secrets/consul-vault.csr.pem" \
            -out "secrets/consul-vault.cert.pem" \

    bold '* Verifying certificate...'
    openssl x509 -noout -text \
            -in "secrets/consul-vault.cert.pem"
}


check_pgp() {
    if [ -z ${PGP_KEY} ]; then
        cat << EOF
${fmt_rev}${fmt_bold}You have not provided a value for --pgp-key. In the next step we will create a
trusted PGP keypair in your GPG key ring. The public key will be uploaded to the
Vault instances. The private key will not be exported or leave this machine!${fmt_reset}
EOF
        echo
        read -rsp $'Press any key to continue or Ctrl-C to cancel...\n' -n1 key
        echo
        mkdir -p secrets/
        bold '* Creating PGP key...'
        gpg -q --batch --gen-key <<EOF
Key-Type: RSA
Key-Length: 2048
Name-Real: Example User
Name-Email: example@example.com
Expire-Date: 0
%commit
EOF
        gpg --export 'Example User <example@example.com>' | base64 > secrets/example.asc
        PGP_KEYFILE="example.asc"
        bold '* Created a PGP key and exported the public key to ./secrets/example.asc'
    else
        bold '* Exporting PGP public key ${PGP_KEY_ARG} to file'
        gpg --export "${PGP_KEY_ARG}" | base64 > secrets/${PGP_KEY_ARG}.asc
        PGP_KEYFILE="secrets/${PGP_KEY_ARG}.asc"
    fi
}

init() {
    echo
    bold '* Initializing the vault with your PGP key. If you had multiple keys you'
    bold '  would pass these into the setup script as follows:'
    echo '  ./setup.sh -k 'mykey1.asc,mykey2.asc' -t 2 init'
    echo
    echo "./setup.sh -k ${PGP_KEYFILE} -t 1 init"
    COMPOSE_FILE=${COMPOSE_FILE} ./setup.sh -k "${PGP_KEYFILE}" -t 1 init
}

unseal() {
    echo
    bold '* Unsealing the vault with your PGP key. If you had multiple keys,';
    bold '  each operator would unseal the vault with their own key as follows:'
    echo '  ./setup.sh unseal secrets/mykey1.asc.key'
    echo
    echo "./setup.sh unseal ${PGP_KEYFILE}.key"
    COMPOSE_FILE=${COMPOSE_FILE} ./setup.sh unseal "secrets/${PGP_KEYFILE}.key"
}

clean() {
    bold '* Deleting the key(s) associated with the example user'
    local key=$(gpg --list-keys 'Example User <example@example.com>' | awk -F'/| +' '/pub/{print $3}')
    gpg --delete-secret-keys $key
    gpg --delete-keys $key
    bold '* Deleting the CA and associated keys'
    rm -rf secrets/
}

main() {
    check_tls
    check_pgp
    check_triton
    up
    wait_for_consul
    init
    unseal
}

# ---------------------------------------------------
# parse arguments

while true; do
    case $1 in
        -p | --pgp-key ) PGP_KEY=$2; shift 2;;
        -k | --tls-key ) TLS_KEY=$2; shift 2;;
        -c | --tls-cert ) TLS_CERT=$2; shift 2;;
        -f | --compose-file ) COMPOSE_FILE=$2; shift 2;;
        _ca | check_* | clean | main | help) cmd=$1; shift; break;;
        *) break;;
    esac
done

if [ -z $cmd ]; then
    main
    exit
fi
$cmd $@
