run "the_bytes32_base64_generator_produces_exactly_32_decoded_bytes" {
  command = apply

  module {
    source = "./tests/bytes32"
  }

  assert {
    condition     = output.decoded_length == 32
    error_message = "A bytes32-base64 json_generate entry stores the base64 of a 32 byte random_bytes, and webbpulse-python validates the master key as exactly 32 raw bytes, so the stored string must decode back to 32 bytes."
  }

  assert {
    condition     = output.encoded_length == 44
    error_message = "Standard base64 of 32 bytes is always 44 characters ending in a single pad, so a different length means the generator produced the wrong number of bytes or a different encoding."
  }

  assert {
    condition     = output.is_standard_base64
    error_message = "The stored form must be standard base64, not the URL safe alphabet, because the application decodes it with a standard base64 decoder."
  }
}
