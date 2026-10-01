// Synthetic TLS fixtures: roots expire in 2046; the 825-day leaf expires in December 2028.
import Foundation

struct MLLPTLSTestMaterial {
    let directory: URL
    let caCertificatePath: String
    let serverCertificatePath: String
    let serverPrivateKeyPath: String
    let wrongCACertificatePath: String

    static func write() throws -> MLLPTLSTestMaterial {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MLLPTLSTestMaterial-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let caCertificate = directory.appendingPathComponent("ca_cert.pem")
        let serverCertificate = directory.appendingPathComponent("server_cert.pem")
        let serverPrivateKey = directory.appendingPathComponent("server_key.pem")
        let wrongCACertificate = directory.appendingPathComponent("wrong_ca_cert.pem")

        try caCertificatePEM.write(to: caCertificate, atomically: true, encoding: .utf8)
        try serverCertificatePEM.write(to: serverCertificate, atomically: true, encoding: .utf8)
        try serverPrivateKeyPEM.write(to: serverPrivateKey, atomically: true, encoding: .utf8)
        try wrongCACertificatePEM.write(to: wrongCACertificate, atomically: true, encoding: .utf8)

        return MLLPTLSTestMaterial(
            directory: directory,
            caCertificatePath: caCertificate.path,
            serverCertificatePath: serverCertificate.path,
            serverPrivateKeyPath: serverPrivateKey.path,
            wrongCACertificatePath: wrongCACertificate.path
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private let caCertificatePEM = """
-----BEGIN CERTIFICATE-----
MIIDMjCCAhqgAwIBAgIJAKbGYktJ/RCqMA0GCSqGSIb3DQEBCwUAMCYxJDAiBgNV
BAMMG0lzaXMgc3ludGhldGljIE1MTFAgdGVzdCBDQTAeFw0yNjA5MTUwMzE3MTJa
Fw00NjA5MTAwMzE3MTJaMCYxJDAiBgNVBAMMG0lzaXMgc3ludGhldGljIE1MTFAg
dGVzdCBDQTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBALXiKQwSeEl6
vHfOsWc4KUD6y+robgrfO9CCr1RHQI2MvoC8gkaR/iDI4i7GirPkpMcw5cLUFFgA
h99yysiF9UArB9Xs4Fgce1ZdNl10f2shN8MzBMbO1YPm0gneIDZu5gJamQjzq1ie
U5dA1viFSjX02POmzyRakZ5lomgQGGoWuY0GLDvQFV18xlNbsampctNseEPWj+Ls
3X0GZ7yte2rIdaoCxqNoqtdZ1E5vA060CEJC/nabEFmxPRrHITCFcf21UZGlRmmU
mitaaHzqX7PJw4tZwlggAic+d7emlmAV6t1CYjYoTllpS/ZDkyHI82rn+StKZ3Dx
hRWdnS958tUCAwEAAaNjMGEwDwYDVR0TAQH/BAUwAwEB/zAOBgNVHQ8BAf8EBAMC
AQYwHQYDVR0OBBYEFGjS2QtFYIH+viLcDTre8Gik4CnnMB8GA1UdIwQYMBaAFGjS
2QtFYIH+viLcDTre8Gik4CnnMA0GCSqGSIb3DQEBCwUAA4IBAQBrYjqI3vBUqG+q
yd2Hmf+mhHaQHWsOb5g7axMEgC5QeKi24E0FvwvqaK/pISXZuNfpgMtosj19bPBP
bAAfDDui0ktnupxip+9zZCXgjjtLJhksSWuRlSGwllw1mPgedyTWMQLFigNERaKD
j9KqFx09mM1qCVQw8apQFbrl84EHld+KN+CuV5ZDn+vzNlx6Ku4Qd/UGsPmYrPiH
imUE3C/NsxWD1hUNceegbKrduPbXHiB7kYZ2VXUWKfTTQrXPxOtHmZOCRN2dY5MW
+u3lykDNA8BWBSkLhDlM6tQa95MQkAMtkZztWOnkK3/Am5drye4aKKXKP70DiHHJ
Ab4Axm79
-----END CERTIFICATE-----
"""

private let serverCertificatePEM = """
-----BEGIN CERTIFICATE-----
MIIDUDCCAjigAwIBAgIJAPWZo9fmWbbIMA0GCSqGSIb3DQEBCwUAMCYxJDAiBgNV
BAMMG0lzaXMgc3ludGhldGljIE1MTFAgdGVzdCBDQTAeFw0yNjA5MTUwMzE3MTJa
Fw0yODEyMTgwMzE3MTJaMBQxEjAQBgNVBAMMCWxvY2FsaG9zdDCCASIwDQYJKoZI
hvcNAQEBBQADggEPADCCAQoCggEBAM0Bc8qal7VqPSMqys0lwvuXFTANQaojZ6O1
Af4kb50tlynWSWsFhb4fs4zwt7NM9r86tOyYxXr/qaDhKRtPct9e3DqOT14RhrUM
VEd3iundnaz8DkUalea0YBjt/2tV2wucXv+NlxjDp7glOz15+e2n2J8qF4CuKCpk
gdP7wGct/kbyZMRO8ho+Id31gEJcW7gCxbzUSzDmR5vHeW7QRVlFpTlNXLGamWk7
Fx1jfg891nRzOGTvSmAIuz7qJ9jupASdg3RjbLbwMK6LwzpWBnxRSjxB2XEuJNDY
uIR47UHSOyuCWu3XvGew3l5SrmbxiIFz6NeajuYXc6BeuFg2TRECAwEAAaOBkjCB
jzAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIFoDATBgNVHSUEDDAKBggrBgEF
BQcDATAaBgNVHREEEzARgglsb2NhbGhvc3SHBH8AAAEwHQYDVR0OBBYEFCzfYpAL
4Z6tyB1N9p+tBhoaq26YMB8GA1UdIwQYMBaAFGjS2QtFYIH+viLcDTre8Gik4Cnn
MA0GCSqGSIb3DQEBCwUAA4IBAQBplceFxj6IWsKTdAe8D7gPmZFOO/r3O7U9pGOO
sxo56bsx8q+jK8dHapUlkjmOXFEBoff3GThzjs8WmOetofiuagdL1toCS+BYawjO
zXl3+dX4ch76LRO7Pm2mipLLc7tKBdnLPgfInEc8YUmb6VBPBP5FluSl4OXp1GvN
c2FzFJ9VqcTlbjYtNB5bqYxZF3LvAcMsNXI2OH2xb/Z2kw2djE91FPN9qFZrMfEH
qujqIXnbhpKG7kQTq8BRiy9XyywSbdsDcR2J4dxXw4YmlhGDP5JwrjhCoNjTmMvj
UkQkS9wgiyHcIDUmVBU49uB9Xqv9Hb4hbgB+0GDflu51ogEP
-----END CERTIFICATE-----
"""

private let serverPrivateKeyPEM = """
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDNAXPKmpe1aj0j
KsrNJcL7lxUwDUGqI2ejtQH+JG+dLZcp1klrBYW+H7OM8LezTPa/OrTsmMV6/6mg
4SkbT3LfXtw6jk9eEYa1DFRHd4rp3Z2s/A5FGpXmtGAY7f9rVdsLnF7/jZcYw6e4
JTs9efntp9ifKheArigqZIHT+8BnLf5G8mTETvIaPiHd9YBCXFu4AsW81Esw5keb
x3lu0EVZRaU5TVyxmplpOxcdY34PPdZ0czhk70pgCLs+6ifY7qQEnYN0Y2y28DCu
i8M6VgZ8UUo8QdlxLiTQ2LiEeO1B0jsrglrt17xnsN5eUq5m8YiBc+jXmo7mF3Og
XrhYNk0RAgMBAAECggEADph93/zltDreI3TWf4iiuzrkfUlUVYKzzEoE3E1HzQ8D
5iyliYMZJJIpPG2fBpsCLldFrlqqJLmzIAsn3BPp/9FHKLwdFnt09crs7TGrqD7p
DPndIjpkVcqd1OiM+N1h/Q+jC9rO2SqE9G1iLFxU2QDMQXjDt5uurGX/gFI6Pp48
54n+oUuWiB+u4i84hRuK7lWVRmhk39WY+eH9VYb0ikcGcJx2W/9LyYTuJ8H2CvLA
vkocmhtRa7FGevIjPw557I0K8NIr/VPKyb+l+LUpVmrBWdlP28RlPxA/envC5Fan
zKxpYClOlIBK8/i/EqFpwPanl950vEJberr0ESm1yQKBgQD8lYtDhDCBdTTrhDOC
dajoADji4wFZq8JONFTSUid8uJMSe2ea2MMOs336ZmjNCWRBBkjmozvIdj88IFNJ
79IRu/KxNzJG4YT3KhyYboc110r4ydrKVNAlNuBamZtRMd3TgPD32/McE4+2xjE/
THz8uwA/2XzxAWTsvgPqzlhXcwKBgQDPxzCVtoFtChXivl/aqwKsyMTAESVj2J5/
hcpCoDWsXAfLRc2sUJOFZez457FnH+wJB00qIdQ7oW/Wc9DLMOPln00Hr1weEgBz
et0hx1tEUrjcjSPrm9wFxqh0JwoVozy1nILKS1qnsOnFXxZnWMFV/KLQP0rm7yvn
DsWGwZ9AawKBgQDDNmTispi2hTp4R71zt7HqVLmiiSWzAy9yN7nSr1H7b7+jSiMB
p0Ph6dGUpG+dAAQuyUewkToULWej9avJegNWV3czheBircuRJ0fge5QehZ1Y+NET
DUeta2MsQomq0CqMW5xhQ+n5qhipfzXyoQ/8WB7SOin5LkWtPxJR+FaIhwKBgFi+
42mOwkkofaCTX62uTT4vopnGuQmkhE5DfthmRYaQ6GNSNT7cS6Y2mrjVfVhmshJJ
JBRSzquJkJMwdIXVJAH3wJb/t4DAf6DTYZAD7l+IVZ0eS7FeqONurpSt+Ai16EBJ
0TNGbDojvjWnH5KUvj9T4NbBseRhU4clMAkWukZxAoGAFgpiNgezxF8xOv11kygw
WVJQvuUWMtJZRtMnGn1q8wgG7dg8RygND3SsVWSVAP+BiCQ03NNT1NllESn4YHl4
nhaD7nzzt4vEDFZh9h5xE9qLJ7wQCxLJ+lizaUMxmK3/xM94Rx9uLdt2hZ1bCtF9
1+XlzBcrfhRsLS2bQd6Onps=
-----END PRIVATE KEY-----
"""

private let wrongCACertificatePEM = """
-----BEGIN CERTIFICATE-----
MIIDMjCCAhqgAwIBAgIJAK4UZ0+9umyqMA0GCSqGSIb3DQEBCwUAMCYxJDAiBgNV
BAMMG0lzaXMgc3ludGhldGljIHVucmVsYXRlZCBDQTAeFw0yNjA5MTUwMzE3MTJa
Fw00NjA5MTAwMzE3MTJaMCYxJDAiBgNVBAMMG0lzaXMgc3ludGhldGljIHVucmVs
YXRlZCBDQTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBANPHGuevQp1C
Pz/UGfFTZPjBZq4YNYVrzyGqjX9xXd+XE6ic24j1OLK6u9x9FoTRHjGfYM3HReti
P0lKUpK/4CcDwfYur1NAMABZyl55S2Wn8zVsmYKgjAxacFs+1SlT3+4C0Eeyu9w1
4lqSmHjfsXnkEL0mNQLiag6n+L/QUJYDFDQUAVaTaJdTMgLOmMcjYGOx4VGPk99G
Ct70G/q2aZKC6v6Ker+bZ169xuj4jcUKYCY1KNgYHM8AlMLgL7GNNm6jQ4rLbCOD
Nx88S5riBNqTy6ojAovAkEQorjR/RpG0IWqvxDRGh+h+/BlsMhr4iGUe8CFvtCg5
TIuc+JdYAscCAwEAAaNjMGEwDwYDVR0TAQH/BAUwAwEB/zAOBgNVHQ8BAf8EBAMC
AQYwHQYDVR0OBBYEFMMO6M4Bcr2n5NV1dUvE3fs1JkdkMB8GA1UdIwQYMBaAFMMO
6M4Bcr2n5NV1dUvE3fs1JkdkMA0GCSqGSIb3DQEBCwUAA4IBAQCHfOYacDkQdVDg
As+uLsz8G4wPa7f7hNXRPiLNnovGTTBI8PyBw18RG3yKbBMAztKkpjLUISaBF0HD
LfGxiKalqWfw1Foe5TGSjgVq1ogfzLzGcV4aTr9AfBtiycOdpPqyOB90ExoY4Ltz
gNpplCpVZDJovJFXcbZEvWh3TLfUj+ExWUFcY3oKWFU5Uw9CyIXBrmp7Ph6H3pBa
/RjvdMv3BHL48DkXQum2y570O3SI6xUL1/JEiK2hmmJfoUVgcfxyqFY6+MQJoLkd
UnDSFshqwf1a/v0N5UWsxgWASl9fh+uEtW1V9WjJLytA0/FbV4c+KB7+6Rf1ES9x
H2mwLHn/
-----END CERTIFICATE-----
"""
