# Citadel: vendored copy and its patches

Origin: `https://github.com/orlandos-nl/Citadel`, tag 0.12.1 (revision ae8562f895de06ccb86fdb1cbb65fd99c8976e12).
Licence: MIT (`LICENSE`, unchanged).

Copied: `Sources/Citadel`, `Sources/CCitadelBcrypt`, `Tests/CitadelTests`. Left out: the example server target and its
ColorizeSwift dependency, `Examples/`, the Dockerfile. `Package.swift` depends on the vendored, patched swift-nio-ssh
next to it (`../swift-nio-ssh`, see its PATCHES.md) instead of `Wellz26/swift-nio-ssh` 0.3.4..<0.4.0.

Each change below is self-contained, so it can be offered upstream as one pull request.

## 1. Agent forwarding (client side)

Needs swift-nio-ssh patch 1 (`SSHChannelType.authAgent`, `SSHChannelRequestEvent.AgentForwardingRequest`).

- `TTY/Client/TTY.swift`: `withPTY(_:environment:forwardAgent:perform:)` (default false) and
  `_executeCommandStream(environment:forwardAgent:mode:)` send `auth-agent-req@openssh.com` (want-reply false) on the
  session channel before the environment, PTY and shell requests, as `ssh -A` does.
- `Agent/AgentForwarding+Client.swift`: `SSHClient.setAgentForwardingHandler(_:)` and the `SSHAgentChannelHandler`
  type: the app serves each agent channel the server opens; the channel's pipeline already carries `ByteBuffer`s.
  Without a handler agent channels are refused.
- `ClientSession.swift`: `SSHClientInboundChannelHandler.agentHandler`; `handleChannel` routes `.authAgent` channels
  to it (after `DataToBufferCodec`) or refuses them.
- `Server.swift`: the server refuses `.authAgent` channels (a client never opens one; keeps the `switch` exhaustive).

## 2. Decrypted private section of any OpenSSH key

- `Agent/OpenSSHPrivateSection.swift`: `OpenSSHPrivateSection.decrypted(_:passphrase:)` returns the private section
  of an `openssh-key-v1` key after Citadel's own bcrypt KDF + AES-CTR decryption, for every key type (Citadel itself
  only builds ed25519 and RSA keys from it). An app with its own key parser can then use encrypted ECDSA keys too.
  Throws on a missing or wrong passphrase (check integers differ).

Tests for both: `Tests/CitadelTests/AgentForwardingTests.swift`.

## 3. Custom login delegates are asked more than once

- `SSHAuthenticationMethod.swift`: `.custom(delegate)` is no longer removed after its first offer; it is asked again
  after each refusal and ends the login itself by failing the promise. Upstream removes it like a fixed offer, so a
  delegate that tries several keys (RSSHRemote `SSHLoginChain`: the server's key, then the agent's other vault keys)
  only ever got one try. Fixed offers (`.passwordBased`, `.ed25519`, ...) behave as before. Checked against OpenSSH by
  RSSHRemote's `SFTPIntegrationTests.vaultKeysAreTriedAfterARefusedOne`.

## Follow-up planned in this same fork

- RSA with SHA-2 (`rsa-sha2-256`/`rsa-sha2-512`, RFC 8332) for user authentication: today RSA keys sign with
  `ssh-rsa` (SHA-1), which OpenSSH 8.8+ refuses by default. Upstream PRs #131 and #135 show the approach.

## Known upstream issues, not patched here

- `Exec/Client/ExecClient.swift`: the response size cap counts stdout only; stderr grows without a cap.
- `WithExecTests` (`testExecuteCommandReceivesStderrOnly`, `testExecuteCommandPairReceivesStderr`) fail
  intermittently on Linux (`channelFailure`, sometimes SIGSEGV in the runner) on the unpatched copy as well.
