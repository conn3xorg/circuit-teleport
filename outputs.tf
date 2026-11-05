output "service" {
  description = "The systemd unit Teleport runs as on each host."
  value       = "teleport.service"
}

output "config_file" {
  description = "Teleport's config file on each host."
  value       = "/etc/teleport.yaml"
}
