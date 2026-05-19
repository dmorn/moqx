output "servers" {
  description = "Created benchmark endpoints."
  value = {
    for role, server in hcloud_server.node : role => {
      id          = server.id
      name        = server.name
      role        = role
      location    = local.nodes[role].location
      server_type = var.server_type
      public_ipv4 = server.ipv4_address
      private_ip  = var.enable_private_network ? local.nodes[role].private_ip : null
      ssh         = "ssh root@${server.ipv4_address}"
    }
  }
}

output "path_metadata_public" {
  description = "Benchmark path metadata for public IPv4 runs."
  value = {
    evidence_tier = local.evidence_tier
    path_id       = "hetzner-${var.client_location}-${var.server_location}-${var.server_type}-public-ipv4"
    client = {
      host_id              = hcloud_server.node["client"].name
      provider             = "hetzner_cloud"
      region               = var.client_location
      instance_class       = var.server_type
      os                   = var.image
      kernel               = null
      cpu_model            = null
      memory_bytes         = null
      nic_or_network_class = "public_ipv4"
    }
    server = {
      host_id              = hcloud_server.node["server"].name
      provider             = "hetzner_cloud"
      region               = var.server_location
      instance_class       = var.server_type
      os                   = var.image
      kernel               = null
      cpu_model            = null
      memory_bytes         = null
      nic_or_network_class = "public_ipv4"
    }
  }
}

output "path_metadata_private" {
  description = "Benchmark path metadata for private-network runs."
  value = var.enable_private_network ? {
    evidence_tier = local.evidence_tier
    path_id       = "hetzner-${var.client_location}-${var.server_location}-${var.server_type}-private-network"
    client = {
      host_id              = hcloud_server.node["client"].name
      provider             = "hetzner_cloud"
      region               = var.client_location
      instance_class       = var.server_type
      os                   = var.image
      kernel               = null
      cpu_model            = null
      memory_bytes         = null
      nic_or_network_class = "hetzner_private_network"
    }
    server = {
      host_id              = hcloud_server.node["server"].name
      provider             = "hetzner_cloud"
      region               = var.server_location
      instance_class       = var.server_type
      os                   = var.image
      kernel               = null
      cpu_model            = null
      memory_bytes         = null
      nic_or_network_class = "hetzner_private_network"
    }
  } : null
}

output "toolchain_check_commands" {
  description = "Read-only commands to confirm cloud-init and toolchain readiness after apply."
  value = {
    for role, server in hcloud_server.node : role =>
    "ssh root@${server.ipv4_address} 'cloud-init status --wait && go version && elixir --version && iperf3 --version | head -1'"
  }
}
