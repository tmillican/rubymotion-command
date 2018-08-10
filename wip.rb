# autorun:
# brew install fswatch
# fswatch ./wip.rb | xargs -n1 -I{} ruby ./wip.rb

require 'open3'
#require 'pp'

# Represents a set of test data comprising the result of a single test.
#
# Ex: a collection of detected OSX framework versions.
class TestResult
  # The name of the test result. Used as the label in test reports.
  attr_accessor :name,
                # An array of TestDatum objects comprising the TestResult
                :data

  def initialize name='', data=[]
    @name = name
    @data = data
  end

  def add datum
    @data << datum
  end
end



# Represents a single data point of a TestResult.
class TestDatum
  # The value of the test datum.
  attr_accessor :value

  # The status of the test datum. May be:
  #
  # * +:good+ - Indicates success or an acceptable value
  # * +:maybe+ - Indicates a possible, but not certain problem
  # * +:bad+ - Indicates failure or a problematic value
  # * +:neutral+ - Indicates an informational result, or that we just don't care
  attr_accessor :status

  # Meta information/description that we'd like to pass along with the result
  # is :status_maybe or :status_bad
  attr_accessor :meta

  def initialize value=nil, status=:good, meta=nil
    @value = value
    @status = status
    @meta = meta
  end

  def is_good?
    status == :good
  end

  def is_maybe?
    status == :maybe
  end

  def is_bad?
    status == :maybe
  end

  def is_netural?
    status == :neutral
  end
end



# Represents the result of a shell command
class CommandResult
  # Stdout capture of command
  attr_accessor :stdout

  # Stderr capture of command
  attr_accessor :stderr

  # Exit status of the command, *if* it could be executed
  attr_accessor :exit

  # Overall status of the command. May be:
  #
  # * +:success+ - command executed with exit code 0
  # * +:failure+ - command executed with non-zero exit code
  # * +:not_found+ - command not found
  # * +:sys_failure+ - command couldn't execute for reasons other than command not found
  attr_accessor :status

  # The SystemCallError produced if the command couldn't be executed.
  attr_accessor :syserror

  def initialize command
    begin
      @stdout, @stderr, @exit = Open3.capture3 command
      if @exit == 0
        @status = :success
      else
        @status = :failure
      end
    rescue Errno::ENOENT => e
      @syserror = e
      @status = :not_found
    rescue SystemCallError => e
      @syserror = e
      @status = :sys_failure
    end
  end

  def success?
    @exit == 0
  end

  def executed?
    @syserror.nil?
  end
end



