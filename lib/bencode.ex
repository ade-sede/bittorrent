defmodule Bittorrent.Bencode do
  def decode(encoded_binary) when is_binary(encoded_binary),
    do: do_decode(encoded_binary)

  def decode(_), do: {:error, "Unsupported type"}

  defp do_decode(""), do: :empty
  defp do_decode("l" <> encoded_list), do: decode_list(encoded_list, [])
  defp do_decode("d" <> encoded_dict), do: decode_dict(encoded_dict, %{})

  defp do_decode("i" <> encoded_number) do
    case Integer.parse(encoded_number) do
      {int, "e" <> remaining} -> {int, remaining}
      {_, _} -> {:error, "Failed to parse integer, wrong format. Missing `e` suffix ?"}
      :error -> {:error, "Failed to parse integer, invalid number"}
    end
  end

  defp do_decode(encoded_binary), do: decode_binary(encoded_binary)

  # Value is not guaranteed to be UTF8
  # <length represented as ASCII>:<value>
  defp decode_binary(encoded_binary) do
    case Integer.parse(encoded_binary) do
      :error ->
        {:error, "Failed to parse integer, invalid length"}

      # If `String.length()` we count the number of graphemes, which doesn't
      # work if value is not UTF8
      {length, ":" <> encoded_value} when byte_size(encoded_value) >= length ->
        <<decoded_value::binary-size(^length), remaining::binary>> = encoded_value
        {decoded_value, remaining}

      _ ->
        {:error,
         "Input does not match the `<length>:<value>` format or <value> is smaller than specified by <length>"}
    end
  end

  defp decode_list("e" <> remaining, acc), do: {Enum.reverse(acc), remaining}

  defp decode_list(encoded_list, acc) do
    case decode(encoded_list) do
      {:error, reason} ->
        {:error, reason}

      {decoded_value, remaining} ->
        decode_list(remaining, [decoded_value | acc])
    end
  end

  defp decode_dict("e" <> remaining, map), do: {map, remaining}

  defp decode_dict(encoded_dict, map) do
    case decode_binary(encoded_dict) do
      {:error, _} ->
        {:error, "Dict key must be a string"}

      {key, remaining} ->
        case decode(remaining) do
          {:error, reason} ->
            {:error, reason}

          {value, remaining} ->
            decode_dict(remaining, Map.merge(map, %{key => value}))
        end
    end
  end

  def encode(binary) when is_binary(binary), do: "#{byte_size(binary)}:" <> binary
  def encode(number) when is_number(number), do: "i#{number}e"

  def encode(list) when is_list(list) do
    items =
      Enum.map(list, fn item -> encode(item) end)
      |> Enum.join()

    "l" <> items <> "e"
  end

  def encode(map) when is_map(map) do
    items =
      Map.keys(map)
      |> Enum.sort()
      |> Enum.map(fn key -> encode(key) <> encode(Map.get(map, key)) end)
      |> Enum.join()

    "d" <> items <> "e"
  end
end
