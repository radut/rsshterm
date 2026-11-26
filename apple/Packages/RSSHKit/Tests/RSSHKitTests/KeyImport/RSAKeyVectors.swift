/// Throwaway keys made with openssl and ssh-keygen for these tests only; they log in nowhere. Passphrase: "pass".
enum RSAKeyVectors {
    /// 1024-bit RSA, `openssl genrsa -traditional`.
    static let pkcs1 = """
    -----BEGIN RSA PRIVATE KEY-----
    MIICXAIBAAKBgQDQUM2dKiNVNXW5Zahvqs6a73BJBLB9O3baW2PBMRmg6Cy88HQ8
    ESUhgZEwFpAJ33p5miNQGmJqEHGHf0cQbI51z2Xm7fDOBQafG1LBZB3PVavr8laV
    KzVZ4jJi9z/AqIULYyKrSrOhTUAiPeqD0ipim7L4C1go95Bi2L7DjKTalwIDAQAB
    AoGABsobaXvuGuDbLWe6zajrgvE636ZfejVt8j/4SFupUi0/CAluQGbupuDqMn8J
    wsid3UjAzeOOQZa3nIrxbf+bxPwWYorqZ7P3fu5G85DEMGQR5rwtBx69hD6tJdx4
    1Oh8jcDOlffjehkAaae0NAP1grFtpd4kaWabYJxx7yJAMQECQQD9+7IYk5meP7pg
    SeZQmzOaQKWqcLxgJB6aQym4xJQ4vWc3Z2ZHUCvOpzqU06eUBxw0v6tvN/AgHTgR
    QjvZPC4nAkEA0fhF754W366Tf9e8baq9QlXYP8bFKmRKHooBcH7X53RvwMjW7xSZ
    ZGilfT25tNimaNO+QMQ7WzEagDrnFFQmEQJAAQLwmaJ02Sl9z4Zb0XRcxz98qWob
    hfJ+4LRlxSObR4KRl6nkwWHzWrZVyGPzZeaFWTxuLVo2rZoQMBlobZwMvwJAIcMU
    K8V11B3UJdhguhmcORBop0ik534c1PBH7vjWaqc0WQFyXhsn1xdklNDaDZRQncZ+
    bxeem7k3k6rlAUXOoQJBALRjT5Wv9cFWLHYi8G+5BPh2Puc5bR3Z6JD7GyhtnkZm
    /RVlW7BmS6xXynmoz/OfVpxK2vPEbKd6Cqlki2jUPrg=
    -----END RSA PRIVATE KEY-----
    """

    /// `openssl rsa -traditional -aes128`
    static let pkcs1AES128 = """
    -----BEGIN RSA PRIVATE KEY-----
    Proc-Type: 4,ENCRYPTED
    DEK-Info: AES-128-CBC,10210117771B7C6FA26E4AC1826B77D1

    TRD25NtAeqxPEUlXQL536UDKD+fvg07ORBVyrylfAmlK3awLd3UqgcwjzGsOXveL
    QiY/05KQpuTfLW/aWqzSV5bS/nm5yMy4EsSJd6eiHtJm3j4f4C4DtV7beTtK1lsp
    DJbCLu+Pp/59Ycmm/mpEVNxh2wYptlng2SqWRV8cCsa5cDUv9VlX1dLbsN35LFsD
    eUR4JK+J2SwQt1NEq1haVL5v5ex9kgVkRy/AbQymDVJd6SCbASNFIOSeHWgnTQTG
    CnnKwOlTO+GZ9Jb0kdQDjazD6K2rDMGsOtD164IkoWeIU5NJpj4HNb0ge74w4UbN
    XC0+CFgAexcmYIL57padeiNniiVKj3w9fBwO0bcqw0Zc7/drXoEdD9nr7NCFxFg/
    JXfFEAwXsNCM3SrX8cf2TRxX2cOgEyk+kVYTvyjcDtY4FxRXtpcftopP4bflx4HL
    /aVo40PQaDoQ8aGsqCFpK4YsVaqBGDfek+dwdsJZbPEpuaSYtGbXFhyRV9SegiJa
    gIkptlfZDmxyeRxZAzrGI+aaZjO6JXahzvRPlFVJ2qEM2p9Y/Er2McVQQRIePoql
    ssBWfBe7n2pCKBfaM2qiImUtlt1NlIIDDRkg4IMiwypR/M1txzuybYFi0P1SuW6C
    8/aFh1QfJsuzXWfuE2HkAiwcNaKbLuSakUKQeWTLACqtt0rxIKYwRT+brn9AjqYy
    sdKh19hGcY2hQyd5VHtCFPDUCZYevLv1KNS3O5fyYI8VV1G+2iop+AnQwq+VvUBh
    4yCGWGKD5PwXmT5qlMgtW+PoVmBO3masR58vScoJLeoSvxBe2Ezr+Y27vecjVn/z
    -----END RSA PRIVATE KEY-----
    """

