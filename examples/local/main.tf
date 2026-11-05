variable "port" {
  type    = number
  default = 2222
}

variable "node_port" {
  type    = number
  default = 2223
}

# The server's container name, which the node reaches it by and the
# certificate up.sh made is for.
variable "server_name" {
  type    = string
  default = "circuit-teleport"
}

# Pass it in TF_VAR_join_token. See the README for one way to make one.
variable "join_token" {
  type      = string
  default   = null
  ephemeral = true
}

variable "join" {
  type    = bool
  default = true
}

# CI applies an older release first, then this one, to test the upgrade.
variable "teleport_version" {
  type    = string
  default = "18.11.8"
}

# up.sh makes the CA. Before it has, validate still works.
locals {
  proxy_ca = try(file("${path.module}/ca.crt"), null)
}

module "server" {
  source = "../.."

  hosts                = { server = "127.0.0.1" }
  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  role               = "server"
  teleport_version   = var.teleport_version
  cluster_name       = "example"
  public_addr        = "${var.server_name}:443"
  web_listen_address = "0.0.0.0:443"
  https_cert_file    = "/etc/teleport-tls/tls.crt"
  https_key_file     = "/etc/teleport-tls/tls.key"
  proxy_ca           = local.proxy_ca

  join       = var.join
  join_token = var.join_token
}

module "node" {
  source = "../.."

  hosts                = { node1 = "127.0.0.1" }
  ssh_port             = var.node_port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  role             = "node"
  teleport_version = var.teleport_version
  proxy_address    = "${var.server_name}:443"
  proxy_ca         = local.proxy_ca
  labels           = { env = "example" }

  join       = var.join
  join_token = var.join_token

  # The node joins with the token the server has created.
  depends_on = [module.server]
}
