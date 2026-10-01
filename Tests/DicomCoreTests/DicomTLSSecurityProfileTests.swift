import Foundation
import XCTest
@testable import DicomCore

final class DicomTLSSecurityProfileTests: XCTestCase {
    func test_currentProfile_usesTLS12Minimum() {
        XCTAssertEqual(
            DicomTLSOptionsFactory.minimumTLSProtocolVersionName(for: .bcp195RFC8996),
            "TLSv1.2"
        )
    }

    func test_legacyRawValues_decodeAsCurrentProfile() throws {
        let legacyRawValues = [
            "nonDowngradingBCP195",
            "bcp195",
            "extendedBCP195",
            "basicRetired",
            "aesRetired",
            "authenticatedUnencryptedRetired"
        ]

        for rawValue in legacyRawValues {
            let data = try XCTUnwrap("\"\(rawValue)\"".data(using: .utf8))
            let decoded = try JSONDecoder().decode(DicomTLSSecurityProfile.self, from: data)

            XCTAssertEqual(decoded, .bcp195RFC8996, rawValue)
        }
    }

    func test_currentProfile_encodesCanonicalRawValue() throws {
        let data = try JSONEncoder().encode(DicomTLSSecurityProfile.bcp195RFC8996)

        XCTAssertEqual(String(data: data, encoding: .utf8), "\"bcp195RFC8996\"")
    }

    func test_unknownRawValue_isRejected() throws {
        let data = try XCTUnwrap("\"unknown\"".data(using: .utf8))

        XCTAssertThrowsError(try JSONDecoder().decode(DicomTLSSecurityProfile.self, from: data))
    }
}


