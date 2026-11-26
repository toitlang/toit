import net.sandbox-http

main:
  client := sandbox-http.open
  response := client.get "https://example.com/"
  print response.body.read-all.size
  response.close
