#!/bin/bash
set -e -o pipefail

help() {
cat << EOF
Usage: ./setup.sh [options] <command>
--------------------------------------------------------------------------------
setup.sh check:
	Checks that your Triton and Docker environment is sane and configures an
	environment file with a CNS record for Consul.

setup.sh up:
	Starts a 3-node Vault cluster via Docker Compose and waits for all instances
	to be up. Once instances are up, it will poll Consul's status to ensure the
	raft has been created.

setup.sh secure:
	Generates a token for gossip encryption and uploads the TLS cert for RPC
	encryption to the Consul cluster, updates the Consul configuration file to
	use these keys, and SIGHUPs all the instances. This should be run before the
	Vault is initialized and unsealed. Use the following options:

	--tls-key/-k <val>:
		The file containing the TLS key (in PEM format) used to encrypt RPC.

	--tls-cert/-c <val>:
		The file containing the TLS cert (in PEM format) used to encrypt RPC.

	--ca-cert/-a <val>:
		The file containing the CA cert (in PEM format) used to sign the TLS
		cert. If the cert is self-signed or signed by a CA found in the
		container's certificate chain, this argument may be omitted.


setup.sh init:
	Initializes a started Vault cluster. Creates encrypted keyfiles for each
	operator's public key, which should be redistributed back to operators
	out-of-band. Use the following options:

	--keys/-k "<val>,<val>":
		List of public keys used to initialize the vault. These keys
		must be base64 encoded public keys without ASCII armoring.
	--threshold/-t <val>:
		Optional number of keys required to unseal the vault. Defaults
		to 1 if a single --keys argument was provided, otherwise 2.

setup.sh unseal [keyfile]:
	Unseals a Vault with the provided operator's key. Requires access to all
	Vault nodes via 'docker exec'. A number of operator keys equal to the
	'--threshold' parameter (above) must be used to unseal the Vault.

setup.sh policy [policyname] [policyfile]:
	Adds an ACL to the Vault cluster by uploading a policy HCL file and writing
	it via 'vault policy-write'.

--------------------------------------------------------------------------------

setup.sh demo:
	Runs a demonstration of the entire stack on Triton, creating a 3-node
	cluster with RPC over TLS. The demo includes initializing the Vault and
	unsealing it with PGP keys. You can either provide the demo with PGP keys
	and TLS certificates or allow the script to generate them for you.
	Parameters:

	-p, --pgp-key        use this PGP key in lieu of creating a new one
	-k, --tls-key        use this TLS key file in lieu of creating a CA and cert
	-c, --tls-cert       use this TLS cert file in lieu of creating a CA and cert-
	-f, --compose-file   use this Docker Compose manifest

setup.sh demo clean:
	Cleans up the demo PGP keys and CA.

EOF

}

# project and service name
repo=autopilotpattern/vault
project_version=0.1
project=vault
service=vault
vault="${project}_${service}"
COMPOSE_FILE=${COMPOSE_FILE:-docker-compose.yml}

# TLS setup paths
openssl_config=/usr/local/etc/openssl/openssl.cnf
ca=secrets/CA
tls_cert=
tls_key=
ca_cert=

# formatting
fmt_rev=$(tput rev)
fmt_bold=$(tput bold)
fmt_reset=$(tput sgr0)

# populated by `check` function whenever we're using Triton
TRITON_USER=
TRITON_DC=
TRITON_ACCOUNT=

# prints the argument bold and then resets the terminal colors
bold() {
    echo "${fmt_bold}${1}${fmt_reset}"
}

# checks that a file exists and exits with an error if not
_file_or_exit() {
    if [ ! -f "${1}" ]; then
        echo "${2}"
        exit 1
    fi
}

# checks if a variable is set and exits with an error if not
# usage: _var_or_exit myvar "text of error"
_var_or_exit() {
    if [ -z ${!1} ]; then
        echo "${2}"
        exit 1
    fi
}

# upload public key file to Vault
_copy_key() {
    local keyfile=$1
    echo "Uploading public keyfile ${keyfile} to vault instance"
    docker cp secrets/${keyfile} ${vault}_1:${keyfile}
}

