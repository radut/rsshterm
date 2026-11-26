/// Throwaway keys made with `ssh-keygen -t ed25519` for these tests only; they log in nowhere.
enum OpenSSHKeyVectors {
    static let ed25519PEM = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
    QyNTUxOQAAACBD/YrMcEYGJGPCrh3O4/HbqYpUw+NEm0KoKNTSrrfGhwAAAJC6L3P2ui9z
    9gAAAAtzc2gtZWQyNTUxOQAAACBD/YrMcEYGJGPCrh3O4/HbqYpUw+NEm0KoKNTSrrfGhw
    AAAECqPx5gM/rogOd9+T+jSi59J3hegXuobHpBUX9cUDVA50P9isxwRgYkY8KuHc7j8dup
    ilTD40SbQqgo1NKut8aHAAAADHRlc3RAcnNzaGtpdAE=
    -----END OPENSSH PRIVATE KEY-----

    """
    static let ed25519PublicLine =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEP9isxwRgYkY8KuHc7j8dupilTD40SbQqgo1NKut8aH test@rsshkit"
    static let ed25519CheckInt: UInt32 = 0xba2f_73f6

    /// The same kind of key, encrypted with the passphrase "pass" (aes256-ctr, bcrypt).
    static let encryptedPEM = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABCmh0nOM7
    jZmTFTy3t08HRdAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAILYhd0FOLBLxm5dk
    jYqiQMCDitZcuC64lq+aSyupEzNjAAAAkDUNJSXugE6jIjR5zxQ+nggmZxz4oZ1xv9rhYf
    FPHBcxL3VXTsPRG0gNKEgnxumFZ+BEe3lU1zWb2UGn+5JdbjNB7dhBkSDRYEh2S3AxGT1Z
    lBXK35ugkG+5kbIKmw7pHky+HzRQAbgnI/f0ktB1VYUl9gM4cB1UsoLJx1C48WNW430kRI
    ETs93iyIh04Nt9UQ==
    -----END OPENSSH PRIVATE KEY-----
    """
    static let encryptedPublicLine =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILYhd0FOLBLxm5dkjYqiQMCDitZcuC64lq+aSyupEzNj"

    /// An unencrypted 1024-bit RSA key: inspectable, but not an ed25519 key.
    static let rsaPEM = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAlwAAAAdzc2gtcn
    NhAAAAAwEAAQAAAIEAruGJtQo9i/sgtDARInfjc5IsWUQReN+p90mGgmZUPxnNjznT9bXS
    p2m8p8Zvw095VXKAQT/+2qjQloSXTmbecPrCLiHeQqkk//JQK9jTv65/QNdsM6+rsm2HyH
    3/JIsslOgDhG9Pl7XIkfKWHxpQsBv2clFXtDRyeD9l0IXdBJ8AAAIAI38dDiN/HQ4AAAAH
    c3NoLXJzYQAAAIEAruGJtQo9i/sgtDARInfjc5IsWUQReN+p90mGgmZUPxnNjznT9bXSp2
    m8p8Zvw095VXKAQT/+2qjQloSXTmbecPrCLiHeQqkk//JQK9jTv65/QNdsM6+rsm2HyH3/
    JIsslOgDhG9Pl7XIkfKWHxpQsBv2clFXtDRyeD9l0IXdBJ8AAAADAQABAAAAgFgngM8t1l
    CVyqqKAFkrrhA4AvsMgPI5bOgmvBNHmfgk/aXRNLOLcCDMADliojwF99fG3DgIFmQK7Pqy
    48K1wDLFccqCFDBc0bXxoLKwkGNhhVvG0R4WiRdInIaWAicNflmPC5AwSPW6nDqWx+VN4w
    iSfaSwrMNcuAYc0PDbNOEBAAAAQGvUeU2Vei6d9/o127dQIVM4B0Ujo47c8mCMk72HVI6l
    SKff17++n+I6Y0ciTY5WPG45szdEnHLO5KBl6VIjs2IAAABBAOVY/wMALLTovF0ikwt69X
    TrDBjSy8h564LuE2gNg6nBMVhlRG6v97c15UdeHTYijB3GPJiaeN3WivWGc5da4qEAAABB
    AMM0LjESkywLRKRIr3Nm9KzhULO2aVzVHUpZnOOJsGGsDg/XiZbayBtyTgtR06lohNha/c
    k30pb2aiq6dtf13z8AAAAFcnNhQHgBAgMEBQY=
    -----END OPENSSH PRIVATE KEY-----
    """
    static let rsaPublicLine = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAAgQCu4Ym1Cj2L+yC0MBEid+NzkixZRBF436n3SYaCZlQ/Gc2POdP1tdKnabynxm/DT3lVcoBBP/7aqNCWhJdOZt5w+sIuId5CqST/8lAr2NO/rn9A12wzr6uybYfIff8kiyyU6AOEb0+XtciR8pYfGlCwG/ZyUVe0NHJ4P2XQhd0Enw=="
}
