/// Throwaway keys made with openssl and ssh-keygen for these tests only; they log in nowhere. Passphrase: "pass".
enum ECKeyVectors {
    /// `openssl ecparam -name prime256v1 -genkey -noout`
    static let p256SEC1 = """
    -----BEGIN EC PRIVATE KEY-----
    MHcCAQEEIE3/xJSSSJxKR3zvFL7zjysWFiOSBTO/hZsj0GPl7xgdoAoGCCqGSM49
    AwEHoUQDQgAEQKXDepDiiI9q9K/w6R97/ys3o/oxAiSjHP7l1bBrcI0vhZ8G6uxb
    JVnsh3f3y9CrPBevNXIBMssG+6e2pzJJww==
    -----END EC PRIVATE KEY-----
    """

    /// `openssl ec -no_public`: the point must be computed.
    static let p256SEC1NoPublic = """
    -----BEGIN EC PRIVATE KEY-----
    MDECAQEEIE3/xJSSSJxKR3zvFL7zjysWFiOSBTO/hZsj0GPl7xgdoAoGCCqGSM49
    AwEH
    -----END EC PRIVATE KEY-----
    """

    /// `openssl ec -aes128`
    static let p256SEC1AES128 = """
    -----BEGIN EC PRIVATE KEY-----
    Proc-Type: 4,ENCRYPTED
    DEK-Info: AES-128-CBC,B6C8A753D31BE29B75D428E9AB27C98E

    Sfcl1KyPOSw22E030xSbBOTo49ffj+RHj5wxV4yDbkrCVsVry1bpEKHB5Q4pmmz2
    o70Sk8DpdM+mW2LfGHGNHkzEQ4E2SR5wdRchocwhwyRBYrb/K6VQrim0pATrwT73
    yh5G5phj8iKv5VUMyauB6d3OkRwA1iCPPPeYL3t6XaE=
    -----END EC PRIVATE KEY-----
    """

    static let p256PKCS8 = """
    -----BEGIN PRIVATE KEY-----
    MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgTf/ElJJInEpHfO8U
    vvOPKxYWI5IFM7+FmyPQY+XvGB2hRANCAARApcN6kOKIj2r0r/DpH3v/Kzej+jEC
    JKMc/uXVsGtwjS+Fnwbq7FslWeyHd/fL0Ks8F681cgEyywb7p7anMknD
    -----END PRIVATE KEY-----
    """

    /// PBES2, PBKDF2-HMAC-SHA256, AES-256-CBC.
    static let p256PKCS8Encrypted = """
    -----BEGIN ENCRYPTED PRIVATE KEY-----
    MIHsMFcGCSqGSIb3DQEFDTBKMCkGCSqGSIb3DQEFDDAcBAhyswuepVxSqAICCAAw
    DAYIKoZIhvcNAgkFADAdBglghkgBZQMEASoEEOhVRZKjqS3RKD34hElpsqsEgZBS
    tAhbmDKgFudI+wbFAIlSFHzVEF1f9wIVKvngg7XL5sw5CrzORNYq8rWmEENTRPhc
    P8Ott8erNiZCL7jEphPvfK/RfumBngKL5huDvL5e8idmGTWn35w660NCb0c6m9uo
    om1J3uL4rQ1WOxnjsWOmR2SmpDwOH2pnX3KGZMW0Dj812sgoSHqvIKM8tIwv8WU=
    -----END ENCRYPTED PRIVATE KEY-----
    """

