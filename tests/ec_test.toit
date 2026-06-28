import crypto.ec
import crypto.sha256
import expect show *

expect-throws expected-error [code]:
  actual := catch code
  expect-equals expected-error actual

main:
  curves := [ec.EcKey.CURVE-SECP256R1, ec.EcKey.CURVE-SECP384R1, ec.EcKey.CURVE-SECP521R1]
  
  curves.do: | curve |
    print "Testing curve: $curve"
    
    // Test generation.
    key-pair := ec.EcKeyPair.generate --curve=curve
    print "  Generated key pair (size: $key-pair.private-key.size bytes)"
           
    // Test signing.
    message := "Hello EC World!"
    signature := key-pair.sign message
    print "  Signature: $(signature.size) bytes"
    
    // Test verification.
    expect (key-pair.verify message signature)
    print "  Verification: SUCCESS"

    // Test PEM export and parsing.
    pem := key-pair.private-key.to-pem
    print "  Exported to PEM"
    print pem
    
    parsed-key := ec.EcKey.parse-private pem
    expect (parsed-key.der == key-pair.private-key.der)
    print "  Parse Private: SUCCESS"

    pub-pem := key-pair.public-key.to-pem
    parsed-pub := ec.EcKey.parse-public pub-pem
    expect-equals key-pair.public-key.der parsed-pub.der
    print "  Parse Public: SUCCESS"

    // Test ECDH.
    print "  Testing ECDH..."
    key-pair-b := ec.EcKeyPair.generate --curve=curve
    secret-a := key-pair.compute-shared-secret key-pair-b.public-key
    secret-b := key-pair-b.compute-shared-secret key-pair.public-key
    expect-equals secret-a secret-b
    print "    Shared secret: MATCH (size: $secret-a.size)"

    // Test ECIES.
    print "  Testing ECIES..."
    msg := "Sensitive Information ($curve)"
    ciphertext := ec.Ecies.encrypt msg key-pair.public-key --curve=curve
    print "    Ciphertext size: $ciphertext.size"
    
    decrypted := key-pair.decrypt-ecies ciphertext
    expect-equals msg decrypted.to-string
    print "    ECIES: SUCCESS"
      
    // Test tampering.
    print "    Testing tampering detection..."
    
    // 1. Tamper with tag (last bytes).
    tampered-tag := ciphertext.copy
    tampered-tag[tampered-tag.size - 1] ^= 0xFF
    expect-throws ec.Ecies.AUTHENTICATION-FAILURE:
      key-pair.decrypt-ecies tampered-tag
      
    // 2. Tamper with ciphertext.
    tampered-ct := ciphertext.copy
    tampered-ct[ciphertext.size - 17] ^= 0xFF // Just before the tag.
    expect-throws ec.Ecies.AUTHENTICATION-FAILURE:
      key-pair.decrypt-ecies tampered-ct
      
    // 3. Tamper with nonce.
    tampered-nonce := ciphertext.copy
    der-len := (ciphertext[0] << 8) | ciphertext[1]
    tampered-nonce[2 + der-len] ^= 0xFF
    expect-throws ec.Ecies.AUTHENTICATION-FAILURE:
      key-pair.decrypt-ecies tampered-nonce
      
    print "      Tampering Detection: SUCCESS"

  print "\nAll EC tests passed!"
