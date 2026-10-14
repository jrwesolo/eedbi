# frozen_string_literal: true

module Eedbi
  # Choosing and invoking the editor.
  module Editor
    # Extra arguments for editors that would otherwise copy the plaintext
    # outside the private temp dir: no swap file, no viminfo or shada (it
    # stores registers, so anything yanked), and no backup or undo files,
    # which are often configured to live in a shared directory.
    #
    # The -c command runs after the user's vimrc or init.vim, so it wins over
    # settings there. That matters: neovim honors a configured 'shadafile'
    # even when started with -i NONE. ("viminfo" is an alias of "shada" in
    # neovim, and must stay last because its value is empty.)
    #
    # The GUI variants also get -f, to stay in the foreground. Otherwise they
    # detach, eedbi sees an unchanged file, and the private temp dir is
    # removed while the editor still has the file open.
    VIM_HARDENING = ['-n', '-i', 'NONE', '-c', 'set nobackup nowritebackup noundofile noswapfile viminfo='].freeze
    HARDENING = {
      %w[vim nvim] => VIM_HARDENING,
      %w[gvim mvim] => ['-f', *VIM_HARDENING].freeze
    }.freeze

    module_function

    # Same precedence as git: tool specific, then $VISUAL, then $EDITOR.
    def default
      [ENV.fetch('EEDBI_EDITOR', nil), ENV.fetch('VISUAL', nil), ENV.fetch('EDITOR', nil)]
        .find { |editor| editor && !editor.strip.empty? } || platform_default
    end

    def platform_default
      return 'notepad' if WINDOWS

      on_path?('vim') ? 'vim' : 'vi'
    end

    # Splits an editor setting into an argv array. The whole value is used as
    # one path when it names an executable, so unquoted paths containing
    # spaces work. Windows paths use backslashes, which Shellwords treats as
    # escapes, so only double quotes group words there.
    #
    # Hardening arguments go right after the program, before the user's own
    # arguments, so that for example a user supplied "-c wq" cannot write the
    # file before the hardening "-c set ..." has run.
    def command(editor, windows: WINDOWS)
      editor = editor.to_s.strip
      words = if executable?(editor)
                [editor]
              elsif windows
                editor.scan(/"([^"]*)"|(\S+)/).map { |quoted, word| quoted || word }
              else
                Shellwords.split(editor)
              end
      return words if words.empty?

      [words.first, *hardening_for(words.first), *words.drop(1)]
    end

    def hardening_for(program)
      # Split on both separators so Windows paths are recognized on any OS.
      # The vim installer for Windows also creates vim.bat wrappers.
      name = program.to_s.split(%r{[\\/]}).last.to_s.downcase.sub(/\.(exe|bat|cmd)\z/, '')
      HARDENING.find { |names, _| names.include?(name) }&.last || []
    end

    def executable?(path)
      !path.empty? && ::File.file?(path) && ::File.executable?(path)
    end

    def on_path?(program)
      ENV.fetch('PATH', '').split(::File::PATH_SEPARATOR).any? { |dir| executable?(::File.join(dir, program)) }
    end
  end
end
