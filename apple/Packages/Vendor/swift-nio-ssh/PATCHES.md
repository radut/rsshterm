# swift-nio-ssh: vendored copy and its patches

Origin: the swift-nio-ssh fork Citadel 0.12.1 depends on, `https://github.com/Wellz26/swift-nio-ssh.git`, tag 0.3.7
(revision d88989f3d3bb1dfb2a38ce4af598afbf7fc3095c), itself a fork of `apple/swift-nio-ssh`. Licence: Apache 2.0
(`LICENSE.txt`, unchanged).

Copied: `Sources/NIOSSH` (without the docc catalogue) and `Tests/NIOSSHTests`. Left out: the example client and server,
the performance tester, the docc plugin and the Swift 5.4/5.5 manifests; `Package.swift` lists only the library and its
tests.

Each change below is self-contained, so it can be offered upstream as one pull request.

## 1. Agent forwarding (`auth-agent-req@openssh.com`, `auth-agent@openssh.com`)

OpenSSH's agent forwarding (`ssh -A`, OpenSSH `PROTOCOL` §2.4, draft-miller-ssh-agent): the client sends the channel
request `auth-agent-req@openssh.com` (no fields, want-reply false) on a session channel; the server then opens one
`auth-agent@openssh.com` channel (no type-specific fields) back to the client for every agent client on its side.
Before this patch the request could not be sent and an inbound `auth-agent@openssh.com` open failed to parse
(`unknownPacketType`), which tears down the connection.

- `Child Channels/SSHChannelType.swift`: public case `SSHChannelType.authAgent`, mapped to and from the message type.
- `SSHMessages.swift`: `ChannelOpenMessage.ChannelType.authAgent` read and written as `auth-agent@openssh.com`;
  `ChannelRequestMessage.RequestType.authAgentRequest` read and written as `auth-agent-req@openssh.com`.
- `Child Channels/ChildChannelUserEvents.swift`: public `SSHChannelRequestEvent.AgentForwardingRequest(wantReply:)`
  (default false), its conversion from an inbound request and to an outbound message.
- `Child Channels/SSHChildChannel.swift`: `triggerUserOutboundEvent` accepts `AgentForwardingRequest`.
- Tests: `Tests/NIOSSHTests/AgentForwardingTests.swift` (byte-exact encode/decode against the OpenSSH layout, partial
  reads, event conversion, other unknown channel types still rejected, a server-opened agent channel reaching a client
  initializer with data flowing, a refusing client keeping the connection); `EndToEndTests.testChannelRequests` also
  round-trips the new request.

Source note: adding a case to the public `SSHChannelType` enum breaks exhaustive `switch`es in dependants (Citadel's
`ClientSession` and `Server` were updated in the same change).

## Known upstream issues, not patched here

- `SSHPacketParser`: `packetLength + UInt32(protection.macBytes)` can overflow and trap on a hostile length field
  before authentication (a malicious server can crash the client). Apple's swift-nio-ssh has later parser fixes.
