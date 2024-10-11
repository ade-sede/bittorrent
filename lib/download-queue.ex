defmodule Bittorrent.DownloadQueue do
  use GenServer

  defstruct [
    :info_hash,
    :piece_length,
    :file_length,
    :target_block,
    :blocks,
    :completed_pieces,
    :parent
  ]

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  defp filter_blocks(blocks, target) do
    case target do
      :all ->
        blocks

      piece_index when is_number(piece_index) ->
        if Enum.empty?(blocks) do
          %{}
        else
          case Enum.find(blocks, nil, fn {idx, _} -> idx == piece_index end) do
            {_, piece_data} ->
              %{piece_index => piece_data}

            nil ->
              if Enum.empty?(blocks) do
                raise ArgumentError,
                      "Piece #{piece_index} does not exist"
              end
          end
        end

      _ ->
        raise ArgumentError,
              "Invalid piece_to_download. Expected :all or a number, got: #{inspect(target)}"
    end
  end

  @impl true
  def init({info_hash, piece_length, file_length, piece_hashes, parent, piece_to_download}) do
    blocks =
      if Enum.count(piece_hashes) > 0,
        do: initialize_blocks(piece_hashes, piece_length, file_length),
        else: %{}

    blocks = filter_blocks(blocks, piece_to_download)

    state = %__MODULE__{
      info_hash: info_hash,
      piece_length: piece_length,
      file_length: file_length,
      blocks: blocks,
      completed_pieces: [],
      target_block: piece_to_download,
      parent: parent
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:initialize_blocks, piece_hashes, piece_length, file_length}, _from, state) do
    blocks = initialize_blocks(piece_hashes, piece_length, file_length)
    blocks = filter_blocks(blocks, state.target_block)

    {:reply, {:ok, blocks}, %{state | blocks: blocks}}
  end

  @impl true
  def handle_call({:get_block_to_download, piece_indexes}, _from, state) do
    case find_available_block(state, piece_indexes) do
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
  def handle_call({:available_to_download?, piece_indexes}, _from, state) do
    available_to_download =
      state.blocks
      |> Map.to_list()
      |> Enum.any?(fn {idx, piece} ->
        piece.completed == false && Enum.member?(piece_indexes, idx)
      end)

    {:reply, available_to_download, state}
  end

  @impl true
  def handle_call({:get_block, piece_index}, _from, state) do
    case find_available_block_in_piece(state, piece_index) do
      nil ->
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

    log_download_progress_short(new_state)

    {:reply, :ok, new_state}
  end

  # defp log_download_progress_long(state) do
  #   overall_progress =
  #     "#{length(state.completed_pieces)}/#{map_size(state.blocks)} pieces completed"
  #
  #   IO.puts("Download Progress - #{overall_progress}")
  #
  #   Enum.each(state.blocks, fn {piece_index, piece} ->
  #     completed_blocks = Enum.count(piece.blocks, fn {_, block} -> block.state == :complete end)
  #     total_blocks = map_size(piece.blocks)
  #
  #     piece_progress = "Piece #{piece_index}: #{completed_blocks}/#{total_blocks} blocks"
  #
  #     block_states =
  #       Enum.map(piece.blocks, fn {offset, block} ->
  #         "#{offset}:#{block.state}"
  #       end)
  #       |> Enum.join(", ")
  #
  #     IO.puts("  #{piece_progress}")
  #     IO.puts("  Block states: #{block_states}")
  #   end)
  # end

  defp log_download_progress_short(state) do
    completed_count = length(state.completed_pieces)
    total_pieces = map_size(state.blocks)
    incomplete_count = total_pieces - completed_count

    # Main progress counts
    IO.puts("#{completed_count}/#{total_pieces} pieces completed")
    IO.puts("#{incomplete_count}/#{total_pieces} pieces incomplete")

    # Show in-progress pieces
    in_progress_count =
      state.blocks
      |> Enum.count(fn {_, piece} ->
        not piece.completed and
          Enum.any?(piece.blocks, fn {_, block} -> block.state == :in_progress end)
      end)

    if in_progress_count > 0 do
      IO.puts("Currently downloading: #{in_progress_count} pieces")
    end
  end

  defp initialize_blocks(pieces, piece_length, file_length) do
    piece_count = length(pieces)

    0..(piece_count - 1)
    |> Enum.map(fn piece_index ->
      last_piece = piece_index == piece_count - 1
      piece_size = if last_piece, do: rem(file_length, piece_length), else: piece_length
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

  defp find_available_block(state, piece_indexes) do
    Enum.find_value(piece_indexes, fn idx ->
      find_available_block_in_piece(state, idx)
    end)
  end

  defp find_available_block_in_piece(state, piece_index) do
    piece = state.blocks[piece_index]

    if piece do
      Enum.find_value(piece.blocks, fn {offset, block} ->
        if block.state == :not_started do
          {piece_index, offset, block.length}
        end
      end)
    else
      false
    end
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

      calculated_hash = :crypto.hash(:sha, piece_data)
      expected_hash = piece.hash

      if calculated_hash == expected_hash do
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
        IO.puts("Hash verification failed for piece #{piece_index}. Resetting all blocks.")

        new_state =
          state
          |> put_in([Access.key(:blocks), Access.key(piece_index), Access.key(:completed)], false)
          |> put_in([Access.key(:blocks), Access.key(piece_index), Access.key(:data)], <<>>)
          |> update_in(
            [Access.key(:blocks), Access.key(piece_index), Access.key(:blocks)],
            fn blocks ->
              Enum.map(blocks, fn {offset, block} ->
                {offset, %{block | state: :not_started, data: nil}}
              end)
              |> Map.new()
            end
          )

        new_state
      end
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
