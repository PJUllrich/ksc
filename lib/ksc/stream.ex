defmodule Ksc.Stream do
  @moduledoc "Lightweight runtime for Kaitai Struct generated parsers."

  @doc "Parse items repeatedly until binary is exhausted."
  def repeat_eos(data, parse_fn) do
    repeat_eos_acc(data, parse_fn, [])
  end

  defp repeat_eos_acc(<<>>, _parse_fn, acc), do: {Enum.reverse(acc), <<>>}

  defp repeat_eos_acc(data, parse_fn, acc) do
    {item, rest} = parse_fn.(data)
    repeat_eos_acc(rest, parse_fn, [item | acc])
  end

  @doc "Parse items repeatedly until condition is met."
  def repeat_until(data, parse_fn, until_fn) do
    repeat_until_acc(data, parse_fn, until_fn, [])
  end

  defp repeat_until_acc(data, parse_fn, until_fn, acc) do
    {item, rest} = parse_fn.(data)
    new_acc = acc ++ [item]

    if until_fn.(item, new_acc) do
      {new_acc, rest}
    else
      repeat_until_acc(rest, parse_fn, until_fn, new_acc)
    end
  end

  @doc "Strip trailing pad bytes from binary."
  def strip_pad_right(data, pad_byte) when is_binary(data) and is_integer(pad_byte) do
    data
    |> :binary.bin_to_list()
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 == pad_byte))
    |> Enum.reverse()
    |> :binary.list_to_bin()
  end

  @doc "Terminate binary at first occurrence of byte."
  def terminate_at(data, term_byte, include \\ false) do
    bytes = :binary.bin_to_list(data)

    case Enum.find_index(bytes, &(&1 == term_byte)) do
      nil ->
        data

      idx ->
        if include do
          :binary.list_to_bin(Enum.take(bytes, idx + 1))
        else
          :binary.list_to_bin(Enum.take(bytes, idx))
        end
    end
  end

  @doc "Read a null-terminated string from binary, returning {string, rest}."
  def read_strz(data, _encoding \\ "UTF-8") do
    case :binary.match(data, <<0>>) do
      {pos, 1} ->
        str = binary_part(data, 0, pos)
        rest = binary_part(data, pos + 1, byte_size(data) - pos - 1)
        {str, rest}

      :nomatch ->
        {data, <<>>}
    end
  end

  @doc """
  Read bytes from binary until a terminator byte is found.
  Returns {bytes_read, rest_of_binary}.

  - consume: if true (default), the terminator byte is consumed from the stream
  - include: if true, the terminator byte is included in the returned value
  """
  def read_terminated(data, term_byte, consume \\ true, include \\ false) do
    bytes = :binary.bin_to_list(data)

    case Enum.find_index(bytes, &(&1 == term_byte)) do
      nil ->
        {data, <<>>}

      idx ->
        result_bytes = if include do
          Enum.take(bytes, idx + 1)
        else
          Enum.take(bytes, idx)
        end

        rest_start = if consume, do: idx + 1, else: idx
        rest_bytes = Enum.drop(bytes, rest_start)

        {:binary.list_to_bin(result_bytes), :binary.list_to_bin(rest_bytes)}
    end
  end

  @doc """
  Read N bits from a binary. Returns {value, rest_binary}.
  Reads from the MSB side (big-endian bit order).
  The binary is consumed in full bytes; remaining bits are discarded
  only if the total bits read align to a byte boundary.
  """
  def read_bits(data, num_bits) when is_binary(data) and is_integer(num_bits) do
    total_bits = byte_size(data) * 8

    if num_bits > total_bits do
      raise "Not enough data: need #{num_bits} bits, have #{total_bits}"
    end

    <<value::unsigned-big-integer-size(num_bits), remaining::bitstring>> = data

    # Convert remaining bitstring back to binary
    # If remaining is byte-aligned, it's already a binary
    remaining_bits = bit_size(remaining)

    rest = if rem(remaining_bits, 8) == 0 do
      # Byte-aligned - just use it as binary
      remaining_to_binary(remaining)
    else
      # Not byte-aligned - we need to track this
      # For now, pad to next byte boundary
      pad_bits = 8 - rem(remaining_bits, 8)
      <<rest_val::bitstring>> = remaining
      remaining_to_binary(<<rest_val::bitstring, 0::size(pad_bits)>>)
    end

    {value, rest}
  end

  @doc "Get size of a list or byte_size of a binary."
  def kaitai_size(nil), do: 0
  def kaitai_size(bin) when is_binary(bin), do: byte_size(bin)
  def kaitai_size(list) when is_list(list), do: length(list)
  def kaitai_size(%{} = map), do: map_size(map)

  @doc "Get minimum value from a list or binary (treating bytes as values)."
  def kaitai_min(bin) when is_binary(bin), do: :binary.bin_to_list(bin) |> Enum.min()
  def kaitai_min(list) when is_list(list), do: Enum.min(list)

  @doc "Get maximum value from a list or binary."
  def kaitai_max(bin) when is_binary(bin), do: :binary.bin_to_list(bin) |> Enum.max()
  def kaitai_max(list) when is_list(list), do: Enum.max(list)

  @doc "Access element at index (supports both lists and binaries)."
  def kaitai_at(bin, idx) when is_binary(bin), do: :binary.at(bin, idx)
  def kaitai_at(list, idx) when is_list(list), do: Enum.at(list, idx)

  @doc "Get first element of a list or first byte of a binary."
  def kaitai_first(nil), do: nil
  def kaitai_first(bin) when is_binary(bin), do: :binary.at(bin, 0)
  def kaitai_first(list) when is_list(list), do: List.first(list)

  @doc "Get last element of a list or last byte of a binary."
  def kaitai_last(nil), do: nil
  def kaitai_last(bin) when is_binary(bin), do: :binary.at(bin, byte_size(bin) - 1)
  def kaitai_last(list) when is_list(list), do: List.last(list)

  @doc "Convert value to integer (like Ruby's .to_i)."
  def to_i(true), do: 1
  def to_i(false), do: 0
  def to_i(x) when is_integer(x), do: x
  def to_i(x) when is_float(x), do: trunc(x)
  def to_i(x) when is_binary(x) do
    case Integer.parse(x) do
      {val, _} -> val
      :error -> 0
    end
  end
  def to_i(x) when is_atom(x), do: 0

  defp remaining_to_binary(bits) when is_binary(bits), do: bits
  defp remaining_to_binary(bits) do
    size = bit_size(bits)
    if rem(size, 8) == 0 do
      <<val::binary-size(div(size, 8))>> = bits
      val
    else
      pad = 8 - rem(size, 8)
      <<val::binary>> = <<bits::bitstring, 0::size(pad)>>
      val
    end
  end
end