    /// `openssl rsa -traditional -aes256`
    static let pkcs1AES256 = """
    -----BEGIN RSA PRIVATE KEY-----
    Proc-Type: 4,ENCRYPTED
    DEK-Info: AES-256-CBC,DC75B18F66176EB223F54FE4DBDB249A

    JYYSfT16jocn2hydMLoAV0YlxkQg6hU5h2aIMiEP8UqVqkGkhc7uFMBvQyhzDWh1
    lZNeRcBkoxEl/OdTZDE/MLhM2TmxCYllrThYqmzmVMXYqWo1hg5r1W/ubYaeVQdZ
    fAZLm73G7ybF1hi/uD71kCOwwnw5LlH/StUzNg9EP/cEZ5ooSlbN2HCpGhcRGS59
    fUaNX8uiYzeZ3Fr6n53apjfEwMaiVr1a48rHPBnxSE/llsMtcCiKeHmoqDCd1n0d
    vB3AEUBD3qR5DBbrBmMLdF2M5KX18MDSLeXXixrorE+uZEygJj2H8coDLhRvQ/rs
    XLWzB9QHHPGNy+oBefnyybKilOtAVu9GHu+qlCiDC4/h4LYG8yI5rpZHExcPb0w6
    //vXmbCtoIa+nBTA8ljjJiMG7lQNiT+ci7TimW6JSRwxmHsb42mliUd+sYqJZMNX
    Kf0oLhvUgn9dOJwYGAH7N0q+qqIvl8SHSjeoF9bZaP1VGfo52tP1iIL93l1yLeh/
    u4RtJUG2hUzhUY4Ce4qTDoZoo1vjGkhE9VJNGWLdG1zaV6/ZOPEtau0xBWC9emn/
    C7HEuH+qlj0hA2vhckMWxqITEzOFajuRjfv0a3HpGb0fAOcrIoO3j6bPes7cv7bu
    RlXM/6pwTNZbA51pmFNGzScb00i8VVRMOqEt5ch6QRhqNCOldA2AUOrYjj68BAXl
    hT8TeGoF/5CgKnXgtvqZxjUQE5zK0yJirlHSEOioiAnFjHd3BKrFG9W/DO/ngRF0
    G8jjXvMW39x10EI0tLI51Vfnxkk4TfVgs7CHMdpBG34uDLLZlQ9lkL/rMWcJ+Kgs
    -----END RSA PRIVATE KEY-----
    """

    /// `openssl rsa -traditional -des3`
    static let pkcs1DES3 = """
    -----BEGIN RSA PRIVATE KEY-----
    Proc-Type: 4,ENCRYPTED
    DEK-Info: DES-EDE3-CBC,225F09F2A86045DC

    8Q7VXPH0xucEcZtUjSWUR3DqFCpl+coyOv/f/qAHgark8sGMQuD6tBGcCqqNgl1t
    e8F7z108BuEKkHmbMqTn6FBfU91k04dDzS7ErDO9YT5lmTXwq/kpbpphvv4BXOXF
    xdyzUtOnxooETu9mH9+Sn+dQaB2AKTA4Fb6OhzZXOwACcmKWeL/hxCmzuVR33oaf
    0Zs+exw76Bj99+QxtCAkeZTS4i70D/kLgPW07mFrCiuX6b3EhK7McN6kAeq6wXWu
    i/gVrAm7nj/jFZEUQwwnT4rrKjJ1J318TsnwgSAGthwOmyZrqtF/1pHb6CW5qXVc
    iYK8JiT41fLag619MK3rY2l5ojmTuOGJTulhLIiZYqU1bSu0mx+3OYeyPYa2xdYN
    KbeZPpxOtjPi5P2GkvAFXtQvBCfgU2NCgcXR0k6APgLziiv/KX4Z02XhjcXm3BIv
    83hSnsCp2lgKCQCIC+wTw7PLp+aRguZGs52BBG/pAJKjo6dGDWwIT8WEw/veAA/a
    KF1rorelGXngqFwFx3OWCwecj214ZokpYwrlFM8EusAFrtRe1heNikFBhym2ep96
    o2HHgMyi7U09hTzG4e6OclEmijHjaDbyLAOfJXRaWfFFW4fuKfaJZCvWb76H5nww
    5NZZ8EXmEo12yp1jfnmmhldBJw4yhwver3O4SbDUnxYTm6I+RD9qSOwKn7KsncdA
    1SZuG2+UJE6ddsS9pnCSIQtH55VudvgkHfdBzHqlJQYFGK9C5ASjrr5unApVULT+
    8g0n+jK5qwbaFB8DnmZuWZxV8DVTPOpqdhBpzJmne0/JRUF7OAqAmw==
    -----END RSA PRIVATE KEY-----
    """

