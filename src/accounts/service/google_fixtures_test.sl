// A throwaway 2048-bit test key's JWKS and ID tokens it signed (RS256),
// made with openssl. The nonce in each is fixed-nonce-7701.

fn fixture_jwks() -> str {
    return "{\"keys\":[{\"kty\":\"RSA\",\"kid\":\"test-kid\",\"alg\":\"RS256\",\"use\":\"sig\",\"n\":\"n1eZRofV5JQwT_5atXjc" +
        "a4syQu8nBFW421KqxHC_968pasbXomUawzdzcbGFjyFKKehrsGmokCzRwuds9e-yuuodV3AM7DlSbMVv7Zkt3PsH4t" +
        "agM4_dK9DKCC9WqxLdLReJd5vaYqhVxldKJmNUS31GROzPvJTegoBoSruMSihV1jh74K4clpHPL0LudsPdXQ0v16WX" +
        "tE2JmsWmKk2RSdgFJ5tIB7NODpK4lDSJmEi-nfbV42uLwyUkOGyLciY59ZSmA71bmLDRfP3TZ2gm5SdsksOFcCwkXq" +
        "lvfjfOQmT7gz5uHjkCPf6OZ3bpyOpquywfQ5LovNlz4Q9K98V3TQ\",\"e\":\"AQAB\"}]}";
}

fn fixture_good() -> str {
    return "eyJhbGciOiJSUzI1NiIsImtpZCI6InRlc3Qta2lkIiwidHlwIjoiSldUIn0.eyJpc3MiOiJodHRwczovL2FjY291bn" +
        "RzLmdvb2dsZS5jb20iLCJhdWQiOiJjbGllbnQtMSIsInN1YiI6Imdvb2dsZS1zdWItNzcwMSIsImVtYWlsIjoiZy50" +
        "ZXN0ZXJAZ21haWwuY29tIiwiZW1haWxfdmVyaWZpZWQiOnRydWUsIm5vbmNlIjoiZml4ZWQtbm9uY2UtNzcwMSIsIm" +
        "V4cCI6NDEwMjQ0NDgwMCwiaWF0IjoxNzAwMDAwMDAwfQ.hTGkM6-XMaofHQt8QH87Gn4_0vMSRVaZZpNe6QN-FTMmA" +
        "9VPjkh7l5P7wXmpyQMz0bWJjbCBmN5M2aOmn5H53uXCzmzUJ_-4Emaj2-0TDi1UkMR1U1_bY2d_6rl18jEWwsMLke-" +
        "H7sGDiMUXR-ag_BBtndK_o2Up9d4-dbTqz8CNNLGSJJkQxwAyffeeKurSNleS867ZRpP9ZZwoxDcEZy4EeQbS8bvs0" +
        "PaSFU0m3TaU330yUlZdJJs1BndDymv-F0koFlnuoBvA7HudJ9abdju3te1HDyLlxwFIwm4vUNFnvrM68-wFlYJukBW" +
        "q07QW-FdHy8ul49WnjRp_TCn7kA";
}

fn fixture_wrong_aud() -> str {
    return "eyJhbGciOiJSUzI1NiIsImtpZCI6InRlc3Qta2lkIiwidHlwIjoiSldUIn0.eyJpc3MiOiJodHRwczovL2FjY291bn" +
        "RzLmdvb2dsZS5jb20iLCJhdWQiOiJzb21lb25lLWVsc2UiLCJzdWIiOiJnb29nbGUtc3ViLTc3MDEiLCJlbWFpbCI6" +
        "ImcudGVzdGVyQGdtYWlsLmNvbSIsImVtYWlsX3ZlcmlmaWVkIjp0cnVlLCJub25jZSI6ImZpeGVkLW5vbmNlLTc3MD" +
        "EiLCJleHAiOjQxMDI0NDQ4MDAsImlhdCI6MTcwMDAwMDAwMH0.aPlmP4l5LOpXMjLnnQ3mXkK6OdrwvnYD11-ulanM" +
        "A65RLdE-ClNlXJQIKp044jYI26ASVeOzpiPzW9eJwqNeeUaPODNoosgec5Hdx4e0IgLGDGMTw5-joFipsMdr0VM1Ta" +
        "m21muceuOL3p-ToG1Lj2GE9J--uS_n6rpKpGaxMTm4zQthtpa5Wr1_u-1IYDG5f8YdjV86hB-gJEo4e8KmrE8DIgNz" +
        "JL9Jo3lhnY-csrGn7-LbBGUwPkkh_y_DhZJ2YzYS8opwmWdviMejWf_e_brkDLHB87TTtaAppO79wtrnQjNeUZXaVF" +
        "u6RRf0oYWtMvXhUe_s6gR2MzF8gnNwVA";
}

