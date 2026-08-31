# source: main.rb
# frozen_string_literal: true


# source: lib/backend.rb
# frozen_string_literal: true

class SuiteBackend
  SCORE_LABEL = "live plugins"
  STATUSES = ["active", "loaded", "changed", "attention"].freeze
  KNOWN_OMARCHY_UI_RUNTIMES = {
    "c5a5aec0078465a14af991e7de90a13fe4294d120032a2519e1979ec8b1d6d8f" => "Omarchy UI runtime v0.1.0",
    "ccf010017a5f6d2ae06def4357e6bce2b344e6f245f195c5dbee92cd048017b0" => "Omarchy UI runtime v0.1.1",
    "f75d3bccbd1e4424f71709dd91fab4c8611c52f9c217d8410ef4eb17ace53594" => "Omarchy UI runtime v0.1.3",
    "721e023e7868a0f2a85c9b63250042a97d981943d9e60b8d98cf7c781a87de6e" => "Omarchy UI runtime v0.1.4"
  }.freeze
  MAX_ITEMS = 128
  MAX_HISTORY = 256
  MAX_TEXT = 512
  MAX_STATE_BYTES = 262_144
  OUTPUT_LIMIT = 65_536

  Result = Struct.new(:stdout, :stderr, :exitstatus) do
    def success? = exitstatus.to_i.zero?
  end

  attr_reader :records

  def initialize(state_dir: File.expand_path("~/.local/state/omarchy-plugin-pulse"), runner: nil)
    @state_dir = state_dir
    @state_path = File.join(state_dir, "state.json")
    @runner = runner
    @records = []
    @history = []
    @settings = {}
    @summary = "Starting"
    @score = 0
    create_directory(@state_dir)
    load_state
  end

  def snapshot
    {
      "items" => @records.first(MAX_ITEMS),
      "history" => @history.last(MAX_HISTORY),
      "summary" => clean(@summary, 100),
      "score" => @score.to_i,
      "updated_at" => Time.now.to_i
    }
  end

  def add(primary, secondary = "")
    title = clean(primary)
    detail = clean(secondary)
    return snapshot if title.empty?
    record = {
      "id" => "#{Time.now.to_i}-#{rand(1_000_000)}",
      "title" => title,
      "detail" => detail,
      "status" => STATUSES.first,
      "meta" => Time.now.strftime("%Y-%m-%d %H:%M")
    }
    after_add(record)
    @records.unshift(record)
    @records = @records.first(MAX_ITEMS)
    @score = @records.length
    @summary = "#{@records.length} #{SCORE_LABEL}"
    persist
    snapshot
  end

  def act(id)
    record = @records.find { |candidate| candidate["id"] == id.to_s }
    return snapshot unless record
    current = STATUSES.index(record["status"]) || 0
    record["status"] = STATUSES[(current + 1) % STATUSES.length]
    record["meta"] = "Updated #{Time.now.strftime("%Y-%m-%d %H:%M")}"
    persist
    snapshot
  end

  def remove(id)
    @records.reject! { |candidate| candidate["id"] == id.to_s }
    @score = @records.length
    @summary = @records.empty? ? "Ready" : "#{@records.length} #{SCORE_LABEL}"
    persist
    snapshot
  end

  def refresh
    scanned = scan_system
    @records = scanned if scanned.is_a?(Array)
    @records = @records.first(MAX_ITEMS)
    persist
    snapshot
  rescue StandardError => error
    @summary = "Needs attention"
    @records.unshift(item("Refresh issue", clean(error.message, 180), "inspect", "No system state was changed"))
    @records = @records.first(MAX_ITEMS)
    snapshot
  end

  private

  def after_add(record)
    record["status"] = STATUSES.first
    record
  end

  def scan_system
    registry = parse_json(command_text(["omarchy", "plugin", "list", "--json"]))
    registry = [] unless registry.is_a?(Array)
    enabled = registry.select { |plugin| plugin.is_a?(Hash) && plugin["enabled"] }

    stock_root = "/usr/share/omarchy/shell/plugins"
    stock_paths = {}
    relative_files(stock_root).select { |relative| relative.end_with?("manifest.json") }.each do |relative|
      path = File.join(stock_root, relative)
      manifest = parse_json(safe_read(path))
      next unless manifest.is_a?(Hash) && manifest["id"]
      stock_paths[manifest["id"].to_s] = File.dirname(path)
    end

    processes = command_text([
      "ps", "-C", "omarchy-ui-runt", "-o",
      "pid=,ppid=,%cpu=,%mem=,etimes=,args=", "--sort=ppid"
    ]).lines
    sockets = command_text(["ss", "-H", "-t", "-u", "-n", "-p"], timeout: 5).lines
    journal = command_text([
      "journalctl", "--user", "--since", "-30 minutes", "-n", "240",
      "--no-pager", "-o", "cat"
    ], timeout: 10).lines
    source_extensions = %w[.rb .qml .js .sh .service .desktop]
    cue_sets = {
      "command" => ["Command.run", "ShellCommand", "Process", "spawn", "exec", "system("],
      "network" => ["Net::HTTP", "TCPSocket", "UDPSocket", "WebSocket", "curl", "wget"],
      "write" => ["File.write", "File.open", "File.rename", "File.delete", "mkdir", "FileUtils", " > "],
      "secrets" => ["/.ssh", "~/.ssh", "/.gnupg", "~/.gnupg", "/.aws", "~/.aws", "keyring", "secret-tool"],
      "privilege" => ["sudo", "pkexec", "doas", "polkit"],
      "persistence" => ["systemctl --user enable", ".config/autostart", "crontab", "loginctl enable-linger"]
    }

    rows = enabled.filter_map do |plugin|
      plugin_id = clean(plugin["id"], 120)
      next if plugin_id.empty? || plugin_id == "izeesoft.plugin-pulse"
      first_party = plugin["firstParty"] == true
      root = if first_party
        stock_paths[plugin_id]
      else
        File.join(File.expand_path("~/.config/omarchy/plugins"), plugin_id)
      end
      files = root ? relative_files(root).first(512) : []
      files = files.reject do |relative|
        %w[Components/ Controls/ Fonts/ Theme/].any? { |prefix| relative.start_with?(prefix) }
      end
      executable_paths = if root
        command_text([
          "find", root, "-xdev", "-type", "f", "-perm", "/111",
          "-not", "-path", "*/.git/*", "-print"
        ], timeout: 5).lines.first(64).map(&:strip).reject(&:empty?)
      else
        []
      end
      executable_count = executable_paths.length

      cues = {}
      cue_sets.each_key { |kind| cues[kind] = 0 }
      languages = []
      source_endpoints = []
      files.each do |relative|
        extension = File.extname(relative).downcase
        next unless source_extensions.include?(extension)
        languages << "Ruby" if extension == ".rb"
        languages << "QML" if extension == ".qml"
        languages << "JavaScript" if extension == ".js"
        languages << "Shell" if extension == ".sh"
        content = safe_read(File.join(root, relative), 131_072)
        next unless content
        extract_http_urls(content, 8).each do |url|
          endpoint = redact_http_url(url)
          source_endpoints << endpoint unless endpoint.empty? || source_endpoints.include?(endpoint)
        end
        cue_sets.each do |kind, markers|
          cues[kind] += 1 if markers.any? { |marker| content.include?(marker) }
        end
      end

      process_line = processes.find do |line|
        !first_party && line.include?("/#{plugin_id}/") && line.include?("omarchy-ui-runtime")
      end
      process_fields = process_line ? process_line.strip.split : []
      pid = process_fields[0]
      cpu = process_fields[2]
      memory = process_fields[3]
      age = process_fields[4]
      child_lines = if pid && pid.to_i.positive?
        command_text([
          "ps", "--ppid", pid, "-o", "pid=,ppid=,%cpu=,%mem=,etimes=,args="
        ], timeout: 5).lines.first(16)
      else
        []
      end
      process_ids = []
      process_ids << pid if pid
      child_lines.each do |line|
        child_pid = line.strip.split.first
        process_ids << child_pid if child_pid
      end
      connections = sockets.filter_map do |line|
        socket_pid = socket_process_id(line)
        next unless socket_pid && process_ids.include?(socket_pid)
        fields = line.strip.split
        next if fields.length < 6
        {
          "protocol" => clean(fields[0], 12),
          "state" => clean(fields[1], 20),
          "local" => clean(fields[4], 120),
          "remote" => clean(fields[5], 120),
          "pid" => socket_pid
        }
      end.first(8)
      child_lines.each do |line|
        extract_http_urls(line, 4).each do |url|
          endpoint = redact_http_url(url)
          source_endpoints << endpoint unless endpoint.empty? || source_endpoints.include?(endpoint)
        end
      end
      source_endpoints = source_endpoints.first(8)
      live_sockets = connections.length
      http_calls = http_audit_records(plugin_id)

      evidence = journal.select { |line| line.include?(plugin_id) }
      reloads = evidence.count { |line| line.downcase.include?("reload") }
      errors = evidence.count do |line|
        value = line.downcase
        value.include?("error") || value.include?("failed") || value.include?("warning")
      end

      commit = ""
      origin = ""
      changed = false
      if root && File.directory?(File.join(root, ".git"))
        commit = clean(command_text(["git", "-C", root, "rev-parse", "--short=10", "HEAD"]), 20).strip
        changed = !command_text([
          "git", "-C", root, "status", "--porcelain", "--untracked-files=no"
        ]).strip.empty?
        git_config = safe_read(File.join(root, ".git", "config"), 16_384).to_s
        origin_line = git_config.lines.find { |line| line.strip.start_with?("url =") }
        origin = clean(origin_line.to_s.sub("url =", "").strip, 120)
      end

      manifest = root ? parse_json(safe_read(File.join(root, "manifest.json"))) : nil
      manifest = {} unless manifest.is_a?(Hash)
      runtime_path = root ? File.join(root, "omarchy-ui-runtime") : ""
      checksum_path = root ? File.join(root, "omarchy-ui-runtime.sha256") : ""
      expected_sha = safe_read(checksum_path, 256).to_s.split.first.to_s
      actual_sha = if !runtime_path.empty? && File.file?(runtime_path)
        command_text(["sha256sum", runtime_path], timeout: 8).split.first.to_s
      else
        ""
      end
      checksum_matches = expected_sha.length == 64 && actual_sha == expected_sha
      known_runtime = KNOWN_OMARCHY_UI_RUNTIMES[actual_sha]
      runtime_known = !known_runtime.nil?
      other_executables = executable_paths.reject { |path| path == runtime_path }
      checksum_mismatch = expected_sha.length == 64 && !actual_sha.empty? && actual_sha != expected_sha
      omarchy_ui = files.include?("main.rb") && (runtime_known || files.include?("runtime-provenance.json"))
      framework = if omarchy_ui
        "Omarchy UI · Ruby + Zui"
      elsif languages.empty?
        "No readable source"
      else
        languages.uniq.first(3).join(" + ")
      end
      trust = if first_party
        "official"
      elsif runtime_known && checksum_matches && other_executables.empty?
        "verified runtime"
      elsif executable_count.zero?
        "source visible"
      else
        "executable review"
      end

      security_level, security_finding = if first_party
        finding = if executable_count.zero?
          "Official Omarchy plugin · no standalone executable"
        else
          "Official Omarchy plugin · #{executable_count} packaged executable file#{executable_count == 1 ? "" : "s"}"
        end
        ["official", finding]
      elsif checksum_mismatch
        ["danger", "Runtime checksum mismatch · executable file changed"]
      elsif runtime_known && checksum_matches && other_executables.empty?
        ["verified", "Known #{known_runtime} · executable checksum verified"]
      elsif runtime_known && checksum_matches
        count = other_executables.length
        ["review", "Known framework runtime + #{count} other executable file#{count == 1 ? "" : "s"} · review"]
      elsif executable_count.positive?
        suffix = checksum_matches ? "plugin checksum matches, but executable is not recognized" : "review before trusting"
        ["review", "#{executable_count} executable file#{executable_count == 1 ? "" : "s"} detected · #{suffix}"]
      else
        ["clear", "No standalone executable file detected"]
      end

      capabilities = []
      capabilities << "runs local commands" if cues["command"].positive?
      capabilities << "can make network requests" if cues["network"].positive?
      capabilities << "writes local files" if cues["write"].positive?
      capabilities << "references credential paths" if cues["secrets"].positive?
      capabilities << "requests elevated access" if cues["privilege"].positive?
      capabilities << "can add persistence" if cues["persistence"].positive?
      capabilities << "no high-impact source cues" if capabilities.empty?

      sensitive_source = []
      sensitive_source << "credential paths" if cues["secrets"].positive?
      sensitive_source << "elevated access" if cues["privilege"].positive?
      sensitive_source << "persistence" if cues["persistence"].positive?
      if !first_party && !sensitive_source.empty?
        security_level = "review" unless security_level == "danger"
        security_finding = "#{security_finding} · source references #{sensitive_source.join(" + ")}"
      end

      service_kind = Array(plugin["kinds"]).include?("service")
      status = if %w[danger review].include?(security_level) || errors.positive? || (!first_party && service_kind && !process_line)
        "attention"
      elsif changed
        "changed"
      elsif process_line
        "active"
      else
        "loaded"
      end
      kinds = Array(plugin["kinds"]).join(" · ")
      detail = if process_line
        "#{process_ids.length} live process#{process_ids.length == 1 ? "" : "es"} · PID #{pid} · CPU #{cpu}% · MEM #{memory}% · age #{age}s"
      else
        "Shared Omarchy shell · #{kinds}"
      end
      meta = capabilities.join(" · ")
      record = item(plugin["name"] || plugin_id, detail, status, meta)
      record["evidence"] = {
        "plugin_id" => plugin_id,
        "trust" => trust,
        "security_level" => security_level,
        "security_finding" => security_finding,
        "framework" => framework,
        "live_sockets" => live_sockets,
        "connections" => connections,
        "source_endpoints" => source_endpoints,
        "http_calls" => http_calls,
        "processes" => process_ids.length,
        "errors" => errors,
        "reloads" => reloads,
        "executables" => executable_count,
        "origin" => origin.empty? ? (first_party ? "packaged by Omarchy" : "origin unavailable") : origin,
        "commit" => commit,
        "version" => clean(manifest["version"], 40),
        "author" => clean(manifest["author"], 80),
        "capabilities" => capabilities.join(" · "),
        "cue_total" => cues.values.inject(0) { |sum, value| sum + value }
      }
      record
    end

    attention = rows.count { |record| record["status"] == "attention" }
    active = rows.count { |record| record["status"] == "active" }
    @score = rows.length
    @summary = attention.positive? ? "#{attention} need review · #{active} live" : "#{active} live · no flags"
    rows.sort_by do |record|
      rank = { "attention" => 0, "changed" => 1, "active" => 2, "loaded" => 3 }
      [rank.fetch(record["status"], 4), record["title"].downcase]
    end
  end

  def item(title, detail, status = "observed", meta = "")
    {
      "id" => fnv1a("#{title}:#{detail}:#{status}"),
      "title" => clean(title), "detail" => clean(detail),
      "status" => clean(status, 80), "meta" => clean(meta, 240)
    }
  end

  def run(argv, timeout: 8)
    return @runner.call(argv, timeout: timeout) if @runner
    OmarchyUI::Command.run(argv, timeout: timeout, max_output_bytes: OUTPUT_LIMIT)
  rescue Errno::ENOENT, OmarchyUI::CommandTimeout, OmarchyUI::CommandOutputLimit
    nil
  end

  def command_text(argv, timeout: 8)
    result = run(argv, timeout: timeout)
    return "" unless result && result.success?
    clean(result.stdout.to_s, OUTPUT_LIMIT)
  end

  def parse_json(text)
    return nil if text.nil? || text.empty? || text.bytesize > OUTPUT_LIMIT
    JSON.parse(text)
  rescue JSON::ParserError
    nil
  end

  def clean(value, limit = MAX_TEXT)
    value.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "�").byteslice(0, limit).to_s
  rescue StandardError
    value.to_s.byteslice(0, limit).to_s
  end

  def safe_read(path, limit = MAX_STATE_BYTES)
    return nil unless File.file?(path)
    File.open(path, "rb") do |file|
      data = file.read(limit + 1)
      return nil if data && data.bytesize > limit
      data
    end
  rescue SystemCallError
    nil
  end

  def redact_http_url(value)
    url = clean(value, 300)
    query_index = url.index("?")
    fragment_index = url.index("#")
    ending = [query_index, fragment_index].compact.min
    url = url.byteslice(0, ending).to_s if ending
    scheme, remainder = url.split("://")
    return "" unless %w[http https].include?(scheme) && remainder
    parts = remainder.split("/")
    authority = parts.shift
    path = parts.join("/")
    authority = authority.split("@").last.to_s
    clean("#{scheme}://#{authority}#{path.empty? ? "" : "/#{path}"}", 180)
  end

  def extract_http_urls(text, limit)
    value = text.to_s
    results = []
    position = 0
    while position < value.bytesize && results.length < limit
      plain = value.index("http://", position)
      secure = value.index("https://", position)
      starts = [plain, secure].compact
      break if starts.empty?
      start = starts.min
      finish = start
      while finish < value.bytesize
        byte = value.getbyte(finish)
        break if byte <= 32 || [34, 39, 40, 41, 44, 59, 60, 62, 91, 93, 123, 125].include?(byte)
        finish += 1
      end
      results << value.byteslice(start, finish - start).to_s
      position = [finish + 1, start + 1].max
    end
    results
  end

  def socket_process_id(line)
    marker = line.to_s.index("pid=")
    return nil unless marker
    position = marker + 4
    number = 0
    found = false
    while position < line.bytesize
      byte = line.getbyte(position)
      break unless byte >= 48 && byte <= 57
      number = (number * 10) + (byte - 48)
      found = true
      position += 1
    end
    found ? number.to_s : nil
  end

  def http_audit_records(plugin_id)
    identifier = plugin_id.to_s
    return [] if identifier.empty? || identifier.bytesize > 120
    identifier.each_byte do |byte|
      allowed = (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) ||
        (byte >= 97 && byte <= 122) || [45, 46, 58, 95].include?(byte)
      return [] unless allowed
    end
    path = File.join(File.expand_path("~/.local/state/omarchy-ui-audit"), "#{identifier}.jsonl")
    return [] unless File.file?(path) && !File.symlink?(path)
    body = safe_read(path, 131_072)
    return [] unless body
    body.lines.last(8).filter_map do |line|
      event = parse_json(line.strip)
      next unless event.is_a?(Hash) && event["type"] == "http"
      url = redact_http_url(event["url"])
      next if url.empty?
      status = event["http_status"].to_i
      {
        "method" => clean(event["method"].to_s.upcase, 12),
        "url" => url,
        "http_status" => status.between?(100, 599) ? status : 0,
        "exit_status" => event["exit_status"].to_i,
        "duration_ms" => [[event["duration_ms"].to_i, 0].max, 3_600_000].min,
        "response_bytes" => [[event["response_bytes"].to_i, 0].max, OUTPUT_LIMIT].min,
        "observed_at" => event["observed_at"].to_i
      }
    end
  rescue SystemCallError
    []
  end

  def relative_files(root)
    return [] unless File.directory?(root)
    result = []
    queue = [[root, ""]]
    until queue.empty? || result.length >= 2_000
      absolute, relative = queue.shift
      Dir.children(absolute).sort.first(512).each do |entry|
        next if entry == ".git" || entry == "node_modules" || entry == "vendor"
        child = File.join(absolute, entry)
        rel = relative.empty? ? entry : File.join(relative, entry)
        if File.directory?(child) && !File.symlink?(child)
          queue << [child, rel]
        elsif File.file?(child)
          result << rel
        end
      rescue SystemCallError
        next
      end
    end
    result
  end

  def executable?(name)
    return false if name.to_s.include?(File::SEPARATOR)
    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |directory|
      path = File.join(directory, name.to_s)
      File.respond_to?(:executable?) ? File.executable?(path) : File.file?(path)
    end
  end

  def secure_equal?(left, right)
    return false unless left.bytesize == right.bytesize
    difference = 0
    left.bytes.zip(right.bytes) { |a, b| difference |= a ^ b }
    difference.zero?
  end

  def fnv1a(value)
    hash = 2_166_136_261
    value.to_s.each_byte { |byte| hash = ((hash ^ byte) * 16_777_619) & 0xffff_ffff }
    format("%08x", hash)
  end

  def percent(part, whole)
    return 0 if whole.to_i <= 0
    [[(part.to_f / whole.to_f * 100).round, 0].max, 100].min
  end

  def human_bytes(bytes)
    value = bytes.to_f
    units = %w[B KiB MiB GiB TiB]
    unit = units.shift
    while value >= 1024 && !units.empty?
      value /= 1024.0
      unit = units.shift
    end
    "#{value.round(value >= 10 ? 0 : 1)} #{unit}"
  end

  def human_duration(seconds)
    days = seconds.to_f / 86_400
    return "#{days.round} days" if days < 365
    "#{(days / 365).round(1)} years"
  end

  def short_path(path)
    home = File.expand_path("~")
    path.start_with?(home) ? path.sub(home, "~") : path
  end

  def create_directory(path)
    current = path.start_with?(File::SEPARATOR) ? File::SEPARATOR : ""
    path.split(File::SEPARATOR).each do |part|
      next if part.empty?
      current = File.join(current, part)
      Dir.mkdir(current, 0o700) unless File.directory?(current)
    end
  end

  def load_state
    return unless File.file?(@state_path) && !File.symlink?(@state_path)
    data = safe_read(@state_path)
    parsed = data ? JSON.parse(data) : {}
    @records = Array(parsed["records"]).filter_map { |record| normalize_record(record) }.first(MAX_ITEMS)
    @history = Array(parsed["history"]).select { |entry| entry.is_a?(Hash) }.last(MAX_HISTORY)
    @settings = parsed["settings"].is_a?(Hash) ? parsed["settings"] : {}
    @score = @records.length
    @summary = @records.empty? ? "Ready" : "#{@records.length} #{SCORE_LABEL}"
  rescue JSON::ParserError, SystemCallError
    @records = []; @history = []; @settings = {}
  end

  def normalize_record(record)
    return nil unless record.is_a?(Hash)
    title = clean(record["title"])
    return nil if title.empty?
    {
      "id" => clean(record["id"], 80), "title" => title,
      "detail" => clean(record["detail"]), "status" => clean(record["status"], 80),
      "meta" => clean(record["meta"], 240), "evidence" => record["evidence"].is_a?(Hash) ? record["evidence"] : nil
    }.compact
  end

  def persist
    payload = JSON.generate("records" => @records.first(MAX_ITEMS), "history" => @history.last(MAX_HISTORY), "settings" => @settings)
    raise "state exceeds safety limit" if payload.bytesize > MAX_STATE_BYTES
    temporary = "#{@state_path}.tmp-#{Process.pid}-#{rand(1_000_000)}"
    File.open(temporary, "w", 0o600) { |file| file.write(payload) }
    File.rename(temporary, @state_path)
  ensure
    File.delete(temporary) if temporary && File.file?(temporary)
  end
end


backend = SuiteBackend.new

OmarchyUI.plugin do
  state :snapshot, backend.snapshot
  state :primary, ""
  state :secondary, ""
  state :compose, false
  state :page, 0
  state :selected_plugin, ""

  refresh = proc do
    state.snapshot = backend.refresh
  rescue StandardError
    state.snapshot = backend.snapshot
  end

  status_color = lambda do |status|
    value = status.to_s.downcase
    danger = false
    healthy = false
    %w[broken critical missing mismatch drift inactive slow tight risk invalid attention].each do |token|
      danger = true if value.include?(token)
    end
    %w[ready valid verified finished aligned unique internal familiar steady covered available detected normal active loaded].each do |token|
      healthy = true if value.include?(token)
    end
    if danger
      "#ff6b78"
    elsif healthy
      "#73e6cf"
    else
      "#efc66b"
    end
  end

  status_icon = lambda do |status|
    value = status.to_s.downcase
    danger = false
    healthy = false
    %w[broken critical missing mismatch drift inactive slow tight risk invalid attention].each do |token|
      danger = true if value.include?(token)
    end
    %w[ready valid verified finished aligned unique internal familiar steady covered available detected normal active loaded].each do |token|
      healthy = true if value.include?(token)
    end
    if danger
      :warning
    elsif healthy
      :circle_check
    else
      :circle_info
    end
  end

  first_number = lambda do |value|
    number = 0
    value.to_s.split.each do |token|
      candidate = token.to_i
      if candidate > 0
        number = candidate
        break
      end
    end
    number
  end

  bar_widget do
    row spacing: 6 do
      icon :eye, size: 14, color: "#73e6cf"
      text "PULSE", style: :caption, color: "#73e6cf"
      text(style: :caption) { state.snapshot.fetch("summary") }
    end
    on_click { open_panel :plugin_pulse }
  end

  panel :plugin_pulse do
    scroll width: 660, height: 780 do
      dynamic id: :scene, spacing: 16 do
        entries = state.snapshot.fetch("items")
        selected_entry = entries.find { |entry| entry.fetch("id", "") == state.selected_plugin }

        if selected_entry
          evidence = selected_entry.fetch("evidence", {})
          connections = Array(evidence.fetch("connections", []))
          endpoints = Array(evidence.fetch("source_endpoints", []))
          http_calls = Array(evidence.fetch("http_calls", []))
          signal_color = evidence.fetch("security_level", "") == "danger" ? "#ff8b8b" :
            (evidence.fetch("security_level", "") == "review" ? "#f0bd6a" : "#73e6cf")

          row spacing: 10 do
            button "Back", icon: :arrow_left do
              state.selected_plugin = ""
            end
            column spacing: 1 do
              text selected_entry.fetch("title"), size: 27, bold: true, width: 390
              text evidence.fetch("plugin_id", ""), style: :caption, width: 390
            end
            text evidence.fetch("trust", "unknown").upcase, style: :caption, color: signal_color
          end
          separator
          text "SECURITY SIGNAL", size: 12, bold: true, color: signal_color
          text "━━━━━━╲╱━━━━━━━━╲━━╱━━━━━━━━━━━━━━━━━━━━━━●", size: 17, color: signal_color
          text evidence.fetch("security_finding", "Security finding unavailable"),
               size: 18, bold: true, width: 590, wrap: true
          text evidence.fetch("framework", "Unknown framework"), style: :caption,
               color: "#73e6cf", width: 590, wrap: true
          text selected_entry.fetch("meta", ""), style: :caption, color: "#829088", width: 590, wrap: true
          row spacing: 34 do
            column spacing: 0 do
              text evidence.fetch("errors", 0).to_s.rjust(2, "0"), size: 28, bold: true,
                   color: evidence.fetch("errors", 0).to_i.zero? ? "#73e6cf" : "#ff8b8b"
              text "ERRORS", style: :caption
            end
            column spacing: 0 do
              text evidence.fetch("reloads", 0).to_s.rjust(2, "0"), size: 28, bold: true
              text "RELOADS", style: :caption
            end
            column spacing: 0 do
              text evidence.fetch("executables", 0).to_s.rjust(2, "0"), size: 28, bold: true
              text "EXECUTABLES", style: :caption
            end
            column spacing: 0 do
              text evidence.fetch("live_sockets", 0).to_s.rjust(2, "0"), size: 28, bold: true
              text "SOCKETS", style: :caption
            end
          end
          text selected_entry.fetch("detail", ""), style: :caption, width: 590, wrap: true
          separator
          text "LIVE NETWORK", size: 12, bold: true, color: "#73e6cf"
          if connections.empty?
            text "○━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  no attributable socket",
                 style: :caption, color: "#829088", width: 590, wrap: true
          else
            connections.each do |connection|
              column spacing: 3 do
                text "#{connection.fetch("protocol", "?").upcase}  PID #{connection.fetch("pid", "?")}  #{connection.fetch("state", "unknown").upcase}",
                     style: :caption, color: "#73e6cf"
                text "●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━●", style: :caption, color: "#73e6cf"
                text "#{connection.fetch("local", "?")}  →  #{connection.fetch("remote", "?")}",
                     style: :caption, width: 590, wrap: true
              end
            end
          end
          separator
          text "HTTP RESPONSES", size: 12, bold: true, color: "#73e6cf"
          if http_calls.empty?
            text "No framework HTTP response recorded; encrypted payloads remain private.",
                 style: :caption, color: "#829088", width: 590, wrap: true
          else
            http_calls.reverse_each do |call|
              http_status = call.fetch("http_status", 0).to_i
              call_color = http_status >= 400 || call.fetch("exit_status", 0).to_i != 0 ? "#ff8b8b" : "#73e6cf"
              response = http_status.positive? ? "HTTP #{http_status}" : "EXIT #{call.fetch("exit_status", 0)}"
              column spacing: 2 do
                text "#{call.fetch("method", "GET")}  #{response}  ━━━━━━━━━━━━━━━━━━━●", color: call_color
                text call.fetch("url", ""), style: :caption, width: 590, wrap: true
                text "#{call.fetch("response_bytes", 0)} bytes · #{call.fetch("duration_ms", 0)} ms",
                     style: :caption, color: "#829088"
              end
            end
          end
          unless endpoints.empty?
            separator
            text "SOURCE ENDPOINTS", size: 12, bold: true, color: "#73e6cf"
            endpoints.each { |endpoint| text endpoint, style: :caption, width: 590, wrap: true }
          end
        else
          attention = entries.count { |entry| entry.fetch("status", "") == "attention" }
          dedicated = entries.count { |entry| entry.fetch("status", "") == "active" }
          live_sockets = entries.inject(0) do |sum, entry|
            sum + entry.fetch("evidence", {}).fetch("live_sockets", 0).to_i
          end
          page_size = 5
          page_count = [(entries.length.to_f / page_size).ceil, 1].max
          page = state.page.to_i % page_count
          visible_entries = entries.drop(page * page_size).first(page_size)

          column spacing: 2 do
            text "#{entries.length} plugin runtimes on the monitor", style: :caption, width: 610
            row spacing: 9 do
              text "Plugin", size: 30, bold: true
              icon :eye, size: 22, color: "#73e6cf"
              text "Pulse", size: 30, bold: true, width: 455
              action_button :refresh, tooltip: "Sample runtime signals", foreground: "#73e6cf" do
                async(&refresh)
              end
            end
          end
          separator
          text "LIVE RUNTIME SIGNAL", size: 12, bold: true, color: "#73e6cf"
          text "●━━━━━━━━╲╱━━━━━━╲━━╱━━━━━━━━╲╱━━━━━━━━━━━━━━●", size: 18, color: "#73e6cf"
          row spacing: 42 do
            column spacing: 0 do
              text dedicated.to_s.rjust(2, "0"), size: 34, bold: true, color: "#73e6cf"
              text "LIVE RUNTIMES", style: :caption
            end
            column spacing: 0 do
              text live_sockets.to_s.rjust(2, "0"), size: 34, bold: true
              text "SOCKETS", style: :caption
            end
            column spacing: 0 do
              text attention.to_s.rjust(2, "0"), size: 34, bold: true,
                   color: attention.zero? ? "#829088" : "#ff8b8b"
              text "REVIEW FLAGS", style: :caption
            end
          end
          separator
          row spacing: 10 do
            text "RUNTIME CHANNELS  ·  #{page + 1}/#{page_count}", size: 12, bold: true,
                 color: "#73e6cf", width: 380
            button "Previous", icon: :arrow_left do
              state.page = page.zero? ? page_count - 1 : page - 1
            end
            button "Next", icon: :arrow_right, accent: "#73e6cf" do
              state.page = (page + 1) % page_count
            end
          end

          if entries.empty?
            text "No enabled plugin runtimes were returned by Omarchy.",
                 style: :caption, color: "#829088", width: 590, wrap: true
          else
            visible_entries.each_with_index do |entry, index|
              evidence = entry.fetch("evidence", {})
              pulse_color = status_color.call(entry.fetch("status", ""))
              column spacing: 4 do
                row spacing: 10 do
                  rectangle width: 4, height: 54, radius: 2, color: pulse_color
                  text (page * page_size + index + 1).to_s.rjust(2, "0"),
                       style: :caption, color: pulse_color, width: 24
                  column spacing: 1 do
                    text entry.fetch("title"), size: 16, bold: true, width: 360
                    text evidence.fetch("framework", "Unknown framework"),
                         style: :caption, color: "#73e6cf", width: 360, wrap: true
                  end
                  text evidence.fetch("trust", "unknown").upcase,
                       style: :caption, color: pulse_color, width: 100
                  button "Trace", icon: :circle_info do
                    state.selected_plugin = entry.fetch("id", "")
                  end
                end
                text "    ●━━━━━━╲╱━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━●", style: :caption, color: pulse_color
                text "    #{evidence.fetch("errors", 0)} errors · #{evidence.fetch("reloads", 0)} reloads · #{evidence.fetch("executables", 0)} executables · #{evidence.fetch("live_sockets", 0)} sockets",
                     style: :caption, color: "#829088", width: 560, wrap: true
                text "    #{evidence.fetch("security_finding", "Security finding unavailable")}",
                     style: :caption, color: pulse_color, width: 560, wrap: true
              end
              separator unless index == visible_entries.length - 1
            end
          end
        end
      end
    end
  end

  after(0.08, &refresh)
  every(45, &refresh)
end
