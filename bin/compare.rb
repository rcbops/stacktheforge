#!/usr/bin/ruby

require 'pp'
require 'yaml'
require 'open-uri'
require 'optparse'
require 'tempfile'
require 'deep_merge'

# StackForge project
STACKFORGE_GITHUB_URL = 'https://raw.github.com/stackforge'

# RPC->StackForge
NAME_MAP = {
  'ceilometer'   => 'metering',
  'cinder'       => 'block-storage',
  'glance'       => 'image',
  'heat'         => 'orchestration',
  'horizon'      => 'dashboard',
  'keystone'     => 'identity',
  'nova'         => 'compute',
  'nova-network' => 'networking',
  'swift-lite'   => 'object-storage',
}

# stubs for parsing the attributes file
def platform?; "ubuntu"; end
def platform_family?; "debian"; end

@platform_family = "debian"
@platform        = "ubuntu"
@lsb             = { 'codename' => 'precise' }
@kernel          = { 'release'  => '3.8', 'machine' => 'x86_64' }
@default         = Hash.new{ |h,k| h[k] = Hash.new(&h.default_proc) }
@override        = Hash.new{ |h,k| h[k] = Hash.new(&h.default_proc) }
@default_unless  = Hash.new{ |h,k| h[k] = Hash.new(&h.default_proc) }

# rescope_vars
#
# Iterates over each line of an attributes file and converts all occurrences
# of default/default_unless/override/etc into instance variables so they
# can be in scope when the file is read with `require_relative'.  Also 
# defangs calls to node[] by surrounding the variable with quotes.
#
def rescope_vars(contents)
  contents.each do |line|
    line.gsub!(/(default|default_unless|override|kernel|lsb)\[/, "@\\1[");
    line.gsub!(/([^'"])platform/, "\\1@platform");
    line.gsub!(/platform_family/, '@platform_family');

    node_regex = %r{[^'"](node(\[['"]\w+['"]\]){1,})}
    while line =~ node_regex
      node = $1
      q = (node =~ /'/) ? '"' : "'"
      defanged =  q + node + q
      line.gsub!(/#{Regexp.quote(node)}/, defanged)
    end
  end
  contents
end

#
# handle ARGV
#
options = {}
OptionParser.new(nil, 25) do |opts|
  opts.banner = "usage: #{File.basename($0)} [options] <YAML_FILE>"

  opts.on('-n', '--name <COOKBOOK>',
          "Name of StackForge cookbook (can be shortened)") do |n|
    options[:bookname] = n
  end
  opts.on('-h', '--help', "This useless garbage") do
    puts opts
    exit
  end

  begin
    opts.parse!
  rescue OptionParser::ParseError => e
    $stderr.puts e.message, "\n", opts
    exit(-1)
  end

  # make sure we have a positional argument for filename
  if ARGV.length != 1
    puts opts
    exit(-1)
  end
  options[:file] = ARGV[0]
end

# check file exists
if not File.exists? options[:file]
  $stderr.puts "ERROR: file `#{options[:file]}' does not exist"
  exit(1)
end

#
# determine name of target stackforge cookbook
#
cookbook  = ''
if options.has_key? :bookname
  cookbook = options[:bookname]
else
  # derive from name of yaml file
  basename = File.basename(options[:file], ".yml")
  if NAME_MAP.has_key? basename
    cookbook = NAME_MAP[basename]
  end
end

if cookbook.empty?
  $stderr.puts "couldn't determine stackforge book name from yaml file name;"
  $stderr.puts "please use --name option to be explicit."
  exit(1)
end

# prepend "cookbook-openstack-" if necessary
cookbook = "cookbook-openstack-#{cookbook}" if cookbook !~ /^cookbook/

#
# load YAML now to make sure file is valid
#
begin
  yaml = YAML.load_file(options[:file])
rescue => e
  $stderr.puts "ERROR: couldn't load YAML from `#{options[:file]}':"
  $stderr.puts e.message
  exit(1)
end

#     TODO also fetch and parse openstack-common.
#       turn a bunch of the following sections into methods.
#
# fetch latest attributes file from github
#
begin
  url = File.join(STACKFORGE_GITHUB_URL, cookbook,"master/attributes/default.rb")
  upstream_content = open(url).readlines
rescue => e
  $stderr.puts "ERROR: couldn't fetch #{url}:"
  $stderr.puts e.message
  exit(1)
end

#
# rescope the variables and write new file
#
begin
  tmpfile = Tempfile.new(cookbook)
  tmpfile.puts(rescope_vars(upstream_content))
  tmpfile.close
rescue => e
  $stderr.puts "ERROR: writing tempfile #{tmpfile.path}:"
  $stderr.puts e.message
  tmpfile.unlink
  exit(1)
end

#
# rename tmpfile so we can load it (add .rb extension)
#
begin
  newfile = tmpfile.path + ".rb"
  File.rename(tmpfile.path, newfile)
rescue => e
  $stderr.puts "ERROR: renaming tempfile #{tmpfile.path}:"
  $stderr.puts e.message
  File.unlink(newfile)
  exit(1)
ensure
  tmpfile.unlink
end

#
# load attribute file
#
begin
  require newfile
rescue LoadError => e
  $stderr.puts "ERROR: could not require '#{newfile}':"
  $stderr.puts e.message
  File.unlink(newfile)
  exit(1)
end

# 
# merge different attributes into final hash by precedence
#
theirs = {}
theirs.merge!(@default_unless)
theirs.merge!(@default)
theirs.merge!(@override)

ours = {}
yaml.keys.each do |k|
  next unless yaml[k].has_key?(:stack_name)

  name  = yaml[k][:stack_name]
  value = yaml[k][:stack_default]
  parts = name.split('.')
  hash_construction = {}
  
  parts.each_with_index.inject({}) do |memo, (e,i)|
    if hash_construction.empty?
      #puts "initializing outer array (i=#{i})"
      hash_construction[e] = {}
      hash_construction[e]
    else
      if i == (parts.size-1)
        #puts "we're at the end (i=#{i}), setting value #{value}"
        memo[e] = value
      else
        #puts "we're in the middle (i=#{i}, parts.size=#{parts.size})"
        memo[e] = {}
      end
      #puts "returning #{memo[e].class}"
      memo[e]
    end
  end
  ours.deep_merge!(hash_construction)
end

#
# TODO  Diff the hashes
#
if ours != theirs
  puts "hashes differ."

  #if ours.size != theirs.size
  #  puts "sizes different:"
  #  puts "ours:   #{ours.size}"
  #  puts "theirs: #{theirs.size}"
  #else
  #  puts "hashes are same size."
  #end

  #diff1 = ours.to_a - theirs.to_a
  #diff2 = theirs.to_a - ours.to_a

  #pp Hash[*diff1.flatten]
  #puts
  #pp Hash[*diff2.flatten]
else
  puts "hashes are equal."
end

File.unlink(newfile)
