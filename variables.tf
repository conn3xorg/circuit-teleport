variable "hosts" {
  type        = any
  description = "Hosts to configure: a map of names to addresses, or to host objects with an address and optional host_key, user, port, private_key_file, jump_hosts or os."

  validation {
    condition     = alltrue([for h in var.hosts : contains(["debian", "ubuntu", "rocky", "almalinux", "rhel", "fedora"], try(h.os, "debian"))])
    error_message = "A host object's os must be one of debian, ubuntu, rocky, almalinux, rhel or fedora. CentOS Linux reached end of life on 30 June 2024: use Rocky Linux."
  }
}

variable "ssh_user" {
  type        = string
  default     = "root"
  description = "User to log in as."
}

variable "ssh_port" {
  type        = number
  default     = 22
  description = "SSH port."
}

variable "ssh_private_key_file" {
  type        = string
  default     = null
  description = "Path to a private key. When null, Conn3x uses the SSH agent."
}

variable "ssh_known_hosts_file" {
  type        = string
  default     = null
  description = "known_hosts file to check host keys against. When null, ~/.ssh/known_hosts."
}

variable "ssh_become" {
  type        = bool
  default     = false
  description = "Run commands as root through sudo."
}

variable "role" {
  type        = string
  description = "What the hosts run: \"server\" for the auth and proxy services on one host, or \"node\" for SSH nodes that join a server through its proxy."

  validation {
    condition     = contains(["server", "node"], var.role)
    error_message = "role must be \"server\" or \"node\"."
  }
}

variable "teleport_version" {
  type        = string
  default     = "18.11.8"
  description = "Teleport Community Edition release to install from Teleport's repository, such as \"18.11.8\". Its major version picks the repository channel, stable/v18."

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.teleport_version))
    error_message = "teleport_version is a release number such as \"18.11.8\"."
  }
}

variable "public_addr" {
  type        = string
  default     = null
  description = "Server only, required there: the name and port users and nodes reach the proxy on, such as \"teleport.example.com:443\". The certificate has to cover the name."

  validation {
    condition     = var.role != "server" || can(regex("^[A-Za-z0-9.-]+:[0-9]{1,5}$", coalesce(var.public_addr, "-")))
    error_message = "A server needs public_addr, a name and port such as \"teleport.example.com:443\"."
  }
}

variable "web_listen_address" {
  type        = string
  default     = null
  description = "Server only, required there: the address and port the proxy listens on, such as \"192.168.1.40:443\". Users, nodes and the auth service all come in through this one port."

  validation {
    condition     = var.role != "server" || can(regex("^([0-9.]+|\\[[0-9a-fA-F:]+\\]):[0-9]{1,5}$", coalesce(var.web_listen_address, "-")))
    error_message = "A server needs web_listen_address, an IP address and port such as \"192.168.1.40:443\"."
  }
}

variable "cluster_name" {
  type        = string
  default     = null
  description = "Server only: the cluster's name, which can't change once the server has started. When null, the name in public_addr."

  validation {
    condition     = var.cluster_name == null || can(regex("^[A-Za-z0-9][A-Za-z0-9.-]*$", coalesce(var.cluster_name, "-")))
    error_message = "cluster_name must be letters, digits, . and -, such as \"homelab\"."
  }
}

variable "https_cert_file" {
  type        = string
  default     = null
  description = "Server only: path on the host to the proxy's certificate chain, in PEM, for the name in public_addr. When null, Teleport makes a self-signed one, which nodes won't join through."
}

variable "https_key_file" {
  type        = string
  default     = null
  description = "Server only: path on the host to the key for https_cert_file."

  validation {
    condition     = (var.https_cert_file == null) == (var.https_key_file == null)
    error_message = "Set https_cert_file and https_key_file together."
  }
}

variable "proxy_address" {
  type        = string
  default     = null
  description = "Node only, required there: the server's public_addr, such as \"teleport.example.com:443\". Nodes connect out to it, so they need no open port of their own."

  validation {
    condition     = var.role != "node" || can(regex("^[A-Za-z0-9.-]+:[0-9]{1,5}$", coalesce(var.proxy_address, "-")))
    error_message = "A node needs proxy_address, the server's name and port such as \"teleport.example.com:443\"."
  }
}

variable "proxy_ca" {
  type        = string
  default     = null
  description = "PEM certificate of a private CA that signed the proxy's certificate, added to each host's trust store so Teleport trusts the proxy. Leave null for a certificate from a public CA."

  validation {
    condition     = var.proxy_ca == null || can(regex("-----BEGIN CERTIFICATE-----", coalesce(var.proxy_ca, "-")))
    error_message = "proxy_ca must be a PEM certificate, starting -----BEGIN CERTIFICATE-----."
  }
}

variable "join" {
  type        = bool
  default     = true
  description = "On a server, create join_token as a token nodes join with. On a node, join the server with it. When false, no token is needed."
}

variable "join_token" {
  type        = string
  default     = null
  ephemeral   = true
  sensitive   = true
  description = "The join token, at least 32 letters, digits, _ or -. Pass the same one to the server and its nodes. Required when join is true."

  validation {
    condition     = !var.join || can(regex("^[A-Za-z0-9_-]{32,}$", var.join_token))
    error_message = "Set join_token to at least 32 letters, digits, _ or -, or set join = false."
  }
}

variable "join_token_ttl" {
  type        = number
  default     = 24
  description = "Server only: hours the join token works for, counted from when the server creates it. Teleport deletes it after that."

  validation {
    condition     = var.join_token_ttl >= 1 && var.join_token_ttl <= 720 && floor(var.join_token_ttl) == var.join_token_ttl
    error_message = "join_token_ttl is a whole number of hours from 1 to 720."
  }
}

variable "labels" {
  type        = map(string)
  default     = {}
  description = "Labels for the SSH service on every host, such as { env = \"homelab\" }, which Teleport roles can match on."

  validation {
    condition     = alltrue([for k, v in var.labels : can(regex("^[A-Za-z0-9/._-]+$", k))])
    error_message = "Each label name must be letters, digits, /, ., _ and -."
  }
}
