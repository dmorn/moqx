locals {
  safe_profile_name = substr(replace(lower(var.profile_name), "/[^a-z0-9-]/", "-"), 0, 32)
  safe_run_id       = substr(replace(lower(var.run_id), "/[^a-z0-9-]/", "-"), 0, 24)
  name_prefix       = substr("${var.project_name}-${local.safe_profile_name}-${local.safe_run_id}", 0, 54)

  evidence_tier = var.client_location == var.server_location ? "same_region_pair" : "cross_region_pair"

  common_labels = {
    purpose = "moqx-transport-bench"
    profile = local.safe_profile_name
    run_id  = local.safe_run_id
    ttl     = var.ttl
  }

  nodes = {
    client = {
      location   = var.client_location
      private_ip = var.client_private_ip
    }
    server = {
      location   = var.server_location
      private_ip = var.server_private_ip
    }
  }
}

resource "hcloud_ssh_key" "operator" {
  name       = "${local.name_prefix}-operator"
  public_key = file(pathexpand(var.ssh_public_key_path))
  labels     = local.common_labels
}

resource "hcloud_network" "bench" {
  count    = var.enable_private_network ? 1 : 0
  name     = "${local.name_prefix}-net"
  ip_range = var.private_network_cidr
  labels   = local.common_labels
}

resource "hcloud_network_subnet" "bench" {
  count        = var.enable_private_network ? 1 : 0
  network_id   = hcloud_network.bench[0].id
  type         = "cloud"
  network_zone = var.private_network_zone
  ip_range     = var.private_subnet_cidr
}

resource "hcloud_firewall" "operator" {
  name   = "${local.name_prefix}-operator-fw"
  labels = local.common_labels

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "any"
    source_ips  = [var.operator_cidr]
    description = "operator TCP access"
  }

  rule {
    direction   = "in"
    protocol    = "udp"
    port        = "any"
    source_ips  = [var.operator_cidr]
    description = "operator UDP access"
  }

  rule {
    direction   = "in"
    protocol    = "icmp"
    source_ips  = [var.operator_cidr]
    description = "operator ICMP access"
  }

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "any"
    source_ips  = [var.private_network_cidr]
    description = "private-network TCP access"
  }

  rule {
    direction   = "in"
    protocol    = "udp"
    port        = "any"
    source_ips  = [var.private_network_cidr]
    description = "private-network UDP access"
  }

  rule {
    direction   = "in"
    protocol    = "icmp"
    source_ips  = [var.private_network_cidr]
    description = "private-network ICMP access"
  }

  rule {
    direction       = "out"
    protocol        = "tcp"
    port            = "any"
    destination_ips = ["0.0.0.0/0", "::/0"]
    description     = "allow outbound TCP"
  }

  rule {
    direction       = "out"
    protocol        = "udp"
    port            = "any"
    destination_ips = ["0.0.0.0/0", "::/0"]
    description     = "allow outbound UDP"
  }

  rule {
    direction       = "out"
    protocol        = "icmp"
    destination_ips = ["0.0.0.0/0", "::/0"]
    description     = "allow outbound ICMP"
  }
}

resource "hcloud_server" "node" {
  for_each = local.nodes

  name                       = "${local.name_prefix}-${each.key}"
  image                      = var.image
  server_type                = var.server_type
  location                   = each.value.location
  ssh_keys                   = concat([hcloud_ssh_key.operator.name], var.extra_ssh_keys)
  ignore_remote_firewall_ids = true
  labels = merge(local.common_labels, {
    role     = each.key
    location = each.value.location
  })

  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    profile_name   = var.profile_name
    role           = each.key
    otp_version    = var.otp_version
    elixir_version = var.elixir_version
    go_version     = var.go_version
  })

  firewall_ids = [hcloud_firewall.operator.id]

  public_net {
    ipv4_enabled = true
    ipv6_enabled = var.enable_ipv6
  }

  dynamic "network" {
    for_each = var.enable_private_network ? [1] : []

    content {
      network_id = hcloud_network.bench[0].id
      ip         = each.value.private_ip
    }
  }

  depends_on = [hcloud_network_subnet.bench]
}

resource "hcloud_firewall" "peer_public" {
  name   = "${local.name_prefix}-peer-public-fw"
  labels = local.common_labels

  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "any"
    source_ips = [
      for server in hcloud_server.node : "${server.ipv4_address}/32"
    ]
    description = "benchmark peer TCP access over public IPv4"
  }

  rule {
    direction = "in"
    protocol  = "udp"
    port      = "any"
    source_ips = [
      for server in hcloud_server.node : "${server.ipv4_address}/32"
    ]
    description = "benchmark peer UDP access over public IPv4"
  }

  rule {
    direction = "in"
    protocol  = "icmp"
    source_ips = [
      for server in hcloud_server.node : "${server.ipv4_address}/32"
    ]
    description = "benchmark peer ICMP access over public IPv4"
  }
}

resource "hcloud_firewall_attachment" "peer_public" {
  firewall_id = hcloud_firewall.peer_public.id
  server_ids  = [for server in hcloud_server.node : server.id]
}
