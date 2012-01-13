#!/usr/bin/env ruby

require 'find'
require 'tempfile'
require 'pathname'

script_dir = File.dirname(__FILE__)

$LOAD_PATH.unshift(script_dir + '/.') unless $LOAD_PATH.include?(script_dir + '/.')
$LOAD_PATH.unshift(script_dir + '/./lib') unless $LOAD_PATH.include?(script_dir + '/./lib')

#puts "LOAD_PATH: #{$LOAD_PATH.inspect}\n" # nice debugging

require 'vcproj2cmake/util_file' # V2C_Util_File.mkdir_p()

# load common settings
load 'vcproj2cmake_settings.rb'

script_fqpn = File.expand_path $0
script_path = Pathname.new(script_fqpn).parent
source_root = Dir.pwd

if not File.exist?($v2c_config_dir_local)
  FileUtils.mkdir_p $v2c_config_dir_local
end

time_cmake_root_folder = 0
arr_excl_proj = Array.new()
time_cmake_root_folder = File.stat($v2c_config_dir_local).mtime.to_i
excluded_projects = "#{$v2c_config_dir_local}/project_exclude_list.txt"
if File.exist?(excluded_projects)
  f_excl = File.new(excluded_projects, 'r')
  f_excl.each do |line|
    # TODO: we probably need a per-platform implementation,
    # since exclusion is most likely per-platform after all
    arr_excl_proj.push(line.chomp)
  end
  f_excl.close
end

# FIXME: should _split_ operation between _either_ scanning entire .vcproj hierarchy into a
# all_sub_projects.txt, _or_ converting all sub .vcproj as listed in an existing all_sub_projects.txt file.
# (provide suitable command line switches)
# Hmm, or perhaps port _everything_ back into vcproj2cmake.rb,
# providing --recursive together with --scan or --convert switches for all_sub_projects.txt generation or use.

# write into temporary file, to avoid corrupting previous CMakeLists.txt due to syntax error abort, disk space or failure issues
tmpfile = Tempfile.new('vcproj2cmake_recursive')
projlistfile = File.open(tmpfile.path, 'w')

