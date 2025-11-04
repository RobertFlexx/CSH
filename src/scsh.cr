#!/usr/bin/env crystal run
# scsh — Simple Crystal SHell
# Build:  crystal build src/scsh.cr -o scsh --release
# Dev:    crystal run src/scsh.cr

require "time"

module Scsh
  SCSH_VERSION = "0.1.1-BETA"

  # ---------------- State ----------------
  @@child_pids        = [] of Int32
  @@aliases           = {} of String => String
  @@history           = [] of String
  @@prompt_color      = 33
  @@current_quote     = "Keep calm and code on."
  @@last_render_rows  = 1

  # ---------------- Init: env & CWD ----------------
  ENV["SHELL"] = "scsh-#{SCSH_VERSION}"
  print "\033]0;scsh-#{SCSH_VERSION}\007"

  begin
    if home = ENV["HOME"]?
      Dir.cd(home)
    end
  rescue
  end

  # ---------------- History (file) ----------------
  HISTORY_FILE = (ENV["HOME"]? ? File.join(ENV["HOME"], ".scsh_history") : ".scsh_history")

  begin
    if File.exists?(HISTORY_FILE)
      File.each_line(HISTORY_FILE) { |line| @@history << line.chomp }
    end
  rescue
  end

  # ---------------- RC file (create if missing) ----------------
  RC_FILE = (ENV["HOME"]? ? File.join(ENV["HOME"], ".scshrc") : ".scshrc")
  begin
    unless File.exists?(RC_FILE)
      rc = "# ~/.scshrc — scsh configuration\n" \
           "# This file was created automatically by scsh #{SCSH_VERSION}.\n" \
           "# You can keep personal notes or planned settings here.\n" \
           "# (Currently not sourced by scsh runtime.)\n"
      File.write(RC_FILE, rc)
    end
  rescue
  end

  # Ensure TTY echo of ^C is restored and history is saved
  at_exit do
    begin
      File.open(HISTORY_FILE, "w") do |f|
        @@history.each { |line| f.puts line }
      end
    rescue
    end
    restore_ctrl_c_echo
  end

  # ---------------- Quotes ----------------
  QUOTES = [
    "Keep calm and code on.",
    "Did you try turning it off and on again?",
    "There’s no place like 127.0.0.1.",
    "To iterate is human, to recurse divine.",
    "sudo rm -rf / – Just kidding, don’t do that!",
    "The shell is mightier than the sword.",
    "A journey of a thousand commits begins with a single push.",
    "In case of fire: git commit, git push, leave building.",
    "Debugging is like being the detective in a crime movie where you are also the murderer.",
    "Unix is user-friendly. It's just selective about who its friends are.",
    "Old sysadmins never die, they just become daemons.",
    "Listen you flatpaker! – Totally Terry Davis",
    "How is #{Crystal::VERSION}? 🤔",
    "Life is short, but your command history is eternal.",
    "If at first you don’t succeed, git commit and push anyway.",
    "rm -rf: the ultimate trust exercise.",
    "Coding is like magic, but with more coffee.",
    "There’s no bug, only undocumented features.",
    "Keep your friends close and your aliases closer.",
    "Why wait for the future when you can Ctrl+Z it?",
    "A watched process never completes.",
    "When in doubt, make it a function.",
    "Some call it procrastination, we call it debugging curiosity.",
    "Life is like a terminal; some commands just don’t execute.",
    "Good code is like a good joke; it needs no explanation.",
    "sudo: because sometimes responsibility is overrated.",
    "Pipes make the world go round.",
    "In bash we trust, in Crystal we wonder.",
    "A system without errors is like a day without coffee.",
    "Keep your loops tight and your sleeps short.",
    "Stack traces are just life giving you directions.",
    "Your mom called, she wants her semicolons back."
  ] of String

  # ---------------- Utilities ----------------
  def self.color(text : String, code : Int32 | String) : String
    "\e[#{code}m#{text}\e[0m"
  end

  def self.random_color : Int32
    [31, 32, 33, 34, 35, 36, 37].sample
  end

  def self.rainbow_codes : Array(Int32)
    [31, 33, 32, 36, 34, 35, 91, 93, 92, 96, 94, 95]
  end

  def self.dynamic_quote : String
    text  = @@current_quote
    codes = rainbow_codes
    len   = codes.size
    String.build do |io|
      text.each_char_with_index do |ch, i|
        io << color(ch.to_s, codes[i % len])
      end
    end
  end

  # Strip ANSI color codes (for width calculations)
  def self.strip_ansi(str : String) : String
    str.gsub(/\e\[[0-9;]*m/, "")
  end

  # Robust $VAR expansion
  def self.expand_vars(str : String) : String
    re = /\$([A-Za-z_][A-Za-z0-9_]*)/
    String.build do |io|
      last = 0
      str.scan(re) do |m|
        s = m.byte_begin(0)
        e = m.byte_end(0)
        io << str.byte_slice(last, s - last)
        if name = m[1]?
          io << (ENV[name]? || "")
        end
        last = e
      end
      io << str.byte_slice(last, str.bytesize - last)
    end
  end

  # Shellwords-ish splitter
  def self.shellsplit(s : String) : Array(String)
    args = [] of String
    mem  = IO::Memory.new
    in_s = false
    in_d = false
    esc  = false

    s.each_char do |ch|
      if esc
        mem << ch
        esc = false
        next
      end

      case ch
      when '\\'
        esc = true
      when '\''
        if !in_d
          in_s = !in_s
        else
          mem << ch
        end
      when '"'
        if !in_s
          in_d = !in_d
        else
          mem << ch
        end
      when ' ', '\t'
        if in_s || in_d
          mem << ch
        else
          if mem.size > 0
            args << String.new(mem.to_slice)
            mem.clear
          end
        end
      else
        mem << ch
      end
    end

    args << String.new(mem.to_slice) if mem.size > 0
    args
  end

  def self.parse_redirection(cmd : String) : {String, String?, String?, Bool}
    stdin_file  = nil.as(String?)
    stdout_file = nil.as(String?)
    append      = false

    if md = cmd.match(/(.*)>>\s*(\S+)/)
      cmd         = md[1].strip
      stdout_file = md[2].strip
      append      = true
    elsif md = cmd.match(/(.*)>\s*(\S+)/)
      cmd         = md[1].strip
      stdout_file = md[2].strip
    end

    if md = cmd.match(/(.*)<\s*(\S+)/)
      cmd        = md[1].strip
      stdin_file = md[2].strip
    end

    {cmd, stdin_file, stdout_file, append}
  end

  def self.human_bytes(bytes : Int64 | Int32 | UInt64 | UInt32 | Float64) : String
    units = ["B", "KB", "MB", "GB", "TB"]
    size  = bytes.to_f64
    unit  = units.shift
    while size > 1024 && !units.empty?
      size /= 1024
      unit = units.shift
    end
    "%.2f %s" % {size, unit}
  end

  # Executable check
  def self.executable_file?(path : String) : Bool
    begin
      (LibC.access(path, LibC::X_OK) == 0) && !File.directory?(path)
    rescue
      false
    end
  end

  # ---------------- PATH lookup ----------------
  def self.find_executable(cmd : String) : String?
    if cmd.includes?('/') || cmd.starts_with?('.')
      return cmd if executable_file?(cmd) && !File.directory?(cmd)
      return nil
    end
    (ENV["PATH"]? || "").split(':').each do |dir|
      path = File.join(dir, cmd)
      return path if executable_file?(path) && !File.directory?(path)
    end
    nil
  end

  # ---------------- Aliases ----------------
  def self.expand_aliases(cmd : String, seen = [] of String) : String
    stripped = cmd.strip
    return cmd if stripped.empty?
    parts = stripped.split(' ', 2)
    first = parts[0]
    rest  = parts.size > 1 ? parts[1] : nil

    return cmd if seen.includes?(first)
    seen << first

    if val = @@aliases[first]?
      expanded = expand_aliases(val, seen)
      rest ? "#{expanded} #{rest}" : expanded
    else
      cmd
    end
  end

  # ---------------- System Info ----------------
  def self.current_time : String
    Time.local.to_s
  end

  def self.hostname : String
    if env = ENV["HOSTNAME"]?
      env
    else
      begin
        System.hostname
      rescue
        "unknown"
      end
    end
  end

  def self.detect_distro : String
    begin
      if File.exists?("/etc/os-release")
        line = File.read("/etc/os-release").lines.find { |l| l.starts_with?("PRETTY_NAME=") }
        if line
          val = line.split('=', 2)[1]?
          return val ? val.strip.gsub('"', "") : Crystal::VERSION
        end
      end
    rescue
    end
    Crystal::VERSION
  end

  def self.read_cpu_times : Array(Int64)
    return [] of Int64 unless File.exists?("/proc/stat")
    line = File.read("/proc/stat").lines.find { |l| l.starts_with?("cpu ") }
    return [] of Int64 unless line
    parts = line.split
    parts[1..].map { |x| x.to_i64 }
  rescue
    [] of Int64
  end

  def self.calculate_cpu_usage(prev : Array(Int64), cur : Array(Int64)) : Float64
    return 0.0 if prev.empty? || cur.empty?
    prev_idle = prev[3] + (prev[4]? || 0_i64)
    idle      = cur[3] + (cur[4]? || 0_i64)
    prev_non  = prev[0] + prev[1] + prev[2] + (prev[5]? || 0_i64) + (prev[6]? || 0_i64) + (prev[7]? || 0_i64)
    non       = cur[0] + cur[1] + cur[2] + (cur[5]? || 0_i64) + (cur[6]? || 0_i64) + (cur[7]? || 0_i64)
    prev_total = prev_idle + prev_non
    total      = idle + non
    totald     = total - prev_total
    idled      = idle - prev_idle
    return 0.0 if totald <= 0
    ((totald - idled).to_f64 / totald.to_f64) * 100.0
  end

  def self.cpu_cores_and_freq : {Int32, Array(Float64)}
    return {0, [] of Float64} unless File.exists?("/proc/cpuinfo")
    cores = 0
    freqs = [] of Float64
    File.each_line("/proc/cpuinfo") do |line|
      cores += 1 if line =~ /^processor\s*:\s*\d+/
      if md = line.match(/^cpu MHz\s*:\s*([\d.]+)/)
        freqs << md[1].to_f64
      end
    end
    {cores, freqs[0, cores]}
  rescue
    {0, [] of Float64}
  end

  def self.nice_bar(p : Float64, w : Int32 = 30, code : Int32 = 32) : String
    p = 0.0 if p < 0.0
    p = 1.0 if p > 1.0
    f   = (p * w).round.to_i
    bar = "█" * f + "░" * (w - f)
    pct = (p * 100).round.to_i
    "#{color("[#{bar}]", code)} #{color("%3d%%" % pct, 37)}"
  end

  def self.cpu_info : String
    prev  = read_cpu_times
    sleep 50.milliseconds
    cur   = read_cpu_times
    usage = calculate_cpu_usage(prev, cur).round(1)
    cores, freqs = cpu_cores_and_freq
    freq_display = freqs.empty? ? "N/A" : freqs.map { |f| "#{f.round(0)}MHz" }.join(", ")
    "#{color("CPU Usage:", 36)} #{color("#{usage}%", 33)} | " \
    "#{color("Cores:", 36)} #{color(cores.to_s, 32)} | " \
    "#{color("Freqs:", 36)} #{color(freq_display, 35)}"
  end

  def self.ram_info : String
    begin
      return "#{color("RAM Usage:", 36)} Info not available" unless File.exists?("/proc/meminfo")
      mem = {} of String => Int64
      File.each_line("/proc/meminfo") do |line|
        parts = line.split(':', 2)
        next unless parts.size == 2
        key   = parts[0].strip
        first = parts[1].strip.split.first?
        mem[key] = first ? first.to_i64 * 1024 : 0_i64
      end
      total = mem["MemTotal"]? || 0_i64
      free  = (mem["MemFree"]? || 0_i64) + (mem["Buffers"]? || 0_i64) + (mem["Cached"]? || 0_i64)
      used  = total - free
      "#{color("RAM Usage:", 36)} #{color(human_bytes(used), 33)} / #{color(human_bytes(total), 32)}"
    rescue
      "#{color("RAM Usage:", 36)} Info not available"
    end
  end

  def self.storage_info : String
    begin
      out   = `df -B1 .`
      lines = out.lines
      return "#{color("Storage Usage:", 36)} Info not available" if lines.size < 2
      fields = lines[1].split
      total  = fields[1]?.try &.to_i64 || 0_i64
      used   = fields[2]?.try &.to_i64 || 0_i64
      "#{color("Storage Usage (#{Dir.current}):", 36)} #{color(human_bytes(used), 33)} / #{color(human_bytes(total), 32)}"
    rescue
      "#{color("Storage Usage:", 36)} Info not available"
    end
  end

  # ---------------- Builtins ----------------
  def self.builtin_help
    puts color("=" * 60, "1;35")
    puts color("scsh #{SCSH_VERSION} - Builtin Commands", "1;33")
    puts color("%-15s%-45s" % {"Command", "Description"}, "1;36")
    puts color("-" * 60, "1;34")
    puts color("%-15s" % {"cd"}, "1;36")          + "Change directory"
    puts color("%-15s" % {"pwd"}, "1;36")         + "Print working directory"
    puts color("%-15s" % {"exit / quit"}, "1;36") + "Exit the shell"
    puts color("%-15s" % {"alias"}, "1;36")       + "Create or list aliases"
    puts color("%-15s" % {"unalias"}, "1;36")     + "Remove alias"
    puts color("%-15s" % {"jobs"}, "1;36")        + "Show background jobs (tracked pids)"
    puts color("%-15s" % {"systemfetch"}, "1;36") + "Display system information"
    puts color("%-15s" % {"hist"}, "1;36")        + "Show shell history"
    puts color("%-15s" % {"clearhist"}, "1;36")   + "Clear saved history (memory + file)"
    puts color("%-15s" % {"help"}, "1;36")        + "Show this help message"
    puts color("=" * 60, "1;35")
  end

  def self.builtin_systemfetch
    user        = ENV["USER"]? || "user"
    host        = hostname
    os          = detect_distro
    crystal_ver = Crystal::VERSION

    cpu_percent = begin
      prev = read_cpu_times
      sleep 50.milliseconds
      cur  = read_cpu_times
      calculate_cpu_usage(prev, cur).round(1)
    rescue
      0.0
    end

    mem_percent = begin
      if File.exists?("/proc/meminfo")
        mem = {} of String => Int64
        File.each_line("/proc/meminfo") do |line|
          k, v = line.split(':', 2)
          next unless v
          first = v.strip.split.first?
          bytes = first ? first.to_i64 * 1024 : 0_i64
          mem[k.strip] = bytes
        end
        total = mem["MemTotal"]? || 1_i64
        free  = (mem["MemAvailable"]? || mem["MemFree"]? || 0_i64)
        used  = total - free
        ((used.to_f64 / total.to_f64) * 100.0).round(1)
      else
        0.0
      end
    rescue
      0.0
    end

    puts color("=" * 60, "1;35")
    puts color("scsh System Information", "1;33")
    puts color("User:        ", "1;36") + color("#{user}@#{host}", "0;37")
    puts color("OS:          ", "1;36") + color(os, "0;37")
    puts color("Shell:       ", "1;36") + color("scsh v#{SCSH_VERSION}", "0;37")
    puts color("Crystal:     ", "1;36") + color(crystal_ver, "0;37")
    puts color("CPU Usage:   ", "1;36") + nice_bar(cpu_percent / 100.0, 30, 32)
    puts color("RAM Usage:   ", "1;36") + nice_bar(mem_percent / 100.0, 30, 35)
    puts color("=" * 60, "1;35")
  end

  def self.builtin_jobs
    if @@child_pids.empty?
      puts color("No tracked child jobs.", 36)
      return
    end
    @@child_pids.each do |pid|
      status = begin
        running = LibC.kill(pid, 0) == 0
        running ? "running" : "done"
      rescue
        "done"
      end
      puts "[#{pid}] #{status}"
    end
  end

  def self.builtin_hist
    i = 0
    @@history.each do |h|
      i += 1
      puts "%5d  %s" % {i, h}
    end
  end

  def self.builtin_clearhist
    @@history.clear
    begin
      File.delete(HISTORY_FILE) if File.exists?(HISTORY_FILE)
    rescue
    end
    puts color("History cleared (memory + file).", 32)
  end

  # ---------------- External Command Execution ----------------
  def self.run_command(cmd_in : String)
    cmd_str = cmd_in.to_s.strip
    return if cmd_str.empty?

    cmd_str = expand_aliases(cmd_str)
    cmd_str = expand_vars(cmd_str)
    cmd, stdin_file, stdout_file, append = parse_redirection(cmd_str)

    argv = shellsplit(cmd)
    return if argv.empty?

    case argv[0]
    when "cd"
      path = if argv.size > 1
        File.expand_path(argv[1])
      else
        ENV["HOME"]? || Dir.current
      end
      if !File.exists?(path)
        if argv.size > 1
          puts color("cd: no such file or directory: #{argv[1]}", 31)
        else
          puts color("cd: no such file or directory", 31)
        end
      elsif !File.directory?(path)
        if argv.size > 1
          puts color("cd: not a directory: #{argv[1]}", 31)
        else
          puts color("cd: not a directory", 31)
        end
      else
        begin
          Dir.cd(path)
        rescue
          puts color("cd: failed to change directory", 31)
        end
      end
      return

    when "exit", "quit"
      @@child_pids.each do |pid|
        begin
          Process.signal(Signal::TERM, pid)
        rescue
        end
      end
      exit 0

    when "alias"
      if argv.size == 1
        @@aliases.each { |k, v| puts "#{k}='#{v}'" }
      else
        arg = cmd.sub(/^alias\s+/, "")
        if md = arg.match(/^(\w+)=(["']?)(.+?)\2$/)
          @@aliases[md[1]] = md[3]
        else
          puts color("Invalid alias format", 31)
        end
      end
      return

    when "unalias"
      if argv.size > 1
        @@aliases.delete(argv[1])
      else
        puts color("unalias: usage: unalias name", 31)
      end
      return

    when "help"
      builtin_help
      return

    when "systemfetch"
      builtin_systemfetch
      return

    when "jobs"
      builtin_jobs
      return

    when "pwd"
      puts color(Dir.current, 36)
      return

    when "hist"
      builtin_hist
      return

    when "clearhist"
      builtin_clearhist
      return
    end

    # Directory guard
    if argv[0].includes?('/') || argv[0].starts_with?('.')
      begin
        if File.directory?(argv[0])
          puts color("scsh: #{argv[0]}: is a directory", 31)
          return
        end
      rescue
      end
    end

    exe = find_executable(argv[0])
    if exe.nil?
      puts color("Command not found: #{argv[0]}", rainbow_codes.sample)
      return
    end

    input_io  = stdin_file  ? File.open(stdin_file, "r") : nil
    output_io = stdout_file ? File.open(stdout_file, append ? "a" : "w") : nil

    child_pid : Int32? = nil

    begin
      Signal::INT.trap do
        if pid = child_pid
          begin
            Process.signal(Signal::INT, pid)
          rescue
          end
        end
      end

      pr = Process.new(
        exe,
        argv[1..-1]? || [] of String,
        input:  (input_io  || Process::Redirect::Inherit),
        output: (output_io || Process::Redirect::Inherit),
        error:  Process::Redirect::Inherit
      )

      child_pid = pr.pid.to_i32
      @@child_pids << child_pid.not_nil!

      pr.wait
    rescue ex : Exception
      msg = ex.message || ""
      if msg.includes?("No such file or directory")
        puts color("Command not found: #{argv[0]}", rainbow_codes.sample)
      elsif msg.includes?("Permission denied")
        puts color("Permission denied: #{argv[0]}", 31)
      else
        puts color("Error: #{msg}", rainbow_codes.sample)
      end
    ensure
      begin
        Signal::INT.reset
      rescue
      end

      if pid = child_pid
        @@child_pids.delete(pid)
      end

      begin
        input_io.try  &.close
      rescue
      end
      begin
        output_io.try &.close
      rescue
      end
    end
  end

  # ---------------- Chained Commands ----------------
  def self.run_input_line(input : String)
    input.split(/&&|;/).each do |piece|
      cmd = piece.strip
      next if cmd.empty?
      run_command(cmd)
    end
  end

  # ---------------- Prompt / Welcome ----------------
  def self.prompt : String
    "#{color(Dir.current, 33)} #{color(hostname, 36)}#{color(" > ", @@prompt_color)}"
  end

  def self.print_welcome
    @@prompt_color  = random_color
    @@current_quote = QUOTES.sample

    puts color("Welcome to scsh #{SCSH_VERSION} - your simple Crystal shell!", 36)
    puts color("Current Time:", 36) + " " + color(current_time, 34)
    puts cpu_info
    puts ram_info
    puts storage_info
    puts dynamic_quote
    puts
    puts color("Coded with love by https://github.com/RobertFlexx", 90)
    puts
  end

  # ---------------- Ctrl+C echo helpers ----------------
  def self.disable_ctrl_c_echo
    return unless STDIN.tty?
    begin
      Process.run("stty", ["-echoctl"],
        input:  Process::Redirect::Inherit,
        output: Process::Redirect::Inherit,
        error:  Process::Redirect::Inherit
      )
    rescue
    end
  end

  def self.restore_ctrl_c_echo
    return unless STDIN.tty?
    begin
      Process.run("stty", ["echoctl"],
        input:  Process::Redirect::Inherit,
        output: Process::Redirect::Inherit,
        error:  Process::Redirect::Inherit
      )
    rescue
    end
  end

  # ---------------- Input / Completion Helpers (srsh-style) ----------------

  enum InputStatus
    Ok
    Interrupt
    Eof
  end

  def self.terminal_width : Int32
    begin
      io = IO::Memory.new
      Process.run("stty", ["size"],
        input:  Process::Redirect::Inherit,
        output: io,
        error:  Process::Redirect::Close
      )
      parts = io.to_s.split
      if parts.size == 2
        cols = parts[1].to_i
        return cols if cols > 0
      end
    rescue
    end

    if cols_env = ENV["COLUMNS"]?
      if v = cols_env.to_i?
        return v if v > 0
      end
    end

    80
  end

  def self.history_ghost_for(line : String?) : String?
    return nil if line.nil? || line.empty?
    @@history.reverse_each do |h|
      next if h.empty?
      next if h.starts_with?("[completions:")
      next unless h.starts_with?(line.not_nil!)
      next if h == line
      return h
    end
    nil
  end

  def self.tab_completions_for(prefix : String, first_word : String, at_first_word : Bool) : Array(String)
    dir  = "."
    base = prefix.dup

    if prefix.includes?('/')
      if prefix.ends_with?('/')
        dir  = prefix.chomp("/")
        base = ""
      else
        dir  = File.dirname(prefix)
        base = File.basename(prefix)
      end
      dir = "." if dir.empty?
    end

    file_completions = [] of String

    if Dir.exists?(dir)
      Dir.children(dir).each do |entry|
        next unless entry.starts_with?(base)
        full = File.join(dir, entry)

        rel =
          if dir == "."
            entry
          else
            if prefix.includes?('/')
              File.join(File.dirname(prefix), entry)
            else
              entry
            end
          end

        case first_word
        when "cd"
          next unless File.directory?(full)
          rel = rel + "/" unless rel.ends_with?("/")
          file_completions << rel
        when "cat"
          next unless File.file?(full)
          file_completions << rel
        else
          rel = rel + "/" if File.directory?(full) && !rel.ends_with?("/")
          file_completions << rel
        end
      end
    end

    exec_completions = [] of String
    if first_word != "cat" && first_word != "cd" && at_first_word && !prefix.includes?('/')
      path_entries = (ENV["PATH"]? || "").split(':')
      execs = [] of String
      path_entries.each do |p|
        begin
          Dir.each_child(p) do |f|
            full = File.join(p, f)
            if executable_file?(full) && !File.directory?(full)
              execs << f
            end
          end
        rescue
        end
      end
      exec_completions = execs.select { |name| name.starts_with?(prefix) }.uniq
    end

    (file_completions + exec_completions).uniq
  end

  def self.longest_common_prefix(strings : Array(String)) : String
    return "" if strings.empty?
    shortest = strings.min_by(&.size)
    return "" unless shortest
    (0...shortest.size).each do |i|
      c = shortest[i]
      strings.each do |s|
        return shortest[0, i] if s[i]? != c
      end
    end
    shortest
  end

  def self.print_tab_list(comps : Array(String))
    return if comps.empty?

    width    = terminal_width
    max_len  = comps.map(&.size).max? || 0
    col_width = {max_len + 2, 4}.max
    cols      = {width // col_width, 1}.max
    rows      = (comps.size + cols - 1) // cols

    STDOUT.print "\r\n"
    STDOUT.puts "[completions: #{comps.size}]"
    rows.times do |r|
      line = String.build do |io|
        cols.times do |c|
          idx = c * rows + r
          break if idx >= comps.size
          item    = comps[idx]
          padding = col_width - item.size
          io << item
          io << " " * padding
        end
      end
      STDOUT.print "\r"
      STDOUT.puts line.rstrip
    end
    STDOUT.print "\r\n"
    STDOUT.flush
  end

  def self.render_line(prompt_str : String, buffer : String, cursor : Int32, show_ghost : Bool = true)
    buf = buffer
    cur = cursor
    cur = 0 if cur < 0
    cur = buf.size if cur > buf.size

    ghost_tail = ""
    if show_ghost && cur == buf.size
      if suggestion = history_ghost_for(buf)
        ghost_tail = suggestion[buf.size..-1]? || ""
      end
    end

    # ---- Clear previous logical line (all rows it used) ----
    rows_to_clear = @@last_render_rows
    if rows_to_clear > 1
      # Move to start of first row of previous render
      STDOUT.print "\r"
      STDOUT.print "\e[#{rows_to_clear - 1}A" if rows_to_clear > 1

      # Clear each row
      rows_to_clear.times do |i|
        STDOUT.print "\e[0K"
        STDOUT.print "\n" if i < rows_to_clear - 1
      end

      # Move back up to first row
      STDOUT.print "\r"
      STDOUT.print "\e[#{rows_to_clear - 1}A" if rows_to_clear > 1
    else
      STDOUT.print "\r"
      STDOUT.print "\e[0K"
    end

    # ---- Draw new line ----
    STDOUT.print prompt_str
    STDOUT.print buf
    STDOUT.print color(ghost_tail, "2") unless ghost_tail.empty?

    move_left = ghost_tail.size + (buf.size - cur)
    STDOUT.print "\e[#{move_left}D" if move_left > 0
    STDOUT.flush

    # ---- Recompute how many rows this logical line occupies ----
    visible_line = strip_ansi(prompt_str) + strip_ansi(buf) + ghost_tail
    width = terminal_width
    cols  = width > 0 ? width : 80
    rows  = (visible_line.size + cols - 1) // cols
    rows  = 1 if rows < 1
    @@last_render_rows = rows
  end

  def self.handle_tab_completion(prompt_str : String, buffer : String, cursor : Int32, last_tab_prefix : String?, tab_cycle : Int32) : {String, Int32, String?, Int32, Bool}
    buf = buffer
    cur = cursor
    cur = 0 if cur < 0
    cur = buf.size if cur > buf.size

    wstart = -1
    if cur > 0
      i = cur - 1
      while i >= 0
        ch = buf[i]
        if ch == ' ' || ch == '\t'
          wstart = i
          break
        end
        i -= 1
      end
    end
    wstart += 1

    prefix_len = cur - wstart
    prefix_len = 0 if prefix_len < 0
    prefix = prefix_len > 0 ? buf[wstart, prefix_len] : ""

    before_word = wstart > 0 ? buf[0, wstart] : ""

    stripped = buf.strip
    first_word = ""
    unless stripped.empty?
      if idx = stripped.index(' ')
        first_word = stripped[0, idx]
      else
        first_word = stripped
      end
    end
    at_first_word = before_word.strip.empty?

    comps = tab_completions_for(prefix, first_word, at_first_word)
    return {buf, cur, nil, 0, false} if comps.empty?

    if comps.size == 1
      new_word = comps.first
      head = wstart > 0 ? buf[0, wstart] : ""
      tail = cur < buf.size ? buf[cur..-1] : ""
      buf  = head + new_word + tail
      cur  = wstart + new_word.size
      return {buf, cur, nil, 0, true}
    end

    lp = last_tab_prefix || ""
    if prefix != lp
      lcp = longest_common_prefix(comps)
      if !lcp.empty? && lcp.size > prefix.size
        head = wstart > 0 ? buf[0, wstart] : ""
        tail = cur < buf.size ? buf[cur..-1] : ""
        buf  = head + lcp + tail
        cur  = wstart + lcp.size
      else
        STDOUT.print "\a"
      end
      last_tab_prefix = prefix
      tab_cycle       = 1
      return {buf, cur, last_tab_prefix, tab_cycle, false}
    else
      render_line(prompt_str, buf, cur, false)
      print_tab_list(comps)
      last_tab_prefix = prefix
      tab_cycle      += 1
      return {buf, cur, last_tab_prefix, tab_cycle, true}
    end
  end

  def self.read_key : String
    buffer = Bytes.new(4)
    bytes_read = 0

    STDIN.raw do |io|
      bytes_read = io.read(buffer)
    end

    return "" if bytes_read == 0
    String.new(buffer[0, bytes_read])
  end

  def self.read_line_with_ghost(prompt_str : String) : {InputStatus, String?}
    buffer = ""
    cursor = 0
    hist_index = @@history.size
    saved_line_for_history = ""
    last_tab_prefix : String? = nil
    tab_cycle = 0

    @@last_render_rows = 1
    render_line(prompt_str, buffer, cursor)

    status = InputStatus::Ok

    loop do
      key = read_key
      break if key.empty?

      case key
      when "\r", "\n"
        cursor = buffer.size
        render_line(prompt_str, buffer, cursor, false)
        STDOUT.print "\r\n"
        STDOUT.flush
        break

      when "\u0003" # Ctrl-C
        STDOUT.print "^C\r\n"
        STDOUT.flush
        status = InputStatus::Interrupt
        buffer = ""
        break

      when "\u0004" # Ctrl-D
        if buffer.empty?
          status = InputStatus::Eof
          buffer = ""
          STDOUT.print "\r\n"
          STDOUT.flush
          break
        else
          # ignore if line not empty
        end

      when "\u007F", "\b" # Backspace
        if cursor > 0
          head = cursor > 1 ? buffer[0, cursor - 1] : ""
          tail = cursor < buffer.size ? buffer[cursor..-1] : ""
          buffer = head + tail
          cursor -= 1
        end
        last_tab_prefix = nil
        tab_cycle       = 0

      when "\t" # Tab completion
        buffer, cursor, last_tab_prefix, tab_cycle, _printed =
          handle_tab_completion(prompt_str, buffer, cursor, last_tab_prefix, tab_cycle)

      when "\e[A" # Up arrow
        if hist_index == @@history.size
          saved_line_for_history = buffer.dup
        end
        if hist_index > 0
          hist_index -= 1
          buffer = @@history[hist_index]? || ""
          cursor = buffer.size
        end
        last_tab_prefix = nil
        tab_cycle       = 0

      when "\e[B" # Down arrow
        if hist_index < @@history.size - 1
          hist_index += 1
          buffer = @@history[hist_index]? || ""
          cursor = buffer.size
        elsif hist_index == @@history.size - 1
          hist_index = @@history.size
          buffer    = saved_line_for_history || ""
          cursor    = buffer.size
        end
        last_tab_prefix = nil
        tab_cycle       = 0

      when "\e[C" # Right arrow
        if cursor < buffer.size
          cursor += 1
        else
          if suggestion = history_ghost_for(buffer)
            buffer = suggestion
            cursor = buffer.size
          end
        end
        last_tab_prefix = nil
        tab_cycle       = 0

      when "\e[D" # Left arrow
        cursor -= 1 if cursor > 0
        last_tab_prefix = nil
        tab_cycle       = 0

      when "\e[H" # Home
        cursor = 0
        last_tab_prefix = nil
        tab_cycle       = 0

      when "\e[F" # End
        cursor = buffer.size
        last_tab_prefix = nil
        tab_cycle       = 0

      else
        ch = key[0]?
        if ch && ch >= ' ' && ch != '\u007F'
          head = cursor > 0 ? buffer[0, cursor] : ""
          tail = cursor < buffer.size ? buffer[cursor..-1] : ""
          buffer = head + key + tail
          cursor += key.size
          hist_index      = @@history.size
          last_tab_prefix = nil
          tab_cycle       = 0
        end
      end

      render_line(prompt_str, buffer, cursor) if status == InputStatus::Ok
    end

    {status, buffer}
  end

  # ---------------- Main Loop (srsh-style input) ----------------
  def self.run
    disable_ctrl_c_echo
    print_welcome

    loop do
      print "\033]0;scsh-#{SCSH_VERSION}\007"
      prompt_str = prompt

      status, input = read_line_with_ghost(prompt_str)

      case status
      when InputStatus::Eof
        break
      when InputStatus::Interrupt
        next
      else
        # continue
      end

      line = input
      next if line.nil?
      ln = line.not_nil!.strip
      next if ln.empty?

      @@history << ln
      run_input_line(ln)
    end
  end
end

# ----- start -----
Scsh.run
