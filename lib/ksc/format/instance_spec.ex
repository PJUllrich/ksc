defmodule Ksc.Format.InstanceSpec do
  @moduledoc "Instance specification - either a value instance or a parse instance."

  defstruct [
    :id,
    :value,
    :type,
    :pos,
    :io,
    :size,
    :size_eos,
    :encoding,
    :enum,
    :if_expr,
    :repeat,
    :repeat_expr,
    :repeat_until,
    :terminator,
    :pad_right,
    :include
  ]
end
