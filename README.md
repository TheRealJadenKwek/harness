# Harness push relay

Forwards completion/approval notifications from self-hosted [Harness](https://github.com/TheRealJadenKwek/harness)
servers to APNs, so users don't need Apple signing keys. Holds only device-token ↔ relay-id pairs;
message content is not stored. Rate-limited per device.
