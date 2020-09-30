#!/usr/bin/ruby -w

require "ostruct"
require "optparse"
require "fileutils"
require "http"
require "nokogiri"
require "openssl"
require_relative "miniyamldump.rb"

## based on (somewhat dated) tld popularity charts
TLDS = %w(
  arpa int biz mobi name
  com net org de eu us info
  me online co nl ro ru
  win club mobi store space shop live
  life co ml ma np stream pro 
  news website asia fun men work science
  travel party 
)

# this class is used for each host - app class is down below
class HostSearch
  def initialize(ds, opts, host)
    @ds = ds
    @opts = opts
    @host = host
    @outputdir = opts.outputdir
    @redirection = nil
    @finalurl = nil
    @finalresponse = nil
    @cached_isavailable = nil
    # quite a few sites have shitty ssl. 
    @sslctx = OpenSSL::SSL::SSLContext.new
    @sslctx.verify_mode = OpenSSL::SSL::VERIFY_NONE
  end

  def isavailable
    if @cached_isavailable != nil then
      return @cached_isavailable
    end
    return check_isavail
  end

  def check_isavail(newurl: nil, level: 0)
    @finalurl = (
      if newurl != nil then
        newurl
      else
        sprintf("http://%s/", @host)
      end
    )
    tryagain = false
    $stderr.printf("[%s] get(%p) ... ", Time.now.strftime("%T"), @finalurl)
    begin
      if (level == 5) then
        raise HTTP::RequestError, "too many redirects"
      end
      # first, retrieve the URL as-is
      @finalresponse = HTTP.timeout(10).get(@finalurl, ssl_context: @sslctx)
      $stderr.printf("received HTTP status %d %p", @finalresponse.code, @finalresponse.reason)
      if @finalresponse.code == 200 then
        @cached_isavailable = true
      else
        #if there is a HTTP redirect, keep a note, and continue with new url
        if (loc = @finalresponse["location"]) != nil then
          tryagain = true
          if loc.match?(/^https?:\/\//) then
            newurl = loc
          else
            newurl = URI.join(@finalurl, loc)
          end
          @redirection = newurl
        else
          @cached_isavailable = false
        end
      end
    rescue => ex
      $stderr.printf("failed: (%s) %s", ex.class.name, ex.message)
      @cached_isavailable = false
    ensure
      $stderr.print("\n")
    end
    if tryagain then
      check_isavail(newurl: newurl, level: level+1)
    end
  end

  def have_nodes(nodes)
    return (
      (nodes != nil) &&
      (nodes != []) &&
      (not nodes.empty?)
    )
  end

  # extract the wildly ridiculous meta-refresh shit
  # todo: also check for <noscript>? but who even uses that anymore?
  def deparse_metarefresh(metanode)
    if metanode.attributes.key?("http-equiv") then
      httpequiv = metanode.attributes["http-equiv"].to_s
      if httpequiv.downcase == "refresh" then
        content = metanode["content"]
        _, *rest = content.split(";")
        desturlfrag = rest.join(";").scrub.strip.gsub(/^url\s*=/i, "").strip
        # apparently some browsers allow stuff like content="0; url='http://...'"
        # so we need to check for that
        if (desturlfrag[0] == '\'') || (desturlfrag[0] == '"') then
          desturl = desturl[1 .. -1]
        end
        if (desturlfrag[-1] == '\'') || (desturlfrag[-1] == '"') then
          desturlfrag = desturlfrag[0 .. -2]
        end
        desturlfrag.strip!
        if not desturlfrag.empty? then
          # urls can be relative
          if not desturlfrag.match?(/^\w+:\/\//) then
            return URI.join(@finalurl, desturlfrag)
          end
          return desturlfrag
        end
      end
    end
    return nil
  end

  def find_metarefresh(metanodes)
    if have_nodes(metanodes) then
      metanodes.each do |metanode|
        if (url = deparse_metarefresh(metanode)) != nil then
          return url
        end
      end
    end
    return nil
  end

  def main
    # these files are only written if there was some kind of response
    opathhead = File.join(@outputdir, "head", sprintf("%s.yml", @host))
    opathbody = File.join(@outputdir, "body", sprintf("%s.html", @host))
    return if File.file?(opathhead)
    check_isavail
    res = @finalresponse
    data = {
      "available" => @cached_isavailable,
    }
    dummy = {"headers" => {}}
    if res != nil then
      ctype = res["content-type"]
      if @redirection != nil then
        data["redirect"] = @redirection.to_s
        data["redirtype"] = "http-location"
      end
      res.headers.each do |k, v|
        next if v.empty?
        dumped = v.dump[1 .. -2]
        dummy["headers"][k.downcase] = dumped
      end
      body = res.body.to_s.scrub
      if ctype != nil then
        # this is a deliberately placed duplicate field!
        data["content-type"] = ctype
        if ctype.match?(/text\/html/) then
          doc = Nokogiri::HTML(body)
          tnodes = doc.css("title")
          metanodes = doc.css("meta")
          if have_nodes(tnodes) then
            txt = tnodes.first.text
            $stderr.printf("    title = %p\n", txt)
            data["title"] = txt
          end
          if (url = find_metarefresh(metanodes)) != nil then
            data["redirect"] = url
            data["redirtype"] = "meta-refresh" 
          end
        end
      end
      FileUtils.mkdir_p(File.join(@outputdir, "head"))
      FileUtils.mkdir_p(File.join(@outputdir, "body"))
      $stderr.printf("    writing %p and %p ...\n", opathhead, opathbody)
      File.open(opathhead, "wb") do |ofh|
        MiniYAMLDump.new(data, ofh).write
        MiniYAMLDump.new(dummy, ofh).write
      end
      File.open(opathbody, "wb") do |ofh|
        ofh.puts(body)
      end
      return true
    end
    return false
  end
end

class DomainSearch
  def initialize(opts)
    @opts = opts
    @badjson = File.join(@opts.outputdir, "badhosts.json")
    @badhosts = (
      if File.file?(@badjson) then
        JSON.load(File.read(@badjson))
      else
        []
      end
    )
  end
    
  def fromword(word)
    TLDS.each do |tld|
      host = (word + "." + tld)
      if not @badhosts.include?(host) then
        begin
          if not HostSearch.new(self, @opts, host).main then
            @badhosts.push(host)
          end
          $stderr.puts("-------------------------------------------\n")
        rescue => ex
          $stderr.printf("    shouldn't happen: exception outside #main: (%s) %s\n", host, ex.class.name, ex.message)
        end
      end
    end
  end

  def fromio(fh)
    seen = []
    fh.each_line do |line|
      word = line.strip.scrub
      next if word.empty?
      next if word.match?(/^\s*#/)
      #next if not word.match?(/^\w+$/)
      word.downcase!
      next if seen.include?(word)
      fromword(word)
    end
  end

  def fromfile(file)
    File.open(file, "rb") do |fh|
      fromio(fh)
    end
  end

  def writecache
    if @badjson.length > 0 then
      File.write(@badjson, JSON.pretty_generate(@badhosts))
    end
  end

end

begin
  opts = OpenStruct.new({
    outputdir: nil,
  })
  OptionParser.new{|prs|

  }.parse!
  if ARGV.empty? then
    $stderr.printf("usage: gen <file containing hostname words> ...\n")
    $stderr.printf("nb: the file should be one word per line!\n")
  else
    ARGV.each do |arg|
      if File.file?(arg) then
        if opts.outputdir == nil then
          base = File.basename(arg)
          ext = File.extname(base)
          stem = File.basename(base, ext)
          name = ("out_" + stem)
          opts.outputdir = name
        end
        ds = DomainSearch.new(opts)
        begin
          ds.fromfile(arg)
        ensure
          ds.writecache
        end
      else
        $stderr.printf("not a file: %p\n", arg)
      end
    end
  end
end
