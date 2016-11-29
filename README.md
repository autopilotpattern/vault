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

Once the Vaults are unsealed and the Vault is healthy, the Consul service's `onChange` handler will notice and generate a gossip encryption key and add this to the Consul cluster via `consul keyring`, thereby encrypting all gossip communication between Consul servers.

### High Availability

Vault elects a primary via locks in Consul. If the primary fails, a new node will become the primary. Other nodes will automatically redirect via client requests (with an HTTP307) to the primary. If a node is restarted or a new node created it will be sealed and unable to enter the pool until it's manually unsealed.

---

## Run the demo!

This repo provides a tool (`./setup.sh`) to launch and manage the Vault cluster. You'll need the following to get started:

1. [Get a Joyent account](https://my.joyent.com/landing/signup/) and [add your SSH key](https://docs.joyent.com/public-cloud/getting-started).
1. Install the [Docker Toolbox](https://docs.docker.com/installation/mac/) (including `docker` and `docker-compose`) on your laptop or other environment, as well as the [Joyent Triton CLI](https://www.joyent.com/blog/introducing-the-triton-command-line-tool).

If you want to see how a completed stack looks, try the demo first.

**`setup.sh demo`:** Runs a demonstration of the entire stack on Triton, creating a 3-node cluster with RPC over TLS. The demo includes initializing the Vault and unsealing it with PGP keys. You can either provide the demo with PGP keys and TLS certificates or allow the script to generate them for you. Parameters:

	-p, --pgp-key        use this PGP key in lieu of creating a new one
	-k, --tls-key        use this TLS key file in lieu of creating a CA and cert
	-c, --tls-cert       use this TLS cert file in lieu of creating a CA and cert-
	-f, --compose-file   use this Docker Compose manifest

**`setup.sh demo clean`:** Cleans up the demo PGP keys and CA.

The Vault cluster runs as Docker containers on Triton, so you can use your Docker client and Compose to explore the cluster further.

```bash
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

$ docker exec -it vault_vault_3 vault write secret/hello value=world
Success! Data written to: secret/hello

```

---

## Run it in production!

Once you've seen the demo, you'll want to run the stack as you will in production.

**`setup.sh check`:** Checks that your Triton and Docker environment is sane and configures an environment file `_env` with a CNS record for Consul. We'll use this CNS name to bootstrap the Consul cluster.

**`setup.sh up`:** Starts the Vault cluster via Docker Compose and waits for all instances to be up. Once instances are up, it will poll Consul's status to ensure the raft has been created.

**`setup.sh init`:** Initializes a started Vault cluster. Creates encrypted keyfiles for each operator's public key, which should be redistributed back to operators out-of-band. Use the following options:

	--keys/-k "<val>,<val>":
		List of public keys used to initialize the vault. These keys
		must be base64 encoded public keys without ASCII armoring.
	--threshold/-t <val>:
		Optional number of keys required to unseal the vault. Defaults
		to 1 if a single --keys argument was provided, otherwise 2.

**`setup.sh unseal [keyfile]`:** Unseals a Vault with the provided operator's key. Requires access to all Vault nodes via `docker exec`. A number of operator keys equal to the `--threshold` parameter (above) must be used to unseal the Vault.

**`setup.sh policy [policyname] [policyfile]`:** Adds an ACL to the Vault cluster by uploading a policy HCL file and writing it via `vault policy-write`.
