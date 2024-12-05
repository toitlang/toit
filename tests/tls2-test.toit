// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import net
import net.modules.tcp
import net.x509 as net
import system
import system show platform
import tls

network := net.open

monitor LimitLoad:
  current := 0
  has-test-failure := null
  // FreeRTOS does not have enough memory to run 10 in parallel.
  concurrent-processes ::= platform == system.PLATFORM-FREERTOS ? 1 : 2

  inc:
    await: current < concurrent-processes
    current++

  flush:
    await: current == 0

  test-failures:
    await: current == 0
    return has-test-failure

  log-test-failure message:
    has-test-failure = message

  dec:
    current--

load-limiter := LimitLoad

main:
  run-tests

run-tests:
  // Github and Google pages fail because we don't have their trusted root installed.
  test-site "github.com" false
  test-site "www.google.com" false
  test-site "drive.google.com" false
  load-limiter.flush  // Sequence point so we don't install the roots until the previous test completed.

  // Now they should succeed.
  test-site "github.com" true
  test-site "www.google.com" true
  test-site "drive.google.com" true
  if load-limiter.test-failures:
    throw load-limiter.has-test-failure

GLOBALSIGN-ROOT-CA ::= net.Certificate.parse """\
-----BEGIN CERTIFICATE-----
MIIDdTCCAl2gAwIBAgILBAAAAAABFUtaw5QwDQYJKoZIhvcNAQEFBQAwVzELMAkG
A1UEBhMCQkUxGTAXBgNVBAoTEEdsb2JhbFNpZ24gbnYtc2ExEDAOBgNVBAsTB1Jv
b3QgQ0ExGzAZBgNVBAMTEkdsb2JhbFNpZ24gUm9vdCBDQTAeFw05ODA5MDExMjAw
MDBaFw0yODAxMjgxMjAwMDBaMFcxCzAJBgNVBAYTAkJFMRkwFwYDVQQKExBHbG9i
YWxTaWduIG52LXNhMRAwDgYDVQQLEwdSb290IENBMRswGQYDVQQDExJHbG9iYWxT
aWduIFJvb3QgQ0EwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDaDuaZ
jc6j40+Kfvvxi4Mla+pIH/EqsLmVEQS98GPR4mdmzxzdzxtIK+6NiY6arymAZavp
xy0Sy6scTHAHoT0KMM0VjU/43dSMUBUc71DuxC73/OlS8pF94G3VNTCOXkNz8kHp
1Wrjsok6Vjk4bwY8iGlbKk3Fp1S4bInMm/k8yuX9ifUSPJJ4ltbcdG6TRGHRjcdG
snUOhugZitVtbNV4FpWi6cgKOOvyJBNPc1STE4U6G7weNLWLBYy5d4ux2x8gkasJ
U26Qzns3dLlwR5EiUWMWea6xrkEmCMgZK9FGqkjWZCrXgzT/LCrBbBlDSgeF59N8
9iFo7+ryUp9/k5DPAgMBAAGjQjBAMA4GA1UdDwEB/wQEAwIBBjAPBgNVHRMBAf8E
BTADAQH/MB0GA1UdDgQWBBRge2YaRQ2XyolQL30EzTSo//z9SzANBgkqhkiG9w0B
AQUFAAOCAQEA1nPnfE920I2/7LqivjTFKDK1fPxsnCwrvQmeU79rXqoRSLblCKOz
yj1hTdNGCbM+w6DjY1Ub8rrvrTnhQ7k4o+YviiY776BQVvnGCv04zcQLcFGUl5gE
38NflNUVyRRBnMRddWQVDf9VMOyGj/8N7yy5Y0b2qvzfvGn9LhJIZJrglfCm7ymP
AbEVtQwdpf5pLGkkeB6zpxxxYu7KyJesF12KwvhHhm4qxFYxldBniYUr+WymXUad
DKqC5JlR3XC321Y9YeRq4VzW9v493kHMB65jUr9TU/Qr6cf9tveCX4XSQRjbgbME
HMUfpIBvFSDJ3gyICh3WZlXi/EjJKSZp4A==
-----END CERTIFICATE-----"""

USERTRUST-ECC-CERTIFICATION-AUTHORITY ::= tls.RootCertificate --fingerprint=0xbadc5b59 USERTRUST-ECC-CERTIFICATION-AUTHORITY-BYTES_

