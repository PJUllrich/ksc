defmodule Ksc.Format.AttrSpec do
  @moduledoc "Sequence attribute specification."

  defstruct [
    :id,
    :type,
    :size,
    :size_eos,
    :encoding,
    :enum,
    :contents,
    :if_expr,
    :repeat,
    :repeat_expr,
    :repeat_until,
    :terminator,
    :pad_right,
    :include,
    :process,
    :consume,
    :eos_error
  ]
end