# create gossip token, and install token and keys on Consul instances
# to encrypt both gossip and RPC
secure() {

    while true; do
        case $1 in
            -k | --tls-key ) tls_key=$2; shift 2;;
            -c | --tls-cert ) tls_cert=$2; shift 2;;
            -a | --ca-cert ) ca_cert=$2; shift 2;;
            -g | --gossip ) gossipKey=$2; shift 2;;
            *) break;;
        esac
    done

    if [ -z ${gossipKey} ]; then
        echo 'Gossip key not provided; will be generated at secrets/gossip.key'
        gossipKey=$(docker exec -it ${vault}_1 consul keygen | tr -d '\r')
        echo ${gossipKey} > secrets/gossip.key
    fi

    if [ -z ${ca_cert} ]; then
        echo "CA cert not provided. Assuming self-signed or already in cert store"
    fi
    _file_or_exit "${ca_cert}" "CA cert ${ca_cert} does not exist. Exiting!"
    _file_or_exit "${tls_cert}" "TLS cert ${tls_cert} does not exist. Exiting!"
    _file_or_exit "${tls_key}" "TLS cert ${tls_key} does not exist. Exiting!"

    local tls_config=./etc/consul-tls.json

    json -f /etc/consul.json \
         -e $(printf 'this.ca_file="/etc/ssl/certs/%s"' $(basename ${ca_cert})) \
         -e $(printf 'this.cert_file="/etc/ssl/certs/%s"' $(basename ${tls_cert})) \
         -e $(printf 'this.key_file="/etc/ssl/private/%s"' $(basename ${tls_key})) \
         -e $(printf 'this.encrypt="%s"' "${gossipKey}") \
         > ${tls_config}
    exit
    for i in {1..3}; do
        docker exec -it ${vault}_$i mkdir -p /etc/ssl/private
        docker cp ${ca_cert} ${vault}_$i:/etc/ssl/certs/$(basename ${ca_cert})
        docker cp ${tls_cert} ${vault}_$i:/etc/ssl/certs/$(basename ${tls_cert})
        docker cp ${tls_key} ${vault}_$i:/etc/ssl/private/$(basename ${tls_key})
        docker cp ${tls_config} ${vault}_$i:/etc/consul/consul.json
    done

    # unfortunately we can't do a graceful reload here
    echo
    echo 'Restarting cluster with new configuration'
    docker-compose restart ${service}
}

