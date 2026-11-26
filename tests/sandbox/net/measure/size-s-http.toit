import http
import net.sandbox

main:
  client := http.Client sandbox.open.with-tls
  response := client.get --uri="http://example.com:443/"
  print response.body.read-all.size
  client.close
