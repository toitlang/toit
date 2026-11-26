import net.sandbox

main:
  socket := sandbox.open.tcp-connect "example.com" 80
  socket.out.write "GET / HTTP/1.0\r\n\r\n"
  print socket.in.read-all.size
  socket.close
