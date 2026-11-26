/// Throwaway keys made with puttygen 0.78 for these tests only; they log in nowhere. Passphrase: "pass".
enum PuTTYKeyVectors {
    /// `RSAKeyVectors.pkcs1` through `puttygen --ppk-param version=2`.
    static let rsaV2 = """
    PuTTY-User-Key-File-2: ssh-rsa
    Encryption: none
    Comment: rsa@putty
    Public-Lines: 4
    AAAAB3NzaC1yc2EAAAADAQABAAAAgQDQUM2dKiNVNXW5Zahvqs6a73BJBLB9O3ba
    W2PBMRmg6Cy88HQ8ESUhgZEwFpAJ33p5miNQGmJqEHGHf0cQbI51z2Xm7fDOBQaf
    G1LBZB3PVavr8laVKzVZ4jJi9z/AqIULYyKrSrOhTUAiPeqD0ipim7L4C1go95Bi
    2L7DjKTalw==
    Private-Lines: 8
    AAAAgAbKG2l77hrg2y1nus2o64LxOt+mX3o1bfI/+EhbqVItPwgJbkBm7qbg6jJ/
    CcLInd1IwM3jjkGWt5yK8W3/m8T8FmKK6mez937uRvOQxDBkEea8LQcevYQ+rSXc
    eNTofI3AzpX343oZAGmntDQD9YKxbaXeJGlmm2Ccce8iQDEBAAAAQQD9+7IYk5me
    P7pgSeZQmzOaQKWqcLxgJB6aQym4xJQ4vWc3Z2ZHUCvOpzqU06eUBxw0v6tvN/Ag
    HTgRQjvZPC4nAAAAQQDR+EXvnhbfrpN/17xtqr1CVdg/xsUqZEoeigFwftfndG/A
    yNbvFJlkaKV9Pbm02KZo075AxDtbMRqAOucUVCYRAAAAQQC0Y0+Vr/XBVix2IvBv
    uQT4dj7nOW0d2eiQ+xsobZ5GZv0VZVuwZkusV8p5qM/zn1acStrzxGynegqpZIto
    1D64
    Private-MAC: 8987ad1bd35b569e7bf3555ce2cbe0156158f845
    """

    static let rsaV3 = """
    PuTTY-User-Key-File-3: ssh-rsa
    Encryption: none
    Comment: rsa@putty
    Public-Lines: 4
    AAAAB3NzaC1yc2EAAAADAQABAAAAgQDQUM2dKiNVNXW5Zahvqs6a73BJBLB9O3ba
    W2PBMRmg6Cy88HQ8ESUhgZEwFpAJ33p5miNQGmJqEHGHf0cQbI51z2Xm7fDOBQaf
    G1LBZB3PVavr8laVKzVZ4jJi9z/AqIULYyKrSrOhTUAiPeqD0ipim7L4C1go95Bi
    2L7DjKTalw==
    Private-Lines: 8
    AAAAgAbKG2l77hrg2y1nus2o64LxOt+mX3o1bfI/+EhbqVItPwgJbkBm7qbg6jJ/
    CcLInd1IwM3jjkGWt5yK8W3/m8T8FmKK6mez937uRvOQxDBkEea8LQcevYQ+rSXc
    eNTofI3AzpX343oZAGmntDQD9YKxbaXeJGlmm2Ccce8iQDEBAAAAQQD9+7IYk5me
    P7pgSeZQmzOaQKWqcLxgJB6aQym4xJQ4vWc3Z2ZHUCvOpzqU06eUBxw0v6tvN/Ag
    HTgRQjvZPC4nAAAAQQDR+EXvnhbfrpN/17xtqr1CVdg/xsUqZEoeigFwftfndG/A
    yNbvFJlkaKV9Pbm02KZo075AxDtbMRqAOucUVCYRAAAAQQC0Y0+Vr/XBVix2IvBv
    uQT4dj7nOW0d2eiQ+xsobZ5GZv0VZVuwZkusV8p5qM/zn1acStrzxGynegqpZIto
    1D64
    Private-MAC: a1aae18df9bdee7b8b57f4584b54112c3ea26a8ff0fd38a53211e11a5b77c0a8
    """

