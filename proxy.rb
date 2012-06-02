
require 'socket'
require 'uri'
require 'webrick'
require 'json'
require 'openssl'
require 'base64'
require 'stringio'
require 'yaml'

config = YAML::load_file 'config.yml'
$key = Base64.decode64 config['key']
$iv = Base64.decode64 config['iv']

$remote_server = config['remote_server']
$remote_port = config['remote_port'] || 80


module Proxy
  
  def write out, data
    puts data
    out.write data
  end
  module_function :write

  def write_request_enveloped req, server
    
    aes = OpenSSL::Cipher::Cipher.new('AES-256-CBC')
    aes.encrypt
    aes.key = $key
    aes.iv = $iv
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
     aes.key = $key
     aes.iv = $iv

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
  
class ProxyForwarder
  include Proxy
  # Hold a TCP connection
  def run port
    puts "Starting Proxy to #{$remote_server}:#{$remote_port}. Listening on #{port}"
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

    server = TCPSocket.new($remote_server, $remote_port)
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
    puts "Receiver listening on #{port}"
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


if ARGV.empty? || ARGV[0] == '--client'
  ProxyForwarder.new.run 8008
elsif ARGV[0] == '--server'
  ProxyReceiver.new.run 8009
elsif ARGV[0] == '--both'
  threads = []
  threads << Thread.new do
    ProxyForwarder.new.run 8008
  end
  threads << Thread.new do
    ProxyReceiver.new.run 8009
  end
  threads.each { |t| t.join }
end
