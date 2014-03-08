#!/usr/bin/ruby

require 'yaml'
require 'optparse'
require 'tempfile'
require 'open-uri'

# rubygems
require 'deep_merge'
require 'awesome_print'

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

# common cookbook and its attribute files
COOKBOOK_COMMON = 'cookbook-openstack-common'
COMMON_FILES = %w{
  master/attributes/default.rb
  master/attributes/database.rb
  master/attributes/messaging.rb 
}

# ansi colors
RED="\e[31m"
GRN="\e[32m"
YLW="\e[33m"
CYN="\e[36m"
RST="\e[0m"

def red(txt);    @options[:color] ? "#{RED}#{txt}#{RST}" : txt; end
def green(txt);  @options[:color] ? "#{GRN}#{txt}#{RST}" : txt; end
def yellow(txt); @options[:color] ? "#{YLW}#{txt}#{RST}" : txt; end
def cyan(txt);   @options[:color] ? "#{CYN}#{txt}#{RST}" : txt; end

# stubs for parsing cookbook attributes file
def platform?; "ubuntu"; end
def platform_family?; "debian"; end
@platform_family = "debian"
@platform        = "ubuntu"
@lsb             = { 'codename' => 'precise' }
@kernel          = { 'release'  => '3.8', 'machine' => 'x86_64' }

# Hash#deep_diff
#
# return a hash containing nested subkeys for keys in `other' hash which are
# either missing or have different values.  Each leaf key in the returned hash
# will point to a 2-element array; this array contains our current value for
# the key and the `other' hash's value for it (if any).
#
class Hash
  def deep_diff(other)
    a = self
    b = other
    (a.keys | b.keys).inject({}) do |diff, k|
      if a[k] != b[k]
        if a[k].respond_to?(:deep_diff) && b[k].respond_to?(:deep_diff)
          diff[k] = a[k].deep_diff(b[k])
        else
          diff[k] = [a[k], b[k]]
        end
      end
      diff
    end
  end
end

# get_sha
#
# find commit SHA from `SOURCES' file
#
# returns sha string
#
def get_sha(bookname)
  file = @options[:sources]
  sha  = ''

  begin
    File.open(file).readlines.each do |l|
      if l =~ /\s*^([a-f0-9]+) \s*#{Regexp.quote(bookname)}\s*$/
        sha = $1
        break
      end
    end
  rescue => e
    $stderr.puts "couldn't read SHA for `#{bookname}' from `#{file}'"
    exit(1)
  end

  if sha.empty? or (sha.length != 40)
    $stderr.puts "couldn't find valid SHA for `#{bookname}' from `#{file}'"
    exit(1)
  end
  sha
end

# fetch_raw
#
# HTTP/GET latest attributes file from github.com
#
# return array of lines
#
def fetch_raw(bookname, path='master/attributes/default.rb')
  begin
    url = File.join(STACKFORGE_GITHUB_URL, bookname, path)
    open(url).readlines
  rescue => e
    $stderr.puts "ERROR: couldn't fetch #{url}:"
    $stderr.puts e.message
    exit(1)
  end
end

# prepare_import
#
# rescope attribute variables and write to tempfile.
#
# returns string for file path
#
def prepare_import(content, var_append='_new')
  begin
    tmpfile = Tempfile.new("rescope#{var_append}-")
    tmpfile.puts(rescope_vars(content, var_append))
    tmpfile.close
    #puts File.open(tmpfile.path).readlines
  rescue => e
    $stderr.puts "ERROR: writing tempfile #{tmpfile.path}:"
    $stderr.puts e.message
    tmpfile.unlink
    exit(1)
  end

  # rename tmpfile so we can load it (add .rb extension)
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

  newfile
end