    /// aes256-cbc, passphrase "pass".
    static let rsaV2Encrypted = """
    PuTTY-User-Key-File-2: ssh-rsa
    Encryption: aes256-cbc
    Comment: rsa@putty
    Public-Lines: 4
    AAAAB3NzaC1yc2EAAAADAQABAAAAgQDQUM2dKiNVNXW5Zahvqs6a73BJBLB9O3ba
    W2PBMRmg6Cy88HQ8ESUhgZEwFpAJ33p5miNQGmJqEHGHf0cQbI51z2Xm7fDOBQaf
    G1LBZB3PVavr8laVKzVZ4jJi9z/AqIULYyKrSrOhTUAiPeqD0ipim7L4C1go95Bi
    2L7DjKTalw==
    Private-Lines: 8
    yElGHm+KfZ8pz0llFnVM6JEhX1QCs+/jL6HWaOdQwrXea8SawD01LPjCdAnvjMEM
    416vuxoForS6b8wh9bmSfpaFeEb40+L0JrSoNCdesPsRfuXBJ33QfH8psmNLdOd6
    XLwRLbu5e3vMQxyYpB7ruobtDSn9zkEaEtS610xOUQTVPqkTdbS+B0BeQrBvhz14
    qrS56vSqou2gA3mQwUSJxOiFQz4aXIjGN+oP3oSXKmwVBMGFkp2x1pA7jOVK1fls
    v6zGRB9QpQPat/udQuBCNFK4kgdn7/0LUWMRuXWFbSlmNdLYnnnoDur0sbF4DTtP
    2D8up8B4bUM6o5TPaDa+j0xHNFs3MZ5EF5+MY5FGl2go8rDMXHTl3Pyu9eupbt2B
    xcx7ZyrspJdfPKw8cbJgnqdKxSeWoFI0v5nJ+28qLp2jfp0S0KE0mwsmuBaUG9Hr
    Na3sXlR7swdJVa95bC3QNQ==
    Private-MAC: 78a0c98c09fe4a8b5e3a2ca865205aa9ddfd85b1
    """

    /// Argon2id: not readable here.
    static let rsaV3Encrypted = """
    PuTTY-User-Key-File-3: ssh-rsa
    Encryption: aes256-cbc
    Comment: rsa@putty
    Public-Lines: 4
    AAAAB3NzaC1yc2EAAAADAQABAAAAgQDQUM2dKiNVNXW5Zahvqs6a73BJBLB9O3ba
    W2PBMRmg6Cy88HQ8ESUhgZEwFpAJ33p5miNQGmJqEHGHf0cQbI51z2Xm7fDOBQaf
    G1LBZB3PVavr8laVKzVZ4jJi9z/AqIULYyKrSrOhTUAiPeqD0ipim7L4C1go95Bi
    2L7DjKTalw==
    Key-Derivation: Argon2id
    Argon2-Memory: 8192
    Argon2-Passes: 34
    Argon2-Parallelism: 1
    Argon2-Salt: 4a99aec1f82e4bd3b46b12ea4b49c45e
    Private-Lines: 8
    t661RWnQwLec4ayT0qittLvZnmsaIHjh9yQ0Qx8PC/FDMaaLV3ideYe7+UAHRq6x
    xLfPBhyDoMNRpjTaLNjtJ+1waS99opdgJ97SQ9YcCnXMP9S4xVqj5/M6oVm3qshX
    qxsSDAbs7YWFkQ/4ob22vW9U/RU+tkkB69CACL+X4Yygwh1yQC4MtTzKFCFjEmX+
    gGalZdlym13lCmouaOQ8ULkzz/Z57ASF7PLlVfdVYX+z+prGwdTzoIEiWf0713ls
    Ho4H1dESu+E/AxPrTGBsGTvSpypkdeMJ8YEGDzKdCFtJBTDDQyDCIqw3GVoeDP4J
    mhY30HvT0255B4/HAOibvuZI7x9lKQySNPcNSYQ58GphVYCXhgiGZXdQ4Lxm7Zlx
    BHxQ31WoNe+jY5aQN9MgGymKgB3S53p4l6iN4HH1z0eUFpolQGkny9w6WUl8Z3ON
    n+yZMtNkMa/OQmTXvZOSjQ==
    Private-MAC: 52809d89f4f57a28e8b644edd4693ca6695be355820bfd3d7a6b8ac3847774cf
    """

