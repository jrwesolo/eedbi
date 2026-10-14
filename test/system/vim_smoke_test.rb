# frozen_string_literal: true

require_relative '../test_helper'

# Runs real vim and neovim non-interactively (-es with -c commands) through
# eedbi, with a config that sends undo, backup, swap and viminfo/shada files
# to a directory we can inspect.
#
# A control run without eedbi first proves that this config does leak. Only
# then is the run through eedbi meaningful. Skipped when the editor is not
# installed.
class VimSmokeTest < Minitest::Test
  include EedbiTestHelper

  # Git for Windows ships vim, but not always on PATH.
  EXTRA_DIRS = {
    'vim' => ['C:/Program Files/Git/usr/bin']
  }.freeze

  def find_program(name)
    dirs = ENV.fetch('PATH', '').split(File::PATH_SEPARATOR)
    dirs += EXTRA_DIRS.fetch(name, []) if WINDOWS
    candidates = WINDOWS ? ["#{name}.exe", name] : [name]
    dirs.product(candidates).map { |dir, file| File.join(dir, file) }
        .find { |file| File.file?(file) && File.executable?(file) }
  end

  def leak_dir
    path('leak')
  end

  def reset_leak_dir
    FileUtils.rm_rf(leak_dir)
    %w[swap backup undo].each { |sub| FileUtils.mkdir_p(File.join(leak_dir, sub)) }
  end

  def leaky_config(name)
    history = if name == 'nvim'
                "set shadafile=#{leak_dir}/shada"
              else
                "set viminfo='100,<50,s10,h,n#{leak_dir}/viminfo"
              end
    rc = path("#{name}rc.vim")
    File.write(rc, <<~VIM)
      set swapfile directory=#{leak_dir}/swap//
      set backup writebackup backupdir=#{leak_dir}/backup//
      set undofile undodir=#{leak_dir}/undo//
      #{history}
    VIM
    rc
  end

  def leaked_files
    Dir.glob(File.join(leak_dir, '**', '*')).select { |file| File.file?(file) }
  end

  def edit_args(config)
    ['-es', '-u', config, '-c', '%s/false/true/', '-c', 'wq']
  end

  %w[vim nvim].each do |name|
    define_method("test_#{name}_leaks_nothing_through_eedbi") do
      program = find_program(name) or skip("#{name} not installed")
      config = leaky_config(name)

      reset_leak_dir
      control = path('control.json')
      File.write(control, %({\n  "a": false\n}\n))
      system(program, *edit_args(config), control, out: File::NULL, err: File::NULL)
      assert_includes File.read(control), 'true', "#{name} control edit failed"
      skip("#{name} leaked nothing even without hardening, so the check proves nothing") if leaked_files.empty?

      reset_leak_dir
      editor = [program, *edit_args(config)].map { |word| %("#{word}") }.join(' ')
      r = eedbi('edit', path('v3.json'), '-e', editor)
      assert_equal 0, r.status, r.err
      assert_equal true, decrypt('v3.json')['disabled']
      assert_empty leaked_files, "#{name} leaked plaintext copies"
    end
  end
end