extension DicomTLSSecurityProfileTests {
    /// Synthetic identity, used only to exercise SecPKCS12Import on both iOS and macOS.
    func test_pkcs12Identity_importsAndRejectsWrongPassword() throws {
        let fixture = """
        MIIKFwIBAzCCCcUGCSqGSIb3DQEHAaCCCbYEggmyMIIJrjCCBBoGCSqGSIb3DQEHBqCCBAswggQHAgEAMIIEAAYJKoZIhvcNAQcB
        MF8GCSqGSIb3DQEFDTBSMDEGCSqGSIb3DQEFDDAkBBBgO2XgOf50T4Z/Ins4RMVpAgIIADAMBggqhkiG9w0CCQUAMB0GCWCGSAFl
        AwQBKgQQQr7raw0lGA2qGiHkOR0jboCCA5BENxEEnmlogdJE77P5MS4ltR3QYQtDPnjv573+upnaIH472uFqxFyNbOvOwWVYHE+8
        bbitDeafgWxqNXJV3Z+OhKbltH74zjc2mHKUM7moNpMkQ4S9HkoI/9qHDgg544zw+upYOvHskWLwI5HRHt4U9VNNFlOzwCBvwEC/
        h0pvBiKy4RMYSBL/JeeAr+vIpj85q7ngJoaQnaFkaqW5xqbKF5QoPfOPG8sJVO2RdcpFq5uhh1nQ8FwfUAyrcJKZpxHhNwcZPmt3
        haXoLsx83mdhklZHsq5ZHXYoDBbBvuHtTdUBHmmDHkRi27pPcXL4xwVyt732yePA+A6pNZVT2ES2bUAqgdiUjTVC2tO0sP4ChrR0
        ocMVN96vdRPe9jWvqQ2fykcsn3HbHrBNy1CTAjBFgBi6clHtLxe80PgiuTrPF7firAFQ3g9dB/lOEuc1njrIiV4isiIj4ZB47m91
        emC6kgdXKgcmmCh5bXGTLK6eOGpOVZrZWbAWCd20DrVTkViUSyLMtdfAJUyZ7/aLqEe7llHIJqGbMrlsMnDVRoVhvlhfLM5PHlpX
        kHvdfrNQLbhOOLz/qqEz1S3NnZQV6JlVPUdPWZPVYaC6n8zqF8U5RzmKyOO4C+IEqdHQTZQu1Qd0THQh0ijBGUnwFS0iLjiM0Roh
        avwiAnM94mtn5SlgobxQ1zcvk9AtuSbwtkbW2jQilQ/DToobusK90HW8utJ2qkADAsUGESlIb3jgZE+TyO6uI6cU8F5aps0nzhW9
        mMKshiXZfNGDuJ7WuCskDlQ+0vy9UPDINHIi7jCGhZGvNEMplCLVcGWzP8qWWkpehCXJx+shxMaSHfPMOOcwTcsXD4o1zqnt6b5M
        ocmmn8V7Ls9MBLs0k77d6dZBrtCmPYvqJVoffHkzvvnEB0EM0sLQcIfp3ype/WNjEhRboiyWPZ9H8GLscT/L088/HXVoZUirhc8b
        QZ/L6xHj2C36NYISuSyDNuCwUTCzgilxcHjGlvFmvmGNHr72T7MzI3yWBMduC0ETzkWNlgZ5OCUV8vwXMXSLm1jHvd7ttUFaG6ex
        b4BX92m+IehBJkp+hdI4NyoUDK5tHE9Sy9rUQ3GeYU4CzCVV9E+iz0cMNKYytPoOtvGTg9/eDUZzqK5SxDd5mzOsj8EI5wHs38Ol
        jMQJW6SKyfpit2pOK9w372J9DUVMMYI506QtQBLGCPui7FA2tl4wggWMBgkqhkiG9w0BBwGgggV9BIIFeTCCBXUwggVxBgsqhkiG
        9w0BDAoBAqCCBTkwggU1MF8GCSqGSIb3DQEFDTBSMDEGCSqGSIb3DQEFDDAkBBA0EoluRuhMfOnOK3VWikEaAgIIADAMBggqhkiG
        9w0CCQUAMB0GCWCGSAFlAwQBKgQQRgPmJ72XiYpN5IvKRUJZAwSCBNDrOfAJYRc1dewC5YWUdH8XTTEi/XcJk83DMCL2z3k8Lzxc
        F7KLyf6NDqhKftcTd4L3eLcEDU9IDH8D4usL0KENGVvh9U+DZo6VH4WJAwQksQ7hdjaaT/w4W3QMpbcjRxboF3BArFZp2ulvt1iV
        djV1A8GD3LnCLWo/Bf981gXw8WBCtmWD5UXYT61bjeefnFcIG8FrdhmO3fjUQgc3lX9h7tIYCxV6/sPR2soqagX6wJjYAdtqix3d
        jWfLxdYNJm/vaOjSzhBp5CO9UAoQ9fnK379kVk7OIAGPsIw1GY7PhI5I9kLfbzxKiasXecUDPKIN8RXW4lLZiSQjQAii4MYIS+YJ
        oGuY3zf1hf+G+eil6yqY7ce6N70Z1r9ludJpcrClQXyr2FLvzhDdTSXXffK+0kmW756gb+bdV8NmjCM4RQ8BgpaLJXgkNVFQUfSQ
        IxfdelpIBDPguAiyRt1B0T4R1hj3zGMru8FAcpqxbw0SeJGGHN5eER2NPKjpAoC7VaNB+XAG0kyRoZbfVobYFKwfHdCgZERDLdUT
        8wXs9RmAzA7FcumvglPF03hUM7vl7jTcCLRb24rYwWVEIIoZ3Vl/l9vyzO1ZkP5rqnAI49BQBfO0cfnooUUekHRsIGHSVw617YxV
        FKWj5/UJtpgyV+oE0qADxoqudmQ3nzHqa90OpHV5EXevBdyZWgzHejWfI3aX3ImWHYYWcj/jVRXTrsbsKvv54neTjxntqnWe13kf
        zWo1jWZEwe2bLHKAMDDnbb52pbRYtLtIabfV8+oQQjDuM8M+nJyDiXlZoS+OYVGOPQF9bBxgk+IYQZ8XWiWNr+8Cf5dZZY/2pP4Q
        ofCxQ/IMvguhaFoCrvxufmLNzwf3tOmKqUrWUBZFiyymZKAno6RCuXo0FdVseQe56ytO32U8wDBmPaR5n9a1AFzBg3bMB3+AryC2
        sGqnnFp8d/qeGYI0vOtHx26dtX8BfPZ5Dl1Ns3ccmuF411SAHY7RLA9BdCqC5GVeUzxG2z5jdUi1dcTjP508trhBNALBzZgazwMC
        uLk/CyC+67xtaUxVtgNi07P+QGeDoPMg7oSOzS8M8V1CuSJl5EP15U+FSug7hK65pCRWtJNj1i5QPqLGPU8SOoWgtKnKiAwoc7wX
        9QwboKHOMlVEcg9vr3lM81Dd5xa/s6m7Yx5zKyBW/ENRWDGNAdZrLrDM3W3NHw50QLXg4izg+mwIG/thJeKnNs+H622WDsPeAeJE
        06ByzVCok9f9/kWeLDwP9J84Tr97OgK9KEwDHsLJXqlSZ3qEFDO/QO6klE2Bwpp7a+S59JXMDpd2zBEmIAE6O64jcmTXLN2EW95G
        evay2frar0WxoJbyghRGtF9lvlyHP09VIpxQCSobW2Odkp3Nau+USDzx3ML9DtmfmNxd8ie++7TGULSSsg4WoVMFux53OIt2Z0V5
        NhjNvo9boDfQu2JeqVBMfBcdrROl0hZ6W7IIV83TQs5aKYPnkyybz6Fbs1attTjdNr9qsVFJUGMYLkLDxebOOQS3diBJIxqPV2gE
        h2cCRySpLgcLcnuYmxIGZxAvh5pvIoFhqusDe3DYEmsjmJEvr5KVf4wcazgaVnOu4ZwCl1n1jpLBdUTuJNa0+d5vwpvJxkZuHzEl
        MCMGCSqGSIb3DQEJFTEWBBRfxpAmzXznfVW9EOd7A7c9fu2iWDBJMDEwDQYJYIZIAWUDBAIBBQAEIKuHpfd4KcIfdsNZ/rf8x6fs
        79cEkGVzaxGybGXaGaptBBBLDcOzdRwBB6oTzhRj4wRAAgIIAA==
        """
        let data = try XCTUnwrap(Data(base64Encoded: fixture, options: .ignoreUnknownCharacters))
        let material = DicomTLSMaterial(pkcs12Data: data, pkcs12Password: "synthetic-a1")
        let prepared = try DicomTLSOptionsFactory.preparedParameters(
            for: .init(mode: .enabled, material: material), role: .server)
        XCTAssertEqual(prepared.tlsContext?.hasLocalIdentity, true)
        XCTAssertThrowsError(try DicomTLSOptionsFactory.preparedParameters(
            for: .init(mode: .enabled, material: .init(pkcs12Data: data, pkcs12Password: "wrong")), role: .server))
        let serialized = try JSONEncoder().encode(material)
        XCTAssertFalse(String(decoding: serialized, as: UTF8.self).contains("synthetic-a1"))
        XCTAssertNil(try JSONDecoder().decode(DicomTLSMaterial.self, from: serialized).pkcs12Data)
    }
}