    static let ed25519V3 = """
    PuTTY-User-Key-File-3: ssh-ed25519
    Encryption: none
    Comment: ed@putty
    Public-Lines: 2
    AAAAC3NzaC1lZDI1NTE5AAAAIDIARJhZrFzLO08e/voLpMI+0/SecKfWJThYoM8T
    hhgy
    Private-Lines: 1
    AAAAIFDmxwH5H7P43kQ4rzGOTIIHRY7Dli3xNkvOFewfXucl
    Private-MAC: 2631f63038d74874141507cfc5b74a4a378991d99d605de9734e33f18658023f
    """

    static let ed25519PublicLine =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDIARJhZrFzLO08e/voLpMI+0/SecKfWJThYoM8Thhgy ed@putty"

    static let p256V3 = """
    PuTTY-User-Key-File-3: ecdsa-sha2-nistp256
    Encryption: none
    Comment: ec@putty
    Public-Lines: 3
    AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBHgEwhzKQM8A
    +P7ZszMbdj3J594syyjnVhz+uCm+OiM0jBny+R23FKrgpITyk0LTcoQtnBix2z/C
    zYAjBMqGt2M=
    Private-Lines: 1
    AAAAIQDXKz//TiZGEog9Ml65cbKHUHEn4/CpDNvz2dm+/O0yFQ==
    Private-MAC: 539d5eb89b1c05944a32a4c84486e3d9ff2236f518fa5fa8576754c1aab4b90e
    """

    static let p256PublicLine =
        "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBHgEwhzKQM8A+P7ZszMbdj3J594syyjnVhz+uCm+OiM0jBny+R23FKrgpITyk0LTcoQtnBix2z/CzYAjBMqGt2M= ec@putty"

    static let p384V2 = """
    PuTTY-User-Key-File-2: ecdsa-sha2-nistp384
    Encryption: none
    Comment: ec384@putty
    Public-Lines: 3
    AAAAE2VjZHNhLXNoYTItbmlzdHAzODQAAAAIbmlzdHAzODQAAABhBOAJ5T9yaUu7
    LuKi2FAE6leu9D9Er6vKSNboe/4gSIZKGbhurztgxDisSzKEQDjVC5CvOf/+bj8b
    FRlfo7AYKLRsE6/AAM9vYxdyGUiloG9Swo3rtVKgB74lxwqGWmvBDA==
    Private-Lines: 2
    AAAAMBRqNYaFa7kMuTvZpmugBCgRmgLJUFKuJzKieAAIO6q1Yh2Rt4zXxpFA1XIN
    I5geVA==
    Private-MAC: d356711ec1a147fe415491355e497721aa5f3357
    """

    static let p384PublicLine =
        "ecdsa-sha2-nistp384 AAAAE2VjZHNhLXNoYTItbmlzdHAzODQAAAAIbmlzdHAzODQAAABhBOAJ5T9yaUu7LuKi2FAE6leu9D9Er6vKSNboe/4gSIZKGbhurztgxDisSzKEQDjVC5CvOf/+bj8bFRlfo7AYKLRsE6/AAM9vYxdyGUiloG9Swo3rtVKgB74lxwqGWmvBDA== ec384@putty"
}
