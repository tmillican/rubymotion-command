# autorun:
# brew install fswatch
# fswatch ./wip.rb | xargs -n1 -I{} ruby ./wip.rb

require 'open3'

# Represents a set of related test results.
#
# Ex: a collection of detected OSX framework versions.
class TestResultSet
  # The name of the test set. Used as the label in test reports.
  attr_accessor :name,
  # An array of TestResult objects comprising the TestSet
                :results

  def initialize name='', results=[]
    @name = name
    @results = results
  end

  def add result
    @results << result
  end
end



# Represents an individual result of a TestSet.
class TestResult
  # The value of the test result.
  attr_accessor :value

  # The status of the test result. May be:
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

  # Pretty-prints a TestResultSet object
  def self.print_test_results result_set
    result_set.results.each do |result|
      if result.equal? result_set.results.first
        print "#{result_set.name.ljust(LABEL_WIDTH)}: "
      else
        print(''.ljust(LABEL_WIDTH + 2, ' '))
      end

      case result.status
      when :good
        print "#{ANSI_PRE_GOOD}#{result.value}"
      when :maybe
        print "#{ANSI_PRE_MAYBE}#{result.value}"
        print " (#{result.meta})" unless result.meta.to_s.empty?
      when :bad
        print "#{ANSI_PRE_BAD}#{result.value}"
        print " (#{result.meta})" unless result.meta.to_s.empty?
      else
        print result.value
      end
      print "#{ANSI_POST}\n"
    end
  end

  # -----------------------------------------------------------------------------
  # Environment Tests
  # -----------------------------------------------------------------------------

  def self.test_working_directory
    TestResultSet.new('Working directory',
                      [
                        TestResult.new(Dir.pwd, :neutral)
                      ])
  end

  # -----------------------------------------------------------------------------
  # Installation Tests
  # -----------------------------------------------------------------------------

  def self.test_rubymotion_version
    cmd_name = 'motion'
    cmd = CommandResult.new "#{cmd_name} --version"
    result_set = TestResultSet.new 'RubyMotion version'

    # TODO: are some versions considered deprecated? EOL?
    case cmd.status
    when :success
      result_set.add(TestResult.new cmd.stdout.chop,
                                    :good)
    when :not_found
      result_set.add(TestResult.new 'Not found',
                                    :bad)
    when :failure
      result_set.add(TestResult.new 'Failed',
                                    :bad,
                                    "#{cmd_name} reports: '#{cmd.stderr}'")
    when :sys_failure
      result_set.add(TestResult.new 'Failed',
                                    :bad,
                                    "System reports: '#{cmd.syserror.message}'")
    end
    result_set
  end

  def self.test_rbenv_version
    cmd_name = 'rbenv'
    cmd = CommandResult.new "#{cmd_name} --version"
    result_set = TestResultSet.new 'rbenv version'

    case cmd.status
    when :success
      result_set.add(
        TestResult.new cmd.stdout.split(' ')[1],
                                    :neutral)
    when :not_found
      result_set.add(TestResult.new 'Not found',
                                    :maybe,
                                    "Recommended, but not required")
    when :failure
      # Even though rbenv isn't required, it's a problem if it's broken
      result_set.add(
        TestResult.new 'Failed',
                       :bad,
                       "#{cmd_name} reports: '#{cmd.stderr}'")
    when :sys_failure
      # Likewise.
      result_set.add(
        TestResult.new 'Failed',
                       :bad,
                       "System reports: '#{cmd.syserror.message}'")
    end
    result_set
  end


  # Determines the Xcode version. Checks against the RubyMotion version for
  # version parity.
  def self.test_xcode_version rm_version

    parities = {
      "5.7"  => "9.2",
      "5.8"  => "9.3",
      "5.9"  => "9.4",
      "5.10" => "9.4",
      # We'll assume we want the latest if the RM version test failed
      :rm_version_unknown => "9.4",
    }
    expected_version = parities[rm_version]

    result_set = TestResultSet.new 'Xcode version'

    # Bail early if xcode-select doesn't give us a valid path. This indicates
    # that Xcode isn't installed at all, and we'll just wind up prompting the
    # user to install Xcode when we try to run `xcodebuild` below.
    if !test_xcode_select_path.results[0].is_good?
      result_set.add(
        TestResult.new 'Not installed',
                       :bad)
      return result_set
    end

    cmd_name = 'xcodebuild'
    cmd = CommandResult.new "#{cmd_name} -version"

    case cmd.status
    when :success
      version = cmd.stdout.split("\n")[0].split(' ')[1]
      result = TestResult.new version
      if version != expected_version
        result.meta = "expected #{expected_version}"
        # What program is complete without gnarly regexps?
        # This (hopefully) detects subversions of the expected version
        version_subregexp = expected_version.gsub(/\./, '\.')
        isminor_regexp = Regexp.new("^#{version_subregexp}(\\.[0-9\\.]+)?$")
        is_minor = version.match(isminor_regexp)
        # Minor versions of expected are *maybe* okay.
        result.status = is_minor ? :maybe : :bad
      end
      result_set.add result
    when :not_found
      result_set.add(
        TestResult.new 'Not installed',
                       :bad,
                       "#{expected_version} required")
    when :failure
      result_set.add(
        TestResult.new 'Failed',
                       :bad,
                       "#{cmd_name} reports: '#{cmd.stderr}'")
    when :sys_failure
      result_set.add(
        TestResult.new 'Failed',
                       :bad,
                       "System reports: '#{cmd.syserror.message}'")
    end
    result_set
  end

  def self.test_xcode_select_path
    result_set = TestResultSet.new 'xcode-select path'

    cmd_name = 'xcode-select'
    cmd = CommandResult.new "#{cmd_name} --print-path"

    case cmd.status
    when :success
      path = cmd.stdout.chop
      case path
      when /CommandLineTools/
        result_set.add(
          TestResult.new path,
                         :bad,
                         "path references a CLI-tool-only Xcode installation")
      when /Xcode\.app/
        result_set.add(
            TestResult.new path)
      else
        result_set.add(
          TestResult.new path,
                         maybe,
                         "custom path detected")
      end
    when :not_found
      # TODO-MAYBE: I'm not sure this can actually happen, since the
      # xcode-select binary should be present on any OSX system, whether or not
      # Xcode is installed. But if it can, this is actually a distinct condition
      # from simply not finding a valid developer directory.
      result_set.add(
        TestResult.new 'Not found',
                       :bad)
    when :failure
      if cmd.stderr.match(/unable to get active developer directory/)
        result_set.add(
          TestResult.new 'Not found',
                         :bad)
      else
        result_set.add(
            TestResult.new 'Indeterminate',
                        :bad,
                        "#{cmd_name} reports: '#{cmd.stderr}'")
      end
    when :sys_failure
      result_set.add(
        TestResult.new 'Failed',
                       :bad,
                       "System reports: '#{cmd.syserror.message}'")
    end
    result_set
  end

  def self.test_frameworks framework_name, framework_subdir
    # TODO: Are any of the frameworks considered mandatory?

    result_set = TestResultSet.new "Supported #{framework_name} frameworks"
    rm_data_path = '/Library/RubyMotion/data'
    framework_path = "#{rm_data_path}/#{framework_subdir}"

    if !File.directory? rm_data_path
      result_set.add(
        TestResult.new 'RubyMotion data directory not found',
                       :bad,
                       rm_data_path)
      return result_set
    end

    if !File.exists? framework_path
      result_set.add(TestResult.new 'None', :neutral)
      return result_set
    end

    if !File.directory? framework_path
      result_set.add(
        TestResult.new 'Indeterminate',
                       :bad,
                       "#{framework_path} is a file -- expected directory")
      return result_set
    end

    Dir.entries(framework_path).each do |entry|
      if File.directory? "#{framework_path}/#{entry}" and
        entry.match('^\d+(\.\d+)*$')

        result_set.add(TestResult.new entry, :neutral)
      end
    end
    if result_set.results.count == 0
      result_set.add(TestResult.new 'None', :neutral)
    end

    result_set
  end

  # -----------------------------------------------------------------------------
  # Run{Foo}
  # -----------------------------------------------------------------------------

  def self.run_environment_tests
    print_section_header "Environment"
    print_test_results test_working_directory
  end

  def self.run_installation_tests
    print_section_header "Installation Tests"
    rm_test_results = test_rubymotion_version
    rm_version =
      if rm_test_results.results[0].is_bad?
        :rm_version_unknown
      else
        rm_test_results.results[0].value
      end
    print_test_results rm_test_results
    print_test_results test_rbenv_version
    print_test_results test_frameworks("OSX", "osx")
    print_test_results test_frameworks("iOS", "ios")
    print_test_results test_frameworks("tvOS", "tvos")
    print_test_results test_frameworks("watchOS", "watch")
    print_test_results test_frameworks("Android", "android")

    print_test_results test_xcode_version(rm_version)
    print_test_results test_xcode_select_path
  end

  def self.run
    print_report_header "RubyMotion Doctor"
    run_environment_tests
    run_installation_tests
    # run_project_tests
  end
end

Wip.run
