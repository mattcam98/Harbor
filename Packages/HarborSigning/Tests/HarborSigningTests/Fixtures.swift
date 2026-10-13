import Foundation
import SideSign

/// Self-signed certificates and RSA keys generated only for these tests.
/// They are not trusted by anything and sign nothing outside this test bundle.
enum Fixture {
    struct Identity {
        let certificatePEM: String
        let privateKeyPEM: String
        let serial: String

        var certificate: X509Certificate {
            X509Certificate(data: Data(certificatePEM.utf8))!
        }

        var keyStore: KeyStore {
            KeyStore(certificate: certificate, privateKey: Data(privateKeyPEM.utf8))
        }
    }

    /// Common name: iPhone Developer: Test A (AAAAAAAAAA)
    static let iPhoneDeveloper = Identity(
        certificatePEM: """
        -----BEGIN CERTIFICATE-----
        MIIDpzCCAo+gAwIBAgIUAd3Iln+1EgKFF4FTzUlI064e7XAwDQYJKoZIhvcNAQEL
        BQAwYzEuMCwGA1UEAwwlaVBob25lIERldmVsb3BlcjogVGVzdCBBIChBQUFBQUFB
        QUFBKTETMBEGA1UECwwKVEVTVFRFQU0wMTEcMBoGA1UECgwTSGFyYm9yIFRlc3Qg
        Rml4dHVyZTAeFw0yNjEwMTMxMTMxNTBaFw0zNjEwMTAxMTMxNTBaMGMxLjAsBgNV
        BAMMJWlQaG9uZSBEZXZlbG9wZXI6IFRlc3QgQSAoQUFBQUFBQUFBQSkxEzARBgNV
        BAsMClRFU1RURUFNMDExHDAaBgNVBAoME0hhcmJvciBUZXN0IEZpeHR1cmUwggEi
        MA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQC8rz7/CLLJ2LkkP0yjtWF8P4L7
        MSEY8yoK7gl8992+47F+BFXM6lwCQWRywmIYb6IaIV2XQgvrpbzKPVDOu6aeKb2C
        eu+FBx6rOgTT+Mp2aAXZ7P3QpUGB7bFTU7JvDEcylhJHVjwRNU1bn44Vf0bkN4VP
        SQ489m53i5u3i/eQjd2SPcl0QXzsO2ZWNejmsvvzTd+6V7OvjYTaG8JA7Nbr3AY9
        9BHz5n9gXkvC8/DKX8vgtdkBb2ilKX700rJwQ2wOeIRm1Ywew6BpwIAvxkWmoxtO
        rlEqyeR5n+MTelEGJIxxV5J4v6zaS3v6e9bLlUJVcnb2sLVUEW4Kjvet3D6VAgMB
        AAGjUzBRMB0GA1UdDgQWBBQeukAddoAEi35j7KJ1BqyTS+5FHDAfBgNVHSMEGDAW
        gBQeukAddoAEi35j7KJ1BqyTS+5FHDAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3
        DQEBCwUAA4IBAQAqBygBOU9jQPdFIT7nV3Sec41EWiDWwKR4xp68btFujUprMVlV
        FHBLMgr7g5DG/0m1QzZUkvoKxPBEoeKgKJXtYGNsZn6I+519e+ZrrjnbPe11SQJe
        MaxDu3Of8IJ/JZEseZfLCaQ7HKD3O0lvRv6VJILg8eVMOFdD8V5dPiqKgE1IenT9
        U6SBTm951kV6T9gT/kLAM5ojoXAs3Q4JJRzIx/cVDdpPCHuP+XF4VoZmsptoJ1UI
        kBVD/HgWl5pVnD7ZysGrpR5oCzmAVWU/cQ5FeUFu699eHFrw6UsuXwz7EUiEdT7c
        ecW+A5A8Jrgo71Xqu1MBl8/VuykXeQ5PiHuv
        -----END CERTIFICATE-----
        """,
        privateKeyPEM: """
        -----BEGIN RSA PRIVATE KEY-----
        MIIEogIBAAKCAQEAvK8+/wiyydi5JD9Mo7VhfD+C+zEhGPMqCu4JfPfdvuOxfgRV
        zOpcAkFkcsJiGG+iGiFdl0IL66W8yj1Qzrumnim9gnrvhQceqzoE0/jKdmgF2ez9
        0KVBge2xU1OybwxHMpYSR1Y8ETVNW5+OFX9G5DeFT0kOPPZud4ubt4v3kI3dkj3J
        dEF87DtmVjXo5rL7803fulezr42E2hvCQOzW69wGPfQR8+Z/YF5LwvPwyl/L4LXZ
        AW9opSl+9NKycENsDniEZtWMHsOgacCAL8ZFpqMbTq5RKsnkeZ/jE3pRBiSMcVeS
        eL+s2kt7+nvWy5VCVXJ29rC1VBFuCo73rdw+lQIDAQABAoIBAC0dA4Vr2X+cU0wA
        3Hyp8fiIoPMZQI4cGbnKRzd7difdfgMg2zjm8f/SDcfIhTbNficcQinXr0z08Co0
        tdzwDfr0BO0tIpaeaK1M7nmWGyZrYbbEzLz1vi9oGwVO1jNp7p4ANreavTrqEShu
        gkTOjS8kvTmDQKW/0BLCLQWaMCN99iUT/J/1CUSn5pM/FM3sRFli7dNlq9ByhM0S
        Tr49ACZmQKhiLVWmBvZRbAc1NgPfdqCzWJTH4O3NlQM74XDfgPbZwEogAby6sO5S
        2hxbCG0rHcZcbCvHBF5qm96eCmI9A5+iR8dHx1v6iVTIJEuwcXk0yiCYe6a2dWPg
        QOIOLHMCgYEA9tdgaHCnNAD0Ro99CVQPX2x6ZOycTDGJsN9h2CUuHIU+5rFS3w6i
        SH+5/hA4G5XzPy8sUhuNK3CMySD2yokI5I+aqlSSao5kiTXAUF3lHKK13NwcOqVM
        K8omBFvxVydIDRBd4UajJRoAwod0XW89nbhWEuNUteRcixjIJGwZgMsCgYEAw693
        nArSOpRs0a5FRMAtu20uDRmxc4fxVHjdtoF3YETFtF+Qwn8ikMbnbbN/Z7F+8hCY
        40KCe1NmYg1R06508lIMpfLbVU8c0r+20w96RTf8Qk21yOpKS/5L6oqkIxf2YvUV
        ktCyxoo9tvgQz0YpC7/uD4GvO7GkkE3WAbUaMh8CgYAf7pC8MgaPRahUEG/eaw9q
        CsBymeFGQgpL5TnlGjoy2lHeygWscVoxAsTuxu5bMzS6ccHMBWBnxDGSOz9xx/Rs
        jN83NaWTP0RmM5vjSaI/6BSas6a7N3L5Hzd3zOUVnzFE718Vq2ujew+qGpfFFoTk
        CFqqKtpkhVwralNJ0uohrQKBgHUlGOSIMdwxuIc53WvP5FC8hoH/LJTt/9HC3W+B
        R7aQ1Q4q250jwMyM1kR83Tt1LXq55ty9lyE/Bx6RvLeNS6M47St3HEiQqL+dV1Q4
        gsjnQBNtM/MIFtwxar8IqkP791q8P2L5ntxuK43aKS38YVwQVPJhf0asDMj6X6/7
        +6efAoGAX/V3tVegcQZ1qf3t7yJjElgAvnJRyit/c2sZCf4RCCyiP3nsUljhgdVo
        9ocIPjJOFJ3OCnhy91PVGo4NGs5kCoJKiSUw0wixHltDREhMqNKeAIFmQq1Hpw1M
        YpDiKCXQYByYw/9BP9fn/UNPA4KbWo4rQoSezW1McF4mDhUUfwI=
        -----END RSA PRIVATE KEY-----
        """,
        serial: "01DDC8967FB5120285178153CD4948D3AE1EED70"
    )

