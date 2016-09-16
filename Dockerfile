FROM autopilotpattern/consul:0.7r0.7

# The Vault binary
ENV VAULT_VERSION=0.6.1
RUN export VAULT_CHECKSUM=4f248214e4e71da68a166de60cc0c1485b194f4a2197da641187b745c8d5b8be \
    && export archive=vault_${VAULT_VERSION}_linux_amd64.zip \
    && curl -Lso /tmp/${archive} https://releases.hashicorp.com/vault/${VAULT_VERSION}/${archive} \
    && echo "${VAULT_CHECKSUM}  /tmp/${archive}" | sha256sum -c \
    && cd /bin \
    && unzip /tmp/${archive} \
    && chmod +x /bin/vault \
    && rm /tmp/${archive}

# configuration files and bootstrap scripts
COPY etc/containerpilot.json etc/
COPY etc/vault.hcl etc/
COPY bin/* /usr/local/bin/

EXPOSE 8200
