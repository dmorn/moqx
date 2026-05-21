variable "project_name" {
  description = "Prefix for Hetzner Cloud resource names."
  type        = string
  default     = "moqx-transport-bench"
}

variable "profile_name" {
  description = "Benchmark infrastructure profile name, recorded in labels and outputs."
  type        = string
  default     = "arm-default"
}

variable "run_id" {
  description = "Caller-chosen run identifier. Keep it short and stable for the lifetime of this Terraform state."
  type        = string
  default     = "manual"
}

variable "ttl" {
  description = "Human-readable lifetime marker recorded as a label. Terraform does not enforce it."
  type        = string
  default     = "manual-destroy"
}

variable "server_type" {
  description = "Hetzner Cloud server type for both benchmark endpoints."
  type        = string
  default     = "cax31"
}

variable "image" {
  description = "Hetzner Cloud image for both benchmark endpoints."
  type        = string
  default     = "ubuntu-24.04"
}

variable "client_location" {
  description = "Hetzner Cloud location for the client endpoint."
  type        = string
  default     = "fsn1"
}

variable "server_location" {
  description = "Hetzner Cloud location for the server endpoint."
  type        = string
  default     = "hel1"
}

variable "operator_cidr" {
  description = "CIDR allowed to reach any TCP/UDP port and ICMP on both servers."
  type        = string
  default     = "95.254.174.121/32"
}

variable "ssh_public_key_path" {
  description = "Local SSH public key file uploaded as an ephemeral Hetzner Cloud SSH key."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "extra_ssh_keys" {
  description = "Additional existing Hetzner Cloud SSH key names or IDs to inject."
  type        = list(string)
  default     = []
}

variable "enable_ipv6" {
  description = "Whether to assign public IPv6 addresses."
  type        = bool
  default     = false
}

variable "enable_private_network" {
  description = "Whether to attach both servers to a Hetzner private network for private-path comparisons."
  type        = bool
  default     = true
}

variable "private_network_cidr" {
  description = "RFC1918 network range used when enable_private_network is true."
  type        = string
  default     = "10.88.0.0/16"
}

variable "private_subnet_cidr" {
  description = "Subnet range used when enable_private_network is true."
  type        = string
  default     = "10.88.0.0/24"
}

variable "private_network_zone" {
  description = "Hetzner Cloud network zone for the private subnet."
  type        = string
  default     = "eu-central"
}

variable "private_network_interface" {
  description = "Guest OS interface name for the first attached Hetzner private network on the selected server families."
  type        = string
  default     = "enp7s0"
}

variable "client_private_ip" {
  description = "Private IP for the client endpoint when enable_private_network is true."
  type        = string
  default     = "10.88.0.11"
}

variable "server_private_ip" {
  description = "Private IP for the server endpoint when enable_private_network is true."
  type        = string
  default     = "10.88.0.12"
}

variable "otp_version" {
  description = "Erlang/OTP version installed by the official Elixir install script."
  type        = string
  default     = "28.1"
}

variable "elixir_version" {
  description = "Elixir version installed by the official Elixir install script."
  type        = string
  default     = "1.19.5"
}

variable "go_version" {
  description = "Go version installed from go.dev. Use \"stable\" for the latest stable Linux archive."
  type        = string
  default     = "stable"
}
