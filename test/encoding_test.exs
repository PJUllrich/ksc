defmodule EncodingTest do
  @moduledoc """
  Tests for the Windows-1252 / ISO-8859-1 codecs and the loud-failure behavior
  for unsupported encodings (both reading and writing).
  """

  use ExUnit.Case, async: true

  alias Ksc.Stream

  describe "Windows-1252" do
    # 0x92 = right single quote ('), 0x97 = em dash (—), 0x80 = euro (€),
    # 0xE9 = é (shared with Latin-1). These are exactly the typographic bytes
    # legacy files emit that the old raw-bytes passthrough turned into invalid UTF-8.
    @cp1252 <<?H, ?i, 0x92, 0x97, 0x80, 0xE9>>

    test "decodes typographic bytes to UTF-8" do
      assert Stream.decode_string(@cp1252, "windows-1252") == "Hi’—€é"
    end

    test "round-trips decode -> encode" do
      decoded = Stream.decode_string(@cp1252, "windows-1252")
      assert Stream.encode_string(decoded, "windows-1252") == @cp1252
    end

    test "the CP1252 alias and case-insensitive name resolve the same" do
      expected = Stream.decode_string(@cp1252, "windows-1252")
      assert Stream.decode_string(@cp1252, "CP1252") == expected
      assert Stream.decode_string(@cp1252, "Windows-1252") == expected
    end

    test "undefined positions (0x81, 0x8D, 0x8F, 0x90, 0x9D) round-trip" do
      undefined = <<0x81, 0x8D, 0x8F, 0x90, 0x9D>>
      decoded = Stream.decode_string(undefined, "windows-1252")
      assert Stream.encode_string(decoded, "windows-1252") == undefined
    end

    test "encoding a codepoint outside Windows-1252 raises" do
      assert_raise ArgumentError, ~r/not representable in windows-1252/, fn ->
        # U+4E2D (中) has no Windows-1252 byte.
        Stream.encode_string("中", "windows-1252")
      end
    end
  end

  describe "ISO-8859-1 (Latin-1)" do
    @latin1 <<0xE9, 0xFC, 0x41>>

    test "decodes high bytes straight to U+00xx" do
      assert Stream.decode_string(@latin1, "ISO-8859-1") == "éüA"
    end

    test "round-trips decode -> encode, including aliases" do
      decoded = Stream.decode_string(@latin1, "ISO-8859-1")
      assert Stream.encode_string(decoded, "ISO-8859-1") == @latin1

      for alias_name <- ~w(ISO8859-1 latin1 LATIN-1) do
        assert Stream.decode_string(@latin1, alias_name) == decoded
        assert Stream.encode_string(decoded, alias_name) == @latin1
      end
    end

    test "encoding a codepoint above U+00FF raises" do
      assert_raise ArgumentError, ~r/not representable in ISO-8859-1/, fn ->
        Stream.encode_string("€", "ISO-8859-1")
      end
    end
  end

  describe "unsupported encodings fail loudly" do
    test "decode_string raises instead of returning raw bytes" do
      assert_raise ArgumentError, ~r/unsupported encoding/, fn ->
        Stream.decode_string(<<0xAB, 0xCD>>, "Shift_JIS-2004")
      end
    end

    test "encode_string raises" do
      assert_raise ArgumentError, ~r/unsupported write encoding/, fn ->
        Stream.encode_string("x", "KOI8-R")
      end
    end
  end

  describe "generated parser/writer integration" do
    defp load(yaml) do
      ns = "Enc#{:erlang.unique_integer([:positive])}"
      {:ok, mod} = Ksc.compile_string_and_load(yaml, namespace: ns, writer: true)
      mod
    end

    test "a windows-1252 field decodes on read and round-trips on write" do
      yaml = """
      meta:
        id: cp1252_str
      seq:
        - id: text
          type: str
          size: 6
          encoding: windows-1252
      """

      mod = load(yaml)
      bin = <<?H, ?i, 0x92, 0x97, 0x80, 0xE9>>

      m = mod.from_binary(bin)
      assert m.text == "Hi’—€é"
      assert mod.to_binary(m) == bin
    end

    test "a windows-1252 field still round-trips after mutation" do
      yaml = """
      meta:
        id: cp1252_eos
      seq:
        - id: text
          type: str
          size-eos: true
          encoding: windows-1252
      """

      mod = load(yaml)
      m = mod.from_binary(<<?o, ?k>>)
      out = mod.to_binary(%{m | text: "café—"})
      # Re-reading the written bytes yields the mutated string.
      assert mod.from_binary(out).text == "café—"
    end
  end
end