    /// `openssl pkcs8 -topk8 -nocrypt`
    static let pkcs8 = """
    -----BEGIN PRIVATE KEY-----
    MIICdgIBADANBgkqhkiG9w0BAQEFAASCAmAwggJcAgEAAoGBANBQzZ0qI1U1dbll
    qG+qzprvcEkEsH07dtpbY8ExGaDoLLzwdDwRJSGBkTAWkAnfenmaI1AaYmoQcYd/
    RxBsjnXPZebt8M4FBp8bUsFkHc9Vq+vyVpUrNVniMmL3P8CohQtjIqtKs6FNQCI9
    6oPSKmKbsvgLWCj3kGLYvsOMpNqXAgMBAAECgYAGyhtpe+4a4NstZ7rNqOuC8Trf
    pl96NW3yP/hIW6lSLT8ICW5AZu6m4OoyfwnCyJ3dSMDN445BlrecivFt/5vE/BZi
    iupns/d+7kbzkMQwZBHmvC0HHr2EPq0l3HjU6HyNwM6V9+N6GQBpp7Q0A/WCsW2l
    3iRpZptgnHHvIkAxAQJBAP37shiTmZ4/umBJ5lCbM5pApapwvGAkHppDKbjElDi9
    ZzdnZkdQK86nOpTTp5QHHDS/q2838CAdOBFCO9k8LicCQQDR+EXvnhbfrpN/17xt
    qr1CVdg/xsUqZEoeigFwftfndG/AyNbvFJlkaKV9Pbm02KZo075AxDtbMRqAOucU
    VCYRAkABAvCZonTZKX3PhlvRdFzHP3ypahuF8n7gtGXFI5tHgpGXqeTBYfNatlXI
    Y/Nl5oVZPG4tWjatmhAwGWhtnAy/AkAhwxQrxXXUHdQl2GC6GZw5EGinSKTnfhzU
    8Efu+NZqpzRZAXJeGyfXF2SU0NoNlFCdxn5vF56buTeTquUBRc6hAkEAtGNPla/1
    wVYsdiLwb7kE+HY+5zltHdnokPsbKG2eRmb9FWVbsGZLrFfKeajP859WnEra88Rs
    p3oKqWSLaNQ+uA==
    -----END PRIVATE KEY-----
    """

    /// `openssl pkcs8 -topk8 -v2 aes-256-cbc -v2prf hmacWithSHA256`
    static let pkcs8SHA256AES256 = """
    -----BEGIN ENCRYPTED PRIVATE KEY-----
    MIIC3TBXBgkqhkiG9w0BBQ0wSjApBgkqhkiG9w0BBQwwHAQIu/VqV8bZHlICAggA
    MAwGCCqGSIb3DQIJBQAwHQYJYIZIAWUDBAEqBBDXXdV3wyhRzXknidL7LrLpBIIC
    gH3ZgBYFs6o2kPTXlYHv1Z2URCuOVqspt5NLwbpqXFzD2YLhs048tDA+GFHkQa2+
    on1Qppy4UwnVcHRqEEACEGS/VBcZgNBaXuM+5XqqbAKOwBrQ9JtVVl4TG2YrgYs6
    Lk+dQhmi2GDJ4UPwNum0cq+uIKKL6QVSDtVGlXTU2LScvwWGwMI4Cppm9I5zagoX
    PB3pXrr+eI9C5DUgLMT7zBwq5Fr9Whdd8f2/zGkYs7ZispCt5QtKwYbXzsEiX4Io
    HhvWHp3yeiEoVVw1oIj+fnMWa/8RPByhfwwKjAVzmn/kw9bCspDUoEl3zqqMOcUi
    d/ugY1U0t9eVnU1am7gpcb/uAHSd4LoDi+e+fMXQhypx1/0RNDM445r0vf5nVHOD
    25aRxlml9miSd2QtpahNmFFd029v3ETXlqhvikTRcRqka1WfoABDJPjl3nSRPvqF
    aMcpg/ex04cRrv2kmLSnS2CGNsUCmB7LuGWaBU8dhYb9sQEuBOFkGv0DmYA+zn0p
    UKbT5rIo1OZXtYNcxfcjRBKE1Ux+Mk5KBPMtkrVA9Xb4AWykqjL3XJiCP7UbR46C
    accnrojHr6kH46rEOH3R1U/CB7Pu3mEh7JXibc9MmdvvOSpvO6TB3FjqV8ZbneDL
    JNRb8+fcMK/fvnUamifxKVh08xKZREUJeBpY1Wk+NTv/KChZ0COy2Az7DQwVDaZ0
    M3ZmCSgQtlYZSel9lFu8NI8eS+aJ0xIjM4UwUYHQeRXLxE2WkN++3B1LqS4iAoUg
    TTeA29vDW/ps8BrbRWhewDguhUzxRs1tjwwwrB80+FOe+U0MfhAYRdpw4mioodns
    zkhxkTjefAfSfyft+bE/+YQ=
    -----END ENCRYPTED PRIVATE KEY-----
    """