class Wip
  # -----------------------------------------------------------------------------
  # Output
  # -----------------------------------------------------------------------------

  # TODO: proper termcap-fu

  LABEL_WIDTH = 33
  COLS = 80
  ANSI = true
  if ANSI
    ANSI_PRE_GOOD = "\033[0;32m"
    ANSI_PRE_MAYBE = "\033[0;33m"
    ANSI_PRE_BAD = "\033[0;31m"
    ANSI_POST = "\033[0m"
  end

  def self.print_report_header title
    print "\n"
    print_spacer '='
    puts title
    print_spacer '='
    print "\n"
  end

  def self.print_section_header title
    print "\n"
    print_spacer '-'
    puts title
    print_spacer '-'
    print "\n"
  end

  def self.print_spacer fill_string, width=COLS
    print ''.ljust(width, fill_string)
    print "\n"
  end

  # Pretty-prints a TestResult object
  def self.print_test_result result
    result.data.each do |datum|
      if datum.equal? result.data.first
        print "#{result.name.ljust(LABEL_WIDTH)}: "
      else
        print(''.ljust(LABEL_WIDTH + 2, ' '))
      end

      case datum.status
      when :good
        print "#{ANSI_PRE_GOOD}#{datum.value}"
      when :maybe
        print "#{ANSI_PRE_MAYBE}#{datum.value}"
        print " (#{datum.meta})" unless datum.meta.to_s.empty?
      when :bad
        print "#{ANSI_PRE_BAD}#{datum.value}"
        print " (#{datum.meta})" unless datum.meta.to_s.empty?
      else
        print datum.value
      end
      print "#{ANSI_POST}\n"
    end
  end

  # -----------------------------------------------------------------------------
  # Environment Tests
  # -----------------------------------------------------------------------------

  def self.test_working_directory
    return TestResult.new('Working directory',
                   [ TestDatum.new(Dir.pwd, :neutral) ]),
           Dir.pwd
  end

  # -----------------------------------------------------------------------------
  # Installation Tests
  # -----------------------------------------------------------------------------

  def self.test_rubymotion_version
    result = TestResult.new 'RubyMotion version'

    cmd_name = 'motion'
    cmd = CommandResult.new "#{cmd_name} --version"

    # TODO: are some versions considered deprecated? EOL?
    case cmd.status
    when :success
      version_str = cmd.stdout.chop
      result.add(TestDatum.new version_str,
                               :good)
      version = {
        :major => version_str.sub(/^(\d+).\d+$/, '\1').to_i,
        :minor => version_str.sub(/^\d+.(\d+)$/, '\1').to_i,
      }
    when :not_found
      result.add(TestDatum.new 'Not found',
                               :bad)
    when :failure
      result.add(TestDatum.new 'Failed',
                               :bad,
                               "#{cmd_name} reports: '#{cmd.stderr}'")
    when :sys_failure
      result.add(TestDatum.new 'Failed',
                               :bad,
                               "System reports: '#{cmd.syserror.message}'")
    end
    return result, version
  end

  def self.test_rbenv_version
    result = TestResult.new 'rbenv version'

    cmd_name = 'rbenv'
    cmd = CommandResult.new "#{cmd_name} --version"

    case cmd.status
    when :success
      version_str = cmd.stdout.split(' ')[1]
      version_split = version_str.split('.')
      version = {
        :major => version_split[0],
        :minor => version_split[1],
        :very_minor => version_split[2],
      }
      result.add(
        TestDatum.new version_str,
                      :neutral)
    when :not_found
      result.add(TestDatum.new 'Not found',
                               :maybe,
                               "Recommended, but not required")
    when :failure
      # Even though rbenv isn't required, it's a problem if it's broken
      result.add(
        TestDatum.new 'Failed',
                      :bad,
                      "#{cmd_name} reports: '#{cmd.stderr}'")
    when :sys_failure
      # Likewise.
      result.add(
        TestDatum.new 'Failed',
                      :bad,
                      "System reports: '#{cmd.syserror.message}'")
    end

    return result, version
  end


  # Determines the Xcode version. Checks against the RubyMotion version for
  # version parity.
  def self.test_xcode_version rm_version

    rm_5_7 = { :major => 5, :minor => 7 }
    rm_5_8 = { :major => 5, :minor => 8 }
    rm_5_9 = { :major => 5, :minor => 9 }
    rm_5_10 = { :major => 5, :minor => 10 }

    xc_9_2 = { :major => 9, :minor => 2, :very_minor => 0 }
    xc_9_3 = { :major => 9, :minor => 3, :very_minor => 0 }
    xc_9_4 = { :major => 9, :minor => 4, :very_minor => 0 }

    rm_to_xcode_parities = {
      rm_5_7 => xc_9_2,
      rm_5_8 => xc_9_3,
      rm_5_9 => xc_9_4,
      rm_5_10 => xc_9_4,
    }
    expected_version = rm_to_xcode_parities[rm_version]
    expected_version ||= xc_9_4

    result = TestResult.new 'Xcode version'

    # Bail early if xcode-select doesn't give us a valid path. This indicates
    # that Xcode isn't installed at all, and we'll just wind up prompting the
    # user to install Xcode when we try to run `xcodebuild` below.
    if test_xcode_select_path[1].nil?
      result.add(
        TestDatum.new 'Not installed',
                      :bad)
      return result, nil
    end

    cmd_name = 'xcodebuild'
    cmd = CommandResult.new "#{cmd_name} -version"

    case cmd.status
    when :success
      version_str = cmd.stdout.split("\n")[0].split(' ')[1]
      version_split = version_str.split('.')
      version = {
        :major => version_split[0].to_i,
        :minor => version_split[1].to_i,
        :very_minor => version_split[2].to_i
      }
      datum = TestDatum.new version_str
      if version != expected_version
        datum.meta = "expected #{expected_version[:major]}" \
                     ".#{expected_version[:minor]}" \
                     ".#{expected_version[:very_minor]}"
        datum.status =
          # Having a very minor version above the expected is *maybe* okay.
          # TODO: This might be perfectly fine. Ask Amir. 9.4.1 is current, so
          # this is going to flag for a decent number of people.
          if version[:major] = expected_version[:major] and
            version[:minor] = expected_version[:minor] and
            version[:very_minor] > expected_version[:very_minor]
            :maybe
          else
            :bad
          end
      end
      result.add datum
    when :not_found
      result.add(
        TestDatum.new 'Not installed',
                      :bad,
                      "#{expected_version} required")
    when :failure
      result.add(
        TestDatum.new 'Failed',
                      :bad,
                      "#{cmd_name} reports: '#{cmd.stderr}'")
    when :sys_failure
      result.add(
        TestDatum.new 'Failed',
                      :bad,
                      "System reports: '#{cmd.syserror.message}'")
    end
    return result, version
  end

  def self.test_xcode_select_version
    result = TestResult.new 'xcode-select version'

    cmd_name = 'xcode-select'
    cmd = CommandResult.new "#{cmd_name} --version"

    # TODO: According to this: https://github.com/amirrajan/rubymotion-applied/issues/58
    # Xcode 9.2 should be paired with 2349. As far as I can tell from my own system,
    # that's still the xcode-select version present with 9.4.1 (latest non-beta)
    #
    # Since the RM version parities only go as far back as Xcode 9.2, I think
    # maybe we just unconditionally want 2349 now? I'm also unclear on what
    # exactly controls the xcode-select version. I'm pretty sure this stands alone from
    # Xcode, and would be relegated to the OSX version.
    case cmd.status
    when :success
      version_str = cmd.stdout.chop.sub(/^xcode-select version ([\.\d]+)\.$/, '\1')
      version = version_str.to_i
      if version == 2349
        result.add(
          TestDatum.new version_str,
                        :good)
      else
        result.add(
          TestDatum.new version,
                        :bad,
                        'expected 2349')
      end
    when :not_found
      result.add(
        TestDatum.new "#{cmd_name} not found",
                      :bad)
    when :failure
      result.add(
        TestDatum.new 'Indeterminate',
                      :bad,
                      "#{cmd_name} reports: '#{cmd.stderr}'")
    when :sys_failure
      result.add(
        TestDatum.new 'Failed',
                      :bad,
                      "System reports: '#{cmd.syserror.message}'")
    end
    return result, version
  end

  def self.test_xcode_select_path
    result = TestResult.new 'xcode-select path'

    cmd_name = 'xcode-select'
    cmd = CommandResult.new "#{cmd_name} --print-path"

    case cmd.status
    when :success
      path = cmd.stdout.chop
      case path
      when /CommandLineTools/
        result.add(
          TestDatum.new path,
                        :bad,
                        'path indicates a CLI-tool-only Xcode installation')
      when /Xcode\.app/
        result.add(
          TestDatum.new path)
      when /Xcode-beta\.app/
        result.add(
          TestDatum.new path,
                        :maybe,
                        'path indicates a beta Xcode installation')
      else
        # TODO: I'm not sure what exactly constitutes a valid
        # path. `xcode-select -s` won't let you set an invalid path, but that's
        # not to say that the path might point to an unsuitable version of
        # Xcode in spite of a passing `xcodebuild -version` result in
        # 'test_xcode_version'
        result.add(
          TestDatum.new path,
                        maybe,
                        'custom path detected')
      end
    when :not_found
      # TODO-MAYBE: I'm not sure if this can actually happen, since the
      # xcode-select binary should be present on any OSX system, whether or not
      # Xcode is installed (I think...). But if it can, this is actually a
      # distinct condition from simply not finding a valid developer directory.
      result.add(
        TestDatum.new 'Not found',
                      :bad)
    when :failure
      if cmd.stderr.match(/unable to get active developer directory/)
        result.add(
          TestDatum.new 'Not found',
                        :bad)
      else
        result.add(
          TestDatum.new 'Indeterminate',
                        :bad,
                        "#{cmd_name} reports: '#{cmd.stderr}'")
      end
    when :sys_failure
      result.add(
        TestDatum.new 'Failed',
                      :bad,
                      "System reports: '#{cmd.syserror.message}'")
    end
    return result, path
  end

  def self.test_frameworks framework_name,
                           framework_subdir=framework_name.downcase

    # TODO: Are any of the frameworks considered mandatory?
    result = TestResult.new "Supported #{framework_name} frameworks"
    rm_data_path = '/Library/RubyMotion/data'
    framework_path = "#{rm_data_path}/#{framework_subdir}"

    if !File.directory? rm_data_path
      result.add(
        TestDatum.new 'RubyMotion data directory not found',
                      :bad,
                      rm_data_path)
      return result, nil
    end

    if !File.exists? framework_path
      result.add(TestDatum.new 'None', :neutral)
      return result, nil
    end

    if !File.directory? framework_path
      result.add(
        TestDatum.new 'Indeterminate',
                      :bad,
                      "#{framework_path} is a file -- expected directory")
      return result, nil
    end

    frameworks = []
    Dir.entries(framework_path).each do |entry|
      if File.directory? "#{framework_path}/#{entry}" and
        entry.match('^\d+(\.\d+)*$')
        result.add(TestDatum.new entry, :neutral)
        entry_split = entry.split('.')
        framework_version = {
          :major => entry_split[0].to_i,
          :minor => entry_split[1].to_i,
          :very_minor => entry_split[2].to_i
        }
        frameworks << framework_version
      end
    end
    if result.data.count == 0
      result.add(TestDatum.new 'None', :neutral)
    end

    return result, frameworks
  end

  # -----------------------------------------------------------------------------
  # Run{Foo}
  # -----------------------------------------------------------------------------

  def self.run_environment_tests
    environment = {}
    print_section_header "Environment"

    result, environment[:wd] = test_working_directory
    print_test_result result

    environment
  end

  def self.run_installation_tests
    install = {}
    print_section_header "Installation Tests"

    # RubyMotion tests
    install[:motion] = {}
    result, install[:motion][:version] = test_rubymotion_version
    print_test_result result

    install[:motion][:frameworks] = {}
    result, install[:motion][:frameworks][:osx] = test_frameworks('OSX')
    print_test_result result
    result, install[:motion][:frameworks][:ios] = test_frameworks('iOS')
    print_test_result result
    result, install[:motion][:frameworks][:tvos] = test_frameworks('tvOS')
    print_test_result result
    result, install[:motion][:frameworks][:watch] = test_frameworks('watchOS', 'watch')
    print_test_result result
    result, install[:motion][:frameworks][:android] = test_frameworks('Android')
    print_test_result result

    # rbenv tests
    install[:rbenv] = {}
    result, install[:rbenv][:version] = test_rbenv_version
    print_test_result result

    # Xcode tests
    install[:xcode] = {}
    result, install[:xcode][:version] = test_xcode_version(install[:motion][:version])
    print_test_result result
    install[:xcode][:select] = {}
    result, install[:xcode][:select][:version] = test_xcode_select_version
    print_test_result result
    result, install[:xcode][:select][:path] = test_xcode_select_path
    print_test_result result

    install
  end

  def self.run
    print_report_header "RubyMotion Doctor"

    run_environment_tests
    run_installation_tests

    #env = run_environment_tests
    #install = run_installation_tests
    #pp env
    #pp install
  end
end

Wip.run