USERTRUST-ECC-CERTIFICATION-AUTHORITY-BYTES_ ::= #[
    '0',0x82,0x2,143,'0',130,2,21,160,3,2,1,2,2,16,92,139,153,197,'Z',148,197,
    0xd2,'q','V',222,205,137,128,204,'&','0',10,6,8,'*',134,'H',206,'=',4,3,3,
    '0',129,136,'1',11,'0',9,6,3,'U',4,6,19,2,'U','S','1',19,'0',17,6,3,'U',4,
    8,19,10,'N','e','w',' ','J','e','r','s','e','y','1',20,'0',18,6,3,'U',4,7,
    19,11,'J','e','r','s','e','y',' ','C','i','t','y','1',30,'0',28,6,3,'U',4,
    0xa,19,21,'T','h','e',' ','U','S','E','R','T','R','U','S','T',' ','N','e',
    't','w','o','r','k','1','.','0',',',0x06,3,'U',4,3,19,'%','U','S','E','R',
    'T','r','u','s','t',' ','E','C','C',' ','C','e','r','t','i','f','i','c',
    'a','t','i','o','n',' ','A','u','t','h','o','r','i','t','y','0',30,23,0xd,
    '1','0','0','2','0','1','0','0','0','0','0','0','Z',23,13,'3','8','0','1',
    '1','8','2','3','5','9','5','9','Z','0',0x81,136,'1',11,'0',9,6,3,'U',4,6,
    19,2,'U','S','1',19,'0',17,6,3,'U',4,8,19,0xa,'N','e','w',' ','J','e','r',
    's','e','y','1',0x14,'0',18,6,3,'U',4,7,19,11,'J','e','r','s','e','y',' ',
    'C','i','t','y','1',30,'0',28,6,3,'U',4,0xa,19,21,'T','h','e',' ','U','S',
    'E','R','T','R','U','S','T',' ','N','e','t','w','o','r','k','1','.','0',
    ',',0x06,3,'U',4,3,19,'%','U','S','E','R','T','r','u','s','t',' ','E','C',
    'C',' ','C','e','r','t','i','f','i','c','a','t','i','o','n',' ','A','u',
    't','h','o','r','i','t','y','0','v','0',16,6,7,'*',0x86,'H',206,'=',2,1,6,
    0x05,'+',129,4,0,'"',3,'b',0,4,26,172,'T','Z',169,249,'h','#',231,'z',213,
    '$','o','S',0xc6,'Z',0xd8,'K',171,198,213,182,209,230,'s','q',174,221,156,
    214,12,'a',253,219,160,137,3,184,5,20,236,'W',206,238,']','?',226,'!',179,
    0xce,0xf7,212,138,'y',224,163,131,'~','-',151,208,'a',196,241,153,220,'%',
    0x91,'c',0xab,0x7f,'0',163,180,'p',226,199,161,'3',156,243,191,'.',92,'S',
    0xb1,'_',0xb3,'}','2',0x7f,138,'4',227,'y','y',163,'B','0','@','0',29,6,3,
    'U',29,0xe,4,22,4,20,':',225,9,134,212,207,25,194,150,'v','t','I','v',220,
    224,'5',198,'c','c',154,'0',14,6,3,'U',29,15,1,1,255,4,4,3,2,1,6,'0',15,6,
    3,'U',29,19,1,1,0xff,4,5,'0',3,1,1,255,'0',10,6,8,'*',134,'H',206,'=',4,3,
    3,3,'h',0,'0','e',2,'0','6','g',161,22,8,220,228,151,0,'A',29,'N',190,225,
    'c',0x1,207,';',170,'B',17,'d',160,157,148,'9',2,17,'y',92,'{',29,250,'d',
    0xb9,238,22,'B',179,191,138,194,9,196,236,228,177,'M',2,'1',0,233,'*','a',
    'G',0x8c,'R','J','K','N',0x18,'p',246,214,'D',214,'n',245,131,186,'m','X',
    0xbd,'$',0xd9,'V','H',234,239,196,162,'F',129,136,'j',':','F',209,169,155,
    'M',201,'a',218,209,']','W','j',24,
]

ROOTS ::= [
  GLOBALSIGN-ROOT-CA,
  USERTRUST-ECC-CERTIFICATION-AUTHORITY,
]

test-site url expect-ok:
  host := url
  port := 443
  if (url.index-of ":") != -1:
    array := url.split ":"
    host = array[0]
    port = int.parse array[1]
  load-limiter.inc
  if expect-ok:
    task:: working-site host port
  else:
    task:: non-working-site host port

non-working-site site port:
  catch:
    connect-to-site site port false
    load-limiter.log-test-failure "*** Incorrectly failed to reject SSL connection to $site ***"
  load-limiter.dec

working-site host port:
  error := true
  try:
    connect-to-site-with-retry host port true
    error = false
  finally:
    if error:
      load-limiter.log-test-failure "*** Incorrectly failed to connect to $host ***"
    load-limiter.dec

connect-to-site-with-retry host port expected-certificate-name:
  2.repeat: | attempt-number |
    error := catch --unwind=(:attempt-number == 1):
      connect-to-site host port expected-certificate-name
    if not error: return

connect-to-site host port add-root:
  raw := tcp.TcpSocket network
  raw.connect host port
  socket := tls.Socket.client raw
    // Install the roots needed.
    --root-certificates=(add-root ? ROOTS : [])

  writer := socket.out
  writer.write """GET / HTTP/1.1\r\nHost: $host\r\nConnection: close\r\n\r\n"""

  bytes := 0

  reader := socket.in
  while data := reader.read:
    bytes += data.size

  socket.close

  print "Read $bytes bytes from https://$host$(port == 443 ? "" : ":$port")/"
