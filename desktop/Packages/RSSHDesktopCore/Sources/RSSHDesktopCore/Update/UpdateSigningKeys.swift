/// Public halves of the latest.json signing key (base64 of the raw 32-byte Ed25519 key). The private half lives only
/// in the CI variable DESKTOP_UPDATE_SIGNING_KEY. Add the new key here before rotating, remove the old one a
/// release later. While the list is empty, every manifest is refused (the updater fails closed).
/// How to create the key and print this value: docs/desktop/update.md.
enum UpdateSigningKeys {
    static let base64: [String] = ["XeMpftz9QCrQv7+BYBQhvI2iSQE8SHmNHr/Btq7dOkY="]
}