# ensure that the user has provided public key(s) and that a valid
# threshold value has been set.
_validate_args() {
    _var_or_exit KEYS 'You must supply at least one public keyfile!'
    if [ -z ${THRESHOLD} ]; then
        if [ ${#KEYS[@]} -lt 2 ]; then
            echo 'No threshold provided; 1 key will be required to unseal vault'
            THRESHOLD=1
        else
            echo 'No threshold provided; 2 keys will be required to unseal vault'
            THRESHOLD=2
        fi
    fi
    if [ ${THRESHOLD} -gt ${#KEYS[@]} ]; then
        echo 'Threshold is greater than the number of keys!'
        exit 1
    fi
    if [ ${#KEYS[@]} -gt 1 ] && [ ${THRESHOLD} -lt 2 ]; then
        echo 'Threshold must be greater than 1 if you have multiple keys!'
        exit 1
    fi
}

_split_encrypted_keys() {
    for i in "${!KEYS[@]}"; do
        keyNum=$(($i+1))
        awk -F': ' "/^Unseal Key $keyNum \(hex\)/{print \$2}" \
            secrets/vault.keys > "secrets/${KEYS[$i]}.key"
        echo "Created encrypted key file for ${KEYS[$i]}: ${KEYS[$i]}.key"
    done
}

_print_root_token() {
    grep 'Initial Root Token' secrets/vault.keys
}

# upload PGP keys passed in as comma-separated file names and
# then initialized the vault with those keys. The first key
# will be used in unseal() so it should be your key
init() {
    mkdir -p secrets/
    IFS=',' read -r -a KEYS <<< "${KEYS_ARG}"
    _validate_args
    for key in ${KEYS[@]}
    do
        _copy_key ${key}
    done
    docker exec -it ${vault}_1 vault init \
           -address='http://127.0.0.1:8200' \
           -key-shares=${#KEYS[@]} \
           -key-threshold=${THRESHOLD} \
           -pgp-keys="${KEYS_ARG}" > secrets/vault.keys \
    && echo 'Vault initialized.'

    echo
    _split_encrypted_keys
    _print_root_token
    echo 'Distribute encrypted key files to operators for unsealing.'
}

# use the encrypted keyfile to unseal all vault nodes. this needs to be
# performed by a minimum number of operators equal to the threshold set
# when initializing
unseal() {
    local keyfile=$1
    _var_or_exit keyfile 'You must provide an encrypted key file!'
    _file_or_exit "${keyfile}" "${keyfile} not found."

    echo 'Decrypting key. You may be prompted for your key password...'
    cat ${keyfile} | xxd -r -p | gpg -d

    echo
    echo 'Use the token above when prompted while we unseal each Vault node...'
    for i in {1..3}; do
        docker exec -it ${vault}_$i \
             vault unseal -address='http://127.0.0.1:8200'
    done
}

# upload a local policy file to a Vault instance and write it to the Vault
# via `docker exec`
policy() {
    local policyname=$1
    local policyfile=$2
    _var_or_exit policyname 'You must provide a name for the policy!'
    _file_or_exit "${policyfile}" "${policyfile} not found."

    docker cp ${policyfile} ${vault}_1:/tmp/$(basename ${policyfile})
    docker exec -it ${vault}_1 vault auth -address='http://127.0.0.1:8200'
    docker exec -it ${vault}_1 \
           vault policy-write -address='http://127.0.0.1:8200' \
           $(basename ${policyname}) /tmp/${policyfile}
}


# Check for correct configuration for running on Triton.
# Create _env file with CNS name for Consul.
check() {

    command -v docker >/dev/null 2>&1 || {
        echo
        echo 'Error! Docker is not installed!'
        echo 'See https://docs.joyent.com/public-cloud/api-access/docker'
        exit 1
    }
    if [ ${COMPOSE_FILE} != "local-compose.yml" ]; then
    command -v triton >/dev/null 2>&1 || {
        echo
        echo 'Error! Joyent Triton CLI is not installed!'
        echo 'See https://www.joyent.com/blog/introducing-the-triton-command-line-tool'
        exit 1
    }
    fi
    command -v gpg >/dev/null 2>&1 || {
        echo
        echo 'Error! GPG is not installed!'
        exit 1
    }

    if [ ${COMPOSE_FILE} != "local-compose.yml" ]; then
        # make sure Docker client is pointed to the same place as the Triton client
        local docker_user=$(docker info 2>&1 | awk -F": " '/SDCAccount:/{print $2}')
        local docker_dc=$(echo $DOCKER_HOST | awk -F"/" '{print $3}' | awk -F'.' '{print $1}')
        TRITON_USER=$(triton profile get | awk -F": " '/account:/{print $2}')
        TRITON_DC=$(triton profile get | awk -F"/" '/url:/{print $3}' | awk -F'.' '{print $1}')
        TRITON_ACCOUNT=$(triton account get | awk -F": " '/id:/{print $2}')
        if [ ! "$docker_user" = "$TRITON_USER" ] || [ ! "$docker_dc" = "$TRITON_DC" ]; then
            echo
            echo 'Error! The Triton CLI configuration does not match the Docker CLI configuration.'
            echo "Docker user: ${docker_user}"
            echo "Triton user: ${TRITON_USER}"
            echo "Docker data center: ${docker_dc}"
            echo "Triton data center: ${TRITON_DC}"
            exit 1
        fi

        local triton_cns_enabled=$(triton account get | awk -F": " '/cns/{print $2}')
        if [ ! "true" == "$triton_cns_enabled" ]; then
            echo
            echo 'Error! Triton CNS is required and not enabled.'
            exit 1
        fi

        # setup environment file
        if [ ! -f "_env" ]; then
            echo '# Bootstrap via Triton CNS' >> _env
            echo CONSUL=consul.svc.${TRITON_ACCOUNT}.${TRITON_DC}.cns.joyent.com >> _env
            echo VAULT=vault.svc.${TRITON_ACCOUNT}.${TRITON_DC}.cns.joyent.com >> _env
            echo >> _env
        else
            echo 'Existing _env file found, exiting'
            exit
        fi
    fi
}

check_triton() {
    echo
    bold '* Checking your setup...'
    echo './setup.sh check'
    COMPOSE_FILE=${COMPOSE_FILE} ./setup.sh check
}

up() {
    _demo_up
    _demo_wait_for_consul
}

_demo_up() {
    echo
    bold '* Standing up the Vault cluster...'
    echo "docker-compose -f ${COMPOSE_FILE} up -d"
    docker-compose -f "${COMPOSE_FILE}" up -d vault consul
    echo "docker-compose -f ${COMPOSE_FILE} scale ${service}=3"
    docker-compose -f "${COMPOSE_FILE}" scale "${service}"=3
}

_demo_secure() {
    echo
    bold '* Encrypting Consul gossip and RPC'
    secure
}

_demo_wait_for_consul() {
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
    if [ -z "${tls_cert}" ] || [ -z "${tls_key}" ]; then
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
    _file_or_exit "${tls_cert}" "${tls_cert} does not exist!"
    _file_or_exit "${tls_key}" "${tls_key} does not exist!"
}

_ca() {
    [ -f "${ca}/ca_key.pem" ] && echo 'CA exists' && return
    [ -f "${ca_cert}" ] && echo 'CA exists' && return

    bold '* Creating a certificate authority...'
    mkdir -p "${ca}"

    # create a cert we can use to sign other certs (a CA)
    openssl req -new -x509 -days 3650 -extensions v3_ca \
            -keyout "${ca}/ca_key.pem" -out "${ca}/ca_cert.pem" \
            -config "${openssl_config}"
    ca_cert="${ca}/ca_cert.pem"
}

_cert() {
    tls_key=${tls_key:-secrets/consul-vault.key.pem}
    tls_cert=${tls_cert:-secrets/consul-vault.cert.pem}

    [ -f "${tls_key}" ] && echo 'TLS certificate exists!' && return
    [ -f "${tls_cert}" ] && echo 'TLS certificate exists!' && return

    echo
    bold '* Creating a private key for Consul and Vault...'
    openssl genrsa -out "${tls_key}" 2048

    echo
    bold '* Generating a Certificate Signing Request for Consul and Vault...'
    openssl req -config ${openssl_config} \
            -key "${tls_key}" \
            -new -sha256 -out "secrets/consul-vault.csr.pem"

    echo
    bold '* Generating a TLS certificate for Consul and Vault...'
    openssl x509 -req -days 365 -sha256 \
            -CA "${ca_cert}" \
            -CAkey "${ca}/ca_key.pem" \
            -CAcreateserial \
            -in "secrets/consul-vault.csr.pem" \
            -out "${tls_cert}"

    echo
    bold '* Verifying certificate...'
    openssl x509 -noout -text -in "${tls_cert}"
}


check_pgp() {
    if [ -z ${pgp_key} ]; then
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
        bold '* Exporting PGP public key ${pgp_key} to file'
        gpg --export "${pgp_key}" | base64 > secrets/${pgp_key}.asc
        PGP_KEYFILE="secrets/${pgp_key}.asc"
    fi
}

_demo_init() {
    echo
    bold '* Initializing the vault with your PGP key. If you had multiple keys you'
    bold '  would pass these into the setup script as follows:'
    echo '  ./setup.sh -k 'mykey1.asc,mykey2.asc' -t 2 init'
    echo
    echo "./setup.sh -k ${PGP_KEYFILE} -t 1 init"
    COMPOSE_FILE=${COMPOSE_FILE} ./setup.sh -k "${PGP_KEYFILE}" -t 1 init
}

_demo_unseal() {
    echo
    bold '* Unsealing the vault with your PGP key. If you had multiple keys,';
    bold '  each operator would unseal the vault with their own key as follows:'
    echo '  ./setup.sh unseal secrets/mykey1.asc.key'
    echo
    echo "./setup.sh unseal ${PGP_KEYFILE}.key"
    COMPOSE_FILE=${COMPOSE_FILE} ./setup.sh unseal "secrets/${PGP_KEYFILE}.key"
}

_demo_policy() {
    echo
    bold '* Adding an example ACL policy. Use the token you received previously';
    bold '  when prompted.'
    echo
    echo "./setup.sh policy secret ./policies/example.hcl"
    policy secret ./policies/example.hcl
}

clean() {
    bold '* Deleting the key(s) associated with the example user'
    local key=$(gpg --list-keys 'Example User <example@example.com>' | awk -F'/| +' '/pub/{print $3}')
    gpg --delete-secret-keys $key
    gpg --delete-keys $key
    bold '* Deleting the CA and associated keys'
    rm -rf secrets/
}

demo() {
    while true; do
        case $1 in
            -p | --pgp-key ) pgp_key=$2; shift 2;;
            -k | --tls-key ) tls_key=$2; shift 2;;
            -c | --tls-cert ) tls_cert=$2; shift 2;;
            -a | --ca-cert ) ca_cert=$2; shift 2;;
            -f | --compose-file ) COMPOSE_FILE=$2; shift 2;;
            _ca | check_* | clean | help) cmd=$1; shift 1; $cmd; exit;;
            *) break;;
        esac
    done

    check_tls
    check_pgp
    check_triton
    _demo_up
    _demo_wait_for_consul
    _demo_secure
    _demo_init
    _demo_unseal
    _demo_policy
}


build() {
    docker build --tag autopilotpattern/vault .
}

ship() {
    local githash=$(git rev-parse --short HEAD)
    docker tag ${repo}:latest ${repo}:${project_version}-${githash}
    docker push ${repo}:latest
    docker push ${repo}:${project_version}-${githash}
}

# ---------------------------------------------------
# parse arguments

while true; do
    case $1 in
        check | check_* | up | secure | init | unseal | policy | demo | build | ship | help) cmd=$1; shift; break;;
        *) break;;
    esac
done

if [ -z $cmd ]; then
    help
    exit
fi
$cmd $@
