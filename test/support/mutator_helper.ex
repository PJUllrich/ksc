defmodule Ksc.MutatorHelper do
  @moduledoc """
  Helpers for generating random mutations of parsed KSY maps, used by
  `WriteBackMutationTest`. Walks a parsed map alongside its `ClassSpec` and
  replaces every writable seq field with a random value of the same type and
  potentially different length (up to 2× original).

  Controller fields (those that `Ksc.Compiler.ElixirCompiler.detect_simple_controllers/1`
  identifies as auto-updated by the writer) are **not** mutated — any value we
  put would be overwritten by the writer's pre-pass.

  ## Scope

  v1 covers the seq fields of non-parameterised, non-imported types. Out of
  scope: positional instances, parameterised types, imported types,
  process/encoding edge cases that the writer skips per its own scope cuts.
  """

  alias Ksc.Format.{AttrSpec, ClassSpec}
  alias Ksc.Compiler.ElixirCompiler

  @doc """
  Mutate every writable seq field of `parsed` in place.

  Returns the mutated map. The seed should be set externally via `:rand.seed/2`
  for reproducibility — this module never seeds itself.
  """
  def mutate(parsed, %ClassSpec{} = spec) when is_map(parsed) do
    controllers_data = ElixirCompiler.detect_simple_controllers(spec)

    controllers =
      controllers_data
      |> Enum.map(fn {ctrl, _, _, _, _} -> ctrl end)
      |> MapSet.new()

    # Set of fields that ARE controlled by a simple controller — these can
    # safely grow because the writer auto-updates the controller. Fields not
    # in this set whose size is a literal integer must keep their length
    # exactly; complex size expressions get shrink-only mutation.
    growable =
      controllers_data
      |> Enum.map(fn {_, controlled, _, _, _} -> controlled end)
      |> MapSet.new()

    # When multiple fields share one controller, they must all get the same
    # new length — otherwise the controller's single value can't satisfy them
    # all and the re-parse drifts. Pre-pick one target length per controlled
    # field-group, based on the FIRST controlled field's original length.
    shared_lengths =
      controllers_data
      |> Enum.group_by(fn {ctrl, _, _, _, _} -> ctrl end)
      |> Enum.flat_map(fn {_ctrl, entries} ->
        case entries do
          [_single] ->
            []

          [{_, first_controlled, kind, _, _} | _] = group ->
            ref_value = Map.get(parsed, String.to_atom(first_controlled))
            ref_len = measure(ref_value, kind) || 0
            new_len = vary_length(ref_len)
            Enum.map(group, fn {_, controlled, _, _, _} -> {controlled, new_len} end)
        end
      end)
      |> Map.new()

    seq = number_anonymous_fields(spec.seq)

    # First pass: mutate non-controller seq fields.
    mutated =
      Enum.reduce(seq, parsed, fn attr, acc ->
        key = String.to_atom(attr.id)

        cond do
          MapSet.member?(controllers, attr.id) -> acc
          attr.contents != nil -> acc
          Map.get(acc, key) == nil -> acc
          true ->
            length_mode = decide_length_mode(attr, growable)
            fixed_len = Map.get(shared_lengths, attr.id)
            new_val = mutate_attr(attr, Map.get(acc, key), spec, length_mode, fixed_len)
            Map.put(acc, key, new_val)
        end
      end)

    # Second pass: update controller fields to match the new payload lengths
    # so the post-write/re-parse comparison succeeds. This mirrors the writer's
    # controller pre-pass (`Ksc.Compiler.ElixirCompiler.compile_controller_assignments/1`).
    update_controllers(mutated, controllers_data, spec)
  end

  def mutate(other, _spec), do: other

  # Length-handling mode for a field:
  #   :grow  — free 0..2× variation (simple controller, the writer auto-updates it)
  #   :fixed — keep the exact length (literal-integer size, e.g. `size: 16`)
  #   :shrink — stay within original size (complex expression, e.g. `size: x - 8`)
  defp decide_length_mode(%AttrSpec{repeat: r} = attr, growable) when r != nil do
    cond do
      MapSet.member?(growable, attr.id) -> :grow
      attr.repeat_expr != nil and literal_integer?(attr.repeat_expr) -> :fixed
      true -> :shrink
    end
  end

  defp decide_length_mode(%AttrSpec{} = attr, growable) do
    cond do
      MapSet.member?(growable, attr.id) -> :grow
      attr.size == nil -> :grow
      literal_integer?(attr.size) -> :fixed
      true -> :shrink
    end
  end

  defp literal_integer?(str) when is_binary(str) do
    case Integer.parse(String.trim(str)) do
      {_, ""} -> true
      _ -> false
    end
  end

  defp literal_integer?(_), do: false

  defp pick_length(:grow, n), do: vary_length(n)
  defp pick_length(:fixed, n), do: n
  defp pick_length(:shrink, n), do: shrink_length(n)

  # Dispatch on the attr's structural shape. `fixed_len` (if non-nil) forces a
  # specific length, used when multiple fields share one controller.
  defp mutate_attr(%AttrSpec{repeat: r} = attr, value, spec, length_mode, fixed_len)
       when r != nil and is_list(value) do
    inner_attr = %{attr | repeat: nil, repeat_expr: nil, repeat_until: nil, if_expr: nil}
    new_length = fixed_len || pick_length(length_mode, length(value))

    Enum.map(0..(new_length - 1)//1, fn _i ->
      seed_item = List.first(value)
      generate_item(inner_attr, seed_item, spec, length_mode, nil)
    end)
  end

  defp mutate_attr(%AttrSpec{} = attr, value, spec, length_mode, fixed_len) do
    generate_item(attr, value, spec, length_mode, fixed_len)
  end

  defp mutate_attr(_attr, value, _spec, _length_mode, _fixed_len), do: value

  defp generate_item(%AttrSpec{type: nil} = attr, value, _spec, length_mode, fixed_len)
       when is_binary(value) do
    new_len = fixed_len || pick_length(length_mode, byte_size(value))
    random_bytes(new_len, attr)
  end

  defp generate_item(%AttrSpec{type: "u1"}, _v, _spec, _length_mode, _fixed_len), do: random_uint(8)
  defp generate_item(%AttrSpec{type: "u2"}, _v, _spec, _length_mode, _fixed_len), do: random_uint(16)
  defp generate_item(%AttrSpec{type: "u4"}, _v, _spec, _length_mode, _fixed_len), do: random_uint(32)
  defp generate_item(%AttrSpec{type: "u8"}, _v, _spec, _length_mode, _fixed_len), do: random_uint(64)
  defp generate_item(%AttrSpec{type: "u2le"}, _v, _spec, _length_mode, _fixed_len), do: random_uint(16)
  defp generate_item(%AttrSpec{type: "u4le"}, _v, _spec, _length_mode, _fixed_len), do: random_uint(32)
  defp generate_item(%AttrSpec{type: "u8le"}, _v, _spec, _length_mode, _fixed_len), do: random_uint(64)
  defp generate_item(%AttrSpec{type: "u2be"}, _v, _spec, _length_mode, _fixed_len), do: random_uint(16)
  defp generate_item(%AttrSpec{type: "u4be"}, _v, _spec, _length_mode, _fixed_len), do: random_uint(32)
  defp generate_item(%AttrSpec{type: "u8be"}, _v, _spec, _length_mode, _fixed_len), do: random_uint(64)
  defp generate_item(%AttrSpec{type: "s1"}, _v, _spec, _length_mode, _fixed_len), do: random_sint(8)
  defp generate_item(%AttrSpec{type: "s2"}, _v, _spec, _length_mode, _fixed_len), do: random_sint(16)
  defp generate_item(%AttrSpec{type: "s4"}, _v, _spec, _length_mode, _fixed_len), do: random_sint(32)
  defp generate_item(%AttrSpec{type: "s8"}, _v, _spec, _length_mode, _fixed_len), do: random_sint(64)
  defp generate_item(%AttrSpec{type: "s2le"}, _v, _spec, _length_mode, _fixed_len), do: random_sint(16)
  defp generate_item(%AttrSpec{type: "s4le"}, _v, _spec, _length_mode, _fixed_len), do: random_sint(32)
  defp generate_item(%AttrSpec{type: "s8le"}, _v, _spec, _length_mode, _fixed_len), do: random_sint(64)
  defp generate_item(%AttrSpec{type: "s2be"}, _v, _spec, _length_mode, _fixed_len), do: random_sint(16)
  defp generate_item(%AttrSpec{type: "s4be"}, _v, _spec, _length_mode, _fixed_len), do: random_sint(32)
  defp generate_item(%AttrSpec{type: "s8be"}, _v, _spec, _length_mode, _fixed_len), do: random_sint(64)

  defp generate_item(%AttrSpec{type: "f4" <> _}, _v, _spec, _length_mode, _fixed_len), do: random_float()
  defp generate_item(%AttrSpec{type: "f8" <> _}, _v, _spec, _length_mode, _fixed_len), do: random_float()

  defp generate_item(%AttrSpec{type: "b" <> rest} = attr, current, _spec, _length_mode, _fixed_len) do
    case Integer.parse(rest) do
      {1, _} ->
        # Boolean (no enum)
        if attr.enum == nil and current in [true, false] do
          :rand.uniform(2) == 1
        else
          random_uint(1)
        end

      {n, _} when is_integer(n) and n >= 1 and n <= 64 ->
        random_uint(n)

      _ ->
        current
    end
  end

  defp generate_item(%AttrSpec{type: "str"} = _attr, value, _spec, length_mode, fixed_len)
       when is_binary(value) do
    new_len = fixed_len || pick_length(length_mode, byte_size(value))
    random_ascii(new_len)
  end

  defp generate_item(%AttrSpec{type: "strz"} = _attr, value, _spec, length_mode, fixed_len)
       when is_binary(value) do
    new_len = fixed_len || pick_length(length_mode, byte_size(value))
    random_ascii(new_len)
  end

  defp generate_item(%AttrSpec{} = attr, value, spec, _length_mode, _fixed_len) when is_map(value) do
    cond do
      is_binary(attr.type) and Map.has_key?(spec.types, attr.type) ->
        mutate(value, Map.get(spec.types, attr.type))

      true ->
        value
    end
  end

  defp generate_item(_attr, value, _spec, _length_mode, _fixed_len), do: value

  defp random_uint(n_bits) do
    cap = bits_pow2(n_bits)
    :rand.uniform(cap) - 1
  end

  defp random_sint(n_bits) do
    half = bits_pow2(n_bits - 1)
    :rand.uniform(bits_pow2(n_bits)) - 1 - half
  end

  defp bits_pow2(n) when n <= 0, do: 1
  defp bits_pow2(n), do: Bitwise.bsl(1, n)

  defp random_float do
    # Avoid extreme values that don't compare equally after float round-tripping.
    (:rand.uniform() - 0.5) * 1000.0
  end

  defp random_ascii(0), do: ""

  defp random_ascii(n) do
    1..n
    |> Enum.map(fn _ -> :rand.uniform(95) + 31 end)
    |> :erlang.list_to_binary()
  end

  defp random_bytes(0, _attr), do: <<>>

  defp random_bytes(n, _attr) do
    :crypto.strong_rand_bytes(n)
  end

  # 1.0–2.0× the original length, biased to grow.
  defp vary_length(0), do: :rand.uniform(8)

  defp vary_length(n) do
    # 80% grow up to 2x; 20% shrink to 0..n.
    if :rand.uniform(5) == 1 do
      :rand.uniform(n + 1) - 1
    else
      n + :rand.uniform(n + 1) - 1
    end
  end

  # Stay within original length (for fields without a simple controller).
  defp shrink_length(0), do: 0
  defp shrink_length(n), do: :rand.uniform(n + 1) - 1

  # Mirror of the writer's controller pre-pass: after mutating controlled
  # fields, set each controller from the actual new payload length so the
  # mutated map matches what `to_binary` will produce.
  defp update_controllers(map, controllers_data, _spec) do
    # First controlled field per controller wins (same convention as
    # `compile_controller_assignments`).
    controllers_data
    |> Enum.uniq_by(fn {ctrl, _, _, _, _} -> ctrl end)
    |> Enum.reduce(map, fn {ctrl_id, controlled_id, kind, inversion, _enc}, acc ->
      ctrl_key = String.to_atom(ctrl_id)
      controlled_key = String.to_atom(controlled_id)

      case Map.get(acc, controlled_key) do
        nil -> acc
        value ->
          actual = measure(value, kind)
          new_ctrl = apply_inversion(actual, inversion)
          if new_ctrl != nil, do: Map.put(acc, ctrl_key, new_ctrl), else: acc
      end
    end)
  end

  defp measure(v, :byte_size) when is_binary(v), do: byte_size(v)
  defp measure(v, :str_byte_size) when is_binary(v), do: byte_size(v)
  defp measure(v, :length) when is_list(v), do: length(v)
  defp measure(_, _), do: nil

  defp apply_inversion(actual, :identity) when is_integer(actual), do: actual
  defp apply_inversion(actual, {:sub, n}) when is_integer(actual), do: actual - n
  defp apply_inversion(actual, {:add, n}) when is_integer(actual), do: actual + n
  defp apply_inversion(actual, {:rsub, n}) when is_integer(actual), do: n - actual
  defp apply_inversion(actual, {:mul, n}) when is_integer(actual), do: actual * n

  defp apply_inversion(actual, {:div, n}) when is_integer(actual) and is_integer(n) and n != 0 do
    if rem(actual, n) == 0, do: div(actual, n), else: nil
  end

  defp apply_inversion(actual, {:rdiv, n}) when is_integer(actual) and actual != 0 do
    if rem(n, actual) == 0, do: div(n, actual), else: nil
  end

  defp apply_inversion(_, _), do: nil

  # Mirrors the compiler's anonymous-field numbering so attr.id is always set.
  defp number_anonymous_fields(seq) do
    {result, _} =
      Enum.reduce(seq, {[], 0}, fn attr, {acc, anon_idx} ->
        if attr.id in [nil, ""] do
          {acc ++ [%{attr | id: "_anon_#{anon_idx}"}], anon_idx + 1}
        else
          {acc ++ [attr], anon_idx}
        end
      end)

    result
  end
end
