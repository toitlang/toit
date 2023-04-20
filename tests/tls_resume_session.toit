// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import encoding.tison
import tls
import net.modules.dns
import .tcp as tcp
import net.x509 as net
import writer

main:
  test_site "amazon.com"
  test_site "app.supabase.com" --no-read_data
  test_site "cloudflare.com"
  test_site "adafruit.com"
  test_site "dkhostmaster.dk"

test_site host/string --read_data/bool=true -> none:
  port := 443

  saved_session := null

  3.repeat: | iteration |
    if iteration != 0:
      sleep --ms=200

    raw := tcp.TcpSocket
    raw.connect host port
    socket := tls.Socket.client raw
      // Install the roots needed.
      --root_certificates=[BALTIMORE_CYBERTRUST_ROOT, GLOBALSIGN_ROOT_CA, DIGICERT_GLOBAL_ROOT_G2, DIGICERT_GLOBAL_ROOT_CA, ISRG_ROOT_X1]
      --server_name=host

    method := "full MbedTLS handshake"
    suite := 0
    if saved_session:
      socket.session_state = saved_session
      decoded := tison.decode saved_session
      if decoded[0].size != 0: method = "resumed with ID"
      if decoded[1].size != 0: method = "resumed with ticket"
      suite = decoded[3]

    duration := Duration.of:
      socket.handshake

    print "Handshake complete ($(%22s method), suite $(%4x suite)) to $(%16s host) in $(%4d duration.in_ms) ms"

    saved_session = socket.session_state

    if read_data:
      socket.write "GET / HTTP/1.1\r\n"
      socket.write "Host: $host\r\n"
      socket.write "\r\n"

      while data := socket.read:
        str := data.to_string
        if str.contains "301 Moved Permanently":
          break

    socket.close

BALTIMORE_CYBERTRUST_ROOT ::= net.Certificate.parse """\
-----BEGIN CERTIFICATE-----
MIIDdzCCAl+gAwIBAgIEAgAAuTANBgkqhkiG9w0BAQUFADBaMQswCQYDVQQGEwJJ
RTESMBAGA1UEChMJQmFsdGltb3JlMRMwEQYDVQQLEwpDeWJlclRydXN0MSIwIAYD
VQQDExlCYWx0aW1vcmUgQ3liZXJUcnVzdCBSb290MB4XDTAwMDUxMjE4NDYwMFoX
DTI1MDUxMjIzNTkwMFowWjELMAkGA1UEBhMCSUUxEjAQBgNVBAoTCUJhbHRpbW9y
ZTETMBEGA1UECxMKQ3liZXJUcnVzdDEiMCAGA1UEAxMZQmFsdGltb3JlIEN5YmVy
VHJ1c3QgUm9vdDCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAKMEuyKr
mD1X6CZymrV51Cni4eiVgLGw41uOKymaZN+hXe2wCQVt2yguzmKiYv60iNoS6zjr
IZ3AQSsBUnuId9Mcj8e6uYi1agnnc+gRQKfRzMpijS3ljwumUNKoUMMo6vWrJYeK
mpYcqWe4PwzV9/lSEy/CG9VwcPCPwBLKBsua4dnKM3p31vjsufFoREJIE9LAwqSu
XmD+tqYF/LTdB1kC1FkYmGP1pWPgkAx9XbIGevOF6uvUA65ehD5f/xXtabz5OTZy
dc93Uk3zyZAsuT3lySNTPx8kmCFcB5kpvcY67Oduhjprl3RjM71oGDHweI12v/ye
jl0qhqdNkNwnGjkCAwEAAaNFMEMwHQYDVR0OBBYEFOWdWTCCR1jMrPoIVDaGezq1
BE3wMBIGA1UdEwEB/wQIMAYBAf8CAQMwDgYDVR0PAQH/BAQDAgEGMA0GCSqGSIb3
DQEBBQUAA4IBAQCFDF2O5G9RaEIFoN27TyclhAO992T9Ldcw46QQF+vaKSm2eT92
9hkTI7gQCvlYpNRhcL0EYWoSihfVCr3FvDB81ukMJY2GQE/szKN+OMY3EU/t3Wgx
jkzSswF07r51XgdIGn9w/xZchMB5hbgF/X++ZRGjD8ACtPhSNzkE1akxehi/oCr0
Epn3o0WC4zxe9Z2etciefC7IpJ5OCBRLbf1wbWsaY71k5h+3zvDyny67G7fyUIhz
ksLi4xaNmjICq44Y3ekQEe5+NauQrz4wlHrQMz2nZQ/1/I6eYs9HRCwBXbsdtTLS
R9I4LtD+gdwyah617jzV/OeBHRnDJELqYzmp
-----END CERTIFICATE-----"""

