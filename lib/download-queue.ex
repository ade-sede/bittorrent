defmodule Bittorrent.DownloadQueue do
  # TODO resilience what happens if we fail to download a piece ? what if the queue process crashes ?
  # what if one of the peer connection crashes ?
  # Proably need some form of persistence which allows us to start over

  # Blocks are input the form of:
  #   {piece_index, block_index, block_offset, block_size}
  # Once downloaded, they are stored in the form of:
  #   {piece_index, block_index, block_offset, block_size, data}
  defstruct name: nil,
            to_download: [],
            downloading: [],
            downloaded: [],
            parent: nil

  use GenServer

  # File is made of N pieces
  # Each piece is of piece_length except the last one which may be shorter
  # Each piece is made of Y blocks
  # Each block is of block_length except the last one of a piece which may be shorter
  def cut_file_into_blocks(file_length, number_of_pieces, piece_length, block_length) do
    Enum.flat_map(0..(number_of_pieces - 1), fn piece_index ->
      piece_size =
        if piece_index == number_of_pieces - 1 do
          rem(file_length, piece_length)
          |> then(&if &1 == 0, do: piece_length, else: &1)
        else
          piece_length
        end

      cut_piece_into_blocks(piece_index, piece_size, block_length)
    end)
  end

  def cut_piece_into_blocks(piece_index, piece_length, block_length) do
    number_of_blocks =
      div(piece_length, block_length) + if rem(piece_length, block_length) > 0, do: 1, else: 0

    Enum.map(0..(number_of_blocks - 1), fn block_index ->
      offset = block_index * block_length
      remaining = piece_length - offset

      size = min(block_length, remaining)

      {piece_index, block_index, offset, size}
    end)
  end

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: args.name)
  end

  @impl true
  def terminate(_reason, _state) do
    :ok
  end

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call(:get_one_to_download, _from, state) do
    case state.to_download do
      [] ->
        {:reply, nil, state}

      [head | tail] ->
        {:reply, head, %{state | to_download: tail, downloading: [head | state.downloading]}}
    end
  end

  @impl true
  def handle_call({:downloaded, block}, _from, state) do
    {piece_index, block_index, _offset, _size, _data} = block

    new_downloading =
      Enum.filter(state.downloading, fn {p, b, _, _} -> p != piece_index || b != block_index end)

    new_downloaded = [block | state.downloaded]

    state = %{state | downloading: new_downloading, downloaded: new_downloaded}

    if Enum.empty?(state.to_download) && Enum.empty?(state.downloading) do
      send(state.parent, {:done, state.downloaded})
    end

    {:reply, :ok, state}
  end
end