Find.find('./') do
  |f|
  # skip symlinks since they might be pointing _backwards_!
  next if FileTest.symlink?(f)
  next if not test(?d, f)

  # skip CMake build directories! (containing CMake-generated .vcproj files!)
  # FIXME: more precise checking: check file _content_ against CMake generation!
  is_excluded = false
  if f =~ /^build/i
    is_excluded = true
  else
    arr_excl_proj.each do |excluded|
      # Tech note: we could have pre-stored the full regex expression
      # in the original array already, but this would be less flexible,
      # thus recreate the regex on each loop:
      excl_regex = "^\.\/#{excluded}$"
      #puts "MATCH: #{f} vs. #{excl_regex}"
      if f.match(excl_regex)
        is_excluded = true
        break
      end
    end
  end
  #puts "excluded: #{is_excluded}"
  if is_excluded == true
    puts "EXCLUDED #{f}!"
    next
  end

  puts "processing #{f}!"
  dir_entries = Dir.entries(f)
  #puts "entries: #{dir_entries}"
  vcproj_files = dir_entries.grep(/\.vcproj$/i)
  #puts vcproj_files

  # No project file type at all? Immediately skip directory.
  next if vcproj_files.nil?

  # in each directory, find the .vcproj file to use.
  # Prefer xxx_vc8.vcproj, but in cases of directories where this is
  # not available, use a non-_vc8 file.
  projfile = nil
  vcproj_files.each do |vcproj_file|
    if vcproj_file =~ /_vc8.vcproj$/i
      # ok, we found a _vc8 version, quit searching since this is what we prefer
      projfile = vcproj_file
      break
    end
    if vcproj_file =~ /.vcproj$/i
      projfile = vcproj_file
	# do NOT break here (another _vc8 file might come along!)
    end
  end
  #puts "projfile is #{projfile}"

  # No project file at all? Skip directory.
  next if projfile.nil?

  # Check whether the directory already contains a CMakeLists.txt,
  # and if so, whether it can be safely rewritten:
  if (!dir_entries.grep(/^CMakeLists.txt$/i).empty?)
    #puts dir_entries
    #puts "CMakeLists.txt exists in #{f}, checking!"
    f_cmakelists = File.new("#{f}/CMakeLists.txt", 'r')
    auto_generated = f_cmakelists.grep(/AUTO-GENERATED by/)
    f_cmakelists.close
    if (auto_generated.empty?)
      puts "existing #{f}/CMakeLists.txt is custom, \"native\" form --> skipping!"
      next
    else
	# ok, it _is_ a CMakeLists.txt, but a temporary vcproj2cmake one
	# which we can overwrite.
      puts "existing #{f}/CMakeLists.txt is our own auto-generated file --> replacing!"
    end
  end

  # Now proceed with conversion of .vcproj file:

  # Detect .vcproj files actually generated by CMake generator itself:
  f_vcproj = File.new("#{f}/#{projfile}", 'r')
  cmakelists_text = f_vcproj.grep(/CMakeLists.txt/)
  f_vcproj.close
  if not cmakelists_text.empty?
    puts "Skipping CMake-generated MSVS file #{f}/#{projfile}"
    next
  end

  if projfile =~ /_vc8.vcproj$/i
  else
    puts "Darn, no _vc8.vcproj in #{f}! Should have offered one..."
  end
  # verify age of .vcproj file... (NOT activated: experimental feature!)
  rebuild = 0
  if File.exist?("#{f}/CMakeLists.txt")
    # is .vcproj newer (or equal: let's rebuild copies with flat timestamps!)
    # than CMakeLists.txt?
    # NOTE: if we need to add even more dependencies here, then it
    # might be a good idea to do this stuff properly and use a CMake-based re-build
    # infrastructure instead...
    # FIXME: doesn't really seem to work... yet?
    time_proj = File.stat("#{f}/#{projfile}").mtime.to_i
    time_cmake_folder = 0
    if File.exist?("#{f}/#{$v2c_config_dir_local}")
      time_cmake_folder = File.stat("#{f}/#{$v2c_config_dir_local}").mtime.to_i
    end
    time_CMakeLists = File.stat("#{f}/CMakeLists.txt").mtime.to_i
    #puts "TIME: CMakeLists #{time_CMakeLists} proj #{time_proj} cmake_folder #{time_cmake_folder} cmake_root_folder #{time_cmake_root_folder}"
    if time_proj > time_CMakeLists
      #puts "modified: project!"
      rebuild = 1
    elsif time_cmake_folder > time_CMakeLists
      #puts "modified: cmake/!"
      rebuild = 1
    elsif time_cmake_root_folder > time_CMakeLists
      #puts "modified: cmake/ root!"
      rebuild = 1
    end
  else
    # no CMakeLists.txt at all, definitely process this project
    rebuild = 2
  end
  if rebuild > 0
    #puts "REBUILD #{f}!! #{rebuild}"
  end
  #puts "#{f}/#{projfile}"
  # see "A dozen (or so) ways to start sub-processes in Ruby: Part 1"
  puts "launching ruby #{script_path}/vcproj2cmake.rb '#{f}/#{projfile}' '#{f}/CMakeLists.txt' '#{source_root}'"
  output = `ruby #{script_path}/vcproj2cmake.rb '#{f}/#{projfile}' '#{f}/CMakeLists.txt' '#{source_root}'`
  puts "output was:"
  puts output

  # the root directory is special: it might contain another project (it shouldn't!!),
  # thus we need to skip it if so (then include the root directory
  # project by placing a CMakeLists_native.txt there and have it include the
  # auto-generated CMakeLists.txt)
  if not f == './'
    if f.include? ' ' # quote strings containing spaces!!
      projlistfile.puts("add_subdirectory( \"#{f}\" )")
    else
      projlistfile.puts("add_subdirectory( #{f} )")
    end
  end
  #output.split("\n").each do |line|
  #  puts "[parent] output: #{line}"
  #end
  #puts
end

# Make sure to close it:
projlistfile.close

# make sure to close that one as well...
tmpfile.close

output_file = "#{$v2c_config_dir_local}/all_sub_projects.txt"

# FIXME: implement common helper for tmpfile renaming as done in
# vcproj2cmake.rb, then use it here as well.

V2C_Util_File.chmod($v2c_cmakelists_create_permissions, tmpfile.path)
V2C_Util_File.mv(tmpfile.path, output_file)
