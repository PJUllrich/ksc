defmodule Ksc.Format.ClassSpec do
  @moduledoc "Top-level type definition from a .ksy file."

  defstruct [
    :id,
    :endian,
    :bit_endian,
    :encoding,
    seq: [],
    types: %{},
    instances: %{},
    enums: %{},
    imports: [],
    params: []
  ]
end
