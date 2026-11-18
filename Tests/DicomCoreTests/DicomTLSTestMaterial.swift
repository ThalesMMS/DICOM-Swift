//
//  DicomTLSTestMaterial.swift
//  DicomCoreTests
//
//  Represents DICOM TLS Test Material metadata and state.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import Foundation

struct DicomTLSTestMaterial {
    let directory: URL
    let caCertificatePath: String
    let serverCertificatePath: String
    let serverPrivateKeyPath: String
    let wrongCACertificatePath: String

    static func write() throws -> DicomTLSTestMaterial {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DicomTLSTestMaterial-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let caCertificate = directory.appendingPathComponent("ca_cert.pem")
        let serverCertificate = directory.appendingPathComponent("server_cert.pem")
        let serverPrivateKey = directory.appendingPathComponent("server_key.pem")
        let wrongCACertificate = directory.appendingPathComponent("wrong_ca_cert.pem")

        try caCertificatePEM.write(to: caCertificate, atomically: true, encoding: .utf8)
        try serverCertificatePEM.write(to: serverCertificate, atomically: true, encoding: .utf8)
        try serverPrivateKeyPEM.write(to: serverPrivateKey, atomically: true, encoding: .utf8)
        try wrongCACertificatePEM.write(to: wrongCACertificate, atomically: true, encoding: .utf8)

        return DicomTLSTestMaterial(
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
MIIDITCCAgmgAwIBAgIUWyhQxY3aT4lC0QtGXLpp+4BXuP4wDQYJKoZIhvcNAQEL
BQAwIDEeMBwGA1UEAwwVRElDT00gRGVjb2RlciBUZXN0IENBMB4XDTI2MDYwMzA2
NDgxNFoXDTI3MDcwNTA2NDgxNFowIDEeMBwGA1UEAwwVRElDT00gRGVjb2RlciBU
ZXN0IENBMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAv3KrDpu4NY2E
j4NJNNu+3VksCyNIsTMcNe4s0hbxTTejra/J9FNwswiLBSO2UWTKxG4Na1PEqydT
H97+V54ZsMiqaNDsVJlgX9xQYVxxhbcPa0MYQuQhZYintljWg7hWzFrrcBPy2DB5
yvwLcm8oKBsjwaZbIAbn1e1k78/zBUX+jhm5Cq68zqJjhwGC4ppSsGq5VazOEyld
YHTD3+t0RuLPVN+VJZ9CPI5IL580ruK7Nh+JQKfm5Llf3ReodGhRi1pkEJDtuYIA
P1Pd888AdcKh8nidR+oF+zM+sZ64PNW40VFHHT0HcYmYFx3bt3ppawzsvUQg5xmi
qslxP2QufwIDAQABo1MwUTAdBgNVHQ4EFgQUphOPIe954wE3jRcY/Fp9DizuEGww
HwYDVR0jBBgwFoAUphOPIe954wE3jRcY/Fp9DizuEGwwDwYDVR0TAQH/BAUwAwEB
/zANBgkqhkiG9w0BAQsFAAOCAQEAXsxcN9S1964W5o3xZJCvlcssh3aW2+UR6hau
CP3jRr3HQcs2/iYfoIbO9FudAynGoF00Gzco6tuhcOAB+J1tv1iDE2+BXIUC11By
8I1PZ1IKP1B0tJrxk71EgT7SB5nJIEc5bX9FS9hvXRJmFV0mDDporx4HsoJcI/5F
/+vM9ERJx/HecY0JSFSVFqdigI48HTmIU5p3fAOQaiX2DfpRK4AziAEkd/ri6yY+
eOZ/5/80NBFMqKp8Vu3Hhl6BAt7R4xb0M3gA3HZVXEke9pIifForwfDWkQIo8WXT
JkR5TCyBkQLQppnKGFPKi35HjEIVFo+ly407dMH5LpgkoN/V4w==
-----END CERTIFICATE-----
"""

private let serverCertificatePEM = """
-----BEGIN CERTIFICATE-----
MIIDQzCCAiugAwIBAgIUaNsF1EIWll8KFzcjM8lpEJBu9gcwDQYJKoZIhvcNAQEL
BQAwIDEeMBwGA1UEAwwVRElDT00gRGVjb2RlciBUZXN0IENBMB4XDTI2MDYwMzA2
NDgxNFoXDTI3MDcwNTA2NDgxNFowFDESMBAGA1UEAwwJbG9jYWxob3N0MIIBIjAN
BgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEApe+dHvU0Tsm33/xCXJ8gygfLmLmh
L7FggTmmkM0wzOX8GyXm42xFPACNjl7TG/QdHmIbmky/IJ+LWXFYqx2Avmu+UZ5q
ezoyYvS/2Sc65ILyJDaJyG2adSXHekDNJdWfAezwEaoVV9ho+C9le7MxrcN0WjRN
mbNFwEJwSXdl2io9fFCog9isNtlPJbNw407IAZj3dd8ay+QK11ieFXqMaOB0/hyE
BAWPJ0AWC5kljt8/QsI7HB1MxLbLZBOUdz+Dm7V9S6pDD1bi9WKp3EC8F+O+9xhp
HPv9c50vlbSLGWO8kPFM/IPTD3eyCo1ua4jf9AtfZAXmKMRnjgf470o5zQIDAQAB
o4GAMH4wGgYDVR0RBBMwEYIJbG9jYWxob3N0hwR/AAABMBMGA1UdJQQMMAoGCCsG
AQUFBwMBMAsGA1UdDwQEAwIFoDAdBgNVHQ4EFgQUI/eQTlIV/kC9g25BET9tnfz/
TL0wHwYDVR0jBBgwFoAUphOPIe954wE3jRcY/Fp9DizuEGwwDQYJKoZIhvcNAQEL
BQADggEBAFqkbIHYszuasZHq/2Cc8J3lD/afRCMfL/LluwDgqm0kSSLOy5ElAaF8
ZAonsdTIQnX+TH/oyE/bFQIwMmZcKv+I2lHwpBOIRh4wniVxvcdvBEvUJAF6baQw
WTkitdJsURanqThynLEGTs/Cni4n5wvdisGPxnLgI3950toB27N5Ka61b2kRmVUj
8mF4ydCWC+S7pw9qeIdc4ggGiUnT4zZTXa2nVTJ2gjft0jzauqRluE9IOKIJMOxI
UgpOxsCTv9pPDy6mGtJc5XANjVZa35tP2ZVEmhW0g4KAk7L8XIo13LsLzMnd2waX
SiAsgSLwWIF48LuHG/sHs3vG8ccUlzc=
-----END CERTIFICATE-----
"""

private let serverPrivateKeyPEM = """
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCl750e9TROybff
/EJcnyDKB8uYuaEvsWCBOaaQzTDM5fwbJebjbEU8AI2OXtMb9B0eYhuaTL8gn4tZ
cVirHYC+a75Rnmp7OjJi9L/ZJzrkgvIkNonIbZp1Jcd6QM0l1Z8B7PARqhVX2Gj4
L2V7szGtw3RaNE2Zs0XAQnBJd2XaKj18UKiD2Kw22U8ls3DjTsgBmPd13xrL5ArX
WJ4Veoxo4HT+HIQEBY8nQBYLmSWO3z9CwjscHUzEtstkE5R3P4ObtX1LqkMPVuL1
YqncQLwX4773GGkc+/1znS+VtIsZY7yQ8Uz8g9MPd7IKjW5riN/0C19kBeYoxGeO
B/jvSjnNAgMBAAECggEADQWTx/UoKLKtylcKgig+s3wPHyoaGxsJXrq+doiTttCp
ixvbVaeOe1nzweNxH7V1f4flcKNrME0060z4z1zeWJMt+Uu8QXVctOVOFOV+OqaI
CA17nI31XBId6Fsjfj+YXddRM6GsURt7iVZ22VFDqcY34EhQeqpV4/OSykEjbg5Y
C02FOmrNd05x6FwRh0v5Ohcwr0fZ7lHUzDRq48dUhwiRmzNfoW5Qhe2Cytmzlc8c
nFu0W/l7vWoxVqhtg7/wNDtsFWWaKnl9k62YqqMkbpvyFDegtEZKVmDlDI7NSwZU
LAq5boKP/iMEojzK4vlmvTlaf0/csHdQhO352PUcoQKBgQDi6RYyPhoHQvu8/UyD
5rjv12cmHneF7bMqaSieAXzBlaXmnK9Jkv2FRmYYTXw3VBqDjJ84YbGZrfIs2wta
c6uqFlbZ3tXlOGMETAAkGjP9MED61h2ELmyFvZZ9FOyg0avq6riu705B0SpwzUiD
mdLzvtE2nCr5E4prhJoe8RTrdQKBgQC7NWvpznqbF2kIoqdxBndBcE8MNBYjBVO2
3YbOPf3gaPOLDpmJpT/j1kwXtTptIksojI7KZbWIPI06/WvFVErUfC39un8SUzYr
W9MZe5Nv7AwPCMDonsTlokDdVoc2mJLgBCeFQFR0FuDacDgRm0prgTsrL8U5OXap
pQ4kgvbB+QKBgQDSeKua/Nl9xNbmLPltG3SNG3rU88uf0aSvgQ0oym5izaEtsEYy
84HuvibzAeRnGb7iKGyDirKGvr70dlUomEQxpzj2K+ixDkVh9fDni9qPTdPoFvUX
50vIHdvZt6/pV7KkWwXlVZl8GTzJltBdKTBv4J4EjoSZtlNdeYjPjIUABQKBgH8p
VlfGbPmT+UBoW5wmbDMC+m6roq2/HJIF/19wNFaOc39tN1WL7c3w7lbcPweKV8r/
Tq6kT55uovAC24V6MCoM/6BtYYstAoqJIOcaTZekmrxLkd1wmwXwJGc0MzwefwWz
TLTycWs5bxpxR2SOOwqzCWHYXPr10WiCOQ0L+FjhAoGAdQ1MzVWdVXhksTin5Qyn
lC3D+YaV2R5kRx0oEU+MzuCYCuY1p+6so8h0eVbT06CmC2AOffZCxs8ym+gxafws
aZKlBG4niUJhPBbADeks7lQNgkUeRUvXAxjEw3HGBBrvNocfrRkUikRq13bEvhQF
5HA5/tLnX66MaKx5HPGaoTI=
-----END PRIVATE KEY-----
"""

private let wrongCACertificatePEM = """
-----BEGIN CERTIFICATE-----
MIIDIzCCAgugAwIBAgIUUia5ESLb/umrMKyAka2+WUbtL28wDQYJKoZIhvcNAQEL
BQAwITEfMB0GA1UEAwwWRElDT00gRGVjb2RlciBXcm9uZyBDQTAeFw0yNjA2MDMw
NjQ4MTRaFw0yNzA3MDUwNjQ4MTRaMCExHzAdBgNVBAMMFkRJQ09NIERlY29kZXIg
V3JvbmcgQ0EwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQC/FlaTsQK/
o+/dq14x8hba4+Zab5eryhL7IcC3ZhnNAFLRfzRtPCuAgJjmLHzy/L+qV56vgXpS
KSNq0peAxOB9ZTYYCOx+LEJr5JZawo4WnxL6q9+DnDqe+9Ggt8xUyUq48fZjFxrI
tJP3bRhv37uN43CagxXLOyKCLl+nXYoOmU8eQyjiU9VjIVdO3rIfN+qzPcdPRewI
BP4g1JjRpTzFzgK/E2bceL1CiBIwMD2VFh845SyY9HO4kSwj4X7fcKQ4TMsW/0Hd
yHF0k3DZP0K4R8a+J30SfBv1vbsXxt4xmbId2PX8Vrl/KzgB14E8XPrkgp9sQrgR
y5QLTHY8snyZAgMBAAGjUzBRMB0GA1UdDgQWBBTCwVjWA001NMmAsk3dvpkpbZhE
lzAfBgNVHSMEGDAWgBTCwVjWA001NMmAsk3dvpkpbZhElzAPBgNVHRMBAf8EBTAD
AQH/MA0GCSqGSIb3DQEBCwUAA4IBAQCJPSXTb41lMEkdPBPE6J2BxlVzpdPp0kfn
RrEd4om4ssA0CL7N+BYGY/A7h3+6tr6+fDQSdyhOvOkg3x++wQqUW6Krts9UXbmS
01YeTeml17hKM6gA61/03oFXlzBZC09ngtGn7Z3ya3McUJ84Aa+viAAI5r7cae/b
VSMp7+E/Q92hGBK51O8YsBuILRuKszmmj8JxMB/ZIrWSK1xge4+dHDJXp5gYZeRo
oB0L+7jbcTKKrtZq8vuiz35zrj5qEoWX90w6+UgwNtlJPTu2KwcDsHhYnyVLk/Is
uIPPc4mZ7B9DGLgk6MlsjZDzoC3jcJVunbWZBTuWpF827TCed7JM
-----END CERTIFICATE-----
"""
