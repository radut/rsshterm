/// Throwaway keys made with `ssh-keygen -N "correct horse"` for these tests only; they log in nowhere.
enum EncryptedKeyVectors {
    static let passphrase = "correct horse"
    static let ed25519 = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABAzTSByF3
    oyISuDWLyO4PpUAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIPJ/pHlK/XQnG4H4
    r6y4fqVF9h5De1NNEdvMc2jCtbYZAAAAkOpH9nZHgjHnRbx2h2ErQWy2J6bJEEZ5jYsRCK
    gXZfnJ4tHN8YOCsw5xSqUXVV5sgbIb1lFSR+M4kUJuWu03kL/spKkfXmD+W6eZcveCFAkN
    VxLWVpHk0dsAScC/0gfpsPDPomCLqDlb1922EUX0iEBYQBDTl+FTAxQ+ZSqpte9Fi5cLNY
    PeCsGkJG5FWHwhHg==
    -----END OPENSSH PRIVATE KEY-----
    """
    static let ed25519Public = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPJ/pHlK/XQnG4H4r6y4fqVF9h5De1NNEdvMc2jCtbYZ ed@test"
    static let ecdsa = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABBKWgnBvC
    1qee7zzjUPcFsUAAAAGAAAAAEAAABoAAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlz
    dHAyNTYAAABBBGLZM5V22M0VrJgZItXE4NoMRqpCAn6N3u5jZbVqIub3lA3eb+fK0UFeKX
    KopsXZe0qkP5wsyS+7X5nOR+TqwVYAAACgbcq6CLIxBRbdl9rdOEazXwAoAl3msvhvy7qK
    XMtISn8HVBoj8FF9eR349j3k4BmGSZToVGHnvuAhOwKDEv1JZlJh2bZj79n6sWWTQn7cR6
    gyu5WcD9gsDTd1kA6SUzXgIS24vL8n+8ZZVn7jBKbxs4za/bdUmkLZLTGu2099Weqwdu75
    Zju/cFyyDVm9xPZ4UUpVlrGnD9kwPh1b8thwPQ==
    -----END OPENSSH PRIVATE KEY-----
    """
    static let ecdsaPublic = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBGLZM5V22M0VrJgZItXE4NoMRqpCAn6N3u5jZbVqIub3lA3eb+fK0UFeKXKopsXZe0qkP5wsyS+7X5nOR+TqwVY= ec@test"
    static let rsa = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABAY0Ba5Ff
    tXeEAYHNg/6utiAAAAGAAAAAEAAAEXAAAAB3NzaC1yc2EAAAADAQABAAABAQCiAv5bwUiV
    7/i8TpObD4kUjSZq93qNH3fQpcmbvZVbbu09pN37Bxl2H0dz/XakkmgvZmSXnqUIT/AenN
    qGpmhmqqx1IHtLIFJ+yFH9niKSllykghw3jX8Jl47i9hmPGdtUH2/YQXwPKnmQ3ssV/Snx
    DhRizI7F+CapABeeQrR01gMyhWhngbNmuxKPd1IPNI/PpQ9fndh6EA1gcwTZ1rNAu3H9tE
    ogvYCnLJh6xEht+dexkYcbG8G0rzzOGwef7SMnhzT3GuCEngKBZDBdYeNduD+vLNxHAkJZ
    BkDupZd488y4FghS/crbbyS2jcn5mmAWfr/CEnETE1JeuONBrQszAAADwKMmJaQDtjHxpW
    jwg58V8iPp/rne9gapXsvzxabtARC1J9w/3Da+KUQmTCpyUlVPZmFh1q0GxrFJm+2ERzXE
    5kBT0MuUJKNwTWavKLM5t5W8z3Zniet/4L67fnUbdz731W06vTu/3bt/1fDATXxEXY88yp
    m2lsBFuTAbM1KE9hrms9C1HyKZ7D9iIPkfHXCNYK1oSuNcBUN4YZAKd+ofs+u562+HB7H3
    yduWW8c52+qR+o2GEuw/lMXMFmKRxuHeDN8NEJ3Ms+V2TtX+x5vCqSnmyH0AzQPecgJuBF
    TA4fVLbnVAMwchDgEEaedhlK6PEBu/wU+ZsRSYYSE7yI655M8hzSuPFcnPxnaqB65hdSPT
    5F9wraqIMex7mFQqItGkLMjqBsMR26ZdvC04OEnuS6XLyoz242t/0yCuV7V8S5F0StjEdc
    Hw3wjry2B2TE1Wip7xS2a950v978XI+81EXYNk+ANuGmw0Nc9iDQ2tXO/pZUa50R2PImKd
    UpIdHmm5v/v5UYnbh01AxfhB7JX/22AzwPm5XiZiG8ZzR0K+iWGgjtu21ShEP5pjMiekZx
    SgODfDCe12gVxNR2GCGjVuoUCoZ7bHe8/xZ49AkijGHqxbFbOm/38uXtTXQcomJk2BQRih
    n/ijiKFQcXL5CJDqMan6XA8BRn6W70zpW98WCD8UnEp3qXICX6eLNgPwqmAHh1BvcKnofZ
    398v4tpP5lfbH4qiThS9pRQu/Ux1HKnLdpwfwLqMDxAgWycO0nqkRw0XPKlAnxhqpPthSW
    Hghy+X7oV0Z4mCiU1hZQCEGJ6tbTxENB/pwTMutipyDoLaQoSvFdr2OR4yOLN66UL6KpIF
    Q32CwrDaga1TknpSbYZxPVLSAEIFV1FqPqQKGMFefYqmJwhdifEVLK3wONXaErb3ODU2TR
    oc93PXOeFL3jiVwgSCmqgUeDRjMqIDFbGMA7PR5ThXg0UI0nPoW1gTcdKBIGemvJE6rwwz
    RMnIirb6dyn46fYgBjMSd0vFp66rKlYoXS+GEZVpsz+SSGfJcMqn1uPihmZ0eE4hi/oId6
    Q0I+S5UDWwQo6opEXsCf3KgToyLrsd2B6Cne92gcJ5nsjCDrQkPEgUiQhP6DNrhGQlNA2H
    aBdqNzB9PMBbBnWimE5YuAIbF7uHl9I1PgMmR64sDpM8wo11dDLXT8n2915Y/yNrLxDA8A
    8bv6F+Cg9MxFX6vzq9aMf0AHnylBzp8GJg02/GG4khArA0kfVku5gVTPt7XCdaHIF6H4Sj
    4bYJ/EhQ==
    -----END OPENSSH PRIVATE KEY-----
    """
    static let rsaPublic = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCiAv5bwUiV7/i8TpObD4kUjSZq93qNH3fQpcmbvZVbbu09pN37Bxl2H0dz/XakkmgvZmSXnqUIT/AenNqGpmhmqqx1IHtLIFJ+yFH9niKSllykghw3jX8Jl47i9hmPGdtUH2/YQXwPKnmQ3ssV/SnxDhRizI7F+CapABeeQrR01gMyhWhngbNmuxKPd1IPNI/PpQ9fndh6EA1gcwTZ1rNAu3H9tEogvYCnLJh6xEht+dexkYcbG8G0rzzOGwef7SMnhzT3GuCEngKBZDBdYeNduD+vLNxHAkJZBkDupZd488y4FghS/crbbyS2jcn5mmAWfr/CEnETE1JeuONBrQsz rsa@test"
    static let ed25519GCM = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAAFmFlczI1Ni1nY21Ab3BlbnNzaC5jb20AAAAGYmNyeXB0AA
    AAGAAAABCjOgF/mZJdLO1tWi+sXGvTAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAA
    IElTYbxeBCcR2pd+PCXbeP73TkYj4CqknQgs8cFhVnIWAAAAkHI5s084x3uTX7PIpQbwnH
    +hVaOSVnLBzntwiTKNXKzRD3FyS027E7lIb5b2ObjuZYKYRB+uYfxw5BwN9DQHHNJ7ZqZQ
    ahbmEFg+FE7t0U8j20YB1lva0PffqzZ8+/f8zv1C6Rx3vqi5N3tFE9FXWThq0//CnVOD+d
    iJcPjisTU6sSvJbDxKKxTteMFNl3VbBwsv4shxvb8AmT9bumJ4uAA=
    -----END OPENSSH PRIVATE KEY-----
    """
    static let ed25519GCMPublic = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIElTYbxeBCcR2pd+PCXbeP73TkYj4CqknQgs8cFhVnIW gcm@test"
    static let ed25519AES128 = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAACmFlczEyOC1jdHIAAAAGYmNyeXB0AAAAGAAAABBSq5s8Ym
    t/ceD5EAmQxlFNAAAABAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAINwj5f4dD0jMCfwu
    l9c87oojcaGXKW1h4EU+zSMY9eBEAAAAkCZTOHET3pk3FsqexDSxMeGzEKY6ETfuc7GwTX
    2Sxbv9ly4DJEk5vDjcXM4BbIGmKdcBWunp+2zkBwjua5om40Uq4yqNylIZBYON+Cycj8XS
    WNPJtHFjjavcnPNIR5IDsmEtHcXYgNmHXTwLczRC3YJEyxgPr+IiZ7jsic1blyceiC3Rwq
    vQ+Ki6xfyKUwiC/g==
    -----END OPENSSH PRIVATE KEY-----
    """
    static let ed25519AES128Public = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINwj5f4dD0jMCfwul9c87oojcaGXKW1h4EU+zSMY9eBE ctr128@test"
    /// bcrypt_pbkdf known answers (pyca/bcrypt `kdf`): (password, salt, rounds, length, hex).
    static let bcryptPBKDF: [(String, String, Int, Int, String)] = [
        ("password", "salt", 4, 32, "5bbf0cc293587f1c3635555c27796598d47e579071bf427e9d8fbe842aba34d9"),
        ("password", "salt", 8, 64, "e1367ec5151a33faac4cc1c144cd23fa15d5548493ecc99b9b5d9c0d3b27bec76227ea66088b849b20ab7aa478010246e74bba51723fefa9f9474d6508845e8d"),
        ("correct horse", "0123456789abcdef", 16, 48, "a1c2879278f7e16f30578823fd9fb40348ed786a6e23033da5c7a193b7732d71bfa8e1cd182c9aa0d87c3ef53911eb76"),
    ]
}
