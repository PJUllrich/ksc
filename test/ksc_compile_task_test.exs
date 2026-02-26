defmodule KscCompileTaskTest do
  use ExUnit.Case, async: true

  @formats_dir "reference_code/kaitai_struct_tests/formats"

  defp tmp_dir(label) do
    Path.join(System.tmp_dir!(), "ksc_test_#{label}_#{System.unique_integer([:positive])}")
  end

  describe "Ksc.compile_to_files/3" do
    test "compiles a single .ksy file with default namespace" do
      output_dir = tmp_dir("single")

      try do
        {:ok, files} = Ksc.compile_to_files(Path.join(@formats_dir, "hello_world.ksy"), output_dir)

        assert length(files) == 1
        [file] = files
        assert String.ends_with?(file, "/hello_world.ex")
        assert File.exists?(file)

        content = File.read!(file)
        assert content =~ "defmodule Ksc.Compiled.HelloWorld do"
        assert content =~ "def parse"
      after
        File.rm_rf!(output_dir)
      end
    end

    test "applies default Ksc.Compiled namespace to cross-module references" do
      output_dir = tmp_dir("imports_ns")

      try do
        {:ok, files} = Ksc.compile_to_files(Path.join(@formats_dir, "imports0.ksy"), output_dir)

        assert length(files) == 2

        imports0_file = Enum.find(files, &String.ends_with?(&1, "/imports0.ex"))
        hello_file = Enum.find(files, &String.ends_with?(&1, "/hello_world.ex"))

        imports0_content = File.read!(imports0_file)
        assert imports0_content =~ "defmodule Ksc.Compiled.Imports0 do"
        assert imports0_content =~ "Ksc.Compiled.HelloWorld.parse("
        assert imports0_content =~ "Ksc.Compiled.HelloWorld.resolve_instances("

        hello_content = File.read!(hello_file)
        assert hello_content =~ "defmodule Ksc.Compiled.HelloWorld do"
      after
        File.rm_rf!(output_dir)
      end
    end

    test "uses custom namespace" do
      output_dir = tmp_dir("custom_ns")

      try do
        {:ok, files} =
          Ksc.compile_to_files(
            Path.join(@formats_dir, "hello_world.ksy"),
            output_dir,
            namespace: "MyApp.Formats"
          )

        assert length(files) == 1
        content = File.read!(List.first(files))
        assert content =~ "defmodule MyApp.Formats.HelloWorld do"
      after
        File.rm_rf!(output_dir)
      end
    end

    test "custom namespace applies to cross-module references" do
      output_dir = tmp_dir("custom_ns_imports")

      try do
        {:ok, files} =
          Ksc.compile_to_files(
            Path.join(@formats_dir, "imports0.ksy"),
            output_dir,
            namespace: "MyApp.Kaitai"
          )

        imports0_file = Enum.find(files, &String.ends_with?(&1, "/imports0.ex"))
        content = File.read!(imports0_file)
        assert content =~ "defmodule MyApp.Kaitai.Imports0 do"
        assert content =~ "MyApp.Kaitai.HelloWorld.parse("
        assert content =~ "MyApp.Kaitai.HelloWorld.resolve_instances("
      after
        File.rm_rf!(output_dir)
      end
    end

    test "compiles a directory of .ksy files" do
      input_dir = tmp_dir("input")
      output_dir = tmp_dir("dir_out")

      try do
        File.mkdir_p!(input_dir)

        File.write!(Path.join(input_dir, "tiny_a.ksy"), """
        meta:
          id: tiny_a
        seq:
          - id: val
            type: u1
        """)

        File.write!(Path.join(input_dir, "tiny_b.ksy"), """
        meta:
          id: tiny_b
        seq:
          - id: num
            type: u2le
        """)

        {:ok, files} = Ksc.compile_to_files(input_dir, output_dir)

        assert length(files) == 2
        basenames = Enum.map(files, &Path.basename/1) |> Enum.sort()
        assert basenames == ["tiny_a.ex", "tiny_b.ex"]

        # Verify default namespace applied
        content = File.read!(Enum.find(files, &String.ends_with?(&1, "/tiny_a.ex")))
        assert content =~ "defmodule Ksc.Compiled.TinyA do"
      after
        File.rm_rf!(input_dir)
        File.rm_rf!(output_dir)
      end
    end

    test "returns error for nonexistent path" do
      assert {:error, _} = Ksc.compile_to_files("/nonexistent/path.ksy", "/tmp/out")
    end

    test "returns error for empty directory" do
      empty_dir = tmp_dir("empty")

      try do
        File.mkdir_p!(empty_dir)
        assert {:error, msg} = Ksc.compile_to_files(empty_dir, "/tmp/out")
        assert msg =~ "no .ksy files found"
      after
        File.rm_rf!(empty_dir)
      end
    end
  end

  describe "mix ksc.compile" do
    test "compiles with default namespace via Mix task" do
      output_dir = tmp_dir("mix")

      try do
        Mix.Tasks.Ksc.Compile.run([
          Path.join(@formats_dir, "hello_world.ksy"),
          "--output", output_dir
        ])

        content = File.read!(Path.join(output_dir, "hello_world.ex"))
        assert content =~ "defmodule Ksc.Compiled.HelloWorld do"
      after
        File.rm_rf!(output_dir)
      end
    end

    test "compiles with custom namespace via Mix task" do
      output_dir = tmp_dir("mix_ns")

      try do
        Mix.Tasks.Ksc.Compile.run([
          Path.join(@formats_dir, "hello_world.ksy"),
          "--output", output_dir,
          "--namespace", "MyApp.Parsers"
        ])

        content = File.read!(Path.join(output_dir, "hello_world.ex"))
        assert content =~ "defmodule MyApp.Parsers.HelloWorld do"
      after
        File.rm_rf!(output_dir)
      end
    end

    test "raises with no arguments" do
      assert_raise Mix.Error, fn ->
        Mix.Tasks.Ksc.Compile.run([])
      end
    end

    test "raises with missing --output" do
      assert_raise Mix.Error, fn ->
        Mix.Tasks.Ksc.Compile.run([Path.join(@formats_dir, "hello_world.ksy")])
      end
    end
  end
end
