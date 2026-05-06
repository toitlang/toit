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

  print "\nAll EC tests passed!"
