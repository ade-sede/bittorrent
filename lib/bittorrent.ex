defmodule Bittorrent.CLI do
  def main(argv) do
    case argv do
      ["decode" | [encoded_str | _]] ->
        decoded_str = Bencode.decode(encoded_str)
        IO.puts(Jason.encode!(decoded_str))

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
  def decode(encoded_value) when is_binary(encoded_value) do
    binary_data = :binary.bin_to_list(encoded_value)

    case binary_data do
      [?i | rest] ->
        case List.last(rest, nil) do
          nil ->
            IO.puts("String starts with 'i' but does not have the 'e' suffix")

          ?e ->
            String.to_integer(List.to_string(Enum.drop(rest, -1)))
        end

      _ ->
        case Enum.find_index(binary_data, fn char -> char == ?: end) do
          nil ->
            IO.puts("The ':' character is not found in the binary")

          index ->
            rest = Enum.slice(binary_data, (index + 1)..-1)
            List.to_string(rest)
        end
    end
  end

  def decode(_), do: "Invalid encoded value: not binary"
end
