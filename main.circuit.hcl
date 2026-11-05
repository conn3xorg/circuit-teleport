# Facts give each host's distribution, which picks Teleport's apt or rpm
# repository.
data "conn3x_host" "facts" {
  for_each = var.hosts

  ssh {
    host             = try(each.value.address, each.value)
    host_key         = try(each.value.host_key, null)
    user             = try(each.value.user, var.ssh_user)
    port             = try(each.value.port, var.ssh_port)
    private_key_file = try(each.value.private_key_file, var.ssh_private_key_file)
    jump_hosts       = try(each.value.jump_hosts, null)
    known_hosts_file = var.ssh_known_hosts_file
  }

  lifecycle {
    postcondition {
      condition     = contains(["debian", "ubuntu", "rocky", "almalinux", "rhel"], try(each.value.os, self.os_id))
      error_message = "Host ${each.key} runs ${self.os_id}. This circuit supports Debian, Ubuntu, Rocky Linux, AlmaLinux and RHEL. Teleport publishes no Fedora repository. CentOS Linux reached end of life on 30 June 2024: use Rocky Linux."
    }
    postcondition {
      condition     = try(each.value.os, self.os_id) == self.os_id
      error_message = "Host ${each.key} is ${self.os_id}, not the ${try(each.value.os, "")} its os says."
    }
    postcondition {
      condition     = !contains(["debian", "ubuntu"], self.os_id) || contains(keys(local.codename), self.os_version)
      error_message = "Host ${each.key} runs ${self.os_id} ${self.os_version}. This circuit knows Ubuntu 22.04, 24.04 and 26.04, and Debian 12 and 13."
    }
  }
}

locals {
  # A host object's os stands in for the facts of a host created in the
  # same plan, which can't be read until it exists.
  os  = { for name, h in var.hosts : name => try(h.os, data.conn3x_host.facts[name].os_id) }
  deb = { for name, o in local.os : name => contains(["debian", "ubuntu"], o) }

  # Teleport keeps a channel per major version. Rocky Linux and AlmaLinux use
  # the RHEL repository for their major release, as Teleport's installer does.
  channel  = "stable/v${split(".", var.teleport_version)[0]}"
  codename = { "22.04" = "jammy", "24.04" = "noble", "26.04" = "resolute", "12" = "bookworm", "13" = "trixie" }
  repo = { for name, f in data.conn3x_host.facts : name => local.deb[name] ? {
    url    = "https://apt.releases.teleport.dev/${local.os[name]}"
    suites = [local.codename[f.os_version]]
    } : {
    url    = "https://yum.releases.teleport.dev/rhel/${split(".", f.os_version)[0]}/Teleport/$basearch/${local.channel}"
    suites = null
  } }

  server = var.role == "server"

  # The package links its binaries here, which isn't on every
  # distribution's PATH for a root login.
  bin         = "/usr/local/bin"
  config_file = "/etc/teleport.yaml"
  token_file  = local.server ? "/etc/teleport/join-token.yaml" : "/etc/teleport/join-token"

  # Health and readiness on loopback, so the apply can wait for Teleport
  # without a login.
  diag_addr = "127.0.0.1:3434"

  ca_file = { for name, d in local.deb : name => d ? "/usr/local/share/ca-certificates/conn3x-teleport-proxy-ca.crt" : "/etc/pki/ca-trust/source/anchors/conn3x-teleport-proxy-ca.pem" }

  cluster_name = coalesce(var.cluster_name, split(":", coalesce(var.public_addr, "-:"))[0])

  config = { for name, h in var.hosts : name => "# Written by Conn3x. Changes here are overwritten on the next apply.\n${yamlencode({
    version = "v3"
    teleport = merge({
      nodename  = name
      data_dir  = "/var/lib/teleport"
      diag_addr = local.diag_addr
      log       = { output = "stderr", severity = "INFO" }
      },
      local.server ? {} : { proxy_server = var.proxy_address },
      # A node that has joined keeps its own identity in data_dir, and no
      # longer needs the token.
      !local.server && var.join ? { join_params = { method = "token", token_name = local.token_file } } : {},
    )
    # Each service's settings go through JSON, since a server's and a node's
    # differ in shape and a conditional needs one type.
    auth_service = jsondecode(local.server ? jsonencode({
      enabled      = true
      cluster_name = local.cluster_name
      # Nodes and tctl reach auth through the proxy's port, or locally.
      listen_addr         = "127.0.0.1:3025"
      proxy_listener_mode = "multiplex"
    }) : jsonencode({ enabled = false }))
    proxy_service = jsondecode(local.server ? jsonencode(merge({
      enabled         = true
      web_listen_addr = var.web_listen_address
      public_addr     = var.public_addr
      }, var.https_cert_file == null ? {} : {
      https_keypairs = [{ cert_file = var.https_cert_file, key_file = var.https_key_file }]
    })) : jsonencode({ enabled = false }))
    # The server's own SSH service is reached by its proxy on loopback.
    # Nodes dial out to the proxy over a reverse tunnel and listen on nothing.
    ssh_service = merge({ enabled = true }, local.server ? { listen_addr = "127.0.0.1:3022" } : {}, length(var.labels) == 0 ? {} : { labels = var.labels })
  })}" }

  # The server holds the token as a provision token resource that expires.
  # The expiry is set when tctl creates it, so it can't be in the file
  # Conn3x compares, and this script adds it. tctl prints the token's name,
  # which is the secret, and a command's output goes into state.
  token_script = <<-EOT
    #!/bin/sh
    # Written by Conn3x. Creates the join token in ${local.token_file},
    # expiring ${var.join_token_ttl} hours from now.
    set -eu
    expires=$(date -u -d '+${var.join_token_ttl} hours' +%Y-%m-%dT%H:%M:%SZ)
    sed "s/^metadata:$/metadata:\n  expires: \"$expires\"/" ${local.token_file} | ${local.bin}/tctl create >/dev/null
  EOT

  ready = "curl -sf http://${local.diag_addr}/readyz >/dev/null"
}

