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
    new_acc = [item | acc]

    if until_fn.(item, new_acc) do
      {Enum.reverse(new_acc), rest}
    else
      repeat_until_acc(rest, parse_fn, until_fn, new_acc)
    end
  end

  @doc "Parse items repeatedly until binary is exhausted, with index tracking."
  def repeat_eos_idx(data, parse_fn) do
    repeat_eos_idx_acc(data, parse_fn, [], 0)
  end

  defp repeat_eos_idx_acc(<<>>, _parse_fn, acc, _idx), do: {Enum.reverse(acc), <<>>}

  defp repeat_eos_idx_acc(data, parse_fn, acc, idx) do
    {item, rest} = parse_fn.(data, idx)
    repeat_eos_idx_acc(rest, parse_fn, [item | acc], idx + 1)
  end

  @doc "Parse items repeatedly until condition is met, with index tracking."
  def repeat_until_idx(data, parse_fn, until_fn) do
    repeat_until_idx_acc(data, parse_fn, until_fn, [], 0)
  end

  defp repeat_until_idx_acc(data, parse_fn, until_fn, acc, idx) do
    {item, rest} = parse_fn.(data, idx)
    new_acc = [item | acc]

    if until_fn.(item, new_acc) do
      {Enum.reverse(new_acc), rest}
    else
      repeat_until_idx_acc(rest, parse_fn, until_fn, new_acc, idx + 1)
    end
  end

  @doc "Parse items until parse fn signals done (returns {item, rest, true})."
  def repeat_until_check(data, parse_fn) do
    repeat_until_check_acc(data, parse_fn, [])
  end

  defp repeat_until_check_acc(data, parse_fn, acc) do
    {item, rest, done} = parse_fn.(data)
    new_acc = [item | acc]

    if done,
      do: {Enum.reverse(new_acc), rest},
      else: repeat_until_check_acc(rest, parse_fn, new_acc)
  end

  @doc "Parse items until parse fn signals done, with index tracking."
  def repeat_until_check_idx(data, parse_fn) do
    repeat_until_check_idx_acc(data, parse_fn, [], 0)
  end

  defp repeat_until_check_idx_acc(data, parse_fn, acc, idx) do
    {item, rest, done} = parse_fn.(data, idx)
    new_acc = [item | acc]

    if done,
      do: {Enum.reverse(new_acc), rest},
      else: repeat_until_check_idx_acc(rest, parse_fn, new_acc, idx + 1)
  end

  @doc "Parse bit items repeatedly until binary is exhausted."
  def repeat_eos_bits(data, num_bits, bit_fn) do
    bits_state = {0, 0, data}
    repeat_eos_bits_acc(bits_state, num_bits, bit_fn, [])
  end

  defp repeat_eos_bits_acc({_, 0, <<>>}, _num_bits, _bit_fn, acc), do: {Enum.reverse(acc), <<>>}

  defp repeat_eos_bits_acc({_bits_acc, bits_left, data} = state, num_bits, bit_fn, acc) do
    # Check if we have enough bits left to read
    total_bits = bits_left + byte_size(data) * 8

    if total_bits < num_bits do
      {Enum.reverse(acc), align_to_byte(state)}
    else
      {item, new_state} = bit_fn.(state, num_bits)
      repeat_eos_bits_acc(new_state, num_bits, bit_fn, [item | acc])
    end
  end

  @doc "Strip trailing pad bytes from binary."
  def strip_pad_right(data, pad_byte) when is_binary(data) and is_integer(pad_byte) do
    do_strip_pad_right(data, byte_size(data), pad_byte)
  end

  defp do_strip_pad_right(_data, 0, _pad_byte), do: <<>>

  defp do_strip_pad_right(data, pos, pad_byte) do
    if :binary.at(data, pos - 1) == pad_byte do
      do_strip_pad_right(data, pos - 1, pad_byte)
    else
      binary_part(data, 0, pos)
    end
  end

  @doc "Terminate binary at first occurrence of byte."
  def terminate_at(data, term_byte, include \\ false) do
    case :binary.match(data, <<term_byte>>) do
      {pos, 1} ->
        if include do
          binary_part(data, 0, pos + 1)
        else
          binary_part(data, 0, pos)
        end

      :nomatch ->
        data
    end
  end

  @doc "Terminate at terminator, then strip pad bytes only when terminator was NOT found."
  def terminate_and_pad(data, term_byte, include, pad_byte) do
    if :binary.match(data, <<term_byte>>) == :nomatch do
      strip_pad_right(data, pad_byte)
    else
      terminate_at(data, term_byte, include)
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

        rest =
          if consume do
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
    case :binary.match(data, <<term_byte>>) do
      {pos, 1} ->
        result = if include, do: binary_part(data, 0, pos + 1), else: binary_part(data, 0, pos)
        rest_start = if consume, do: pos + 1, else: pos
        rest = binary_part(data, rest_start, byte_size(data) - rest_start)
        {result, rest}

      :nomatch ->
        {data, <<>>}
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
    value = bsr(bits_acc, shift) |> band(bsl(1, num_bits) - 1)
    # Remove those bits from accumulator
    remaining_bits = bits_left - num_bits
    remaining_acc = band(bits_acc, bsl(1, remaining_bits) - 1)
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
    value = band(bits_acc, bsl(1, num_bits) - 1)
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
      bytes_needed = div(num_bits - bits_left + 7, 8)
      <<new_bytes::binary-size(bytes_needed), rest::binary>> = data
      new_bits = accum_bits_be(new_bytes, bits_acc)
      {new_bits, bits_left + bytes_needed * 8, rest}
    end
  end

  defp accum_bits_be(<<b, rest::binary>>, acc), do: accum_bits_be(rest, bor(bsl(acc, 8), b))
  defp accum_bits_be(<<>>, acc), do: acc

  defp ensure_bits_le(bits_acc, bits_left, data, num_bits) do
    if bits_left >= num_bits do
      {bits_acc, bits_left, data}
    else
      bytes_needed = div(num_bits - bits_left + 7, 8)
      <<new_bytes::binary-size(bytes_needed), rest::binary>> = data
      new_bits = accum_bits_le(new_bytes, bits_acc, bits_left)
      {new_bits, bits_left + bytes_needed * 8, rest}
    end
  end

  defp accum_bits_le(<<b, rest::binary>>, acc, shift),
    do: accum_bits_le(rest, bor(acc, bsl(b, shift)), shift + 8)

  defp accum_bits_le(<<>>, acc, _shift), do: acc

  @doc "Floor division (Python-style: result rounds towards negative infinity)."
  def floor_div(a, b) when is_integer(a) and is_integer(b) do
    d = div(a, b)
    r = rem(a, b)
    if r != 0 and bxor(r, b) < 0, do: d - 1, else: d
  end

  def floor_div(a, b), do: floor_div(trunc(a), trunc(b))

  @doc "Floor modulo (Python-style: result has same sign as divisor)."
  def floor_mod(a, b) when is_integer(a) and is_integer(b) do
    r = rem(a, b)
    if r != 0 and bxor(r, b) < 0, do: r + b, else: r
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
  def kaitai_size(%{_io_size: size}), do: size
  def kaitai_size(%{} = map), do: map_size(map)

  @doc "Get the sizeof a parsed type or field. Uses stored _sizeof metadata."
  def kaitai_sizeof(%{_sizeof: size}), do: size
  def kaitai_sizeof(_), do: 0

  @doc "Get the IO stream size for a parsed object. Uses stored _io_size metadata."
  def kaitai_io_size(%{_io_size: size}), do: size
  def kaitai_io_size(_), do: 0

  @doc "Get minimum value from a list or binary (treating bytes as values)."
  def kaitai_min(<<first, rest::binary>>), do: do_bin_min(rest, first)
  def kaitai_min(list) when is_list(list), do: Enum.min(list)

  defp do_bin_min(<<b, rest::binary>>, m) when b < m, do: do_bin_min(rest, b)
  defp do_bin_min(<<_, rest::binary>>, m), do: do_bin_min(rest, m)
  defp do_bin_min(<<>>, m), do: m

  @doc "Get maximum value from a list or binary."
  def kaitai_max(<<first, rest::binary>>), do: do_bin_max(rest, first)
  def kaitai_max(list) when is_list(list), do: Enum.max(list)

  defp do_bin_max(<<b, rest::binary>>, m) when b > m, do: do_bin_max(rest, b)
  defp do_bin_max(<<_, rest::binary>>, m), do: do_bin_max(rest, m)
  defp do_bin_max(<<>>, m), do: m

  @doc "Access element at index (supports both lists and binaries)."
  def kaitai_at(bin, idx) when is_binary(bin), do: :binary.at(bin, idx)
  def kaitai_at(list, idx) when is_list(list), do: Enum.at(list, idx)

  @doc "Get first element of a list or first byte of a binary."
  def kaitai_first(nil), do: nil
  def kaitai_first(bin) when is_binary(bin), do: :binary.at(bin, 0)
  def kaitai_first(list) when is_list(list), do: List.first(list)
  def kaitai_first(%{first: val}), do: val
  def kaitai_first(%{} = map), do: map

  @doc "Get last element of a list or last byte of a binary."
  def kaitai_last(nil), do: nil
  def kaitai_last(bin) when is_binary(bin), do: :binary.at(bin, byte_size(bin) - 1)
  def kaitai_last(list) when is_list(list), do: List.last(list)
  def kaitai_last(%{last: val}), do: val
  def kaitai_last(%{} = map), do: map

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

  @doc "Convert value to integer with enum reverse lookup."
  def to_i(true, _reverse_map), do: 1
  def to_i(false, _reverse_map), do: 0
  def to_i(x, reverse_map) when is_atom(x), do: Map.get(reverse_map, x, 0)
  def to_i(x, _reverse_map), do: to_i(x)

  @doc "XOR each byte in data with a single-byte key."
  def process_xor(data, key) when is_binary(data) and is_integer(key) do
    for <<b <- data>>, into: <<>>, do: <<bxor(b, key)>>
  end

  def process_xor(<<>>, _key), do: <<>>

  def process_xor(data, key) when is_binary(data) and is_binary(key) do
    # XOR the whole blob in one shot by treating both sides as big integers: the
    # BEAM runs bignum `bxor` in C, so this beats a per-byte Elixir loop by ~7x
    # with no extra dependencies. `encode_unsigned` drops leading zero bytes, so
    # we left-pad back to the original size.
    size = byte_size(data)
    tiled = tile_key(key, size)
    result = bxor(:binary.decode_unsigned(data), :binary.decode_unsigned(tiled))
    encoded = :binary.encode_unsigned(result)
    pad = size - byte_size(encoded)
    if pad > 0, do: <<0::size(pad * 8), encoded::binary>>, else: encoded
  end

  def process_xor(data, key) when is_binary(data) and is_list(key) do
    process_xor(data, :binary.list_to_bin(key))
  end

  defp tile_key(key, size) do
    copies = div(size, byte_size(key)) + 1
    key |> :binary.copy(copies) |> binary_part(0, size)
  end

  @doc "Rotate each byte left by amount bits."
  def process_rotate_left(data, amount) when is_binary(data) and is_integer(amount) do
    amount = rem(amount, 8)
    for <<b <- data>>, into: <<>>, do: <<band(bor(bsl(b, amount), bsr(b, 8 - amount)), 0xFF)>>
  end

  @doc "Decode a binary from the given encoding to a UTF-8 string."
  def decode_string(data, nil), do: data

  def decode_string(data, encoding) do
    enc = String.upcase(to_string(encoding))

    case enc do
      "UTF-8" ->
        data

      "ASCII" ->
        data

      "UTF-16LE" ->
        :unicode.characters_to_binary(data, {:utf16, :little}, :utf8)

      "UTF-16BE" ->
        :unicode.characters_to_binary(data, {:utf16, :big}, :utf8)

      "SJIS" ->
        decode_sjis(data)

      "IBM437" ->
        decode_ibm437(data)

      enc when enc in ["WINDOWS-1252", "CP1252"] ->
        decode_cp1252(data)

      enc when enc in ["ISO-8859-1", "ISO8859-1", "LATIN1", "LATIN-1"] ->
        decode_latin1(data)

      _ ->
        raise ArgumentError, "unsupported encoding: #{inspect(encoding)}"
    end
  end

  @doc "Read a null-terminated string from binary with encoding support."
  def read_strz_enc(data, encoding, consume \\ true, include \\ false) do
    enc = if encoding, do: String.upcase(to_string(encoding)), else: nil
    # For UTF-16 encodings, the terminator is two null bytes
    if enc in ["UTF-16LE", "UTF-16BE"] do
      {str_bytes, rest} = find_utf16_terminator(data, consume, include)
      {decode_string(str_bytes, encoding), rest}
    else
      case :binary.match(data, <<0>>) do
        {pos, 1} ->
          str =
            if include do
              binary_part(data, 0, pos + 1)
            else
              binary_part(data, 0, pos)
            end

          rest =
            if consume do
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

  defp find_utf16_terminator(data, consume, include) do
    find_utf16_terminator(data, 0, consume, include)
  end

  defp find_utf16_terminator(data, pos, consume, include) when pos + 1 < byte_size(data) do
    if :binary.at(data, pos) == 0 and :binary.at(data, pos + 1) == 0 do
      str =
        if include do
          binary_part(data, 0, pos + 2)
        else
          binary_part(data, 0, pos)
        end

      rest =
        if consume do
          binary_part(data, pos + 2, byte_size(data) - pos - 2)
        else
          binary_part(data, pos, byte_size(data) - pos)
        end

      {str, rest}
    else
      find_utf16_terminator(data, pos + 2, consume, include)
    end
  end

  defp find_utf16_terminator(data, _pos, _consume, _include) do
    {data, <<>>}
  end

  defp decode_sjis(data) do
    decode_sjis_chars(data, [])
  end

  defp decode_sjis_chars(<<>>, acc), do: IO.iodata_to_binary(Enum.reverse(acc))

  defp decode_sjis_chars(<<b, rest::binary>>, acc) when b < 0x80 do
    decode_sjis_chars(rest, [<<b>> | acc])
  end

  defp decode_sjis_chars(<<b, rest::binary>>, acc) when b >= 0xA1 and b <= 0xDF do
    # Half-width katakana
    unicode = 0xFF61 + (b - 0xA1)
    decode_sjis_chars(rest, [<<unicode::utf8>> | acc])
  end

  defp decode_sjis_chars(<<b1, b2, rest::binary>>, acc)
       when (b1 >= 0x81 and b1 <= 0x9F) or (b1 >= 0xE0 and b1 <= 0xEF) do
    unicode = sjis_to_unicode(b1, b2)
    decode_sjis_chars(rest, [<<unicode::utf8>> | acc])
  end

  defp decode_sjis_chars(<<_b, rest::binary>>, acc) do
    decode_sjis_chars(rest, [<<0xEF, 0xBF, 0xBD>> | acc])
  end

  defp sjis_to_unicode(b1, b2) do
    # Convert SJIS to JIS X 0208 row/col
    {row, col} = sjis_to_jis(b1, b2)
    jis_to_unicode(row, col)
  end

  defp sjis_to_jis(b1, b2) do
    row_offset = if b1 < 0xA0, do: 0x70, else: 0xB0
    row = (b1 - row_offset) * 2 - 1

    {row, col} =
      if b2 >= 0x9F do
        {row + 1, b2 - 0x7E}
      else
        col = if b2 > 0x7F, do: b2 - 0x40, else: b2 - 0x3F
        {row, col + 0x20}
      end

    {row, col}
  end

  defp jis_to_unicode(row, col) do
    cond do
      # Hiragana
      row == 0x24 -> 0x3020 + col
      # Katakana
      row == 0x25 -> 0x3080 + col
      # Symbols row 1
      row == 0x21 -> jis_symbols_row1(col)
      # Full-width ASCII
      row == 0x23 -> jis_fullwidth_ascii(col)
      true -> 0xFFFD
    end
  end

  defp jis_symbols_row1(col) do
    # Common JIS X 0208 row 1 symbols
    table = %{
      0x21 => 0x3000,
      0x22 => 0x3001,
      0x23 => 0x3002,
      0x24 => 0xFF0C,
      0x25 => 0xFF0E,
      0x26 => 0x30FB,
      0x27 => 0xFF1A,
      0x28 => 0xFF1B,
      0x29 => 0xFF1F,
      0x2A => 0xFF01,
      0x3C => 0xFF0D,
      0x5C => 0x30FC
    }

    Map.get(table, col, 0xFFFD)
  end

  defp jis_fullwidth_ascii(col) do
    cond do
      # 0-9
      col >= 0x30 and col <= 0x39 -> 0xFF10 + (col - 0x30)
      # A-Z
      col >= 0x41 and col <= 0x5A -> 0xFF21 + (col - 0x41)
      # a-z
      col >= 0x61 and col <= 0x7A -> 0xFF41 + (col - 0x61)
      true -> 0xFFFD
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
      128 => 0x00C7,
      129 => 0x00FC,
      130 => 0x00E9,
      131 => 0x00E2,
      132 => 0x00E4,
      133 => 0x00E0,
      134 => 0x00E5,
      135 => 0x00E7,
      136 => 0x00EA,
      137 => 0x00EB,
      138 => 0x00E8,
      139 => 0x00EF,
      140 => 0x00EE,
      141 => 0x00EC,
      142 => 0x00C4,
      143 => 0x00C5,
      144 => 0x00C9,
      145 => 0x00E6,
      146 => 0x00C6,
      147 => 0x00F4,
      148 => 0x00F6,
      149 => 0x00F2,
      150 => 0x00FB,
      151 => 0x00F9,
      152 => 0x00FF,
      153 => 0x00D6,
      154 => 0x00DC,
      155 => 0x00A2,
      156 => 0x00A3,
      157 => 0x00A5,
      158 => 0x20A7,
      159 => 0x0192,
      160 => 0x00E1,
      161 => 0x00ED,
      162 => 0x00F3,
      163 => 0x00FA,
      164 => 0x00F1,
      165 => 0x00D1,
      166 => 0x00AA,
      167 => 0x00BA,
      168 => 0x00BF,
      169 => 0x2310,
      170 => 0x00AC,
      171 => 0x00BD,
      172 => 0x00BC,
      173 => 0x00A1,
      174 => 0x00AB,
      175 => 0x00BB,
      176 => 0x2591,
      177 => 0x2592,
      178 => 0x2593,
      179 => 0x2502,
      180 => 0x2524,
      181 => 0x2561,
      182 => 0x2562,
      183 => 0x2556,
      184 => 0x2555,
      185 => 0x2563,
      186 => 0x2551,
      187 => 0x2557,
      188 => 0x255D,
      189 => 0x255C,
      190 => 0x255B,
      191 => 0x2510,
      192 => 0x2514,
      193 => 0x2534,
      194 => 0x252C,
      195 => 0x251C,
      196 => 0x2500,
      197 => 0x253C,
      198 => 0x255E,
      199 => 0x255F,
      200 => 0x255A,
      201 => 0x2554,
      202 => 0x2569,
      203 => 0x2566,
      204 => 0x2560,
      205 => 0x2550,
      206 => 0x256C,
      207 => 0x2567,
      208 => 0x2568,
      209 => 0x2564,
      210 => 0x2565,
      211 => 0x2559,
      212 => 0x2558,
      213 => 0x2552,
      214 => 0x2553,
      215 => 0x256B,
      216 => 0x256A,
      217 => 0x2518,
      218 => 0x250C,
      219 => 0x2588,
      220 => 0x2584,
      221 => 0x258C,
      222 => 0x2590,
      223 => 0x2580,
      224 => 0x03B1,
      225 => 0x00DF,
      226 => 0x0393,
      227 => 0x03C0,
      228 => 0x03A3,
      229 => 0x03C3,
      230 => 0x00B5,
      231 => 0x03C4,
      232 => 0x03A6,
      233 => 0x0398,
      234 => 0x03A9,
      235 => 0x03B4,
      236 => 0x221E,
      237 => 0x03C6,
      238 => 0x03B5,
      239 => 0x2229,
      240 => 0x2261,
      241 => 0x00B1,
      242 => 0x2265,
      243 => 0x2264,
      244 => 0x2320,
      245 => 0x2321,
      246 => 0x00F7,
      247 => 0x2248,
      248 => 0x00B0,
      249 => 0x2219,
      250 => 0x00B7,
      251 => 0x221A,
      252 => 0x207F,
      253 => 0x00B2,
      254 => 0x25A0,
      255 => 0x00A0
    }

    Map.get(table, b, 0xFFFD)
  end

  # Windows-1252 differs from ISO-8859-1 only in 0x80..0x9F, where it defines
  # printable typographic characters (curly quotes, dashes, the euro sign, ...).
  # The five undefined positions (0x81, 0x8D, 0x8F, 0x90, 0x9D) fall through to
  # their own byte value, matching ISO-8859-1, so they still round-trip.
  @cp1252_high %{
    0x80 => 0x20AC,
    0x82 => 0x201A,
    0x83 => 0x0192,
    0x84 => 0x201E,
    0x85 => 0x2026,
    0x86 => 0x2020,
    0x87 => 0x2021,
    0x88 => 0x02C6,
    0x89 => 0x2030,
    0x8A => 0x0160,
    0x8B => 0x2039,
    0x8C => 0x0152,
    0x8E => 0x017D,
    0x91 => 0x2018,
    0x92 => 0x2019,
    0x93 => 0x201C,
    0x94 => 0x201D,
    0x95 => 0x2022,
    0x96 => 0x2013,
    0x97 => 0x2014,
    0x98 => 0x02DC,
    0x99 => 0x2122,
    0x9A => 0x0161,
    0x9B => 0x203A,
    0x9C => 0x0153,
    0x9E => 0x017E,
    0x9F => 0x0178
  }
  @cp1252_reverse Map.new(@cp1252_high, fn {byte, cp} -> {cp, byte} end)

  defp decode_cp1252(data) do
    for <<b <- data>>, into: <<>>, do: <<cp1252_codepoint(b)::utf8>>
  end

  defp cp1252_codepoint(b) when b in 0x80..0x9F, do: Map.get(@cp1252_high, b, b)
  defp cp1252_codepoint(b), do: b

  defp encode_cp1252(data) do
    for <<cp::utf8 <- data>>, into: <<>>, do: <<cp1252_byte(cp)>>
  end

  defp cp1252_byte(cp) when cp <= 0xFF, do: cp

  defp cp1252_byte(cp) do
    case Map.get(@cp1252_reverse, cp) do
      nil ->
        raise ArgumentError, "codepoint U+#{int_to_hex(cp)} not representable in windows-1252"

      byte ->
        byte
    end
  end

  # ISO-8859-1 (Latin-1): bytes 0x00..0xFF map straight to U+0000..U+00FF.
  defp decode_latin1(data) do
    for <<b <- data>>, into: <<>>, do: <<b::utf8>>
  end

  defp encode_latin1(data) do
    for <<cp::utf8 <- data>>, into: <<>>, do: <<latin1_byte(cp)>>
  end

  defp latin1_byte(cp) when cp <= 0xFF, do: cp

  defp latin1_byte(cp) do
    raise ArgumentError, "codepoint U+#{int_to_hex(cp)} not representable in ISO-8859-1"
  end

  defp int_to_hex(cp), do: cp |> Integer.to_string(16) |> String.pad_leading(4, "0")

  @doc "KSY add operator - string concat or arithmetic add."
  def kaitai_add(a, b) when is_binary(a) and is_binary(b), do: a <> b
  def kaitai_add(a, b) when is_binary(a), do: a <> to_string(b)
  def kaitai_add(a, b) when is_binary(b), do: to_string(a) <> b
  def kaitai_add(a, b) when is_list(a) and is_list(b), do: a ++ b
  def kaitai_add(a, b), do: a + b

  @doc "Zlib decompress."
  def process_zlib(data) when is_binary(data) do
    :zlib.uncompress(data)
  end

  # ===========================================================================
  # Writer helpers (mirror of the reader helpers above)
  # ===========================================================================

  @doc """
  Write N bits in big-endian bit order into the accumulator state.
  State is `{bits_acc, bits_left, iodata}`. Returns a new state.
  """
  def write_bits_be({bits_acc, bits_left, iodata}, value, num_bits) do
    new_acc = bor(bsl(bits_acc, num_bits), band(value, bsl(1, num_bits) - 1))
    new_left = bits_left + num_bits
    flush_full_bytes_be(new_acc, new_left, iodata)
  end

  defp flush_full_bytes_be(acc, left, iodata) when left >= 8 do
    shift = left - 8
    byte = bsr(acc, shift) |> band(0xFF)
    new_acc = band(acc, bsl(1, shift) - 1)
    flush_full_bytes_be(new_acc, shift, [iodata, byte])
  end

  defp flush_full_bytes_be(acc, left, iodata), do: {acc, left, iodata}

  @doc """
  Write N bits in little-endian bit order. Bits are accumulated low-end-first.
  """
  def write_bits_le({bits_acc, bits_left, iodata}, value, num_bits) do
    masked = band(value, bsl(1, num_bits) - 1)
    new_acc = bor(bits_acc, bsl(masked, bits_left))
    new_left = bits_left + num_bits
    flush_full_bytes_le(new_acc, new_left, iodata)
  end

  defp flush_full_bytes_le(acc, left, iodata) when left >= 8 do
    byte = band(acc, 0xFF)
    new_acc = bsr(acc, 8)
    flush_full_bytes_le(new_acc, left - 8, [iodata, byte])
  end

  defp flush_full_bytes_le(acc, left, iodata), do: {acc, left, iodata}

  @doc """
  Flush a BE bit accumulator: zero-pad any partial byte at the high-end of the byte.
  Returns iodata.
  """
  def flush_bits_be({_acc, 0, iodata}), do: iodata

  def flush_bits_be({acc, left, iodata}) when left > 0 and left < 8 do
    byte = bsl(acc, 8 - left) |> band(0xFF)
    [iodata, byte]
  end

  @doc """
  Flush a LE bit accumulator: emit the partial byte (low bits already in place).
  Returns iodata.
  """
  def flush_bits_le({_acc, 0, iodata}), do: iodata

  def flush_bits_le({acc, left, iodata}) when left > 0 and left < 8 do
    [iodata, band(acc, 0xFF)]
  end

  @doc """
  Encode a UTF-8 string back to the target encoding. Inverse of `decode_string/2`.
  Raises `{:unsupported_write_encoding, enc}` for encodings not yet supported on write.
  """
  def encode_string(data, nil), do: data
  def encode_string(data, "UTF-8"), do: data
  def encode_string(data, "ASCII"), do: data

  def encode_string(data, encoding) do
    enc = String.upcase(to_string(encoding))

    case enc do
      "UTF-8" ->
        data

      "ASCII" ->
        data

      "UTF-16LE" ->
        :unicode.characters_to_binary(data, :utf8, {:utf16, :little})

      "UTF-16BE" ->
        :unicode.characters_to_binary(data, :utf8, {:utf16, :big})

      enc when enc in ["WINDOWS-1252", "CP1252"] ->
        encode_cp1252(data)

      enc when enc in ["ISO-8859-1", "ISO8859-1", "LATIN1", "LATIN-1"] ->
        encode_latin1(data)

      _ ->
        raise ArgumentError, "unsupported write encoding: #{enc}"
    end
  end

  @doc """
  Append the appropriate null terminator for the encoding to already-encoded bytes.
  Two NUL bytes for UTF-16; one for everything else.
  """
  def write_strz(bytes, encoding) do
    enc = if encoding, do: String.upcase(to_string(encoding)), else: nil

    if enc in ["UTF-16LE", "UTF-16BE"] do
      <<bytes::binary, 0, 0>>
    else
      <<bytes::binary, 0>>
    end
  end

  @doc """
  Pad `bytes` on the right with `pad_byte` until length equals `size`.
  Raises `{:size_overflow, actual, expected}` if `byte_size(bytes) > size`.
  """
  def pad_right_to(bytes, size, pad_byte)
      when is_binary(bytes) and is_integer(size) and is_integer(pad_byte) do
    actual = byte_size(bytes)

    cond do
      actual == size ->
        bytes

      actual < size ->
        padding = :binary.copy(<<pad_byte>>, size - actual)
        <<bytes::binary, padding::binary>>

      true ->
        raise ArgumentError, "size_overflow: #{actual} bytes does not fit in #{size}"
    end
  end

  @doc "Append a single terminator byte to bytes."
  def append_terminator(bytes, term_byte) when is_binary(bytes) and is_integer(term_byte) do
    <<bytes::binary, term_byte>>
  end

  @doc """
  Append a terminator byte then pad to size (write-side analogue of `terminate_and_pad/4`).
  The terminator counts toward the size.
  """
  def terminate_and_pad_write(bytes, term_byte, size, pad_byte) do
    bytes |> append_terminator(term_byte) |> pad_right_to(size, pad_byte)
  end

  @doc "Inverse of process_xor — XOR is self-inverse."
  def unprocess_xor(data, key), do: process_xor(data, key)

  @doc """
  Inverse of `process_rotate_left/2`: rotate bytes right by `amount` bits.
  Equivalent to rotating left by `8 - amount`.
  """
  def unprocess_rotate_left(data, amount) when is_binary(data) and is_integer(amount) do
    process_rotate_left(data, 8 - rem(amount, 8))
  end

  @doc "Rotate bytes right (inverse direction for the `ror(n)` process)."
  def unprocess_rotate_right(data, amount) when is_binary(data) and is_integer(amount) do
    process_rotate_left(data, amount)
  end

  @doc """
  Zlib re-compress. Semantically correct round-trip but not byte-identical to the
  original compressed blob (compression level / dictionary may differ).
  """
  def unprocess_zlib(data) when is_binary(data) do
    :zlib.compress(data)
  end

  @doc """
  Write a list of bit-typed values in big-endian bit order. Returns a binary
  with any trailing partial byte zero-padded.
  """
  def repeat_write_bits_be(list, num_bits) when is_list(list) and is_integer(num_bits) do
    state = Enum.reduce(list, {0, 0, []}, fn v, st -> write_bits_be(st, v, num_bits) end)
    state |> flush_bits_be() |> IO.iodata_to_binary()
  end

  @doc "Little-endian variant of `repeat_write_bits_be/2`."
  def repeat_write_bits_le(list, num_bits) when is_list(list) and is_integer(num_bits) do
    state = Enum.reduce(list, {0, 0, []}, fn v, st -> write_bits_le(st, v, num_bits) end)
    state |> flush_bits_le() |> IO.iodata_to_binary()
  end

  @doc "Reverse an iodata list and flatten to a binary. Used by generated `to_binary/1`."
  def to_binary_finalize(iodata_rev) when is_list(iodata_rev) do
    iodata_rev |> :lists.reverse() |> IO.iodata_to_binary()
  end
end
