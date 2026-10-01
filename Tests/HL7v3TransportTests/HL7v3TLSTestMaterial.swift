// Synthetic localhost-only TLS fixtures: roots expire in 2036; the server expires in December 2028
// within the Apple trust policy limit of 825 days for privately issued server certificates.
import Foundation

struct HL7v3TLSTestMaterial {
    let directory: URL
    let caCertificatePath: String
    let serverCertificatePath: String
    let serverPrivateKeyPath: String
    let wrongCACertificatePath: String

    static func write() throws -> HL7v3TLSTestMaterial {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HL7v3TLSTestMaterial-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let caCertificate = directory.appendingPathComponent("ca_cert.pem")
        let serverCertificate = directory.appendingPathComponent("server_cert.pem")
        let serverPrivateKey = directory.appendingPathComponent("server_key.pem")
        let wrongCACertificate = directory.appendingPathComponent("wrong_ca_cert.pem")

        try caCertificatePEM.write(to: caCertificate, atomically: true, encoding: .utf8)
        try serverCertificatePEM.write(to: serverCertificate, atomically: true, encoding: .utf8)
        try serverPrivateKeyPEM.write(to: serverPrivateKey, atomically: true, encoding: .utf8)
        try wrongCACertificatePEM.write(to: wrongCACertificate, atomically: true, encoding: .utf8)

        return HL7v3TLSTestMaterial(
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
MIIDKzCCAhOgAwIBAgIUI1wbRMukY6LWbDYewsyXch1AUbEwDQYJKoZIhvcNAQEL
BQAwHTEbMBkGA1UEAwwSSEw3djMgU3ludGhldGljIENBMB4XDTI2MDkxNTAyNTA1
MloXDTM2MDkxMjAyNTA1MlowHTEbMBkGA1UEAwwSSEw3djMgU3ludGhldGljIENB
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAnDSVDZ2xRNAFw/NlO9pt
KYHEKS6tI5dulZS6ByPfIg8vsvoGQlybn08MuCxlCoYbDxjXX5h2siwIoRQdJs7z
XSDIIxcNA3rZ6dIfLqXFbEpzLY0r1PscCB992Z6CyK6r+nBF6/il8pAhbDbRNMIG
rXRpndHrWxOam2/xxcEeQ/rDVkfTq2WIU/0vDZJCZ+IrdLt+Y5xZ3sWUVMDTs6Je
auTbn4ld5hgWYz3sQpZjJoEd/W9LIqJfLZDeeLKcsttp9D6rgwURFEQIAyIaXLW7
5KVqIoPoKSu4rB8kv0fA2yIFXDakGGUhW51++1e96cl6GtYaZHRXw7gqktx/bN7n
7QIDAQABo2MwYTAdBgNVHQ4EFgQUlg4DXiS2KerLdLjkcubMIV39edswHwYDVR0j
BBgwFoAUlg4DXiS2KerLdLjkcubMIV39edswDwYDVR0TAQH/BAUwAwEB/zAOBgNV
HQ8BAf8EBAMCAQYwDQYJKoZIhvcNAQELBQADggEBABktssdTPydNtKcdR46od2QV
fmzHNqXRAKyT/otyvhLa+U1nfjeJIx/XfaUUkG0xRZZSmOwDW3ERuEIqkLxKzAby
OHaMXcmgYvGqyavQw6Nha+AYg3NxC6dg27o9NmZcnAEiGmrDipnzG03qAOx6VwSG
5JZHK/doII2fQNtLYNs9RUCjKG1avXDqKQp2/jT1Mwq2HpA3Y8Q+rPpAwkPzJZyF
mYYrYn3uKyfql7vqqdgzG4A8mmV1YSa7GT09gll6H4wsplqJzFU0BfL7DxBNdXnV
wSkNlPA2wNWd+IdPpTpeHJImgLo34laY3b4s/6vP4w7EtDQeztSY9Ih0raZt1Ek=
-----END CERTIFICATE-----
"""

private let serverCertificatePEM = """
-----BEGIN CERTIFICATE-----
MIIDUjCCAjqgAwIBAgIUWhVzCyket4QAQtb+JOfAVbcHpWcwDQYJKoZIhvcNAQEL
BQAwHTEbMBkGA1UEAwwSSEw3djMgU3ludGhldGljIENBMB4XDTI2MDkxNTAyNTA1
MloXDTI4MTIxODAyNTA1MlowFDESMBAGA1UEAwwJbG9jYWxob3N0MIIBIjANBgkq
hkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA4iXUs9XSU2YKRlhlxxBwVKLPn/IiceBs
RgXbGGYEk/UvurHO4CzaC0mOS2YxuCehliH9SHmnXjB9s3cBrBZM7HciiuNkcvCs
oeNEAzCMOTuBMlRdFnIgsXb3vJCBg7ewYDsYISIqbORihCZQhWX3Ae5aI7t12BEK
mrSFSknDyOmKlckbWgJHX/71ulU8bRgvH3FeJi8BIlzmUajk818EDLn47C4PygQb
1ImI5pV7cXFDgmUsOEQzs4DEY3LLwPCqp7jgmB4/RSIw/EheNq3lyA6MhCCZuJct
sMUgeSif/NIGGHTYmJ7MVvHmXJP+hp5BUFZqBVg180HYiZ/q1rBidQIDAQABo4GS
MIGPMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgWgMBMGA1UdJQQMMAoGCCsG
AQUFBwMBMBoGA1UdEQQTMBGCCWxvY2FsaG9zdIcEfwAAATAdBgNVHQ4EFgQUk/Lq
loXdCH7kGQlhW0LCSwDufdMwHwYDVR0jBBgwFoAUlg4DXiS2KerLdLjkcubMIV39
edswDQYJKoZIhvcNAQELBQADggEBACbf7iS78tJLSKXJEshGVNT/D4jIWtu+W2VN
oo8ea2coi/Vy/BHiHSebSAOGY0VdrdreuH0w8dnbIqdBpd3XuiBrsFEDcMn2NGqI
65z1c8FoLaWGLRFEsq6hTlGWAcE/BW4gyeHVoZ8tzBF+u2DsCHvyFkYjoCHo2FnJ
NTpEyd4vWVaCvzUt1hRE1VnEmsmrElnmvwvM6e6WDe0FpyDJ9KUCsW7QeE4X/L2x
U19q6rdhIhAe0NajmZ7X5HNzu7pyhUf/GBKZLkPHvLXNPDgj5isqdWZUqsRoslTa
U+7x0cJgLdCh8BDQcCL6qaMUMLuEEs0mv15M/0Sgcr0qT1DJmDc=
-----END CERTIFICATE-----
"""

private let serverPrivateKeyPEM = """
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDiJdSz1dJTZgpG
WGXHEHBUos+f8iJx4GxGBdsYZgST9S+6sc7gLNoLSY5LZjG4J6GWIf1IeadeMH2z
dwGsFkzsdyKK42Ry8Kyh40QDMIw5O4EyVF0WciCxdve8kIGDt7BgOxghIips5GKE
JlCFZfcB7loju3XYEQqatIVKScPI6YqVyRtaAkdf/vW6VTxtGC8fcV4mLwEiXOZR
qOTzXwQMufjsLg/KBBvUiYjmlXtxcUOCZSw4RDOzgMRjcsvA8KqnuOCYHj9FIjD8
SF42reXIDoyEIJm4ly2wxSB5KJ/80gYYdNiYnsxW8eZck/6GnkFQVmoFWDXzQdiJ
n+rWsGJ1AgMBAAECggEADmVyIPCfrwdz5/6AnCeDvx+OMBRt9OngeqSsyeTUrcaR
/0SKcuLoDofkMxCSYbLEKpaHVTHJYcmcduxAgv/4baU34beQEXEYzEV3cuyIQKx1
EQsl0eP6CNIV+z8Hv6bV54pbguB16vCvBNKblaJkEw9lVZj9a3/KOQb85TnE6Ok2
aV6K2DcyeFCGtfgimdOfCQvnJI5JY8oGa6Q/TSo+e12T35iMEimfA7PPQXP+sobo
YOMG/u8bUUUQk0JWuDQBoLo7Js6pldJFrwgLsFXngg6QjWbaLJjdavRdvChsVZJa
vF43IyhgqVp15jgKTBiKM0ECDmUHP9qIU+J4I1CrEQKBgQD8vx8WmLdR9NJPLZyv
qNZNk4F2MO8I6QP8xm3cq5aelNrny+a0zqf/378Uv3mxiBQnbBw8+Iy92OfnD1k9
jWtU1TsBKQlZjhUbrh5kZsEB2lqnqwxyw+SAM5f03Mr1l4N3wvebcHqQxTTh6MEs
C7QGRsm9Myn1ThloEZFXIpA52wKBgQDlDw7iOTDG0FwU2OFCRrK7tP3ih7F93VdN
1DWyiHxUbwgaYYqgxIWEb1coelxU7LOS5TtxNv884yoOJwEiij3MU9mtTJuffOOi
HHpQrThAdsedbN+nHMO8Og9t2Vl2e/flDgGQhi1TRXVkoCFVS16tLqkQ/+PIE76k
HBas4ALN7wKBgBZlHO0UpRG2/reTVBHghPSkwFDnrxZ8ByVrs6pc7eCpUeg+Efgt
Y4dxnO3KtY68fwSrOKlSYK4lvQ6lNoQUttDyf+LvbuungklMmVbOIAX5AhVfO6Aj
qWiOqcVBlx5ByZ1gAi6cvc98Gd52kD9F3jK8LP39vZcFz4yAGf+9iUgHAoGAJ0j1
3IbCftatdEXeHGfTr63S/U8YeeXEW2zR6NTPvgts8FlaVUhfPd96q06RF1+hTMhT
8Y7lJ6QuSk8WOr5K6whWhQpmhmv8/oiz0bJju2qjwbQyh46/Y0Dx9H0agt+wHHDS
g97/VxDKmX99OAu9KSafiHLati3svGi02uFwmbECgYEAzQQeGn5tEEe6Bu0p6Sgd
HrFEnHUtiVPT5vBacAmimpQ5EpcuKxsxxJheibZfwTg+pqt8Y+sHYjJPlr7/th+2
I93Y4NpsNo27U1Twt24xJ/bBia4zx3TxpWd73lcIYd1OvPH/sk445eDgjUjPZiJU
9upbLbSmEC3ascXiLcV/6n8=
-----END PRIVATE KEY-----
"""

private let wrongCACertificatePEM = """
-----BEGIN CERTIFICATE-----
MIIDNzCCAh+gAwIBAgIUGEnrvmnwHRsaMQERdGPOIdD+AlUwDQYJKoZIhvcNAQEL
BQAwIzEhMB8GA1UEAwwYSEw3djMgU3ludGhldGljIHdyb25nIGNhMB4XDTI2MDkx
NTAyNDMwNloXDTM2MDkxMjAyNDMwNlowIzEhMB8GA1UEAwwYSEw3djMgU3ludGhl
dGljIHdyb25nIGNhMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA7j86
wuMvpLjwO6L7clzycnWa0/xLo3KyXaYa6vUvYrH5EAX5mSHuJkdwUkNKFu4eGaJI
QekJOHwCu3+I/o+fR9CuAhzAw40h8cwH5tzPYNm12S6Ktf/PjZhUysGwCSfxOEiI
8vi/lPqo5b2eafP1FXBvhUja+X3sAsl/QYTirG/TBN1E0rSDh3lbefuXhONuD7RF
FC6A63KhBcx2IDK/1DeF0PtS6a/EdyB+8UzuZz268RQzuAVfwjdVkZ4TTxfBHJhW
q7zXnrdvRBzQOQt7eMxQV1/ATal2/jDvujEQ0eJUtxWaLGZcb7pIDHSr+tHjI0gZ
zXXhi3TFyuEc019K3wIDAQABo2MwYTAdBgNVHQ4EFgQUc7KPUkCkFGgrapnaGdj0
V44xOuowHwYDVR0jBBgwFoAUc7KPUkCkFGgrapnaGdj0V44xOuowDwYDVR0TAQH/
BAUwAwEB/zAOBgNVHQ8BAf8EBAMCAQYwDQYJKoZIhvcNAQELBQADggEBAJLBanKY
ntcHdw+9BWO9Cg31Fhi61krDdBkvpIuZcjuyFcGvVuduXTjUeZe04cJURRhNfv67
qR8hRWhb6JQRaYsK+EZRRD0CliehJ+G4lk7f8xd2uBwbupIBTXAtXFRn+s9o66H0
0+OBgLevIsEMImjq0t0g1KclKa2u37vRgc2hoytFMXX34vcCg5gItFsJnoNqDkU7
QbR0vm9NyTdJn5Wq7b1UWnd+sIWw/Bzr8QPfjnyb41IS5YJYMms2bC2Tuy1A+SlA
KZx9oZlt0Ce6PP8ASnHxOoNwrRKvgerlsf2kpZT4fmYFEi/iE+eOokoG0IM0AUuh
xrzsSAxrDCM/lkA=
-----END CERTIFICATE-----
"""
