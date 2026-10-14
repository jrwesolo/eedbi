# frozen_string_literal: true

require_relative '../test_helper'

# How an editor setting becomes an argv array, for both platforms, on any OS.
class EditorCommandTest < Minitest::Test
  HARDENING = Eedbi::Editor::VIM_HARDENING

  def unix(editor)
    Eedbi::Editor.command(editor, windows: false)
  end

  def windows(editor)
    Eedbi::Editor.command(editor, windows: true)
  end

  def test_unix_program_with_arguments
    assert_equal %w[code --wait], unix('code --wait')
  end

  def test_unix_quoted_path_with_spaces
    assert_equal ['/opt/my editor/ed', '-x'], unix("'/opt/my editor/ed' -x")
    assert_equal ['/opt/my editor/ed', '-x'], unix('"/opt/my editor/ed" -x')
  end

  def test_windows_quoted_path_keeps_backslashes
    assert_equal ['C:\Program Files\Notepad++\notepad++.exe', '-multiInst', '-nosession'],
                 windows('"C:\Program Files\Notepad++\notepad++.exe" -multiInst -nosession')
  end

  def test_windows_unquoted_path_keeps_backslashes
    assert_equal ['C:\tools\ed.exe'], windows('C:\tools\ed.exe')
  end

  def test_blank_editor_is_empty
    assert_empty unix('')
    assert_empty windows('   ')
  end

  def test_vim_family_is_hardened_before_user_arguments
    assert_equal ['vim', *HARDENING, '-c', 'wq'], unix('vim -c wq')
    assert_equal ['/usr/bin/nvim', *HARDENING], unix('/usr/bin/nvim')
  end

  def test_windows_vim_path_is_hardened
    assert_equal ['C:\tools\vim.exe', *HARDENING, '-O'], windows('C:\tools\vim.exe -O')
    assert_equal ['C:\Tools\GVIM.EXE', '-f', *HARDENING], windows('C:\Tools\GVIM.EXE')
    assert_equal ['C:\Windows\vim.bat', *HARDENING], windows('C:\Windows\vim.bat')
  end

  def test_gui_vims_stay_in_the_foreground
    assert_equal ['gvim', '-f', *HARDENING, '--nofork'], unix('gvim --nofork')
    assert_equal ['/usr/local/bin/mvim', '-f', *HARDENING], unix('/usr/local/bin/mvim')
  end

  def test_other_editors_are_not_hardened
    assert_equal ['nano'], unix('nano')
    assert_equal ['vimdiff'], unix('vimdiff')
    assert_equal ['notepad'], windows('notepad')
  end
end
