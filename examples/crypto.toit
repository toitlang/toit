
import crypto.aes
import expect

main:

    secret := #[
        0x34, 0x74, 0x36, 0x77, 0x39, 0x7A, 0x24, 0x43, 
        0x26, 0x46, 0x29, 0x4A, 0x40, 0x4E, 0x63, 0x52,
        0x66, 0x55, 0x6A, 0x58, 0x6E, 0x32, 0x72, 0x35,
        0x75, 0x38, 0x78, 0x21, 0x41, 0x25, 0x44, 0x2A
    ]
    iv := ByteArray 16

    plaintext := ByteArray 16: it

    encryptor /aes.Aes := aes.AesCbc.encryptor 
        secret
        iv

    ciphertext := encryptor.encrypt plaintext
    expect.expect_bytes_equal 
        #[
            //Taken from https://the-x.cn/en-us/cryptography/Aes.aspx
            0xAB, 0x66, 0x7F, 0x94, 0x82, 0x93, 0x27, 0x05, 
            0xF6, 0x8B, 0x81, 0xF5, 0x99, 0xB2, 0x15, 0x9D
        ]
        ciphertext

    print "Ciphertext Cbc: $ciphertext"

    decryptor := aes.AesCbc.decryptor
        secret
        iv
    
    decrypted := decryptor.decrypt ciphertext
    expect.expect_bytes_equal 
        plaintext
        decrypted

    print "Decrypted Cbc: $decrypted"


    encryptor = aes.AesEcb.encryptor
        secret
    
    ciphertext = encryptor.encrypt plaintext

    print "Ciphertext Ebc: $ciphertext" 



