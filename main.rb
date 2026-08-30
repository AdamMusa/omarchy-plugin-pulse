# source: main.rb
# frozen_string_literal: true


# source: lib/backend.rb
# frozen_string_literal: true

class SuiteBackend
  SCORE_LABEL = "live plugins"
  STATUSES = ["active", "loaded", "changed", "attention"].freeze
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
    journal = command_text([
      "journalctl", "--user", "--since", "-30 minutes", "-n", "240",
      "--no-pager", "-o", "cat"
    ], timeout: 10).lines
    source_extensions = %w[.rb .qml .js .sh .json .toml .yaml .yml .service .desktop]
    cue_sets = {
      "command" => ["Command.run", "Process", "ShellCommand", "spawn", "exec", "system("],
      "network" => ["https://", "http://", "curl", "wget", "WebSocket", "NetworkManager"],
      "write" => ["File.write", "File.rename", "File.delete", "mkdir", "FileUtils.cp", "FileUtils.mv"]
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
      executable_count = files.count do |relative|
        path = File.join(root, relative)
        File.respond_to?(:executable?) ? File.executable?(path) : false
      end

      cues = { "command" => 0, "network" => 0, "write" => 0 }
      files.each do |relative|
        next unless source_extensions.include?(File.extname(relative).downcase)
        content = safe_read(File.join(root, relative), 131_072)
        next unless content
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

      evidence = journal.select { |line| line.include?(plugin_id) }
      reloads = evidence.count { |line| line.downcase.include?("reload") }
      errors = evidence.count do |line|
        value = line.downcase
        value.include?("error") || value.include?("failed") || value.include?("warning")
      end

      commit = ""
      changed = false
      if root && File.directory?(File.join(root, ".git"))
        commit = clean(command_text(["git", "-C", root, "rev-parse", "--short=10", "HEAD"]), 20).strip
        changed = !command_text([
          "git", "-C", root, "status", "--porcelain", "--untracked-files=no"
        ]).strip.empty?
      end

      service_kind = Array(plugin["kinds"]).include?("service")
      status = if errors.positive? || (!first_party && service_kind && !process_line)
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
        "Dedicated runtime · PID #{pid} · CPU #{cpu}% · MEM #{memory}% · age #{age}s"
      else
        "Shared Omarchy shell · #{kinds}"
      end
      meta = "#{errors} errors · #{reloads} reloads · #{executable_count} executables · " \
        "#{cues["command"]} command cues · #{cues["network"]} network cues · #{cues["write"]} write cues"
      meta += " · commit #{commit}" unless commit.empty?
      item(plugin["name"] || plugin_id, detail, status, meta)
    end

    attention = rows.count { |record| record["status"] == "attention" }
    active = rows.count { |record| record["status"] == "active" }
    @score = rows.length
    @summary = attention.positive? ? "#{attention} need review" : "#{active} dedicated · quiet"
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

  refresh = proc do
    state.snapshot = backend.refresh
  rescue StandardError
    state.snapshot = backend.snapshot
  end

  status_color = lambda do |status|
    value = status.to_s.downcase
    danger = false
    healthy = false
    %w[broken critical missing mismatch drift inactive slow tight hotspot invalid attention].each do |token|
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
    %w[broken critical missing mismatch drift inactive slow tight hotspot invalid attention].each do |token|
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
    row spacing: 7 do
      icon :eye, color: "#73e6cf"
      text { state.snapshot.fetch("summary") }
    end
    on_click { open_panel :plugin_pulse }
  end

  panel :plugin_pulse do
    scroll width: 660, height: 760 do
      dynamic id: :scene, spacing: 16 do
        entries = state.snapshot.fetch("items")
        history = state.snapshot.fetch("history")

        row spacing: 12 do
          icon :eye, size: 30, color: "#73e6cf"
          column spacing: 2 do
            text "Plugin Pulse", style: :heading, width: 500
            text state.snapshot.fetch("summary"), style: :caption, width: 500
          end
          action_button :refresh, tooltip: "Refresh", foreground: "#73e6cf" do
            async(&refresh)
          end
        end

        separator
        attention = entries.count { |entry| entry.fetch("status", "") == "attention" }
            changed = entries.count { |entry| entry.fetch("status", "") == "changed" }
            dedicated = entries.count { |entry| entry.fetch("status", "") == "active" }
            row spacing: 20 do
              column spacing: 2 do
                text "Runtime map", size: 34, bold: true, color: "#73e6cf"
                text "Evidence from the live shell, process table, journal, and installed source.", style: :caption, width: 350, wrap: true
              end
              column spacing: 0 do
                text entries.length.to_s.rjust(2, "0"), size: 42, bold: true
                text "enabled plugins", style: :caption
              end
            end
            row spacing: 10 do
              card padding: 12, spacing: 2, accent: "#73e6cf" do
                text dedicated.to_s, size: 28, bold: true, color: "#73e6cf"
                text "dedicated runtimes", style: :caption
              end
              card padding: 12, spacing: 2 do
                text changed.to_s, size: 28, bold: true, color: "#efc66b"
                text "source changes", style: :caption
              end
              card padding: 12, spacing: 2 do
                text attention.to_s, size: 28, bold: true, color: attention.zero? ? "#73e6cf" : "#ff6b78"
                text "need attention", style: :caption
              end
            end
            text "Signals are observations, not a malware-free guarantee.", style: :caption, color: "#9ca8b2"
            separator
            section_header "Enabled plugin activity"
            if entries.empty?
              column spacing: 8 do
                        icon :eye, size: 34, color: "#73e6cf"
                        text "Nothing to show yet", style: :heading
                        text "No enabled plugins were returned by Omarchy's registry.", style: :caption, wrap: true, width: 560
                      end
            else
              entries.first(18).each_with_index do |entry, index|
                row spacing: 10 do
                  rectangle width: 3, height: 54, radius: 2, color: status_color.call(entry.fetch("status", ""))
                  icon status_icon.call(entry.fetch("status", "")), size: 16, color: status_color.call(entry.fetch("status", ""))
                  column spacing: 2 do
                    row spacing: 8 do
                      text entry.fetch("title"), width: 330
                      text entry.fetch("status", "").upcase, style: :caption, color: status_color.call(entry.fetch("status", ""))
                    end
                    text entry.fetch("detail", ""), style: :caption, width: 500, wrap: true
                    text entry.fetch("meta", ""), style: :caption, color: "#9ca8b2", width: 500, wrap: true
                  end
                end
                separator unless index == [entries.length, 18].min - 1
              end
            end
      end
    end
  end

  after(0.08, &refresh)
  every(45, &refresh)
end