    /// The same key after `ssh-keygen -p -N ""`.
    static let p256OpenSSH = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAaAAAABNlY2RzYS
    1zaGEyLW5pc3RwMjU2AAAACG5pc3RwMjU2AAAAQQRApcN6kOKIj2r0r/DpH3v/Kzej+jEC
    JKMc/uXVsGtwjS+Fnwbq7FslWeyHd/fL0Ks8F681cgEyywb7p7anMknDAAAAmNjRd4jY0X
    eIAAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEClw3qQ4oiPavSv
    8Okfe/8rN6P6MQIkoxz+5dWwa3CNL4WfBursWyVZ7Id398vQqzwXrzVyATLLBvuntqcySc
    MAAAAgTf/ElJJInEpHfO8UvvOPKxYWI5IFM7+FmyPQY+XvGB0AAAAA
    -----END OPENSSH PRIVATE KEY-----
    """

    static let p256PublicLine =
        "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEClw3qQ4oiPavSv8Okfe/8rN6P6MQIkoxz+5dWwa3CNL4WfBursWyVZ7Id398vQqzwXrzVyATLLBvuntqcyScM="

    static let p384PKCS8 = """
    -----BEGIN PRIVATE KEY-----
    MIG2AgEAMBAGByqGSM49AgEGBSuBBAAiBIGeMIGbAgEBBDA5KHl4vUknEemLdiRX
    IuqJdwFmimaObUrGpfdI4CsP4Akjj2CUwnWn+buDBO4Ysw2hZANiAAQMd2R2cefz
    R0T8PTsCwL8+Wk/Pnj+7FcjcYyYgOKvC0HV4Fdi1qNH6IS4oTbfZu9qQULRwsUwY
    EHR0xsQy13jUwssn3U9mzSqU3po1sf7/b8lI5irMXTRkw96s5f29mmU=
    -----END PRIVATE KEY-----
    """

    static let p384PublicLine =
        "ecdsa-sha2-nistp384 AAAAE2VjZHNhLXNoYTItbmlzdHAzODQAAAAIbmlzdHAzODQAAABhBAx3ZHZx5/NHRPw9OwLAvz5aT8+eP7sVyNxjJiA4q8LQdXgV2LWo0fohLihNt9m72pBQtHCxTBgQdHTGxDLXeNTCyyfdT2bNKpTemjWx/v9vyUjmKsxdNGTD3qzl/b2aZQ=="

    static let p521SEC1 = """
    -----BEGIN EC PRIVATE KEY-----
    MIHcAgEBBEIARxZrXTmTyZa45ps9ws4qrMhMXFgRGVkxolCH9CU5QsmjcMZXgEDC
    fgEbBZ4g8PD22Y9K/h3cyPc0jnDYAlHZNMKgBwYFK4EEACOhgYkDgYYABAFYR3Dh
    Jlcgy0NO1T15O8G4qdraOrxUsrsQAUnyduYBn5bTl4Crb/teU7N+wHR3h8yoIuxR
    +yGSwLV/tMXRalDC1AGrA9Db05y7wsx3DV6nqwQuRoRT7reYNnz1SI9h5qcVVvjG
    4D2RDGnB0JEJM25QMkdMi66AM831JeiaURtw1Qmayw==
    -----END EC PRIVATE KEY-----
    """

    static let p521PublicLine =
        "ecdsa-sha2-nistp521 AAAAE2VjZHNhLXNoYTItbmlzdHA1MjEAAAAIbmlzdHA1MjEAAACFBAFYR3DhJlcgy0NO1T15O8G4qdraOrxUsrsQAUnyduYBn5bTl4Crb/teU7N+wHR3h8yoIuxR+yGSwLV/tMXRalDC1AGrA9Db05y7wsx3DV6nqwQuRoRT7reYNnz1SI9h5qcVVvjG4D2RDGnB0JEJM25QMkdMi66AM831JeiaURtw1Qmayw=="

    /// `openssl genpkey -algorithm ed25519`
    static let ed25519PKCS8 = """
    -----BEGIN PRIVATE KEY-----
    MC4CAQAwBQYDK2VwBCIEIJliWXHQMhtMNr4TADRP56X7JHDcPj5dWVk5/YD+sdAY
    -----END PRIVATE KEY-----
    """

    static let ed25519PKCS8Encrypted = """
    -----BEGIN ENCRYPTED PRIVATE KEY-----
    MIGbMFcGCSqGSIb3DQEFDTBKMCkGCSqGSIb3DQEFDDAcBAh9aQqE1n5EfQICCAAw
    DAYIKoZIhvcNAgkFADAdBglghkgBZQMEASoEEKTdvPFUcBf3BX4foDYfR5YEQAGH
    OH9k18TsCvHPHGSe9R8E5M2p2AU1eP0034RxqMxtaUCtiap0HfLkHY0bUHXCBvKa
    YDarFo6pXkd/VLXvZ6I=
    -----END ENCRYPTED PRIVATE KEY-----
    """

    static let ed25519PublicLine =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIORsWgmEHbgkn0jTgwBZQNQjcl2cXTNl6kOSlV7A6I5y"

    /// An X25519 key: a key-agreement key that cannot log in.
    static let x25519PKCS8 = """
    -----BEGIN PRIVATE KEY-----
    MC4CAQAwBQYDK2VuBCIEIOBAFp+ouDK0aVzZaAbVFVUcRM0C5jBYj4rX3VSajY5F
    -----END PRIVATE KEY-----
    """
}
