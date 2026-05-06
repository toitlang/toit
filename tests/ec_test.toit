import crypto.ec
import crypto.sha256

main:
  curves := ["secp256r1", "secp384r1", "secp521r1"]
  
  curves.do: | curve |
    print "Testing curve: $curve"
    
    // Test generation
    key-pair := ec.EcKeyPair.generate --curve=curve
    print "  Generated key pair (size: $key-pair.private-key.size bytes)"
           
    // Test signing
    message := "Hello EC World!"
    signature := key-pair.sign message
    print "  Signature: $(signature.size) bytes"
    
    // Test verification
    if key-pair.verify message signature:
      print "  Verification: SUCCESS"
    else:
      print "  Verification: FAILED"
      throw "Verification failed"

    // Test PEM export and parsing
    pem := key-pair.private-key.to-pem
    print "  Exported to PEM"
    print pem
    
    parsed-key := ec.EcKey.parse-private pem
    if parsed-key.der == key-pair.private-key.der:
      print "  Parse Private: SUCCESS"
    else:
      print "  Parse Private: FAILED"
      throw "Parse Private failed"

    pub-pem := key-pair.public-key.to-pem
    parsed-pub := ec.EcKey.parse-public pub-pem
    if parsed-pub.der == key-pair.public-key.der:
      print "  Parse Public: SUCCESS"
    else:
      print "  Parse Public: FAILED"
      throw "Parse Public failed"

    // Test ECDH
    print "  Testing ECDH..."
    key-pair-b := ec.EcKeyPair.generate --curve=curve
    secret-a := key-pair.compute-shared-secret key-pair-b.public-key
    secret-b := key-pair-b.compute-shared-secret key-pair.public-key
    if secret-a == secret-b:
      print "    Shared secret: MATCH (size: $secret-a.size)"
    else:
      print "    Shared secret: MISMATCH"
      throw "ECDH mismatch"

    // Test ECIES
    print "  Testing ECIES..."
    msg := "Sensitive Information ($curve)"
    ciphertext := ec.Ecies.encrypt msg key-pair.public-key --curve=curve
    print "    Ciphertext size: $ciphertext.size"
    
    decrypted := key-pair.decrypt-ecies ciphertext
    if decrypted.to-string == msg:
      print "    ECIES: SUCCESS"
    else:
      print "    ECIES: FAILED"
      throw "ECIES decryption failed"
      
    // Test tampering
    print "    Testing tampering detection..."
    
    // 1. Tamper with tag (last bytes)
    tampered-tag := ciphertext.copy
    tampered-tag[tampered-tag.size - 1] ^= 0xFF
    if (catch: key-pair.decrypt-ecies tampered-tag) != ec.Ecies.AUTHENTICATION-FAILURE:
      throw "Failed to detect tag tampering"
      
    // 2. Tamper with ciphertext
    tampered-ct := ciphertext.copy
    tampered-ct[ciphertext.size - 17] ^= 0xFF // Just before the tag
    if (catch: key-pair.decrypt-ecies tampered-ct) != ec.Ecies.AUTHENTICATION-FAILURE:
      throw "Failed to detect ciphertext tampering"
      
    // 3. Tamper with nonce
    tampered-nonce := ciphertext.copy
    der-len := (ciphertext[0] << 8) | ciphertext[1]
    tampered-nonce[2 + der-len] ^= 0xFF
    if (catch: key-pair.decrypt-ecies tampered-nonce) != ec.Ecies.AUTHENTICATION-FAILURE:
      throw "Failed to detect nonce tampering"
      
    print "      Tampering Detection: SUCCESS"

  print "\nAll EC tests passed!"
