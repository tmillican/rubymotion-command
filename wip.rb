# autorun:
# brew install fswatch
# fswatch ./wip.rb | xargs -n1 -I{} ruby ./wip.rb

require 'open3'
require 'pp'

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
  # =============================================================================
  # Output
  # =============================================================================

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

  # =============================================================================
  # Environment
  # =============================================================================

  # Determines the OSX version using `sw_vers`
  #
  # ==== Return
  #
  # A Hash describing the OSX version if `sw_vers` succeeds, or describing the
  # failure otherwise.
  def self.sense_osx
    cmd = CommandResult.new 'sw_vers'
    case cmd.status
    when :success
      lines = cmd.stdout.split("\n")
      major = lines[1].sub(/^ProductVersion:\W+(\d+)/, '\1').to_i
      minor = lines[1].sub(/^ProductVersion:\W+\d+\.(\d+)/, '\1').to_i
      versions_to_code_names = {
        '10.0' => 'Cheeta',
        '10.1' => 'Puma',
        '10.2' => 'Jaguar',
        '10.3' => 'Panther',
        '10.4' => 'Tiger',
        '10.5' => 'Leopard',
        '10.6' => 'Snow Leopard',
        '10.7' => 'Lion',
        '10.8' => 'Mountain Lion',
        '10.9' => 'Mavericks',
        '10.10' => 'Yosemite',
        '10.11' => 'El Capitan',
        '10.12' => 'Sierra',
        '10.13' => 'High Sierra',
        '10.14' => 'Mojave',
      }
      {
        :state => :present,
        :version => {
          :major => major,
          :minor => minor,
          :very_minor => lines[1].sub(/^ProductVersion:\W+\d+\.\d+\.(\d+)/, '\1').to_i,
          :build => lines[2].sub(/^BuildVersion:\W+(\w+)/, '\1'),
          :code_name => versions_to_code_names["#{major}.#{minor}"],
        }
      }
    when :not_found
      {
        :state => :absent,
      }
    when :failure
      {
        :state => :failed,
        :fail_source => 'sw_vers',
        :err => cmd.stderr,
      }
    when :sys_failure
      {
        :state => :failed,
        :fail_source => 'system',
        :err => cmd.syserror.message,
      }
    end
  end

  # Tests the OSX version.
  #
  # ==== Attributes
  #
  # * +osx+ - The OSX state as reported by +sense_osx+
  #
  # ==== Return
  #
  # A TestResult object.
  def self.test_osx_version osx
    result = TestResult.new 'OSX version'
    case osx[:state]
    when :present
      very_minor_component =
        ".#{osx[:version][:very_minor]}" if osx[:version][:very_minor] > 0
      code_name_component =
        " (#{osx[:version][:code_name]})" if osx[:version][:code_name]
      result.add(
        TestDatum.new "#{osx[:version][:major]}" \
                      ".#{osx[:version][:minor]}" \
                      "#{very_minor_component}" \
                      "#{code_name_component}")
        if osx[:version][:major] < 10 or
          (osx[:version][:major] == 10 and osx[:version][:minor] < 12)
          result.data[0].status = :bad
        end
    when :absent
      result.add(
        TestDatum.new('Indeterminate',
                      :bad,
                      '`sw_vers` not found'))
    when :failed
      result.add(
        TestDatum.new('Indeterminate',
                      :bad,
                      "#{osx[:fail_source]} reports: #{osx[:err]}"))
    end
    result
  end

  # Determines the working directory
  def self.get_working_directory
    Dir.pwd
  end

  # Tests the working directory.
  #
  # ==== Attributes
  #
  # * +wd+ - The working directory as reported by +get_working_directory+
  #
  # ==== Return
  #
  # A TestResult object.
  def self.test_working_directory wd
    TestResult.new(
      'Working directory',
      [TestDatum.new(wd, :neutral)])
  end

  # =============================================================================
  # Installation/Toolchain
  # =============================================================================

  # -----------------------------------------------------------------------------
  # RubyMotion
  # -----------------------------------------------------------------------------

  # version/presence
  # ----------------

  # Detects the presence of the `motion` command and, if present, determines
  # its version.
  #
  # ==== Return
  #
  # A Hash describing the state of the `motion` command.
  def self.sense_rubymotion
    cmd = CommandResult.new 'motion --version'
    case cmd.status
    when :success
      {
        :state => :present,
        :version => {
          :major => cmd.stdout.chop.sub(/^(\d+).\d+$/, '\1').to_i,
          :minor => cmd.stdout.chop.sub(/^\d+.(\d+)$/, '\1').to_i,
        }
      }
    when :not_found
      {
        :state => :absent,
      }
    when :failure
      {
        :state => :failed,
        :fail_source => 'motion',
        :err => cmd.stderr,
      }
    when :sys_failure
      {
        :state => :failed,
        :fail_source => 'system',
        :err => cmd.syserror.message,
      }
    end
  end

  # Tests the RubyMotion version.
  #
  # ==== Attributes
  #
  # * +motion+ - The RubyMotion status information, as produced by +sense_rubymotion+.
  #
  # ==== Return
  #
  # A +TestResult+ object
  def self.test_rubymotion_version motion
    # TODO: are some versions considered deprecated? EOL?
    result = TestResult.new 'RubyMotion version'
    case motion[:state]
    when :present
      result.add TestDatum.new("#{motion[:version][:major]}" \
                               ".#{motion[:version][:minor]}",
                               :neutral)
    when :absent
      result.add TestDatum.new(
                   'Not found',
                   :bad)
    when :failed
      result.add TestDatum.new(
                   'Failed',
                   :bad,
                   "#{motion[:fail_source]} reports: '#{motion[:error]}'")
    end
    result
  end

  # available SDKs
  # --------------

  # Determines which SDK versions are present for the specified framework
  #
  # ==== Attributes
  #
  # * +framework_name+ - The 'pretty' name of the framework. Ex: "iOS"
  # * +framework_subdir+ - The subdirectory name for the framework. Ex: "ios"
  #
  # ==== Return
  #
  # An array of Hashes, each of which describes a detected SDK version.
  def self.get_rubymotion_sdks framework_name,
                               framework_subdir=framework_name.downcase
    rm_data_path = '/Library/RubyMotion/data'
    framework_path = "#{rm_data_path}/#{framework_subdir}"

    return [] unless File.directory? framework_path

    sdks = []
    Dir.entries(framework_path).each do |entry|
      if File.directory? "#{framework_path}/#{entry}" and
        entry.match('^\d+(\.\d+)*$')

        entry_split = entry.split('.')
        sdk_version = {
          :major => entry_split[0].to_i,
          :minor => entry_split[1].to_i,
          :very_minor => entry_split[2].to_i,
        }
        sdks << sdk_version
      end
    end
    sdks
  end

  # Tests the available SDK versions for a framework
  #
  # ==== Attributes
  #
  # * +sdks+ - An array of SDK versions, as produced by +get_rubymotion_sdks+
  # * +framework_name+ - The 'pretty' name of the framework. Ex: "iOS"
  #
  # ==== Return
  #
  # A TestResult object
  def self.test_rubymotion_sdks sdks,
                                framework_name
    # TODO: Are any of the frameworks considered mandatory?
    result = TestResult.new "Supported #{framework_name} frameworks"
    sdks.each do |sdk|
      minor_component = ".#{sdk[:minor]}" if sdk[:minor] > 0
      very_minor_component = ".#{sdk[:very_minor]}" if sdk[:very_minor] > 0
      result.add(
        TestDatum.new(
          "#{sdk[:major]}#{minor_component}#{very_minor_component}",
          :neutral))
    end
    if result.data.count == 0
      result.add(TestDatum.new 'None', :neutral)
    end
    result
  end

  # -----------------------------------------------------------------------------
  # rbenv
  # -----------------------------------------------------------------------------

  # version
  # -------

  # Detects the presence of the `rbenv` command and, if present, determines
  # its version.
  #
  # ==== Return
  #
  # A Hash describing the state of the `rbenv` command.
  def self.sense_rbenv
    cmd = CommandResult.new 'rbenv --version'
    case cmd.status
    when :success
      version_split = cmd.stdout.split(' ')[1].split('.')
      {
        :state => :present,
        :version => {
          :major => version_split[0],
          :minor => version_split[1],
          :very_minor => version_split[2],
        }
      }
    when :not_found
      {
        :state => :absent,
      }
    when :failure
      {
        :state => :failed,
        :fail_source => :cmd,
        :err => cmd.stderr,
      }
    when :sys_failure
      {
        :state => :failed,
        :fail_source => :system,
        :err => cmd.syserror.message,
      }
    end
  end

  # Tests the `rbenv` version.
  #
  # ==== Attributes
  #
  # * +rbenv+ - The `rbenv` status information, as produced by +sense_rbenv+.
  #
  # ==== Return
  #
  # A +TestResult+ object
  def self.test_rbenv_version rbenv
    result = TestResult.new 'rbenv version'
    case rbenv[:state]
    when :present
      result.add(
        TestDatum.new "#{rbenv[:version][:major]}" \
                      ".#{rbenv[:version][:minor]}" \
                      ".#{rbenv[:version][:very_minor]}",
                      :neutral)
    when :absent
      result.add(
        TestDatum.new 'Not found',
                      :maybe,
                      'Recommended, but not required')
    when :failed
      # Even though rbenv isn't required, it's a problem if it's broken
      result.add TestDatum.new(
                   'Not found',
                   :bad,
                   "#{rbenv[:fail_source]} reports: '#{rbenv[:error]}'")
    end
    result
  end

  # rbenv Ruby versions
  # -------------------

  # Determines which versions of Ruby are provided by `rbenv`.
  # its version.
  #
  # ==== Attributes
  #
  # * +rbenv_state+ - The state of the `rbenv` command, as reported by +sense_rbenv+.
  #
  # ==== Return
  #
  # If `rbenv` is present, an Array of hashes, each of which describes a Ruby
  # version. Otherwise, an empty Array.
  def self.get_rbenv_ruby_versions rbenv_state
    return [] unless rbenv_state == :present

    # TODO: do we consider "system" to be relevant? `rbenv versions --bare`
    # omits it, since it isn't supplied by rbenv
    cmd = CommandResult.new 'rbenv versions --bare'
    lines = cmd.stdout.split("\n")
    versions = []
    lines.each do |version_str|
      version_split = version_str.split('.')
      version = {
        :major => version_split[0].to_i,
        :minor => version_split[1].to_i,
        :very_minor => version_split[2].to_i,
      }
      versions << version
    end
    versions
  end

  # Tests the versions of Ruby provided by `rbenv`.
  #
  # ==== Attributes
  #
  # * +versions+ - The array of Ruby versions, as produced by +get_rbenv_ruby_versions+.
  #
  # ==== Return
  #
  # A +TestResult+ object
  def self.test_rbenv_ruby_versions versions
    result = TestResult.new 'rbenv-supplied Ruby versions'
    if versions.nil?
      result.add(
        TestDatum.new(
          'None',
          :neutral))
    else
      versions.each do |version|
      result.add(
        TestDatum.new(
          "#{version[:major]}.#{version[:minor]}.#{version[:very_minor]}",
          :neutral))
      end
    end
    result
  end

  # -----------------------------------------------------------------------------
  # Xcode
  # -----------------------------------------------------------------------------

  # xcode-select
  # ------------

  # Detects the presence of the `xcode-select` command and, if present,
  # determines its version.
  #
  # ==== Return
  #
  # A Hash describing the state of the `xcode-select` command.
  def self.sense_xcode_select
    cmd = CommandResult.new 'xcode-select --version'
    case cmd.status
    when :success
      {
        :state => :present,
        :version => cmd.stdout.chop.sub(
          /^xcode-select version ([\.\d]+)\.$/,
          '\1').to_i
      }
    when :not_found
      { :state => :absent }
    when :failure
      { :state => :failed,
        :fail_source => 'xcode-select',
        :err => cmd.stderr }
    when :sys_failure
      { :state => :failed,
        :fail_source => 'system',
        :err => cmd.syserror.message }
    end
  end

  # Tests the versions of xcode-select.
  #
  # ==== Attributes
  #
  # * +xcode_select+ - The `xcode-select` state as produced by +sense_xcode_select+
  #
  # ==== Return
  #
  # A +TestResult+ object
  def self.test_xcode_select_version xcode_select
    result = TestResult.new 'xcode-select version'
    case xcode_select[:state]
    when :present
      # TODO:
      # According to https://github.com/amirrajan/rubymotion-applied/issues/58
      # Xcode 9.2 should be paired with 2349. As far as I can tell from my own system,
      # that's still the xcode-select version present as late as 9.4.1 (latest non-beta)
      #
      # Since the RM version parities only go as far back as Xcode 9.2, which also
      # requires 2349, I think maybe we just unconditionally want 2349 now? I'm
      # also not entirely clear on what exactly controls the xcode-select
      # version. I'm pretty sure this stands alone from Xcode, and would be
      # relegated to the OSX version.
      result.add TestDatum.new(xcode_select[:version])
      result.data[0].status = :bad unless xcode_select[:version] == 2349
    when :absent
      result.add TestDatum.new(
                   'Not found',
                   :bad)
    when :failed
      result.add TestDatum.new(
                   'Failed',
                   :bad,
                   "#{motion[:fail_source]} reports: '#{motion[:error]}'")
    end
    result
  end

  # Determines the active developer directory. I.e. `xcode-select --print-path`
  #
  # ==== Attributes
  #
  # * +xcode_select_state+ - The state of `xcode-select` as determined by
  #                          +sense_xcode_select+
  #
  # ==== Return
  #
  # A string containing the Xcode path, if Xcode is installed. Otherwise,
  # a string indicating that Xcode is not present.
  def self.get_xcode_path xcode_select_state
    return 'Xcode not installed' unless xcode_select_state == :present
    (CommandResult.new 'xcode-select --print-path').stdout.chop
  end

  # Tests the active developer directory (i.e. Xcode directory).
  #
  # ==== Attributes
  #
  # * +path+ - The path as reported by +get_xcode_path+
  #
  # ==== Return
  #
  # A TestResult object
  def self.test_xcode_path path
    result = TestResult.new 'Xcode path'
    case path
    when /CommandLineTools/
      result.add(
        TestDatum.new(
          path,
          :bad,
          'path indicates a CLI-tool-only Xcode installation'))
    when /Xcode\.app/
      result.add(TestDatum.new path)
    when /Xcode-beta\.app/
      result.add(
        TestDatum.new(
          path,
          :maybe,
          'path indicates a beta Xcode installation'))
    else
      # TODO: I'm not sure what exactly constitutes a valid
      # path. `xcode-select -s` won't let you set an invalid path, but that's
      # not to say that the path might point to an unsuitable version of
      # Xcode in spite of a passing `xcodebuild -version` result in
      # 'test_xcode_version'
      result.add(
        TestDatum.new(
          path,
          :maybe,
          'custom path detected'))
    end
    result
  end

  # Detects the presence of Xcode and, if present, determines its version.
  #
  # ==== Attributes
  #
  # * +xcode_path+ - The Xcode path as reported by +get_xcode_path+
  #
  # ==== Return
  #
  # A Hash describing the state of Xcode.
  def self.sense_xcode xcode_path
    # Bail early if xcode-select doesn't give us a valid path. This indicates
    # that Xcode isn't installed at all. Running `xcodebuild` in this case
    # won't work, and will only prompt the user to install Xcode in a modal
    # dialog.
    return { :state => :absent } unless xcode_path

    cmd = CommandResult.new 'xcodebuild -version'
    case cmd.status
    when :success
      version_split = cmd.stdout.split("\n")[0].split(' ')[1].split('.')
      {
        :state => :present,
        :version => {
          :major => version_split[0].to_i,
          :minor => version_split[1].to_i,
          :very_minor => version_split[2].to_i,
        }
      }
    when :not_found
      { :state => :absent }
    when :failure
      { :state => :failed,
        :fail_source => 'xcodebuild',
        :err => cmd.stderr, }
    when :sys_failure
      { :state => :failed,
        :fail_source => 'system',
        :err => cmd.syserror.message, }
    end
  end

  # Tests the version of Xcode against the RubyMotion version for version parity.
  #
  # ==== Attributes
  #
  # * +xcode+ - The Xcode state as reported by +sense_xcode+
  # * +rm_version+ - The installed version of RubyMotion as detected by +sense_rubymotion
  #
  # ==== Return
  #
  # A TestResult object
  def self.test_xcode_version xcode, rm_version
    result = TestResult.new 'Xcode version'

    if xcode[:state] != :present
    then
      result.add(
        TestDatum.new(
          'Not installed',
          :bad))
      return result
    end

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
    # If the RubyMotion version wasn't detected, assume we want 9.4
    expected_version ||= xc_9_4

    very_minor_component =
      ".#{xcode[:version][:very_minor]}" if xcode[:version][:very_minor] > 0
    datum = TestDatum.new(
      "#{xcode[:version][:major]}." \
      "#{xcode[:version][:minor]}" \
      "#{very_minor_component}")
    if xcode[:version] != expected_version
      datum.meta = "expected #{expected_version[:major]}" \
                   ".#{expected_version[:minor]}" \
                   ".#{expected_version[:very_minor]}"
      datum.status =
        # Having a very minor version above the expected is *maybe* okay.
        # TODO: This might be perfectly fine. Ask Amir. 9.4.1 is current, so
        # this is going to flag for a decent number of people.
        if xcode[:version][:major] = expected_version[:major] and
          xcode[:version][:minor] = expected_version[:minor] and
          xcode[:version][:very_minor] > expected_version[:very_minor]
          :maybe
        else
          :bad
        end
    end
    result.add datum
    result
  end

  # -----------------------------------------------------------------------------
  # Java
  # -----------------------------------------------------------------------------

  # Detects the presence of the `javac` command and, if present, determines
  # its version.
  #
  # ==== Return
  #
  # A Hash describing the state of the `javac` command.
  def self.sense_java
    cmd = CommandResult.new 'javac -version'
    case cmd.status
    when :success
      # TIL: javac spits out -version to stderr...
      version_split = cmd.stderr.chop.split(' ')[1].split('.')
      {
        :state => :present,
        :version => {
          :major => version_split[0].to_i,
          :minor => version_split[1].to_i,
          :very_minor => version_split[2].sub(/^(\d+)_\d+$/, '\1').to_i,
          :build => version_split[2].sub(/^\d+_(\d+)$/, '\1').to_i,
        }
      }
    when :not_found
      {
        :state => :absent,
      }
    when :failure
      {
        :state => :failed,
        :fail_source => 'motion',
        :err => cmd.stderr,
      }
    when :sys_failure
      {
        :state => :failed,
        :fail_source => 'system',
        :err => cmd.syserror.message,
      }
    end
  end

  # Tests the Java version.
  #
  # ==== Attributes
  #
  # * +java+ - The Java status information, as produced by +sense_java+.
  #
  # ==== Return
  #
  # A +TestResult+ object
  def self.test_java_version java
    result = TestResult.new 'Java version'
    case java[:state]
    when :present
      result.add(
        TestDatum.new(
          "#{java[:version][:major]}" \
          ".#{java[:version][:minor]}" \
          ".#{java[:version][:very_minor]}" \
          "_#{java[:version][:build]}",
          :neutral))
      # TODO: minimum Java? 1.8 preferred? I think the guide is out of date.
      # result.data[0].status = :bad if java[:version][:minor] < 7
    when :absent
      result.add TestDatum.new(
                   'Not found',
                   :bad)
    when :failed
      result.add TestDatum.new(
                   'Failed',
                   :bad,
                   "#{java[:fail_source]} reports: '#{motion[:error]}'")
    end
    result
  end

  # Gets the JAVA_HOME environment variable.
  def self.get_java_home
    ENV['JAVA_HOME']
  end

  # Tests the JAVA_HOME environment variable.
  #
  # ==== Attributes
  #
  # * +home+ - The JAVA_HOME value
  #
  # ==== Return
  #
  # A +TestResult+ object
  def self.test_java_home home
    result = TestResult.new 'Java home'
    if home
      result.add(TestDatum.new home, :neutral)
    else
      result.add(TestDatum.new 'Not set', :bad)
    end
    result
  end

  # =============================================================================
  # Get{Foo}/Test{Foo}
  # =============================================================================

  # Environment
  # -----------

  def self.get_environment_data
    {
      :osx => sense_osx,
      :wd => get_working_directory,
    }
  end

  def self.test_environment_data env
    print_section_header "Environment"
    print_test_result test_osx_version env[:osx]
    print_test_result test_working_directory env[:wd]
  end

  # Installation
  # ------------

  def self.get_rubymotion_data
    motion = sense_rubymotion
    motion[:sdks] = {
      :osx => get_rubymotion_sdks('OSX'),
      :ios => get_rubymotion_sdks('iOS'),
      :tvos => get_rubymotion_sdks('tvOS'),
      :watch => get_rubymotion_sdks('watchOS', 'watch'),
      :android => get_rubymotion_sdks('Android'),
    }
    motion
  end

  def self.get_rbenv_data
    rbenv = sense_rbenv
    rbenv[:ruby_versions] = get_rbenv_ruby_versions(rbenv)
    rbenv
  end

  def self.get_xcode_data
    select = sense_xcode_select
    path = get_xcode_path(select[:state])
    xcode = sense_xcode path
    xcode[:xcode_select] = select
    xcode[:path] = path
    xcode
  end

  def self.get_java_data
    java = sense_java
    java[:home] = get_java_home
    java
  end

  def self.get_installation_data
    {
      :motion => get_rubymotion_data,
      :rbenv => get_rbenv_data,
      :xcode => get_xcode_data,
      :java => get_java_data,
    }
  end

  def self.test_installation_data install
    print_section_header "Installation Tests"

    # RubyMotion tests
    print_test_result test_rubymotion_version(install[:motion])

    print_test_result test_rubymotion_sdks(
                        install[:motion][:sdks][:osx],
                        'OSX')
    print_test_result test_rubymotion_sdks(
                        install[:motion][:sdks][:ios],
                        'iOS')
    print_test_result test_rubymotion_sdks(
                        install[:motion][:sdks][:tvos],
                        'tvOS')
    print_test_result test_rubymotion_sdks(
                        install[:motion][:sdks][:watch],
                        'watchOS')
    print_test_result test_rubymotion_sdks(
                        install[:motion][:sdks][:android],
                        'Android')

    # rbenv tests
    print_test_result test_rbenv_version(install[:rbenv])
    print_test_result test_rbenv_ruby_versions(install[:rbenv][:ruby_versions])

    # Xcode tests
    print_test_result test_xcode_version(
                        install[:xcode],
                        install[:motion][:version])
    print_test_result test_xcode_select_version install[:xcode][:xcode_select]
    print_test_result test_xcode_path install[:xcode][:path]

    # Java tests
    print_test_result test_java_version install[:java]
    print_test_result test_java_home install[:java][:home]

    install
  end

  def self.run
    print_report_header "RubyMotion Doctor"

    env = get_environment_data
    install = get_installation_data

    test_environment_data env
    test_installation_data install

    print_section_header "Guru Meditation"
    pp env
    pp install

  end
end

Wip.run
