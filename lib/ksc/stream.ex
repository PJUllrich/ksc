defmodule Ksc.Stream do
  @moduledoc "Lightweight runtime for Kaitai Struct generated parsers."
  import Bitwise

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

  @doc "Read a null-terminated string with consume control."
  def read_strz_consume(data, consume) do
    case :binary.match(data, <<0>>) do
      {pos, 1} ->
        str = binary_part(data, 0, pos)
        rest = if consume do
          binary_part(data, pos + 1, byte_size(data) - pos - 1)
        else
          binary_part(data, pos, byte_size(data) - pos)
        end
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
  Read N bits from a binary, big-endian bit order.
  Returns {value, rest_binary}.
  """
  def read_bits(data, num_bits) when is_binary(data) and is_integer(num_bits) do
    read_bits_be(data, num_bits)
  end

  @doc """
  Read N bits in big-endian bit order from a {bits_remaining, bit_count, binary} tuple or binary.
  Returns {value, {bits_remaining, bit_count, rest_binary}}.
  This supports consecutive bit reads without byte-realignment.
  """
  def read_bits_be(data, num_bits) when is_binary(data) do
    read_bits_be({0, 0, data}, num_bits)
  end

  def read_bits_be({bits_acc, bits_left, data}, num_bits) do
    {bits_acc, bits_left, data} = ensure_bits(bits_acc, bits_left, data, num_bits)
    # Extract top num_bits from bits_acc
    shift = bits_left - num_bits
    value = bsr(bits_acc, shift) |> band((bsl(1, num_bits)) - 1)
    # Remove those bits from accumulator
    remaining_bits = bits_left - num_bits
    remaining_acc = band(bits_acc, (bsl(1, remaining_bits)) - 1)
    {value, {remaining_acc, remaining_bits, data}}
  end

  @doc """
  Read N bits in little-endian bit order.
  """
  def read_bits_le(data, num_bits) when is_binary(data) do
    read_bits_le({0, 0, data}, num_bits)
  end

  def read_bits_le({bits_acc, bits_left, data}, num_bits) do
    {bits_acc, bits_left, data} = ensure_bits_le(bits_acc, bits_left, data, num_bits)
    # Extract bottom num_bits from bits_acc
    value = band(bits_acc, (bsl(1, num_bits)) - 1)
    remaining_acc = bsr(bits_acc, num_bits)
    remaining_bits = bits_left - num_bits
    {value, {remaining_acc, remaining_bits, data}}
  end

  @doc "Align bit state back to byte boundary, returning binary."
  def align_to_byte({_bits_acc, _bits_left, data}), do: data
  def align_to_byte(data) when is_binary(data), do: data

  defp ensure_bits(bits_acc, bits_left, data, num_bits) do
    if bits_left >= num_bits do
      {bits_acc, bits_left, data}
    else
      # Need more bytes
      bytes_needed = div(num_bits - bits_left + 7, 8)
      <<new_bytes::binary-size(bytes_needed), rest::binary>> = data
      new_bits = :binary.bin_to_list(new_bytes)
        |> Enum.reduce(bits_acc, fn byte, acc -> bor(bsl(acc, 8), byte) end)
      {new_bits, bits_left + bytes_needed * 8, rest}
    end
  end

  defp ensure_bits_le(bits_acc, bits_left, data, num_bits) do
    if bits_left >= num_bits do
      {bits_acc, bits_left, data}
    else
      bytes_needed = div(num_bits - bits_left + 7, 8)
      <<new_bytes::binary-size(bytes_needed), rest::binary>> = data
      new_bits = :binary.bin_to_list(new_bytes)
        |> Enum.with_index()
        |> Enum.reduce(bits_acc, fn {byte, idx}, acc ->
          bor(acc, bsl(byte, bits_left + idx * 8))
        end)
      {new_bits, bits_left + bytes_needed * 8, rest}
    end
  end

  @doc "Floor division (Python-style: result rounds towards negative infinity)."
  def floor_div(a, b) when is_integer(a) and is_integer(b) do
    d = div(a, b)
    r = rem(a, b)
    if r != 0 and (bxor(r, b) < 0), do: d - 1, else: d
  end
  def floor_div(a, b), do: floor_div(trunc(a), trunc(b))

  @doc "Floor modulo (Python-style: result has same sign as divisor)."
  def floor_mod(a, b) when is_integer(a) and is_integer(b) do
    r = rem(a, b)
    if r != 0 and (bxor(r, b) < 0), do: r + b, else: r
  end
  def floor_mod(a, b), do: floor_mod(trunc(a), trunc(b))

  @doc "Length of a string (character count) or size of a list/binary."
  def kaitai_length(bin) when is_binary(bin), do: String.length(bin)
  def kaitai_length(list) when is_list(list), do: length(list)
  def kaitai_length(nil), do: 0

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

  @doc "XOR each byte in data with a single-byte key."
  def process_xor(data, key) when is_binary(data) and is_integer(key) do
    :binary.bin_to_list(data)
    |> Enum.map(fn b -> bxor(b, key) end)
    |> :binary.list_to_bin()
  end

  def process_xor(data, key) when is_binary(data) and is_binary(key) do
    key_bytes = :binary.bin_to_list(key)
    key_len = length(key_bytes)
    :binary.bin_to_list(data)
    |> Enum.with_index()
    |> Enum.map(fn {b, idx} ->
      bxor(b, Enum.at(key_bytes, rem(idx, key_len)))
    end)
    |> :binary.list_to_bin()
  end

  def process_xor(data, key) when is_binary(data) and is_list(key) do
    process_xor(data, :binary.list_to_bin(key))
  end

  @doc "Rotate each byte left by amount bits."
  def process_rotate_left(data, amount) when is_binary(data) and is_integer(amount) do
    amount = rem(amount, 8)
    :binary.bin_to_list(data)
    |> Enum.map(fn b ->
      band(bor(bsl(b, amount), bsr(b, 8 - amount)), 0xFF)
    end)
    |> :binary.list_to_bin()
  end

  @doc "Decode a binary from the given encoding to a UTF-8 string."
  def decode_string(data, nil), do: data
  def decode_string(data, encoding) do
    enc = String.upcase(to_string(encoding))
    case enc do
      "UTF-8" -> data
      "ASCII" -> data
      "UTF-16LE" ->
        :unicode.characters_to_binary(data, {:utf16, :little}, :utf8)
      "UTF-16BE" ->
        :unicode.characters_to_binary(data, {:utf16, :big}, :utf8)
      "SJIS" -> decode_sjis(data)
      "IBM437" -> decode_ibm437(data)
      _ -> data
    end
  end

  @doc "Read a null-terminated string from binary with encoding support."
  def read_strz_enc(data, encoding, consume \\ true) do
    enc = if encoding, do: String.upcase(to_string(encoding)), else: nil
    # For UTF-16 encodings, the terminator is two null bytes
    if enc in ["UTF-16LE", "UTF-16BE"] do
      {str_bytes, rest} = find_utf16_terminator(data, consume)
      {decode_string(str_bytes, encoding), rest}
    else
      case :binary.match(data, <<0>>) do
        {pos, 1} ->
          str = binary_part(data, 0, pos)
          rest = if consume do
            binary_part(data, pos + 1, byte_size(data) - pos - 1)
          else
            binary_part(data, pos, byte_size(data) - pos)
          end
          {decode_string(str, encoding), rest}
        :nomatch ->
          {decode_string(data, encoding), <<>>}
      end
    end
  end

  defp find_utf16_terminator(data, consume) do
    find_utf16_terminator(data, 0, consume)
  end

  defp find_utf16_terminator(data, pos, consume) when pos + 1 < byte_size(data) do
    if :binary.at(data, pos) == 0 and :binary.at(data, pos + 1) == 0 do
      str = binary_part(data, 0, pos)
      rest = if consume do
        binary_part(data, pos + 2, byte_size(data) - pos - 2)
      else
        binary_part(data, pos, byte_size(data) - pos)
      end
      {str, rest}
    else
      find_utf16_terminator(data, pos + 2, consume)
    end
  end

  defp find_utf16_terminator(data, _pos, _consume) do
    {data, <<>>}
  end

  defp decode_sjis(data) do
    # Simple SJIS decoder - handles single byte ASCII and double byte JIS
    decode_sjis_chars(data, [])
  end

  defp decode_sjis_chars(<<>>, acc), do: IO.iodata_to_binary(Enum.reverse(acc))
  defp decode_sjis_chars(<<b, rest::binary>>, acc) when b < 0x80 do
    decode_sjis_chars(rest, [<<b>> | acc])
  end
  defp decode_sjis_chars(<<b1, b2, rest::binary>>, acc) when b1 >= 0x80 do
    # Try to use :unicode conversion through EUC-JP mapping
    # For now, just try direct conversion
    char = sjis_to_utf8(b1, b2)
    decode_sjis_chars(rest, [char | acc])
  end
  defp decode_sjis_chars(<<b, rest::binary>>, acc) do
    decode_sjis_chars(rest, [<<b>> | acc])
  end

  defp sjis_to_utf8(b1, b2) do
    # Convert SJIS double-byte to UTF-8
    # This is a simplified conversion - for full support would need lookup tables
    code = bsl(b1, 8) ||| b2
    # Use iconv-like approach: map through JIS X 0208
    case :unicode.characters_to_binary(<<b1, b2>>, :latin1) do
      result when is_binary(result) ->
        # Fallback: try to look up in common SJIS ranges
        try_sjis_conversion(code)
      _ -> "?"
    end
  end

  defp try_sjis_conversion(code) do
    # Map common SJIS katakana/hiragana ranges to Unicode
    # SJIS 0x82A0-0x82F1 = Hiragana
    # SJIS 0x8340-0x8396 = Katakana
    cond do
      code >= 0x8281 and code <= 0x829A ->
        # Lowercase ASCII a-z mapped
        <<code - 0x8281 + ?a>>
      code >= 0x8260 and code <= 0x8279 ->
        # Uppercase ASCII A-Z mapped
        <<code - 0x8260 + ?A>>
      code >= 0x824F and code <= 0x8258 ->
        # Digits 0-9
        <<code - 0x824F + ?0>>
      code >= 0x82A0 and code <= 0x82F1 ->
        # Hiragana: SJIS 0x82A0 = U+3041 (ぁ), but common start 0x82A0=ぁ
        unicode_point = 0x3041 + (code - 0x82A0)
        <<unicode_point::utf8>>
      code >= 0x8340 and code <= 0x8396 ->
        # Katakana: SJIS 0x8340 = U+30A1 (ァ)
        offset = code - 0x8340
        # Skip 0x837F which is not a valid SJIS byte
        offset = if code > 0x837E, do: offset - 1, else: offset
        unicode_point = 0x30A1 + offset
        <<unicode_point::utf8>>
      true ->
        <<0xEF, 0xBF, 0xBD>>  # Unicode replacement character
    end
  end

  defp decode_ibm437(data) do
    # IBM437 (CP437) to UTF-8 - map high bytes to Unicode
    data
    |> :binary.bin_to_list()
    |> Enum.map(fn
      b when b < 128 -> <<b::utf8>>
      b -> <<ibm437_to_unicode(b)::utf8>>
    end)
    |> IO.iodata_to_binary()
  end

  # IBM437 high byte to Unicode mapping
  defp ibm437_to_unicode(b) do
    table = %{
      128 => 0x00C7, 129 => 0x00FC, 130 => 0x00E9, 131 => 0x00E2, 132 => 0x00E4,
      133 => 0x00E0, 134 => 0x00E5, 135 => 0x00E7, 136 => 0x00EA, 137 => 0x00EB,
      138 => 0x00E8, 139 => 0x00EF, 140 => 0x00EE, 141 => 0x00EC, 142 => 0x00C4,
      143 => 0x00C5, 144 => 0x00C9, 145 => 0x00E6, 146 => 0x00C6, 147 => 0x00F4,
      148 => 0x00F6, 149 => 0x00F2, 150 => 0x00FB, 151 => 0x00F9, 152 => 0x00FF,
      153 => 0x00D6, 154 => 0x00DC, 155 => 0x00A2, 156 => 0x00A3, 157 => 0x00A5,
      158 => 0x20A7, 159 => 0x0192, 160 => 0x00E1, 161 => 0x00ED, 162 => 0x00F3,
      163 => 0x00FA, 164 => 0x00F1, 165 => 0x00D1, 166 => 0x00AA, 167 => 0x00BA,
      168 => 0x00BF, 169 => 0x2310, 170 => 0x00AC, 171 => 0x00BD, 172 => 0x00BC,
      173 => 0x00A1, 174 => 0x00AB, 175 => 0x00BB, 176 => 0x2591, 177 => 0x2592,
      178 => 0x2593, 179 => 0x2502, 180 => 0x2524, 181 => 0x2561, 182 => 0x2562,
      183 => 0x2556, 184 => 0x2555, 185 => 0x2563, 186 => 0x2551, 187 => 0x2557,
      188 => 0x255D, 189 => 0x255C, 190 => 0x255B, 191 => 0x2510, 192 => 0x2514,
      193 => 0x2534, 194 => 0x252C, 195 => 0x251C, 196 => 0x2500, 197 => 0x253C,
      198 => 0x255E, 199 => 0x255F, 200 => 0x255A, 201 => 0x2554, 202 => 0x2569,
      203 => 0x2566, 204 => 0x2560, 205 => 0x2550, 206 => 0x256C, 207 => 0x2567,
      208 => 0x2568, 209 => 0x2564, 210 => 0x2565, 211 => 0x2559, 212 => 0x2558,
      213 => 0x2552, 214 => 0x2553, 215 => 0x256B, 216 => 0x256A, 217 => 0x2518,
      218 => 0x250C, 219 => 0x2588, 220 => 0x2584, 221 => 0x258C, 222 => 0x2590,
      223 => 0x2580, 224 => 0x03B1, 225 => 0x00DF, 226 => 0x0393, 227 => 0x03C0,
      228 => 0x03A3, 229 => 0x03C3, 230 => 0x00B5, 231 => 0x03C4, 232 => 0x03A6,
      233 => 0x0398, 234 => 0x03A9, 235 => 0x03B4, 236 => 0x221E, 237 => 0x03C6,
      238 => 0x03B5, 239 => 0x2229, 240 => 0x2261, 241 => 0x00B1, 242 => 0x2265,
      243 => 0x2264, 244 => 0x2320, 245 => 0x2321, 246 => 0x00F7, 247 => 0x2248,
      248 => 0x00B0, 249 => 0x2219, 250 => 0x00B7, 251 => 0x221A, 252 => 0x207F,
      253 => 0x00B2, 254 => 0x25A0, 255 => 0x00A0
    }
    Map.get(table, b, 0xFFFD)
  end

  @doc "Zlib decompress."
  def process_zlib(data) when is_binary(data) do
    z = :zlib.open()
    :zlib.inflateInit(z)
    result = :zlib.inflate(z, data)
    :zlib.inflateEnd(z)
    :zlib.close(z)
    IO.iodata_to_binary(result)
  end

end
