# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "tmpdir"
require_relative "../lib/backend"

class PluginPulseRuntimeTest < Minitest::Test
  FakeResult = Struct.new(:stdout, :stderr, :exitstatus) do
    def success? = exitstatus.to_i.zero?
  end

  def test_correlates_registry_process_journal_and_source_without_executing_plugin_code
    Dir.mktmpdir do |home|
      plugin_id = "example.runtime-map"
      plugin_root = File.join(home, ".config", "omarchy", "plugins", plugin_id)
      FileUtils.mkdir_p(File.join(plugin_root, ".git"))
      File.write(
        File.join(plugin_root, "main.rb"),
        'Command.run(["probe"]); endpoint = "https://example.invalid"; File.write("state", endpoint)'
      )
      runtime = File.join(plugin_root, "omarchy-ui-runtime")
      File.write(runtime, "not executed")
      FileUtils.chmod(0o755, runtime)

      previous_home = ENV["HOME"]
      ENV["HOME"] = home
      calls = []
      runner = lambda do |argv, timeout:|
        calls << argv
        output = case argv.first
        when "omarchy"
          JSON.generate([
            {
              "id" => plugin_id, "name" => "Runtime Map", "kinds" => ["service"],
              "enabled" => true, "firstParty" => false
            }
          ])
        when "ps"
          "123 1 0.2 0.1 42 #{plugin_root}/omarchy-ui-runtime #{plugin_root}/main.rb\n"
        when "journalctl"
          "warning: #{plugin_id} reported a bounded test issue\n"
        when "git"
          argv.include?("rev-parse") ? "abcdef1234\n" : ""
        else
          ""
        end
        FakeResult.new(output, "", 0)
      end

      snapshot = SuiteBackend.new(state_dir: File.join(home, "state"), runner: runner).refresh
      record = snapshot.fetch("items").fetch(0)

      assert_equal 1, snapshot.fetch("score")
      assert_equal "attention", record.fetch("status")
      assert_includes record.fetch("detail"), "PID 123"
      assert_includes record.fetch("meta"), "1 errors"
      assert_includes record.fetch("meta"), "1 executables"
      assert_includes record.fetch("meta"), "1 network cues"
      assert_includes record.fetch("meta"), "1 write cues"
      refute calls.any? { |argv| argv.first == runtime }
    ensure
      ENV["HOME"] = previous_home
    end
  end
end