circuit "teleport" {
  hosts = var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # curl for the ready check, ca-certificates for proxy_ca.
  step "tools" {
    for_each = toset(["curl", "ca-certificates"])
    package {
      name = item.value
    }
  }

  # A private CA in the system trust store, which Teleport's TLS checks read.
  step "proxy_ca" {
    file {
      path    = local.ca_file[each.key]
      state   = var.proxy_ca == null ? "absent" : "present"
      content = var.proxy_ca
    }
  }

  step "trust" {
    command {
      command  = local.deb[each.key] ? "update-ca-certificates >/dev/null" : "update-ca-trust"
      triggers = { ca = conn3x_file.teleport__proxy_ca[each.key].revision }
    }
  }

  # Teleport signs both repositories with the key in files, fingerprint
  # 0C5E 8BA5 658E 320D 1B03 1179 C87E D53A 6282 C411. It expires on
  # 20 October 2030.
  step "repo" {
    repository {
      name       = "teleport"
      url        = local.repo[each.key].url
      key        = file("${path.module}/files/teleport.asc")
      suites     = local.repo[each.key].suites
      components = local.deb[each.key] ? [local.channel] : null
    }
  }

  step "package" {
    package {
      name    = "teleport"
      version = var.teleport_version
    }
  }

  step "token_dir" {
    directory {
      path = "/etc/teleport"
      mode = "0700"
    }
  }

  # Setting join to false removes the step, and with it the file.
  step "join_token" {
    for_each = var.join ? toset(["token"]) : toset([])
    file {
      path       = local.token_file
      content_wo = local.server ? "kind: token\nversion: v2\nmetadata:\n  name: ${var.join_token}\nspec:\n  roles: [Node]\n  join_method: token\n" : var.join_token
      on_remove  = "delete"
    }
  }

  step "config" {
    file {
      path     = local.config_file
      content  = local.config[each.key]
      mode     = "0600"
      validate = "${local.bin}/teleport configure --test %s >/dev/null"
    }
  }

  # A restart rather than Teleport's own reload, so the ready check below
  # sees the new process. This is a step rather than a handler because
  # handlers run after every step.
  step "restart" {
    command {
      command  = "systemctl restart teleport"
      triggers = { config = conn3x_file.teleport__config[each.key].revision, version = var.teleport_version, ca = conn3x_file.teleport__proxy_ca[each.key].revision }
    }
  }

  step "running" {
    service {
      name    = "teleport"
      state   = "started"
      enabled = true
    }
  }

  # unless is checked at plan time, before a restart, so the restart's
  # triggers make the apply wait again.
  step "ready" {
    command {
      command  = "for _ in $(seq 120); do ${local.ready} && exit 0; sleep 1; done; echo 'Teleport is not ready. See journalctl -u teleport.' >&2; exit 1"
      unless   = local.ready
      triggers = { config = conn3x_file.teleport__config[each.key].revision, version = var.teleport_version }
    }
  }

  step "token_script" {
    for_each = local.server && var.join ? toset(["token"]) : toset([])
    file {
      path      = "/etc/teleport/create-join-token"
      content   = local.token_script
      mode      = "0700"
      on_remove = "delete"
    }
  }

  # Runs once the server is up, and again when the token or its lifetime
  # changes.
  step "create_token" {
    for_each = local.server && var.join ? toset(["token"]) : toset([])
    command {
      command  = "/etc/teleport/create-join-token"
      triggers = { token = conn3x_file.teleport__join_token["${each.key}/token"].content_hmac, ttl = var.join_token_ttl }
    }
  }
}