fn fixture_expired() -> str {
    return "eyJhbGciOiJSUzI1NiIsImtpZCI6InRlc3Qta2lkIiwidHlwIjoiSldUIn0.eyJpc3MiOiJodHRwczovL2FjY291bn" +
        "RzLmdvb2dsZS5jb20iLCJhdWQiOiJjbGllbnQtMSIsInN1YiI6Imdvb2dsZS1zdWItNzcwMSIsImVtYWlsIjoiZy50" +
        "ZXN0ZXJAZ21haWwuY29tIiwiZW1haWxfdmVyaWZpZWQiOnRydWUsIm5vbmNlIjoiZml4ZWQtbm9uY2UtNzcwMSIsIm" +
        "V4cCI6MTcwMDAwMDYwMCwiaWF0IjoxNzAwMDAwMDAwfQ.U7ogQLijm5PGQHWVdTBwoNf9SAZ907zt3kFAx6kVVv42G" +
        "440ns4czlJNtdpKePjebdFY-rEhSciIrGJMZFmhh1sN65YsPteHS7JriAdNx3LfBCsMylG-RXk8-jfblWibH7qrYCn" +
        "EakbbAVXqpCPhXUCkeRagQ17iuOVwQ7r6uMMDflLlELiEZHgWvZFLjRY8bszTFATL9hsrW8TBvv2FV6uWXv4Q9K6An" +
        "iDx4iiqhKdiWayBv0jl9UimuO9A3XfwP30Vh97KkYH4aWK8T600doEMn4q3G39rVaY0y5anY_NIJ69KIKgLWF1thQO" +
        "WR1wO0Hd8l895mXvazx9Lq-fdKA";
}

fn fixture_unverified() -> str {
    return "eyJhbGciOiJSUzI1NiIsImtpZCI6InRlc3Qta2lkIiwidHlwIjoiSldUIn0.eyJpc3MiOiJodHRwczovL2FjY291bn" +
        "RzLmdvb2dsZS5jb20iLCJhdWQiOiJjbGllbnQtMSIsInN1YiI6Imdvb2dsZS1zdWItNzcwMSIsImVtYWlsIjoiZy50" +
        "ZXN0ZXJAZ21haWwuY29tIiwiZW1haWxfdmVyaWZpZWQiOmZhbHNlLCJub25jZSI6ImZpeGVkLW5vbmNlLTc3MDEiLC" +
        "JleHAiOjQxMDI0NDQ4MDAsImlhdCI6MTcwMDAwMDAwMH0.V1tzTHQw7spyLmf12ZKWbSBLI7vqv5h4IbmwK1UeDgft" +
        "aDJb7tXJZ-R0WUVnLYAzo7n55Ct8QTlFPHKB8j8r3WkpyeKiCptH_9LlQqBOHJS3u4xwMcXefeQB_FVvJlGN-KpgzH" +
        "DdTAWxqSvRSG2dJ8JCBLw5Qy-PAr-UCHQsPg6Wr4vRha-s1C3Vjrwds1qcCWHvGaWGhUvxsCShzgj9QxXYl0a1lWKb" +
        "LBjVLKd2z92LbAoOxcRFTjdo0UUm-Wq-V-oOqSSpe_i99E0GuOth7L9WEGwsyuB_C-pDVXfch_nwCOvB5XbxGKxGKB" +
        "Db_jk13r4_PD7-n-fMaY2czagHzA";
}

