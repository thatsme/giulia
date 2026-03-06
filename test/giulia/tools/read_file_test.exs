defmodule Giulia.Tools.ReadFileTest do
  use ExUnit.Case, async: true

  alias Giulia.Tools.ReadFile
  alias Giulia.Core.PathSandbox

  setup do
    # Create a temp dir with a test file
    tmp = System.tmp_dir!()
    sandbox_root = Path.join(tmp, "read_file_test_#{:rand.uniform(10000)}")
    File.mkdir_p!(sandbox_root)
    test_file = Path.join(sandbox_root, "hello.txt")
    File.write!(test_file, "Hello World")

    on_exit(fn -> File.rm_rf!(sandbox_root) end)

    sandbox = PathSandbox.new(sandbox_root)
    %{sandbox: sandbox, sandbox_root: sandbox_root, test_file: test_file}
  end

  test "reads a file within sandbox", %{sandbox: sandbox, test_file: test_file} do
    struct = %ReadFile{path: test_file}
    assert {:ok, "Hello World"} = ReadFile.execute(struct, sandbox: sandbox)
  end

  test "rejects path outside sandbox", %{sandbox: sandbox} do
    struct = %ReadFile{path: "/etc/passwd"}
    assert {:error, msg} = ReadFile.execute(struct, sandbox: sandbox)
    assert is_binary(msg)
  end

  test "returns error for missing file", %{sandbox: sandbox, sandbox_root: root} do
    struct = %ReadFile{path: Path.join(root, "nonexistent.txt")}
    assert {:error, msg} = ReadFile.execute(struct, sandbox: sandbox)
    assert msg =~ "not found"
  end

  test "accepts string-keyed map params", %{sandbox: sandbox, test_file: test_file} do
    assert {:ok, "Hello World"} = ReadFile.execute(%{"path" => test_file}, sandbox: sandbox)
  end

  test "returns error for empty params" do
    assert {:error, :missing_path_parameter} = ReadFile.execute(%{}, [])
  end

  test "changeset validates required path" do
    cs = ReadFile.changeset(%{})
    refute cs.valid?
  end

  test "changeset accepts valid path" do
    cs = ReadFile.changeset(%{"path" => "lib/foo.ex"})
    assert cs.valid?
  end
end
