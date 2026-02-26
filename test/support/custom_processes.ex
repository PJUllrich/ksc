# Custom process implementations for Kaitai Struct test suite.
# These mirror the C++ reference implementations in
# reference_code/kaitai_struct_tests/spec/cpp_stl_98/prereq/

defmodule MyCustomFx do
  @moduledoc """
  Custom process: adds `key` to each byte.
  Constructor: key = flag ? p_key : -p_key
  """
  defstruct [:key]

  def new(key, flag, _some_bytes) do
    %__MODULE__{key: if(flag, do: key, else: -key)}
  end

  def decode(%__MODULE__{key: key}, src) when is_binary(src) do
    src
    |> :binary.bin_to_list()
    |> Enum.map(fn b -> Bitwise.band(b + key, 0xFF) end)
    |> :binary.list_to_bin()
  end
end

defmodule CustomFxNoArgs do
  @moduledoc """
  Custom process with no args: wraps data in "_" bytes.
  """
  defstruct []

  def new, do: %__MODULE__{}

  def decode(%__MODULE__{}, src) when is_binary(src) do
    "_" <> src <> "_"
  end
end

defmodule Nested.Deeply.CustomFx do
  @moduledoc """
  Namespaced custom process: wraps data in "_" bytes (ignores key arg).
  """
  defstruct []

  def new(_key), do: %__MODULE__{}

  def decode(%__MODULE__{}, src) when is_binary(src) do
    "_" <> src <> "_"
  end
end
