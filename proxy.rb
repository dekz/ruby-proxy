
require 'socket'
require 'uri'
require 'webrick'
require 'json'
require 'openssl'
require 'base64'
require 'stringio'

$my_key = "\x05\x10\x98F\xFBlM\xDDP\xA1\x9D\xFC\x8B\f\x7F\x17s\xA3\xA0?\xC6\x90\xBD\x9D\xAF\xD3\xEE\xD2\xBF\xD5\xA0,"
$my_iv = "\xE3\xCAJm\xB5b\xDD\xD4P\x8A\xBECP\x9C.\xF8"

module Proxy
  
  def write out, data
    puts data
    out.write data
  end
  module_function :write

  def write_request_enveloped req, server
    
    aes = OpenSSL::Cipher::Cipher.new('AES-256-CBC')
    aes.encrypt
    aes.key = $my_key
    aes.iv = $my_iv
    c_t = aes.update req.to_json
    c_t << aes.final

    safe_c_t = Base64.encode64 c_t
    
    write server, "POST /tme HTTP/1.1\r\n"
    write server, "Content-Length: #{safe_c_t.length}\r\n"
    write server, "\r\n#{safe_c_t}\r\n"
    write server, "Connection: close\r\n\r\n"
  end
  
  def read_request_enveloped body
     unsafe_c_t = Base64.decode64 body
     
     aes = OpenSSL::Cipher::Cipher.new('AES-256-CBC')
     aes.decrypt
     aes.key = $my_key
     aes.iv = $my_iv

     pt = aes.update unsafe_c_t
     pt << aes.final
     pt
  end
  module_function :read_request_enveloped
  
  def write_request req, server  
    
    query = req.query.map { |k, v| "#{k}=#{v}" }.join '&'
    query = '?' + query unless query.strip.empty?
    query = URI::encode query
  
    write server, "#{req.request_method} #{req.path}#{query} HTTP/#{req.http_version}\r\n"
    req.header.each { |n,v| write server, "#{n.upcase}: #{v[0]}\r\n" }

    write server, "\r\n#{req.body}" if req.body

    write server, "Connection: close\r\n\r\n"
  end
  module_function :write_request
  
  def parse_request client
    req = WEBrick::HTTPRequest.new(WEBrick::Config::HTTP)
    req.parse client
    req
  end
  module_function :parse_request

  
end
  
class ProxySender
  include Proxy
  # Hold a TCP connection
  def run port
    @server = TCPServer.new port
    loop do
      Thread.start @server.accept do |s|
        proxy_request s
        s.close
      end
    end
  end


  # Forward on the data
  def proxy_request client
    req = parse_request client

    query = req.query.map { |k, v| "#{k}=#{v}" }.join '&'
    query = '?' + query unless query.strip.empty?
    query = URI::encode query

    server = TCPSocket.new('localhost', 8009)
    write_request_enveloped req, server
  
    # Read response
    buff = ''
    loop do
      server.read 4096, buff
      # Decrypt our response here and reconstruct the headers
      client.write buff
      break if buff.size < 4096
    end
  
    server.close
  end
end

class ProxyReceiver
  include Proxy
  def run port
    @server = TCPServer.new port
    loop do
      Thread.start @server.accept do |s|
        proxy_respond s
        s.close
      end
    end
  end

  def proxy_respond client
    req = parse_request client
    req = read_request_enveloped req.body
    req = String.class_eval req
    io = StringIO.new req
    req = parse_request io
    
    server = TCPSocket.new(req.host, req.port)
    write_request req, server
    
    # Read response
    buff = ''
    loop do
      server.read 4096, buff
      # Encrypt our response here and reconstruct the headers
      client.write buff
      break if buff.size < 4096
    end

    server.close
  end
end


begin
  if ARGV.empty? || ARGV[0] == '--client'
    ProxySender.new.run 8008
  elsif ARGV[0] == '--server'
      ProxyReceiver.new.run 8009
  elsif ARGV[0] == '--both'
    threads = []
    threads << Thread.new do
      ProxySender.new.run 8008
    end
    threads << Thread.new do
      ProxyReceiver.new.run 8009
    end
    threads.each { |t| t.join }
  end
rescue => e
  puts e.backtrace
end
