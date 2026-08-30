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
        'Command.run(["probe"]); endpoint = "https://example.invalid"; Net::HTTP.get(endpoint); File.write("state", endpoint)'
      )
      runtime = File.join(plugin_root, "omarchy-ui-runtime")
      File.write(runtime, "not executed")
      FileUtils.chmod(0o755, runtime)

      previous_home = ENV["HOME"]
      ENV["HOME"] = home
      audit_root = File.join(home, ".local", "state", "omarchy-ui-audit")
      FileUtils.mkdir_p(audit_root)
      File.write(
        File.join(audit_root, "#{plugin_id}.jsonl"),
        JSON.generate(
          "type" => "http", "method" => "GET",
          "url" => "https://person:secret@example.invalid/private/path?token=hidden#fragment",
          "http_status" => 200, "exit_status" => 0, "duration_ms" => 42,
          "response_bytes" => 512, "observed_at" => 1_788_068_800
        ) + "\n"
      )
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
          if argv.include?("--ppid")
            "124 123 0.1 0.1 7 curl https://example.invalid\n"
          else
            "123 1 0.2 0.1 42 #{plugin_root}/omarchy-ui-runtime #{plugin_root}/main.rb\n"
          end
        when "ss"
          'tcp ESTAB 0 0 127.0.0.1:4000 127.0.0.1:5000 users:(("curl",pid=124,fd=3))' + "\n"
        when "find"
          "#{runtime}\n"
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

      assert_equal 1, snapshot.fetch("score"), snapshot.inspect
      assert_equal "attention", record.fetch("status")
      assert_includes record.fetch("detail"), "PID 123"
      assert_includes record.fetch("detail"), "2 live processes"
      assert_includes record.fetch("meta"), "runs local commands"
      assert_includes record.fetch("meta"), "can make network requests"
      assert_includes record.fetch("meta"), "writes local files"
      evidence = record.fetch("evidence")
      assert_equal "executable review", evidence.fetch("trust")
      assert_equal "review", evidence.fetch("security_level")
      assert_includes evidence.fetch("security_finding"), "1 executable file detected"
      assert_equal "Ruby", evidence.fetch("framework")
      assert_equal 1, evidence.fetch("errors")
      assert_equal 1, evidence.fetch("executables")
      assert_equal 1, evidence.fetch("live_sockets")
      assert_equal "127.0.0.1:5000", evidence.fetch("connections").fetch(0).fetch("remote")
      assert_includes evidence.fetch("source_endpoints"), "https://example.invalid"
      http_call = evidence.fetch("http_calls").fetch(0)
      assert_equal "https://example.invalid/private/path", http_call.fetch("url")
      assert_equal 200, http_call.fetch("http_status")
      assert_equal 512, http_call.fetch("response_bytes")
      refute calls.any? { |argv| argv.first == runtime }
    ensure
      ENV["HOME"] = previous_home
    end
  end

  def test_distinguishes_a_known_framework_runtime_from_an_unknown_executable
    Dir.mktmpdir do |home|
      plugin_id = "example.verified-runtime"
      plugin_root = File.join(home, ".config", "omarchy", "plugins", plugin_id)
      FileUtils.mkdir_p(plugin_root)
      File.write(File.join(plugin_root, "main.rb"), "OmarchyUI.app { text 'Hello' }")
      File.write(File.join(plugin_root, "runtime-provenance.json"), "{}")
      runtime = File.join(plugin_root, "omarchy-ui-runtime")
      digest = SuiteBackend::KNOWN_OMARCHY_UI_RUNTIMES.keys.last
      File.write(runtime, "fixture executable")
      File.write(File.join(plugin_root, "omarchy-ui-runtime.sha256"), "#{digest}  omarchy-ui-runtime\n")
      FileUtils.chmod(0o755, runtime)

      previous_home = ENV["HOME"]
      ENV["HOME"] = home
      runner = lambda do |argv, timeout:|
        output = case argv.first
        when "omarchy"
          JSON.generate([{ "id" => plugin_id, "name" => "Verified Runtime", "kinds" => ["service"],
                           "enabled" => true, "firstParty" => false }])
        when "ps"
          argv.include?("--ppid") ? "" : "321 1 0.0 0.1 12 #{runtime} #{plugin_root}/main.rb\n"
        when "find"
          "#{runtime}\n"
        when "sha256sum"
          "#{digest}  #{runtime}\n"
        else
          ""
        end
        FakeResult.new(output, "", 0)
      end

      record = SuiteBackend.new(state_dir: File.join(home, "state"), runner: runner).refresh.fetch("items").fetch(0)
      evidence = record.fetch("evidence")

      assert_equal "active", record.fetch("status")
      assert_equal "verified runtime", evidence.fetch("trust")
      assert_equal "verified", evidence.fetch("security_level")
      assert_includes evidence.fetch("security_finding"), "executable checksum verified"
      assert_equal "Omarchy UI · Ruby + Zui", evidence.fetch("framework")
    ensure
      ENV["HOME"] = previous_home
    end
  end
end
