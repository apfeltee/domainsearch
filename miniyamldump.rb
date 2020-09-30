#!/usr/bin/ruby -w

class MiniYAMLDump
  class Pair < Array
  end

  def initialize(data, iorec)
    @data = data
    @out = iorec
    @indent = 0
    @level = 0
    @wasobject = false
  end

  # go up in indentation, unless it's the root item
  def levup
    if @level > 0 then
      @indent += 1
    end
  end

  # go down in indentation
  def levdown
    @indent -= 1
    if (@indent < 0) then
      @indent = 0
    end
  end

  # print to @out without indentation
  def oprnt(fmt, *a, **kw)
    if (a.empty? && kw.empty?) then
      @out.print(fmt)
    else
      @out.printf(fmt, *a, **kw)
    end
  end

  # print to @out with added indentation
  def iprnt(fmt, *a, **kw)
    @out.print("    " * @indent)
    oprnt(fmt, *a, **kw)
  end

  def as_object(&b)
    begin
      @wasobject = true
      b.call
    ensure
      @wasobject = false
    end
  end

  def maybe_linefeed
    if @wasobject then
      oprnt("\n")
    end
  end

  def do_item(itm)
    if (@level > 0) && (itm === @data) then
      iprnt("{...recursion...}")
    elsif itm.is_a?(Hash) then
      levup
      as_object() do
        maybe_linefeed
        itm.each do |key, value|
          iprnt("")
          do_item(key)
          oprnt(": ")
          do_item(value)
          oprnt("\n")
        end
      end
      levdown
    elsif itm.is_a?(Array) then
      levup
      as_object() do
        maybe_linefeed
        itm.each do |val|
          iprnt("- ")
          do_item(val)
          oprnt("\n")
        end
      end
      levdown
    elsif itm.is_a?(String) then
      itm.scrub!
      if itm.match?(/^[\w\.\-]+$/i) then
        oprnt(itm)
      else
        oprnt(itm.dump)
      end
    elsif itm.is_a?(Symbol)
      do_item(itm.to_s)
    elsif itm.is_a?(Regexp) then
      do_item(itm.source)
    else
      if itm.respond_to?(:to_h) then
        do_item(itm.to_h)
      elsif itm.respond_to?(:to_a) then
        do_item(itm.to_a)
      else
        oprnt(itm.inspect)
      end
    end
    @level += 1
  end

  def write
    #oprnt("---\n")
    do_item(@data)
  end

  def self.dump_to_io(data, io)
    MiniYAMLDump.new(data, io).write
  end

  def self.dump(data)
    buf = StringIO.new
    MiniYAMLDump.new(data, buf).write
    return buf.string
  end
end