# rescope_vars
#
# Iterate each line of attributes file and convert all occurrences of
# default/default_unless/override/etc to instance variables (so they can be in
# scope when the file is read with `require_relative').  Also defang calls to
# node[] by surrounding the variable with quotes.
#
# return array of lines
#
def rescope_vars(content, append='_new')
  content.inject([]) do |memo, l|
    # preserve the original data since we need it for diff mode (options[:diff])
    line = l.dup

    # replace default[] with @default_new[]
    line.gsub!(/(default|default_unless|override)\[/, "@\\1#{append}[")

    # replace kernel[] with @kernel[]
    line.gsub!(/(kernel|lsb)\[/, "@\\1[")

    # replace `platform' variable (not platform node attribute) with @platform
    line.gsub!(/([^'"])platform/, "\\1@platform")

    # replace platform_family variable with @platform_family
    line.gsub!(/platform_family/, '@platform_family')

    # regex to identify node[][]..[] variables
    node_regex = %r{[^'"](node((\[['"][^'"]+['"]\]){1,}))}

    while line =~ node_regex
      node = $1                       # grab the whole attribute
      keys = $2                       # grab all the subkeys
      #q = (node =~ /'/) ? '"' : "'"   # choose appropriate quotes to use
      #defanged =  q + node + q        # surround with quotes
      line.gsub!(/#{Regexp.quote(node)}/, "@default#{append}#{keys}")
    end
    memo << line
  end
end

# import_rb_file
#
# `require' ruby file
#
def import_rb_file(file)
  begin
    require file
  rescue LoadError => e
    $stderr.puts "ERROR: could not require '#{file}':"
    $stderr.puts e.message
    File.unlink(file)
    exit(1)
  end
end

# generate_names
#
# walk hash and generate nested key names in dotted form,
# eg. key1.subkey1.subkey2.subkey3
#
# returns array ["path.to.key1", "path.to.key2"]
#
def generate_names(hash, path=[], all=[])
  hash.each do |k,v|
    path << k
    if v.class == Hash
      all = generate_names(v, path, all)
    else
      all << path.join('.')
      path.pop
    end
  end
  path.pop
  all
end

# get_attr_value
#
# find deep key value for dotted_name in hash.
#
def get_attr_value(hash, dotted_name)
  dotted_name.split('.').reduce({}) do |memo, e|
    if memo.class == Hash and memo.empty?
      hash[e]
    else
      if !memo.nil?
        memo[e]
      else
        # XXX badness
        #     apparently some hash keys are originally named by dotted names,
        #     eg.:
        #
        #     node['foo']['bar']['baz.wibble.blarg'] = true
        #
        #   this results in dotted name `foo.bar.baz.wibble.blarg', which
        #   cannot be decoded successfully and results in a reconstructed
        #   hash which looks like:
        #
        #     node['foo']['bar']['baz']['wibble']['blarg'] = true
        #
        $stderr.puts "WARNING: #{dotted_name} cannot be resolved--bad attribute"
        break
      end
    end
  end
end

# convert_nil
#
# examine variable and return pretty-printable string for empty or nil types
#
def convert_nil(obj)
  if obj.class == NilClass
    'nil'
  elsif obj.class == String and obj.empty?
    "''"
  else
    obj
  end
end


#
# parse ARGV
#
@options = { color: true }

OptionParser.new(nil, 25) do |opts|
  opts.banner = "usage: #{File.basename($0)} [options] <YAML_FILE>"

  opts.on('-n', '--name <COOKBOOK>',
          "Name of StackForge cookbook (can be shortened)") do |n|
    @options[:bookname] = n
  end
  opts.on('-d', '--diff', "Show unified diff for attributes files") do
    @options[:diff] = true
  end
  opts.on('-h', '--hash-diff',
          "Show data-structure diff between attribute hashes") do
    @options[:hash_diff] = true
  end
  opts.on('-a', '--all', "Diff ALL #{COOKBOOK_COMMON} attrs as well") do
    @options[:diff_all] = true
  end
  opts.on('-s', '--sources <FILE>', "Path to SOURCES file") do |s|
    @options[:sources] = s
  end
  opts.on('--no-color', '--no-colour', "Don't paint your rainbows at me") do
    @options[:color] = false
  end
  opts.on('--help', "This useless garbage") do
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
  @options[:yaml] = ARGV[0]
  @options[:sources] ||= File.join(File.dirname(ARGV[0]), 'SOURCES')
end

# ensure files exist
[@options[:yaml], @options[:sources]].each do |f|
  if not File.exists? f
    $stderr.puts "ERROR: file `#{f}' does not exist"
    exit(1)
  end
end

#
# determine name of target stackforge cookbook
#
cookbook  = ''
if @options.has_key? :bookname
  cookbook = @options[:bookname]
else
  # derive from name of yaml file
  basename = File.basename(@options[:yaml], ".yml")
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
# load YAML
#
begin
  yaml = YAML.load_file(@options[:yaml])
rescue => e
  $stderr.puts "ERROR: couldn't load YAML from `#{@options[:yaml]}':"
  $stderr.puts e.message
  exit(1)
end

# 
# reconstruct attribute hash from yaml file
#
yaml_names = []
yaml_reconstructed = {}

yaml.keys.each do |k|
  next unless yaml[k].has_key?(:stack_name)

  name  = yaml[k][:stack_name]
  value = yaml[k][:stack_default]
  parts = name.split('.')
  construction = {}

  yaml_names << name
  
  parts.each_with_index.inject({}) do |memo, (e,i)|
    if construction.empty?
      construction[e] = {}
      construction[e]
    else
      if i == (parts.size-1)
        #puts "DEBUG: assigning value `#{value}' (#{value.class}) for #{name}"
        memo[e] = value
      else
        memo[e] = {}
      end
      memo[e]
    end
  end
  #ap(construction, {indent:-2, sort_keys:true})
  yaml_reconstructed.deep_merge!(construction)
  #ap(yaml_reconstructed, {indent:-2, sort_keys:true})
end

#puts ""
#puts "DEBUG: LEFT CONSTRUCTION ZONE:"
#ap(yaml_reconstructed, {indent:-2, sort_keys:true})

#
# fetch latest attributes files from github
#
latest_content = fetch_raw(cookbook)
latest_common  = []
COMMON_FILES.each do |path|
  latest_common << fetch_raw(COOKBOOK_COMMON, path)
  latest_common.flatten!
end

#
# rescope variables and write new files
#
# notice how the instance variable names match the `append' parameter
# passed to prepare_import().  Not so DRY... lazy; dirty.
#
import_list = []

@default_new        = Hash.new{ |h,k| h[k] = Hash.new(&h.default_proc) }
@override_new       = Hash.new{ |h,k| h[k] = Hash.new(&h.default_proc) }
@default_unless_new = Hash.new{ |h,k| h[k] = Hash.new(&h.default_proc) }
import_list << prepare_import(latest_content, '_new')

@default_common_new        = Hash.new{ |h,k| h[k] = Hash.new(&h.default_proc) }
@override_common_new       = Hash.new{ |h,k| h[k] = Hash.new(&h.default_proc) }
@default_unless_common_new = Hash.new{ |h,k| h[k] = Hash.new(&h.default_proc) }
import_list << prepare_import(latest_common, '_common_new')

#
# if user wants a file diff(1), prepare previous attributes file
# (given by SOURCES file) by rescoping vars and adding to import_list
#
if @options[:diff] or @options[:hash_diff]
  prev_content = fetch_raw(cookbook, "#{get_sha(cookbook)}/attributes/default.rb")
  prev_common  = fetch_raw(COOKBOOK_COMMON,
                           "#{get_sha(COOKBOOK_COMMON)}/attributes/default.rb")

  @default_old        = Hash.new{ |h,k| h[k] = Hash.new(&h.default_proc) }
  @override_old       = Hash.new{ |h,k| h[k] = Hash.new(&h.default_proc) }
  @default_unless_old = Hash.new{ |h,k| h[k] = Hash.new(&h.default_proc) }
  import_list << prepare_import(prev_content, '_old')

  @default_common_old        = Hash.new{ |h,k| h[k] = Hash.new(&h.default_proc)}
  @override_common_old       = Hash.new{ |h,k| h[k] = Hash.new(&h.default_proc)}
  @default_unless_common_old = Hash.new{ |h,k| h[k] = Hash.new(&h.default_proc)}
  import_list << prepare_import(prev_common, '_common_old')
end

#
# import scoped files
#
import_list.each do |f|
  import_rb_file(f)
end

#
# merge different node attributes by precedence into a final hash
#
latest_tree = {}
latest_tree.merge!(@default_unless_new)
latest_tree.merge!(@default_new)
latest_tree.merge!(@override_new)

#puts "DEBUG: latest_tree before common"
#ap(latest_tree, {indent:-2, sort_keys:true})

latest_tree_common = {}
latest_tree_common.merge!(@default_unless_common_new)
latest_tree_common.merge!(@default_common_new)
latest_tree_common.merge!(@override_common_new)

#puts "DEBUG: latest_tree_common before final merge"
#ap(latest_tree_common, {indent:-2, sort_keys:true})

# final hash
latest_tree_final = latest_tree.deep_merge!(latest_tree_common)

#puts "DEBUG: latest_tree_final AFTER common"
#ap(latest_tree_final, {indent:-2, sort_keys:true})


if @options[:diff] or @options[:hash_diff]
  prev_tree = {}
  prev_tree.merge!(@default_unless_old)
  prev_tree.merge!(@default_old)
  prev_tree.merge!(@override_old)

  prev_tree_common = {}
  prev_tree_common.merge!(@default_unless_common_old)
  prev_tree_common.merge!(@default_common_old)
  prev_tree_common.merge!(@override_common_old)
  # final hash
  prev_tree_final = prev_tree.deep_merge!(prev_tree_common)
  #ap(prev_tree_final, {indent:-2, sort_keys:true})
end

#
# ensure all keys in YAML are contained in latest file
#
latest_names = generate_names(latest_tree_final)
yaml_names.each do |n|
  if latest_names.include?(n)
    ours   = get_attr_value(yaml_reconstructed, n)
    theirs = get_attr_value(latest_tree_final, n)
    if ours != theirs
      puts "#{yellow(n)}: #{convert_nil(ours)} (#{cyan(ours.class)})" +
           " => #{convert_nil(theirs)} (#{cyan(theirs.class)})"
    end
  else
    puts red("#{n} is missing!")
  end
end

#
# Textual diff
#
if @options[:diff]
  if @options[:diff_all] # diff openstack-common files if --all option
    begin
      tmp_prev_common = Tempfile.new("prev-")
      tmp_prev_common.puts(prev_common)
      tmp_prev_common.close

      tmp_latest_common = Tempfile.new("LATEST-")
      tmp_latest_common.puts(latest_common)
      tmp_latest_common.close
    rescue => e
      $stderr.puts "ERROR: writing tempfiles for diff(1):"
      $stderr.puts e.message
      [tmp_prev_common, tmp_latest_common].each do |t|
        File.exists?(t.path) and t.unlink
      end
      exit(1)
    end
    puts
    puts "============================================================"
    puts " Diffs for #{COOKBOOK_COMMON}"
    puts "============================================================"
    system("diff -U3 #{tmp_prev_common.path} #{tmp_latest_common.path}")
  end

  begin
    tmp_prev = Tempfile.new("prev-")
    tmp_prev.puts(prev_content)
    tmp_prev.close

    tmp_latest = Tempfile.new("LATEST-")
    tmp_latest.puts(latest_content)
    tmp_latest.close
  rescue => e
    $stderr.puts "ERROR: writing tempfiles for diff(1):"
    $stderr.puts e.message
    [tmp_prev, tmp_latest].each { |t| File.exists?(t.path) and t.unlink }
    exit(1)
  end
  puts
  puts "============================================================"
  puts " Diffs for #{cookbook}"
  puts "============================================================"
  system("diff -U3 #{tmp_prev.path} #{tmp_latest.path}")
end

#
# Hash diff
#
if @options[:hash_diff]
  if @options[:diff_all]  # diff openstack-common hashes if --all option
    puts
    puts "============================================================"
    puts " Data structure diff for #{COOKBOOK_COMMON}"
    puts "  < [0] previous value"
    puts "  > [1] upstream value"
    puts "============================================================"
    ap(prev_tree_common.deep_diff(latest_tree_common),
       {indent:-2, sort_keys:true})
  end
  puts
  puts "============================================================"
  puts " Data structure diff for #{cookbook}"
  puts "  < [0] previous value"
  puts "  > [1] upstream value"
  puts "============================================================"
  ap(prev_tree.deep_diff(latest_tree), {indent:-2, sort_keys:true})
end

#
# cleanup temp files
#
import_list.each do |f|
  File.exists?(f) and File.unlink(f)
end