    /// Common name: iOS Development: Test B (BBBBBBBBBB)
    static let iOSDevelopment = Identity(
        certificatePEM: """
        -----BEGIN CERTIFICATE-----
        MIIDpTCCAo2gAwIBAgIUW0zu9k5q9NKVUQaOGiR6B4O5j2kwDQYJKoZIhvcNAQEL
        BQAwYjEtMCsGA1UEAwwkaU9TIERldmVsb3BtZW50OiBUZXN0IEIgKEJCQkJCQkJC
        QkIpMRMwEQYDVQQLDApURVNUVEVBTTAxMRwwGgYDVQQKDBNIYXJib3IgVGVzdCBG
        aXh0dXJlMB4XDTI2MTAxMzExMzE1MFoXDTM2MTAxMDExMzE1MFowYjEtMCsGA1UE
        AwwkaU9TIERldmVsb3BtZW50OiBUZXN0IEIgKEJCQkJCQkJCQkIpMRMwEQYDVQQL
        DApURVNUVEVBTTAxMRwwGgYDVQQKDBNIYXJib3IgVGVzdCBGaXh0dXJlMIIBIjAN
        BgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAy6+FhxhO4LnnXwYDZsoLZCm02CJ0
        90577hy/GGEmFYEIT2serzcriAGupaR9kAjY/Us81vrcjAyeI1Cr96Od3LbD/gIB
        O71RiANoGhMHjcRCBnQE4bJT8wg5xowJ6GZe7n88vmWFWF+q5qUSvk4T97OSVX2J
        1nvwqYgtE7dYQKQgA75jQuMo8rnyd7+Zs4SpSPVWYu4TzHJigbRPWunhQmXWkKx0
        SVuCT2YWl+9RXXyn4XwBDbZ8MlsHlKBlyZIFGvXwEBR5GtayHw+SPpeUXahg3bEC
        OpE00xPFTAFpzHXH/NRD4Chr9T3XVfFzpK98SPyXj1iUzQodcpY1yYASLwIDAQAB
        o1MwUTAdBgNVHQ4EFgQUmWS/TcqGiRNH270PrE3tJPuGcyMwHwYDVR0jBBgwFoAU
        mWS/TcqGiRNH270PrE3tJPuGcyMwDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0B
        AQsFAAOCAQEAoUBrXrbnyDdcT8qgorS45EL8AoPEkgJrPQebbnbLz749dyoCRo82
        Vu7zGHA2hTxCm5fIpoop3Rzgdta50/Ga3+s/bBwnWB+rQw/g5F5nn8uY979aXfhO
        xINPBy8ApLmFKkA6/gnFMWAWgdNKncfmi0yzYEtyKRMJ6Tsxo0hnLDGsmX24oJBz
        kQCbwelxT0j+oHdtmn8bGqW6NiH0oy39AlvciqaqB2iVNaWGiFjww6Ye7+kc0h80
        /pMwkCBvxLew5zMMQXsQTDzSKFhZ4o2iutDiTj+WGIvtqyVD65CDOPORX9Cb+ODP
        9CDNteXLlMswuPW5JCvuK8fBIIdBMFkieg==
        -----END CERTIFICATE-----
        """,
        privateKeyPEM: """
        -----BEGIN RSA PRIVATE KEY-----
        MIIEowIBAAKCAQEAy6+FhxhO4LnnXwYDZsoLZCm02CJ090577hy/GGEmFYEIT2se
        rzcriAGupaR9kAjY/Us81vrcjAyeI1Cr96Od3LbD/gIBO71RiANoGhMHjcRCBnQE
        4bJT8wg5xowJ6GZe7n88vmWFWF+q5qUSvk4T97OSVX2J1nvwqYgtE7dYQKQgA75j
        QuMo8rnyd7+Zs4SpSPVWYu4TzHJigbRPWunhQmXWkKx0SVuCT2YWl+9RXXyn4XwB
        DbZ8MlsHlKBlyZIFGvXwEBR5GtayHw+SPpeUXahg3bECOpE00xPFTAFpzHXH/NRD
        4Chr9T3XVfFzpK98SPyXj1iUzQodcpY1yYASLwIDAQABAoIBACCJxDr17HkvOYGP
        ObE3SuU6rw5tSAzPF4fM789lNZWZ10oDQr5FgfQS0Ljas3RJoDWryeb4jDg94Rqj
        IyrxkvZUpq/yggqZDmfmo2qxlN4AzCCxHVaGC63Mp+4f0OAJ+oBUXc/MnVCmImxV
        /SM0NdxhbgRaLvrPMdLjU3rNfzupXa/WjsYVRW+InBd7N8GOCmETgYCWf8Nrug8Z
        sLu3YURQPK8/fFdn51uMS9v0U4SKWFlpYZtPE1mqIdyc/tvj9BRqtnXan8a22Trj
        BgCUm6PTlU/FWwrskYfYz/Wt6FXOF0xYJ069qaJf+Q/NDN52WKYmdbmKHjkWfX22
        Q7aQWIECgYEA/UXxoaJFTqOsEqEQBP4Se6LleET/gbkcsOTPlYEAXVtP9rT2trTn
        Z4lTALLfnIhtRsBZspbgBwTPI3qhD916vRlbEPQWs7Rb1RdEU9Aiu6Yz9RPcXbll
        BmiG1yuCXmoVOko0qFtApWX9+ynwq18hk36izAv2dhlCovzUTUg84+UCgYEAzeDo
        Tq+D4TvNCS1cqDgbrwoj410d5tyr9UsIdo53N5YP+0Hqql8CzmXfAAtl7Apze2GD
        +hpbxbCK06KRP2eF3zXuEdN0kdrGw9GA4w3z1JkWblCL/8ldkGDoa1wloUSdybF2
        kZHTOflNA00b2/F9bxIZeNTlIA7z6yoGuzLqZIMCgYA7BRmRuOa9tJZcoPvCrhJQ
        jV078Zg4+pIdBrT4+d7D4ot3yiPT38Qs9GtLNmO1bnVIj3pXi6EZAZ3jfqgZslrv
        xgDaqoa/yb+8oHdjsJTndYuWCNLJZHKOU71YVuNCbSYVN0WeFeWypVnSNavHw5tn
        a5M0SXVdf/VvVcuDVtoZoQKBgBBtKnvkuyQEbnaV/PebCnJr37MrYdBiuQGoS/OR
        qGdx/LJybvPLAuFO9Xz+a9Jqfw5QGISjB8F9NYZvSSGC9AZ8OhOICJv+la9YDu2O
        1m6XDFge6xysh1+Wq9StFH+KhwBpvWkd9nmAr6lcxKVG3lg3XHrsmZ92MfYIc2MK
        S/NbAoGBAORvZ5CD/7IeqSr0uvlAtjbz6LYJJs0qcf5TSQfBUt7yqNurOG+UX7vk
        AGUQi7pcJsA/MDoiT8MOrHMoiQfArY7Ccyv8sT1MB3+nG1lLGR/2JWNmSNyPhooc
        Ma28dDr/4oA8MvduW+HRU70q2Nm5+gCmfrkqXrWWGcd5Ks4dopNI
        -----END RSA PRIVATE KEY-----
        """,
        serial: "5B4CEEF64E6AF4D29551068E1A247A0783B98F69"
    )

