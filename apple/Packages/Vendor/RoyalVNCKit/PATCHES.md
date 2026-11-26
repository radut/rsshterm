# RoyalVNCKit: vendored copy and its patches

Origin: `https://github.com/royalapplications/royalvnc`, main at revision 090b96eddeee183e9fec293c5cd881d302a4349d
(2026-09-21). Licence: MIT (`LICENSE`, unchanged); bundled zlib (zlib licence), d3des (public domain).

Copied: `Sources/`, `Package.swift`, `Package.resolved`, `LICENSE`. Left out: the two demo executables
(`RoyalVNCKitDemo`, `RoyalVNCKitCDemo`), `Bindings/` (C#, Kotlin), `Design/`, the Android scripts.
Dependencies unchanged: Royal Apps' CryptoSwift fork (branch `foundationessentials`) and Cstb.

## 1. Clipboard on request

RoyalVNCKit only uses the server's clipboard text (ServerCutText) when "clipboard redirection" is on, and then also
polls the system pasteboard every 0.5 s. On iOS each read of another app's pasteboard shows the paste notice, so the
app keeps redirection off and offers Get Clipboard / Send Clipboard buttons instead.

- `SDK/Connection/VNCConnection.swift`: `public var serverCutTextHandler: ((String) -> Void)?`.
- `SDK/Connection/VNCConnection+Receive.swift`: `handleServerCutTextMessage` calls it with every ServerCutText,
  before the redirection check (behaviour with redirection on is unchanged).
- `SDK/Connection/VNCConnection+API.swift`: `public func sendClipboardText(_:)` enqueues a ClientCutText.

## 2. Server clipboard size limits

`Protocol/Messages/ServerToClient/ServerCutText.swift`: a ServerCutText longer than 1 MiB (`maximumLength`) or with
the length Int32.min is refused with `VNCError.protocol(.invalidData)` (the connection closes) instead of being
buffered whole, or trapping in `Int32(abs(Int32.min))`. Upstream read any length the server sent.