    /// `openssl pkcs8 -topk8 -v2 aes-128-cbc -v2prf hmacWithSHA1`
    static let pkcs8SHA1AES128 = """
    -----BEGIN ENCRYPTED PRIVATE KEY-----
    MIICzzBJBgkqhkiG9w0BBQ0wPDAbBgkqhkiG9w0BBQwwDgQI4Z+sOMAW2ocCAgPo
    MB0GCWCGSAFlAwQBAgQQrSijhrQCrawhKlwSYPPGgwSCAoDwFbggBVEjM//hp7Pj
    qdb/+JgptoleLfJFZmToqtMYoeRzBcNK0nhv034JRcPhJOfaQY8UJ5dFF1UkcNeF
    FTitaHgON1a2WR0BxKUNMm2KAM5Ml4Rs5gChJGTUmPr1k9nGfwPOKSdY3QKaTX35
    S3uuTG7nqjy6MH9adzO1+0pz3ztHu5751eDwueNePibHd7Oh/ELFdZkdZCq4E1da
    bw/3nw424++jOtWdE+g0ULjBaigH57k48uUbpgPrlaNX7z5RfLn2LsX4bzle3ueU
    svH3aF2lT+jN5psWr5/NHe673w9M8imB+laWYZHVwYsYbAd9koHOAj3KqO6b1Qmn
    D4VzjVOpe7HDRzMMXrnznZfYPZI/d0sePMqGdTCUpHnglbP782AD6UnETED1Vbz/
    zDBxqriKSMNDmca6ODyGcoOcaUW/foT9N82JvXkQcB177LrQK3611QrGwieKP76o
    uYePqrSrKgpIJ3GGZLzg6R2DsJHd6+RaG7haN9+lABtEfCOJCGHlJMWyfe7fx8hO
    mpoo4Ubv77lD7S4W0E9hn7AnHWAHwG1kbdw1IsstUO/fZUqkrvDt4yEPCb/QwRIN
    aJvU5banI39VfWr5KpCR60WAlC/94QZVtbFWogYZntL3YkdbM3snv0/3MTaoHea1
    B7xem5Txm4Uk5N3tkODPh+cBOolSV5wtpnOlKB03Utf719k2QOOuL9VjgscV5+wB
    UhBJ97Plov8I7yTIP78cn9G2lfzUMG24rc8r5LBMA3bzOSza3ZhF3eCMLEq23mvr
    owmkuwqP5YBy0tILtkazRuQZek9dOinWzz4vjE6Op1y0m46iE9H9pjRlm+/lS+by
    vUPq
    -----END ENCRYPTED PRIVATE KEY-----
    """