    /// Common name: Apple Development: Test C (CCCCCCCCCC)
    static let appleDevelopment = Identity(
        certificatePEM: """
        -----BEGIN CERTIFICATE-----
        MIIDqTCCApGgAwIBAgIUbGess7AbBOovYgaFr3UC4Ws4ve0wDQYJKoZIhvcNAQEL
        BQAwZDEvMC0GA1UEAwwmQXBwbGUgRGV2ZWxvcG1lbnQ6IFRlc3QgQyAoQ0NDQ0ND
        Q0NDQykxEzARBgNVBAsMClRFU1RURUFNMDExHDAaBgNVBAoME0hhcmJvciBUZXN0
        IEZpeHR1cmUwHhcNMjYxMDEzMTEzMTUwWhcNMzYxMDEwMTEzMTUwWjBkMS8wLQYD
        VQQDDCZBcHBsZSBEZXZlbG9wbWVudDogVGVzdCBDIChDQ0NDQ0NDQ0NDKTETMBEG
        A1UECwwKVEVTVFRFQU0wMTEcMBoGA1UECgwTSGFyYm9yIFRlc3QgRml4dHVyZTCC
        ASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAKeTpdRoag7/aVOxSVPZ7ASR
        V05UQRslJTX2a2N+/R94Uo40A6oyfGLNd7wnCpFtQcYdTZpb4OvkJkIudsCkvbhg
        0Ss96B5j5Ej57yVP0MepKyYkHvg/KrZEFiU9dmCefa+5LAEAEDMwjhWwuR1VpvoZ
        /1yNnWrmVfsyuNSshp67N85wHsEwAu5ROsYFKE9AV66ZaRNGfaJy0S9ax+/NMSND
        XWfdNK+AohO21sEkf3fEjVEkXSbrNhTGIwSQQmlCG1JYNBzZC10yxL8kH/JHeaxy
        8fUHvxuUU64y3M9BLOPT2uCYXeJozmLpzLmTYpVX/mYvVVzwxOGlnElJ3SqQskcC
        AwEAAaNTMFEwHQYDVR0OBBYEFD02RX5MGtMGTnF7rtRrCC2BDbwxMB8GA1UdIwQY
        MBaAFD02RX5MGtMGTnF7rtRrCC2BDbwxMA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZI
        hvcNAQELBQADggEBAEw/VdXFMZdjSmY9sJpS/O9SxKg96W5bFdd1JK4enBdJ5q0b
        tQzaRXQ8DE9hZTw4d9FXO7fXbJVzcAdeCsl4NRpDKsa75B7CdgDVYU1q8dzV7jX0
        WjkTw8yO20j4c1o+TP6alV6T18i731RS6EjDg1TwYxjn7vZzHXSqIY9SfaHt+Ldk
        wOvRZ3K0zfW09KD978frvRDzYNzlez0s8w8XYA6O2lqeKx+VUEtmDRCur3TQvrYx
        qZMGuq4vmkaVCK8P2YyYWWmjScFoXjcWahcHyMWnfiE1BHHr+95gTA8gVS/U0rDK
        mm1liVuovPJfI9QjROnQghMp+ShOxUgR2OVtbUI=
        -----END CERTIFICATE-----
        """,
        privateKeyPEM: """
        -----BEGIN RSA PRIVATE KEY-----
        MIIEowIBAAKCAQEAp5Ol1GhqDv9pU7FJU9nsBJFXTlRBGyUlNfZrY379H3hSjjQD
        qjJ8Ys13vCcKkW1Bxh1Nmlvg6+QmQi52wKS9uGDRKz3oHmPkSPnvJU/Qx6krJiQe
        +D8qtkQWJT12YJ59r7ksAQAQMzCOFbC5HVWm+hn/XI2dauZV+zK41KyGnrs3znAe
        wTAC7lE6xgUoT0BXrplpE0Z9onLRL1rH780xI0NdZ900r4CiE7bWwSR/d8SNUSRd
        Jus2FMYjBJBCaUIbUlg0HNkLXTLEvyQf8kd5rHLx9Qe/G5RTrjLcz0Es49Pa4Jhd
        4mjOYunMuZNilVf+Zi9VXPDE4aWcSUndKpCyRwIDAQABAoIBAEMN4Z1M6qN1sD+9
        AQp8eOSbA8RkEmk6Q9mD8RSvC7o7+0zLo2vHJ96hOPgg5ymp/le4AgVyHl5FvMle
        rkYHpaLRmuEitG70qbRJzlevyGscVhe8/Gd5Xy3vsKzWGzguMzzNa746uEDDfRdQ
        z8HdNCN/o571S7gq0tzhPvRa1MNOn7bQtZRPFeQA8gFjymc2xE8vZirQxenhUaqL
        Jjw/FiiLGkwsJGki3P7sbLUEZoBOMeFOmcIXOC2E6MG9XUMZ8TWba8zxZbREi50H
        zuiumAIYm2iBBcdOFCiYJesCm4wrcYht/kxuNEyvGLwCOK700HYFB0BOx1L53oo5
        EqaQAYECgYEA63JS6d4c1TONLPsocQhSQH9Ozcy16Y2Da0KW4OOnTvRGVlYgIfzC
        rWna28KaQgg73j3un6JgColVK6mVAmBFOPAN3MtB9cWZ5CxVa3Z373LHaoHqpklr
        Jlb7ZYiIKJ9nECJ9gGhJ0JjmJrw528sk8PhK9yOVZaTf8CfAKl7axHsCgYEAtjSX
        2mcDJbvK3iF+GqoZ3kW/OvYOxm2VAYiFQvkKXsA8QgoFsm6SKXBxz976bh80eYF6
        M2/CrKt9PoOwIZKt9wF71yix7HVKeDimmmUH6zbaQU7pafW8MuYDT+KFGL2P9TBx
        VIzl+U82q6kOCiLw/RRXCkvij3vcxizdmr7gfaUCgYAa6mLYIXAiX1ZQQhYJde4R
        OXyEwlY5cNgJNv+QjfXebMZtsELUH9URhfxjCwgfbFmLuoDA9wsLqU93Qleqgd7n
        92leSE4uDnzdPMQ3GL/1O6XYYym0AMijBWaP4N/P5QkfKxI1z7ZAhnopC3OB0ONU
        OM45GnRFvmdrSOAK9/UCaQKBgAUMgAi1QgkRoxV0qCHlBMJ7/EiN+OrWroJUXhz0
        +ayWdxT9YhsHpVUwoHa6HwZeJv4W8GPsfOB8AARzcbX8coWdrOjRX9zFg0LBjxxI
        IGgMJRAaN62P+Z8PcJgOFtIQrqSEqx9EqDq4TzOCg7kULslUfvTyFV0UeZGkPJ/F
        GkNhAoGBALOrEAHD3JnY2An3pzEDkK/3Nq8Gk0Z6Iun+6JKvcwo2PE8HBMCBUpSW
        4TPZFtI2PjZnpnSsugD6UUsJHFAiJdOci3eX8ZUd7MTZe6dv27rHCGITXC6YSTgW
        5/t3AWO07z1yvy5mq8e/GnLq0gmP1j1cr/IjFiRiQp7XXxKgYr7+
        -----END RSA PRIVATE KEY-----
        """,
        serial: "6C67ACB3B01B04EA2F620685AF7502E16B38BDED"
    )
}
