#!/bin/bash
set -e

# project and service name
project=vault
service=consul-vault
vault="${project}_${service}"

# this demonstration will add new keys to the user's keyring, so we need
# to make sure they know that before continuing and give them the option
# to bail out and use their own key
_ask() {
    tput rev
    tput bold
    cat << EOF
This demonstration of Autopilot Pattern Vault will create a 3-node Vault
cluster, including initializing and unsealing the Vault with GPG keys.
The demonstration will create a new trusted key in your key ring but remove
it when the demonstration is done. Alternately, you can pass a key fingerprint
as an argument to this demo and it will use that key instead. The private key
will not be exported or leave this machine!
EOF
    tput sgr0
    echo
    read -rsp $'Press any key to continue or Ctrl-C to cancel...\n' -n1 key
    echo
}

# prints the argument bold and then resets the terminal colors
bold() {
    tput bold
    echo "${1}"
    tput sgr0
}


_check() {
    echo
    bold '* Checking your setup...'
    echo "./setup.sh check"
    ./setup.sh check
}

_up() {
    echo
    bold '* Standing up the Vault cluster...'
    docker-compose up -d
    docker-compose scale "${service}"=3
}

_wait_for_consul() {
    echo
    bold '* Waiting for Consul to form raft...'
    while :
    do
        docker exec -it ${vault}_1 consul info | grep -q "num_peers = 2" && break
        echo -n '.'
        sleep 1
    done
    echo
}

_key() {
    if [ -z ${KEY_ARG} ]; then
        bold '* Creating PGP key...'
        gpg -q --batch --gen-key <<EOF
Key-Type: RSA
Key-Length: 2048
Name-Real: Example User
Name-Email: example@example.com
Expire-Date: 0
%commit
EOF
        echo -e \\033c
        gpg --export 'Example User <example@example.com>' | base64 > example.asc
        KEYFILE="example.asc"
        bold '* Created a PGP key and exported the public key to ./example.asc'
    else
        bold "* Exporting PGP public key ${KEY_ARG} to file"
        gpg --export "${KEY_ARG} | base64 > ${KEY_ARG}.asc"
        KEYFILE="${KEY_ARG}.asc"
    fi
}

_init() {
    echo
    bold "* Initializing the vault with your PGP key. If you had multiple keys you"
    bold "  would pass these into the setup script as follows:"
    echo "  ./setup.sh -k 'mykey1.asc,mykey2.asc' -t 2 init"
    echo
    echo "./setup.sh -k ${KEYFILE} -t 1 init"
    ./setup.sh -k "${KEYFILE}" -t 1 init
}

_unseal() {
    echo
    bold "* Unsealing the vault with your PGP key. If you had multiple keys,"
    bold "  each operator would unseal the vault with their own key as follows:"
    echo "  ./setup.sh unseal mykey1.asc.key"
    echo
    echo "./setup.sh unseal ${KEYFILE}.key"
    ./setup.sh unseal "${KEYFILE}.key"
}

cleanup() {
    bold "* Deleting the key associated with the example user"
    local key=$(gpg --list-keys 'Example User <example@example.com>' | awk -F'/| +' '/pub/{print $3}')
    gpg --delete-secret-keys $key
    gpg --delete-keys $key
}

main() {
    _ask
    _check
    _up
    _wait_for_consul
    _key
    _init
    _unseal
}

# ---------------------------------------------------
# parse arguments

while true; do
    case $1 in
        -k | --key ) KEY_ARGS=$2; shift 2;;
        cleanup | main | help) cmd=$1; shift; break;;
        *) break;;
    esac
done

if [ -z $cmd ]; then
    main
    exit
fi
$cmd $@
