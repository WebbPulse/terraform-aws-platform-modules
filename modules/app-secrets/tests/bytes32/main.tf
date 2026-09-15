resource "random_bytes" "sample" {
  length = 32
}

locals {
  encoded = nonsensitive(random_bytes.sample.base64)
  padding = length(regexall("=", local.encoded))
}

output "decoded_length" {
  value = (length(local.encoded) / 4) * 3 - local.padding
}

output "encoded_length" {
  value = length(local.encoded)
}

output "is_standard_base64" {
  value = can(regex("^[A-Za-z0-9+/]+={0,2}$", local.encoded))
}
