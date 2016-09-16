# Autopilot Pattern Vault

[Hashicorp Vault](https://www.vaultproject.io) deployment designed for automated operation using the [Autopilot Pattern](http://autopilotpattern.io/). This repo serves as a blueprint demonstrating the pattern that can be reused as part of other application stacks.

## Architecture

This application blueprint consists of a single Docker container image. We run Consul with ContainerPilot, with Hashicorp Vault running as a ContainerPilot [co-process](https://www.joyent.com/containerpilot/docs/coprocesses). Vault is running under HA mode and using Consul as its storage backend. The Consul deployment is the same as that in the [HA Consul](https://github.com/autopilotpattern/consul) blueprint; this container image's Dockerfile extends that image.

### Bootstrapping Consul

Bootstrapping Consul is identical to [autopilotpattern/consul](https://github.com/autopilotpattern/consul). All Consul instances start with the `-bootstrap-expect` flag. This option tells Consul how many nodes we expect and automatically bootstraps when that many servers are available. We use ContainerPilot's `health` check to check if the node has been joined to peers and attempt to join its peers at the A-record associated with the [Triton Container Name Service (CNS)](https://docs.joyent.com/public-cloud/network/cns) name.

When run locally for testing, we don't have access to Triton CNS. The local-compose.yml file uses the v2 Compose API, which automatically creates a user-defined network and allows us to use Docker DNS for the service.

### Key Sharing

When the Vault is first initialized it is in a sealed state and a number of keys are created that can be used to unseal it. Vault uses Shamir Secret Splitting so that `-key-shares` number of keys are created and `-key-theshold` number of those keys are required to unseal the Vault. If `vault init` is used without providing the `-pgp-keys` argument these keys are presented to the user in plaintext. This blueprint expects that the the `-pgp-keys` argument will be passed. An encrypted secret will be provided for each PGP key provided, and only the holder of the PGP private key will be able to unseal or reseal the Vault.

### Unsealing

The Vault health check will check to make sure that we're unsealed and not advertise itself to Consul for client applications until it is unsealed.

The operator will then initialize one of the Vault nodes. To do so, the operator provides a PGP public key file for each user and a script will take these files and initialize the vault with `-key-shares` equal to the number of keys provided and `-key-threshold=2` (so that any two of the operators can unseal or force it to be rekeyed -- this is the minimum). The script will then decrypt the operator's own Vault key and use it to unseal all the Vault nodes. The script will also provide the operator with the root key, which will get used to set up ACLs for client applications (see below).

Once the Vaults are unsealed and the Vault is healthy, the Consul service's `onChange` handler will notice and generate a gossip encryption key and add this to the Consul cluster via consul keyring, thereby encrypting all gossip communication between Consul servers.

### High Availability

Vault elects a primary via locks in Consul. If the primary fails, a new node will become the primary. Other nodes will automatically redirect via client requests (with an HTTP307) to the primary. If a node is restarted or a new node created it will be sealed and unable to enter the pool until it's manually unsealed.

### Setting up ACLs for an application

TODO


---

## Run it!

1. [Get a Joyent account](https://my.joyent.com/landing/signup/) and [add your SSH key](https://docs.joyent.com/public-cloud/getting-started).
1. Install the [Docker Toolbox](https://docs.docker.com/installation/mac/) (including `docker` and `docker-compose`) on your laptop or other environment, as well as the [Joyent Triton CLI](https://www.joyent.com/blog/introducing-the-triton-command-line-tool).

Check that everything is configured correctly by running `./setup.sh`. This will check that your environment is setup correctly and will create an `_env` file that includes injecting an environment variable for a service name for Consul in Triton CNS. We'll use this CNS name to bootstrap the cluster.

# TODO: need to update this w/ unsealing process

```bash
$ docker-compose up -d
Creating vault_vault_1

$ docker-compose scale vault=3
Creating and starting vault_vault_2 ...
Creating and starting vault_vault_3 ...

$ docker-compose ps
Name                      Command                 State       Ports
--------------------------------------------------------------------------------
vault_vault_1   /usr/local/bin/containerpilot...   Up   53/tcp, 53/udp,
                                                        8200/tcp, 8300/tcp
                                                        8301/tcp, 8301/udp,
                                                        8302/tcp, 8302/udp,
                                                        8400/tcp,
                                                        0.0.0.0:8500->8500/tcp
vault_vault_2   /usr/local/bin/containerpilot...   Up   53/tcp, 53/udp,
                                                        8200/tcp, 8300/tcp
                                                        8301/tcp, 8301/udp,
                                                        8302/tcp, 8302/udp,
                                                        8400/tcp,
                                                        0.0.0.0:8500->8500/tcp
vault_vault_3   /usr/local/bin/containerpilot...   Up   53/tcp, 53/udp,
                                                        8200/tcp, 8300/tcp
                                                        8301/tcp, 8301/udp,
                                                        8302/tcp, 8302/udp,
                                                        8400/tcp,
                                                        0.0.0.0:8500->8500/tcp

$ docker exec -it vault_vault_3 consul info | grep num_peers
    num_peers = 2

$ docker exec -it vault_vault_3 vault???? TODO


```
