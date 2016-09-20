#!/bin/bash
set -e -o pipefail

help() {
cat << EOF
Usage: ./setup.sh [options] <command>
--------------------------------------------------------------------------------
setup.sh check:
	Checks that your Triton and Docker environment is sane and configures
	an environment file with a CNS record for Consul.

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
EOF

}

# populated by `check` function whenever we're using Triton
TRITON_USER=
TRITON_DC=
TRITON_ACCOUNT=


# upload public key file to Vault
_copy_key() {
    local keyfile=$1
    echo "Uploading public keyfile ${keyfile} to vault instance"
    docker cp secrets/${keyfile} vault_consul-vault_1:${keyfile}
}


# ensure that the user has provided public key(s) and that a valid
# threshold value has been set.
_validate_args() {
    if [ -z ${KEYS} ]; then
        echo 'You must supply at least one public keyfile!'
        exit 1
    fi
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
    docker exec -it vault_consul-vault_1 vault init \
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
    if [ -z ${keyfile} ]; then
        echo 'You must provide an encrypted key file!'; exit 1
    elif [ ! -f ${keyfile} ]; then
        echo "${keyfile} not found."; exit 1
    fi

    echo 'Decrypting key. You may be prompted for your key password...'
    cat ${keyfile} | xxd -r -p | gpg -d

    echo
    echo 'Use the token above when prompted while we unseal each Vault node...'
    for i in {1..3}; do
        docker exec -it vault_consul-vault_$i \
             vault unseal -address='http://127.0.0.1:8200'
    done
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
            echo '# Consul bootstrap via Triton CNS' >> _env
            echo CONSUL=consul.svc.${TRITON_ACCOUNT}.${TRITON_DC}.cns.joyent.com >> _env
            echo >> _env
        else
            echo 'Existing _env file found, exiting'
            exit
        fi
    fi
}

# ---------------------------------------------------
# parse arguments

while true; do
    case $1 in
        -t | --threshold ) THRESHOLD=$2; shift 2;;
        -k | --keys ) KEYS_ARG=$2; shift 2;;
        check | init | unseal | help) cmd=$1; shift; break;;
        *) break;;
    esac
done

if [ -z $cmd ]; then
    help
    exit
fi
$cmd $@