fn fixture_other_kid() -> str {
    return "eyJhbGciOiJSUzI1NiIsImtpZCI6InVua25vd24ta2lkIiwidHlwIjoiSldUIn0.eyJpc3MiOiJodHRwczovL2FjY2" +
        "91bnRzLmdvb2dsZS5jb20iLCJhdWQiOiJjbGllbnQtMSIsInN1YiI6Imdvb2dsZS1zdWItNzcwMSIsImVtYWlsIjoi" +
        "Zy50ZXN0ZXJAZ21haWwuY29tIiwiZW1haWxfdmVyaWZpZWQiOnRydWUsIm5vbmNlIjoiZml4ZWQtbm9uY2UtNzcwMS" +
        "IsImV4cCI6NDEwMjQ0NDgwMCwiaWF0IjoxNzAwMDAwMDAwfQ.IFOcqbXg9FupA4fpuvcEoDLpvM3854HRA7pZf2fbz" +
        "JYu-TGA51dbwz4kL_0iNpg0S1BJiYdyY-Fbxwif4TVkE7vcop5ZnknOgGsfTJBgMOojhHkinLwbh_KRoMnWsGJ7KIG" +
        "2F6SobsDB9VS0ShApQsVzORLRar8r61BMDn_-D19cmFDtV0OaXPrpLgQUWsiB1YCDowklvQ-ymO-kKyjw5iYSPYg7Y" +
        "pT013mEojDMkOkAKZ-TY_YXIXL1e27Aa64-zUxDPMuPcKaQr4Gikdskwpn-qczXH4e7-6KLwQCKHyffTVccu7n75-C" +
        "NZ4j2H3hibHguHcvoASFqx2N6UVl20w";
}

fn fixture_bad_sig() -> str {
    return "eyJhbGciOiJSUzI1NiIsImtpZCI6InRlc3Qta2lkIiwidHlwIjoiSldUIn0.eyJpc3MiOiJodHRwczovL2FjY291bn" +
        "RzLmdvb2dsZS5jb20iLCJhdWQiOiJjbGllbnQtMSIsInN1YiI6Imdvb2dsZS1zdWItNzcwMSIsImVtYWlsIjoiZy50" +
        "ZXN0ZXJAZ21haWwuY29tIiwiZW1haWxfdmVyaWZpZWQiOnRydWUsIm5vbmNlIjoiZml4ZWQtbm9uY2UtNzcwMSIsIm" +
        "V4cCI6NDEwMjQ0NDgwMCwiaWF0IjoxNzAwMDAwMDAwfQ.hTGkM6-WMaofHQt8QH87Gn4_0vMSRVaZZpNe6QN-FTMmA" +
        "9VPjkh7l5P7wXmpyQMz0bWJjbCBmN5M2aOmn5H53uXCzmzUJ_-4Emaj2-0TDi1UkMR1U1_bY2d_6rl18jEWwsMLke-" +
        "H7sGDiMUXR-ag_BBtndK_o2Up9d4-dbTqz8CNNLGSJJkQxwAyffeeKurSNleS867ZRpP9ZZwoxDcEZy4EeQbS8bvs0" +
        "PaSFU0m3TaU330yUlZdJJs1BndDymv-F0koFlnuoBvA7HudJ9abdju3te1HDyLlxwFIwm4vUNFnvrM68-wFlYJukBW" +
        "q07QW-FdHy8ul49WnjRp_TCn7kA";
}

fn fixture_existing_email() -> str {
    return "eyJhbGciOiJSUzI1NiIsImtpZCI6InRlc3Qta2lkIiwidHlwIjoiSldUIn0.eyJpc3MiOiJodHRwczovL2FjY291bn" +
        "RzLmdvb2dsZS5jb20iLCJhdWQiOiJjbGllbnQtMSIsInN1YiI6Imdvb2dsZS1zdWItNzcwMiIsImVtYWlsIjoidGFr" +
        "ZW4uYnkucGFzc3dvcmRAc2F5LnRlc3QiLCJlbWFpbF92ZXJpZmllZCI6dHJ1ZSwibm9uY2UiOiJmaXhlZC1ub25jZS" +
        "03NzAxIiwiZXhwIjo0MTAyNDQ0ODAwLCJpYXQiOjE3MDAwMDAwMDB9.Y1vPtN0kSlLOe-qkJ33i9sPT0b53eIUXes3" +
        "8cgn0J8v5heHz2sE-jlH2iaewBW2pwfkSXGeZRo0XDYfysKJd7A0RZrzNeiEcVAiHimgkM4JLr2qgxMov20t-a6Ie6" +
        "caA98y5iKk9ClRaOJi-z2tNrkkjxfxyGyuPNcXzTt4B4DiBCBrH8WUHwYZPoJ74ygpqQ29eQM_zEL3Y3exhOpGhcOm" +
        "BXT_HBtxGqEsgZBmVoY1KFoOZ4_tuhv1lmBD0SNjRk__eQ2v6R54AEj1n2svk9aQEzJXLHzek3KWyTxGuA6oEsp5A_" +
        "EzPVWPK7oA6UNi_SIMST0vJnxnvwP175xeH7g";
}
