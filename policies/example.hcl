path "secret/*" {
  policy = "write"
}

path "secret/foo" {
  policy = "read"
}

path "auth/token/lookup-self" {
  policy = "read"
}
