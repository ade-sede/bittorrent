defmodule Bittorrent.DownloadQueue do
  use GenServer

  defstruct [
    :info_hash,
    :piece_length,
    :total_length,
    :blocks,
    :completed_pieces,
    :parent
  ]

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @impl true
  def init({info_hash, piece_length, total_length, pieces, parent, piece_to_download}) do
    blocks = initialize_blocks(pieces, piece_length, total_length)

    blocks =
      case piece_to_download do
        :all ->
          blocks

        piece_index when is_number(piece_index) ->
          {_, piece_data} = Enum.find(blocks, fn {idx, _} -> idx == piece_index end)

          if Enum.empty?(blocks) do
            raise ArgumentError,
                  "Piece #{piece_index} does not exist"
          end

          %{piece_index => piece_data}

        _ ->
          raise ArgumentError,
                "Invalid piece_to_download. Expected :all or a number, got: #{inspect(piece_to_download)}"
      end

    state = %__MODULE__{
      info_hash: info_hash,
      piece_length: piece_length,
      total_length: total_length,
      blocks: blocks,
      completed_pieces: [],
      parent: parent
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_block_to_download, _from, state) do
    case find_available_block(state) do
      nil ->
        IO.puts("DownloadQueue: No available blocks to download")
        {:reply, nil, state}

      {piece_index, block_offset, block_length} = block ->
        IO.puts(
          "DownloadQueue: Returning block to download: piece #{piece_index}, offset #{block_offset}, length #{block_length}"
        )

        new_state = mark_block_in_progress(state, block)
        {:reply, {piece_index, block_offset, block_length}, new_state}
    end
  end

  @impl true
  def handle_call({:need_piece?, piece_index}, _from, state) do
    need_piece = not Map.get(state.blocks, piece_index).completed
    {:reply, need_piece, state}
  end

  @impl true
  def handle_call({:get_block, piece_index}, _from, state) do
    case find_available_block_in_piece(state, piece_index) do
      nil ->
        {:reply, nil, state}

      {block_offset, block_length} = block ->
        new_state = mark_block_in_progress(state, {piece_index, block_offset, block_length})
        {:reply, block, new_state}
    end
  end

  @impl true
  def handle_call({:reset_block, piece_index, begin, _length}, _from, state) do
    new_state = reset_block(state, piece_index, begin)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:block_received, piece_index, begin, block_data}, _from, state) do
    new_state =
      state
      |> mark_block_complete(piece_index, begin, block_data)
      |> check_piece_completion(piece_index)

    log_download_progress(new_state)

    {:reply, :ok, new_state}
  end

  defp log_download_progress(state) do
    overall_progress =
      "#{length(state.completed_pieces)}/#{map_size(state.blocks)} pieces completed"

    IO.puts("Download Progress - #{overall_progress}")

    Enum.each(state.blocks, fn {piece_index, piece} ->
      completed_blocks = Enum.count(piece.blocks, fn {_, block} -> block.state == :complete end)
      total_blocks = map_size(piece.blocks)

      piece_progress = "Piece #{piece_index}: #{completed_blocks}/#{total_blocks} blocks"

      block_states =
        Enum.map(piece.blocks, fn {offset, block} ->
          "#{offset}:#{block.state}"
        end)
        |> Enum.join(", ")

      IO.puts("  #{piece_progress}")
      IO.puts("  Block states: #{block_states}")
    end)
  end

  defp initialize_blocks(pieces, piece_length, total_length) do
    piece_count = length(pieces)

    0..(piece_count - 1)
    |> Enum.map(fn piece_index ->
      last_piece = piece_index == piece_count - 1
      piece_size = if last_piece, do: rem(total_length, piece_length), else: piece_length
      piece_size = if piece_size == 0, do: piece_length, else: piece_size

      blocks = divide_piece_into_blocks(piece_size)

      {piece_index,
       %{
         hash: Enum.at(pieces, piece_index),
         size: piece_size,
         blocks: blocks,
         completed: false,
         data: <<>>
       }}
    end)
    |> Map.new()
  end

  defp divide_piece_into_blocks(piece_size, block_size \\ 16384) do
    0..ceil(piece_size / block_size - 1)
    |> Enum.map(fn block_index ->
      offset = block_index * block_size
      length = min(block_size, piece_size - offset)
      {offset, %{length: length, state: :not_started, data: nil}}
    end)
    |> Map.new()
  end

  defp find_available_block(state) do
    Enum.find_value(state.blocks, fn {piece_index, piece} ->
      if not piece.completed do
        find_available_block_in_piece(state, piece_index)
      end
    end)
  end

  defp find_available_block_in_piece(state, piece_index) do
    piece = state.blocks[piece_index]

    Enum.find_value(piece.blocks, fn {offset, block} ->
      if block.state == :not_started do
        {piece_index, offset, block.length}
      end
    end)
  end

  defp mark_block_in_progress(state, {piece_index, offset, _length}) do
    put_in(state.blocks[piece_index].blocks[offset].state, :in_progress)
  end

  defp mark_block_complete(state, piece_index, begin, block_data) do
    state
    |> put_in(
      [
        Access.key(:blocks),
        Access.key(piece_index),
        Access.key(:blocks),
        Access.key(begin),
        Access.key(:state)
      ],
      :complete
    )
    |> put_in(
      [
        Access.key(:blocks),
        Access.key(piece_index),
        Access.key(:blocks),
        Access.key(begin),
        Access.key(:data)
      ],
      block_data
    )
    |> update_in(
      [Access.key(:blocks), Access.key(piece_index), Access.key(:data)],
      fn existing_data ->
        new_size = max(byte_size(existing_data), begin + byte_size(block_data))
        new_data = :binary.copy(<<0>>, new_size)

        result =
          new_data
          |> binary_part(0, min(begin, byte_size(new_data)))
          |> Kernel.<>(block_data)
          |> Kernel.<>(
            binary_part(
              new_data,
              min(begin + byte_size(block_data), byte_size(new_data)),
              max(0, new_size - (begin + byte_size(block_data)))
            )
          )

        case byte_size(existing_data) do
          0 ->
            result

          size when size > 0 ->
            existing_part = binary_part(result, 0, min(size, byte_size(result)))

            remaining_part =
              binary_part(
                result,
                min(size, byte_size(result)),
                byte_size(result) - min(size, byte_size(result))
              )

            <<existing_data::binary-size(byte_size(existing_part)), _::binary>> = existing_part
            existing_data <> remaining_part
        end
      end
    )
  end

  defp check_piece_completion(state, piece_index) do
    piece = state.blocks[piece_index]
    all_blocks_complete = Enum.all?(piece.blocks, fn {_, block} -> block.state == :complete end)

    if all_blocks_complete do
      sorted_data =
        piece.blocks
        |> Enum.sort_by(fn {offset, _} -> offset end)
        |> Enum.map(fn {_, block} -> block.data end)
        |> IO.iodata_to_binary()

      piece_data = binary_part(sorted_data, 0, piece.size)

      new_state =
        state
        |> put_in([Access.key(:blocks), Access.key(piece_index), Access.key(:completed)], true)
        |> put_in([Access.key(:blocks), Access.key(piece_index), Access.key(:data)], piece_data)
        |> update_in([Access.key(:completed_pieces)], &[piece_index | &1])

      send(state.parent, {:done, piece_index, piece_data})

      if length(new_state.completed_pieces) == map_size(new_state.blocks) do
        send(state.parent, :all_pieces_completed)
      end

      new_state
    else
      state
    end
  end

  defp reset_block(state, piece_index, begin) do
    update_in(state.blocks[piece_index].blocks[begin], fn block ->
      %{block | state: :not_started, data: nil}
    end)
  end
end