GLOBALSIGN_ROOT_CA ::= net.Certificate.parse """\
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

DIGICERT_GLOBAL_ROOT_G2 ::= net.Certificate.parse """\
-----BEGIN CERTIFICATE-----
MIIDjjCCAnagAwIBAgIQAzrx5qcRqaC7KGSxHQn65TANBgkqhkiG9w0BAQsFADBh
MQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3
d3cuZGlnaWNlcnQuY29tMSAwHgYDVQQDExdEaWdpQ2VydCBHbG9iYWwgUm9vdCBH
MjAeFw0xMzA4MDExMjAwMDBaFw0zODAxMTUxMjAwMDBaMGExCzAJBgNVBAYTAlVT
MRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5j
b20xIDAeBgNVBAMTF0RpZ2lDZXJ0IEdsb2JhbCBSb290IEcyMIIBIjANBgkqhkiG
9w0BAQEFAAOCAQ8AMIIBCgKCAQEAuzfNNNx7a8myaJCtSnX/RrohCgiN9RlUyfuI
2/Ou8jqJkTx65qsGGmvPrC3oXgkkRLpimn7Wo6h+4FR1IAWsULecYxpsMNzaHxmx
1x7e/dfgy5SDN67sH0NO3Xss0r0upS/kqbitOtSZpLYl6ZtrAGCSYP9PIUkY92eQ
q2EGnI/yuum06ZIya7XzV+hdG82MHauVBJVJ8zUtluNJbd134/tJS7SsVQepj5Wz
tCO7TG1F8PapspUwtP1MVYwnSlcUfIKdzXOS0xZKBgyMUNGPHgm+F6HmIcr9g+UQ
vIOlCsRnKPZzFBQ9RnbDhxSJITRNrw9FDKZJobq7nMWxM4MphQIDAQABo0IwQDAP
BgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwIBhjAdBgNVHQ4EFgQUTiJUIBiV
5uNu5g/6+rkS7QYXjzkwDQYJKoZIhvcNAQELBQADggEBAGBnKJRvDkhj6zHd6mcY
1Yl9PMWLSn/pvtsrF9+wX3N3KjITOYFnQoQj8kVnNeyIv/iPsGEMNKSuIEyExtv4
NeF22d+mQrvHRAiGfzZ0JFrabA0UWTW98kndth/Jsw1HKj2ZL7tcu7XUIOGZX1NG
Fdtom/DzMNU+MeKNhJ7jitralj41E6Vf8PlwUHBHQRFXGU7Aj64GxJUTFy8bJZ91
8rGOmaFvE7FBcf6IKshPECBV1/MUReXgRPTqh5Uykw7+U0b6LJ3/iyK5S9kJRaTe
pLiaWN0bfVKfjllDiIGknibVb63dDcY3fe0Dkhvld1927jyNxF1WW6LZZm6zNTfl
MrY=
-----END CERTIFICATE-----"""

ISRG_ROOT_X1_TEXT_ ::= """\
-----BEGIN CERTIFICATE-----
MIIFazCCA1OgAwIBAgIRAIIQz7DSQONZRGPgu2OCiwAwDQYJKoZIhvcNAQELBQAw
TzELMAkGA1UEBhMCVVMxKTAnBgNVBAoTIEludGVybmV0IFNlY3VyaXR5IFJlc2Vh
cmNoIEdyb3VwMRUwEwYDVQQDEwxJU1JHIFJvb3QgWDEwHhcNMTUwNjA0MTEwNDM4
WhcNMzUwNjA0MTEwNDM4WjBPMQswCQYDVQQGEwJVUzEpMCcGA1UEChMgSW50ZXJu
ZXQgU2VjdXJpdHkgUmVzZWFyY2ggR3JvdXAxFTATBgNVBAMTDElTUkcgUm9vdCBY
MTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAK3oJHP0FDfzm54rVygc
h77ct984kIxuPOZXoHj3dcKi/vVqbvYATyjb3miGbESTtrFj/RQSa78f0uoxmyF+
0TM8ukj13Xnfs7j/EvEhmkvBioZxaUpmZmyPfjxwv60pIgbz5MDmgK7iS4+3mX6U
A5/TR5d8mUgjU+g4rk8Kb4Mu0UlXjIB0ttov0DiNewNwIRt18jA8+o+u3dpjq+sW
T8KOEUt+zwvo/7V3LvSye0rgTBIlDHCNAymg4VMk7BPZ7hm/ELNKjD+Jo2FR3qyH
B5T0Y3HsLuJvW5iB4YlcNHlsdu87kGJ55tukmi8mxdAQ4Q7e2RCOFvu396j3x+UC
B5iPNgiV5+I3lg02dZ77DnKxHZu8A/lJBdiB3QW0KtZB6awBdpUKD9jf1b0SHzUv
KBds0pjBqAlkd25HN7rOrFleaJ1/ctaJxQZBKT5ZPt0m9STJEadao0xAH0ahmbWn
OlFuhjuefXKnEgV4We0+UXgVCwOPjdAvBbI+e0ocS3MFEvzG6uBQE3xDk3SzynTn
jh8BCNAw1FtxNrQHusEwMFxIt4I7mKZ9YIqioymCzLq9gwQbooMDQaHWBfEbwrbw
qHyGO0aoSCqI3Haadr8faqU9GY/rOPNk3sgrDQoo//fb4hVC1CLQJ13hef4Y53CI
rU7m2Ys6xt0nUW7/vGT1M0NPAgMBAAGjQjBAMA4GA1UdDwEB/wQEAwIBBjAPBgNV
HRMBAf8EBTADAQH/MB0GA1UdDgQWBBR5tFnme7bl5AFzgAiIyBpY9umbbjANBgkq
hkiG9w0BAQsFAAOCAgEAVR9YqbyyqFDQDLHYGmkgJykIrGF1XIpu+ILlaS/V9lZL
ubhzEFnTIZd+50xx+7LSYK05qAvqFyFWhfFQDlnrzuBZ6brJFe+GnY+EgPbk6ZGQ
3BebYhtF8GaV0nxvwuo77x/Py9auJ/GpsMiu/X1+mvoiBOv/2X/qkSsisRcOj/KK
NFtY2PwByVS5uCbMiogziUwthDyC3+6WVwW6LLv3xLfHTjuCvjHIInNzktHCgKQ5
ORAzI4JMPJ+GslWYHb4phowim57iaztXOoJwTdwJx4nLCgdNbOhdjsnvzqvHu7Ur
TkXWStAmzOVyyghqpZXjFaH3pO3JLF+l+/+sKAIuvtd7u+Nxe5AW0wdeRlN8NwdC
jNPElpzVmbUq4JUagEiuTDkHzsxHpFKVK7q4+63SM1N95R1NbdWhscdCb+ZAJzVc
oyi3B43njTOQ5yOf+1CceWxG1bQVs5ZufpsMljq4Ui0/1lvh+wjChP4kqKOJ2qxq
4RgqsahDYVvTH9w7jXbyLeiNdd8XM2w9U/t7y0Ff/9yi0GE44Za4rF2LN9d11TPA
mRGunUHBcnWEvgJBQl9nJEiU0Zsnvgc/ubhPgXRR4Xq37Z0j4r7g1SgEEzwxA57d
emyPxgcYxn/eR44/KJ4EBs+lVDR3veyJm+kXQ99b21/+jh5Xos1AnX5iItreGCc=
-----END CERTIFICATE-----
"""

ISRG_ROOT_X1 ::= net.Certificate.parse ISRG_ROOT_X1_TEXT_

DIGICERT_GLOBAL_ROOT_CA_BYTES_ ::= #[
    '0',0x82,0x3,175,'0',130,2,151,160,3,2,1,2,2,16,8,';',224,'V',144,'B','F',
    177,161,'u','j',201,'Y',145,199,'J','0',13,6,9,'*',134,'H',134,247,13,1,1,
    5,5,0,'0','a','1',11,'0',9,6,3,'U',4,6,19,2,'U','S','1',21,'0',19,6,3,'U',
    4,0xa,19,12,'D','i','g','i','C','e','r','t',' ','I','n','c','1',25,'0',23,
    0x06,3,'U',4,11,19,16,'w','w','w','.','d','i','g','i','c','e','r','t','.',
    'c','o','m','1',' ','0',30,6,3,'U',4,3,19,23,'D','i','g','i','C','e','r',
    't',' ','G','l','o','b','a','l',' ','R','o','o','t',' ','C','A','0',30,23,
    0xd,'0','6','1','1','1','0','0','0','0','0','0','0','Z',23,13,'3','1','1',
    '1','1','0','0','0','0','0','0','0','Z','0','a','1',0xb,'0',9,6,3,'U',4,6,
    19,2,'U','S','1',21,'0',19,6,3,'U',4,10,19,12,'D','i','g','i','C','e','r',
    't',' ','I','n','c','1',25,'0',23,6,3,'U',4,0xb,19,16,'w','w','w','.','d',
    'i','g','i','c','e','r','t','.','c','o','m','1',' ','0',30,6,3,'U',4,3,19,
    0x17,'D','i','g','i','C','e','r','t',' ','G','l','o','b','a','l',' ','R',
    'o','o','t',' ','C','A','0',130,1,'"','0',13,6,9,'*',134,'H',134,247,13,1,
    1,1,5,0,3,0x82,1,15,0,'0',130,1,10,2,130,1,1,0,226,';',225,17,'r',222,168,
    164,211,163,'W',170,'P',162,143,11,'w',144,201,162,165,238,18,206,150,'[',
    0x1,9,' ',204,1,147,167,'N','0',183,'S',247,'C',196,'i',0,'W',157,226,141,
    '"',0xdd,135,6,'@',0,129,9,206,206,27,131,191,223,205,';','q','F',226,214,
    'f',0xc7,5,179,'v',39,22,143,'{',158,30,149,'}',238,183,'H',163,8,218,214,
    0xaf,'z',0x0c,'9',6,'e',127,'J',']',31,188,23,248,171,190,238,'(',215,'t',
    0x7f,'z','x',0x99,'Y',0x85,'h','n',92,'#','2','K',191,'N',192,232,'Z','m',
    0xe3,'p',0xbf,'w',16,0xbf,252,1,246,133,217,168,'D',16,'X','2',169,'u',24,
    0xd5,209,162,190,'G',226,39,'j',244,154,'3',248,'I',8,'`',139,212,'_',180,
    ':',0x84,0xbf,161,170,'J','L','}','>',207,'O','_','l','v','^',160,'K','7',
    0x91,0x9e,220,'"',230,'m',206,20,26,142,'j',203,254,205,179,20,'d',23,199,
    '[',')',158,'2',191,242,238,250,211,11,'B',212,171,183,'A','2',218,12,212,
    0xef,248,129,213,187,141,'X','?',181,27,232,'I','(',162,'p',218,'1',4,221,
    0xf7,0xb2,22,242,'L',10,'N',7,168,237,'J','=','^',181,127,163,144,195,175,
    0x27,2,3,1,0,1,163,'c','0','a','0',14,6,3,'U',29,15,1,1,255,4,4,3,2,1,134,
    '0',0xf,6,3,'U',29,19,1,1,255,4,5,'0',3,1,1,255,'0',29,6,3,'U',29,14,4,22,
    4,20,3,0xde,'P','5','V',209,'L',187,'f',240,163,226,27,27,195,151,178,'=',
    0xd1,'U','0',0x1f,6,3,'U',29,'#',4,24,'0',22,128,20,3,222,'P','5','V',209,
    'L',0xbb,'f',240,163,226,27,27,195,151,178,'=',209,'U','0',13,6,9,'*',134,
    'H',134,247,13,1,1,5,5,0,3,130,1,1,0,203,156,'7',170,'H',19,18,10,250,221,
    'D',0x9c,'O','R',0xb0,0xf4,223,174,4,245,'y','y',8,163,'$',24,252,'K','+',
    0x84,0xc0,'-',0xb9,213,199,254,244,193,31,'X',203,184,'m',156,'z','t',231,
    0x98,')',0xab,17,0xb5,227,'p',160,161,205,'L',136,153,147,140,145,'p',226,
    171,15,28,190,147,169,255,'c',213,228,7,'`',211,163,191,157,'[',9,241,213,
    0x8e,0xe3,'S',244,142,'c',250,'?',167,219,180,'f',223,'b','f',214,209,'n',
    'A',0x8d,0xf2,'-',181,234,'w','J',159,157,'X',226,'+','Y',192,'@','#',237,
    '-','(',0x82,'E','>','y','T',0x92,'&',152,224,128,'H',168,'7',239,240,214,
    'y','`',22,0xde,172,232,14,205,'n',172,'D',23,'8','/','I',218,225,'E','>',
    '*',0xb9,'6','S',207,':','P',6,247,'.',232,196,'W','I','l','a','!',24,213,
    0x4,173,'x','<',',',':',128,'k',167,235,175,21,20,233,216,137,193,185,'8',
    'l',0xe2,0x91,'l',0x8a,255,'d',185,'w','%','W','0',192,27,'$',163,225,220,
    0xe9,0xdf,'G','|',0xb5,180,'$',8,5,'0',236,'-',189,11,191,'E',191,'P',185,
    0xa9,0xf3,235,152,1,18,173,200,136,198,152,'4','_',141,10,'<',198,233,213,
    149,149,'m',222,
]


/**
DigiCert Global Root CA.
SHA256 fingerprint: 43:48:a0:e9:44:4c:78:cb:26:5e:05:8d:5e:89:44:b4:d8:4f:96:62:bd:26:db:25:7f:89:34:a4:43:c7:01:61
*/
DIGICERT_GLOBAL_ROOT_CA ::= net.Certificate.parse DIGICERT_GLOBAL_ROOT_CA_BYTES_
