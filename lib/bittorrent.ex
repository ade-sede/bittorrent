defmodule Bittorrent.CLI do
  def main(argv) do
    case argv do
      ["decode" | [encoded_str | _]] ->
        case Bencode.decode(encoded_str) do
          {decoded_str, _remaining} ->
            IO.puts(Jason.encode!(decoded_str))

          ret ->
            ret
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
        IO.puts("String starts with 'i' but does not have the 'e' suffix")

      index ->
        numberStr = List.to_string(Enum.slice(binary_data, 0..(index - 1)))
        remaining = Enum.slice(binary_data, (index + 1)..-1//1)
        {String.to_integer(numberStr), remaining}
    end
  end

  defp decode_string(binary_data) do
    case Enum.find_index(binary_data, fn char -> char == ?: end) do
      nil ->
        IO.puts("The ':' character is not found in the binary")

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
        {decoded, remaining} = decode(binary_data)
        decode_list(remaining, [decoded | acc])
    end
  end

  def decode(encoded_value) when is_list(encoded_value) do
    decode(List.to_string(encoded_value))
  end

  def decode(encoded_value) when is_binary(encoded_value) do
    binary_data = :binary.bin_to_list(encoded_value)

    case binary_data do
      [] ->
        :empty

      [?l | tail] ->
        decode_list(tail)

      [?i | tail] ->
        decode_number(tail)

      _ ->
        decode_string(binary_data)
    end
  end

  def decode(_), do: "Invalid encoded value: not binary"
end
