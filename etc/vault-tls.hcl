backend "consul" {
  address = "127.0.0.1:8500"
  path = "vault"
}

listener "tcp" {
  address = "0.0.0.0:8200"
  tls_cert_file = "/etc/ssl/certs/consul-vault.cert.pem"
  tls_key_file = "/etc/ssl/private/consul-vault.key.pem"
}

disable_mlock = true
