defmodule Bittorrent.CLI do
  def main(argv) do
    case argv do
      ["decode" | [encoded_str | _]] ->
        case Bencode.decode(encoded_str) do
          :empty ->
            IO.puts("Nothing to decode")

          {:error, reason} ->
            IO.puts(reason)

          {decoded_str, _remaining} ->
            IO.puts(Jason.encode!(decoded_str))
        end

      # For testing purposes
      ["encode" | _] ->
        val = %{"foo" => "bar", "abc" => "def", "num" => 12, "list" => [13, 2, 3, 4, 5]}
        IO.puts(Bencode.encode(val))

      ["info" | [filename | _]] ->
        file = File.read!(filename)
        content = IO.iodata_to_binary(file)

        case Bencode.decode(content) do
          :empty ->
            IO.puts("Nothing to decode")

          {:error, reason} ->
            IO.puts(reason)

          {decoded_str, _remaining} ->
            IO.puts("Tracker URL: #{decoded_str["announce"]}")
            IO.puts("Length: #{decoded_str["info"]["length"]}")
            # Bencode.encode(decoded_str)
        end

      [command | _] ->
        IO.puts("Unknown command: #{command}")
        System.halt(1)

      [] ->
        IO.puts("Usage: your_bittorrent.sh <command> <args>")
        System.halt(1)
    end
  end
end

defmodule Bencode do
  defp decode_number(binary_data) do
    case Enum.find_index(binary_data, fn char -> char == ?e end) do
      nil ->
        {:error, "`e` suffix not found"}

      index ->
        numberStr = List.to_string(Enum.slice(binary_data, 0..(index - 1)))
        remaining = Enum.slice(binary_data, (index + 1)..-1//1)
        {String.to_integer(numberStr), remaining}
    end
  end

  defp decode_string(binary_data) do
    case Enum.find_index(binary_data, fn char -> char == ?: end) do
      nil ->
        {:error, "`:` delimiter not found"}

      index ->
        prefix = Enum.slice(binary_data, 0..(index - 1))
        length = String.to_integer(List.to_string(prefix))
        str = Enum.slice(binary_data, index + 1, length)
        remaining = Enum.slice(binary_data, (index + 1 + length)..-1//1)
        {List.to_string(str), remaining}
    end
  end

  defp decode_list(binary_data, acc \\ []) do
    case binary_data do
      [] ->
        {Enum.reverse(acc), []}

      [?e | remaining] ->
        {Enum.reverse(acc), remaining}

      _ ->
        case decode(binary_data) do
          {:error, reason} ->
            {:error, reason}

          {decoded, remaining} ->
            decode_list(remaining, [decoded | acc])
        end
    end
  end

  defp decode_dict(binary_data, acc \\ %{}) do
    case binary_data do
      [] ->
        {acc, []}

      [?e | remaining] ->
        {acc, remaining}

      _ ->
        case decode_string(binary_data) do
          {:error, reason} ->
            {:error, "Key could not be decoded: #{reason}"}

          {key, remaining} ->
            {value, remaining} = decode(remaining)
            decode_dict(remaining, Map.put(acc, key, value))
        end
    end
  end

  def decode(data) when is_list(data) do
    case data do
      [] ->
        :empty

      [?l | tail] ->
        decode_list(tail)

      [?i | tail] ->
        decode_number(tail)

      [?d | tail] ->
        decode_dict(tail)

      _ ->
        decode_string(data)
    end
  end

  def decode(encoded_value) when is_binary(encoded_value) do
    decode(:binary.bin_to_list(encoded_value))
  end

  def decode(_), do: "Invalid encoded value: not binary"

  def encode(string) when is_binary(string), do: "#{String.length(string)}:#{string}"

  def encode(number) when is_number(number), do: "i#{number}e"

  def encode(list) when is_list(list) do
    {_, encodedList} =
      Enum.map_reduce(list, "", fn item, byteArray ->
        encodedItem = encode(item)
        {encodedItem, "#{byteArray}#{encodedItem}"}
      end)

    "l#{encodedList}e"
  end

  def encode(map) when is_map(map) do
    {_, encodedMap} =
      Enum.map_reduce(Map.keys(map), "", fn key, byteArray ->
        encodedKey = encode(key)
        encodedVal = encode(map[key])

        {{encodedKey, encodedVal}, "#{byteArray}#{encodedKey}#{encodedVal}"}
      end)

    "d#{encodedMap}e"
  end

  def encode(_), do: "Unsupported data type"
end
