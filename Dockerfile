FROM autopilotpattern/consul:0.7.2-r0.7.2

# The Vault binary
ENV VAULT_VERSION=0.6.4
RUN export VAULT_CHECKSUM=04d87dd553aed59f3fe316222217a8d8777f40115a115dac4d88fac1611c51a6 \
    && export archive=vault_${VAULT_VERSION}_linux_amd64.zip \
    && curl -Lso /tmp/${archive} https://releases.hashicorp.com/vault/${VAULT_VERSION}/${archive} \
    && echo "${VAULT_CHECKSUM}  /tmp/${archive}" | sha256sum -c \
    && cd /bin \
    && unzip /tmp/${archive} \
    && chmod +x /bin/vault \
    && rm /tmp/${archive}

# configuration files and bootstrap scripts
COPY etc/containerpilot.json etc/
COPY etc/consul.json etc/consul/consul.json
COPY etc/vault.hcl etc/
COPY bin/* /usr/local/bin/

EXPOSE 8200