    /// `openssl pkcs8 -topk8 -v2 des3`
    static let pkcs8DES3 = """
    -----BEGIN ENCRYPTED PRIVATE KEY-----
    MIIC1DBOBgkqhkiG9w0BBQ0wQTApBgkqhkiG9w0BBQwwHAQIgI9GiNrbGUcCAgPo
    MAwGCCqGSIb3DQIJBQAwFAYIKoZIhvcNAwcECDvCZisiQZoGBIICgFUAa1fmzDbU
    acE1P5sUSNqKnqfRr2alzyABkGlYk8p1bgxGKFkcVXkSR+AE4dTp1M9AaBBdEvpl
    goimFCglYWl4RK2s71TxIiKnC6xfOKaKFwMW7R6vjmLNxJ1fzgfD9BFuAhPthYvU
    KSJkAlVpAVQySLPoxbCEB2Mt8glTqxYdrtWjvnBcewkAKzWxfwVDLC7Nd84kbJFM
    5Wjuns3EaVXWIfYHrdavA7V5OVW15Ka3e2V3bzlMkUB8zT7nPih8cUwC02WgdaL6
    5xzSyngmJGxfxN8OGOky5pDNfiHNEStcnVbUkTnIcIMxuok0Ss3BLedfGUb4a2TW
    m2YMjQBWWkIOb0c0svzl+NtE93FIZPrlrKqmJj16JBTwkv050EFervMd83AKS0wJ
    Gi5hNOnhr+PKgDRJNGK5c09M+YqjlnU6sMDNuo+pl7U3wGAmGb1YKK658DOPdgW+
    Tsc/8d9KQjWY1OAQh5xGdsr9UrZUJn3z/M+01wFAsSpvL+T14GYgvnYCz3Rouhe5
    +2xvwdSCoudzT57/LtZq8AIVJ0jsGubYmrGopQvU55JyE4LGBuf0G8CsAPSe869u
    Nu64Js0oPELdDk52vFqWDqT+e+ekJ/nf2FZoxf/39fj1lJeDYHv0yi2zonr94njg
    A0x6ER89BtSDc3f6+xf9e2p/iaNG3LAFZz7XxP1ll/LSN4pUHKeiSMrEF6p6WCA6
    /obSq0T3oxFQXaor0kQGepuuZw9f71nSiJ2UOdqQ7XhmpB4hN5wZ3wZB/ooOa1ij
    MaoUi93M85Txgs/xAcLMS9w7NNj2Hrb/xoY8WE67uEcxmV1Jf7Q7pd+zgL+2EoMR
    WVmPIu5FuAY=
    -----END ENCRYPTED PRIVATE KEY-----
    """

    /// The same key after `ssh-keygen -p -N ""` (OpenSSH format, empty comment).
    static let openSSH = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAlwAAAAdzc2gtcn
    NhAAAAAwEAAQAAAIEA0FDNnSojVTV1uWWob6rOmu9wSQSwfTt22ltjwTEZoOgsvPB0PBEl
    IYGRMBaQCd96eZojUBpiahBxh39HEGyOdc9l5u3wzgUGnxtSwWQdz1Wr6/JWlSs1WeIyYv
    c/wKiFC2Miq0qzoU1AIj3qg9IqYpuy+AtYKPeQYti+w4yk2pcAAAH42nNjBtpzYwYAAAAH
    c3NoLXJzYQAAAIEA0FDNnSojVTV1uWWob6rOmu9wSQSwfTt22ltjwTEZoOgsvPB0PBElIY
    GRMBaQCd96eZojUBpiahBxh39HEGyOdc9l5u3wzgUGnxtSwWQdz1Wr6/JWlSs1WeIyYvc/
    wKiFC2Miq0qzoU1AIj3qg9IqYpuy+AtYKPeQYti+w4yk2pcAAAADAQABAAAAgAbKG2l77h
    rg2y1nus2o64LxOt+mX3o1bfI/+EhbqVItPwgJbkBm7qbg6jJ/CcLInd1IwM3jjkGWt5yK
    8W3/m8T8FmKK6mez937uRvOQxDBkEea8LQcevYQ+rSXceNTofI3AzpX343oZAGmntDQD9Y
    KxbaXeJGlmm2Ccce8iQDEBAAAAQQC0Y0+Vr/XBVix2IvBvuQT4dj7nOW0d2eiQ+xsobZ5G
    Zv0VZVuwZkusV8p5qM/zn1acStrzxGynegqpZIto1D64AAAAQQD9+7IYk5meP7pgSeZQmz
    OaQKWqcLxgJB6aQym4xJQ4vWc3Z2ZHUCvOpzqU06eUBxw0v6tvN/AgHTgRQjvZPC4nAAAA
    QQDR+EXvnhbfrpN/17xtqr1CVdg/xsUqZEoeigFwftfndG/AyNbvFJlkaKV9Pbm02KZo07
    5AxDtbMRqAOucUVCYRAAAAAAEC
    -----END OPENSSH PRIVATE KEY-----
    """

    /// `ssh-keygen -y`
    static let publicLine =
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAAgQDQUM2dKiNVNXW5Zahvqs6a73BJBLB9O3baW2PBMRmg6Cy88HQ8ESUhgZEwFpAJ33p5miNQGmJqEHGHf0cQbI51z2Xm7fDOBQafG1LBZB3PVavr8laVKzVZ4jJi9z/AqIULYyKrSrOhTUAiPeqD0ipim7L4C1go95Bi2L7DjKTalw=="
}
