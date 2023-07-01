defmodule Bonfire.Social.Import do
  use Oban.Worker,
    #  TODO: sort out queue vs op
    queue: :import,
    max_attempts: 1

  import Untangle
  alias Bonfire.Data.Identity.User
  # alias Bonfire.Me.Characters
  alias Bonfire.Me.Users
  alias Bonfire.Social.Follows
  alias Bonfire.Boundaries.Blocks
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  def import_from_csv_file(:follows, user, path), do: follows_from_csv_file(user, path)
  def import_from_csv_file(:ghosts, user, path), do: ghosts_from_csv_file(user, path)
  def import_from_csv_file(:silences, user, path), do: silences_from_csv_file(user, path)
  def import_from_csv_file(:blocks, user, path), do: blocks_from_csv_file(user, path)
  def import_from_csv_file(other, user, path), do: error("Please select a valid type of import")

  def follows_from_csv_file(user, path) do
    follows_from_csv(user, File.read!(path))
    # TODO: delete file
  end

  def follows_from_csv(user, list) when is_binary(list) do
    follows_from_list(user, prepare_csv(list))
  end

  def ghosts_from_csv_file(user, path) do
    ghosts_from_csv(user, File.read!(path))
    # TODO: delete file
  end

  def ghosts_from_csv(user, list) when is_binary(list) do
    ghosts_from_list(user, prepare_csv(list))
  end

  def silences_from_csv_file(user, path) do
    silences_from_csv(user, File.read!(path))
    # TODO: delete file
  end

  def silences_from_csv(user, list) when is_binary(list) do
    silences_from_list(user, prepare_csv(list))
  end

  def blocks_from_csv_file(user, path) do
    blocks_from_csv(user, File.read!(path))
    # TODO: delete file
  end

  def blocks_from_csv(user, list) when is_binary(list) do
    blocks_from_list(user, prepare_csv(list))
  end

  defp prepare_csv(list) do
    list
    |> String.split("\n")
    |> Enum.map(&(&1 |> String.split(",") |> List.first()))
    |> List.delete("Account address")
    |> Enum.map(&(&1 |> String.trim() |> String.trim_leading("@")))
    |> Enum.reject(&(&1 == ""))
  end

  def follows_from_list(%User{} = follower, [_ | _] = identifiers) do
    enqueue_many("follows_import", follower, identifiers)
  end

  def ghosts_from_list(%User{} = ghoster, [_ | _] = identifiers) do
    enqueue_many("ghosts_import", ghoster, identifiers)
  end

  def silences_from_list(%User{} = user, [_ | _] = identifiers) do
    enqueue_many("silences_import", user, identifiers)
  end

  def blocks_from_list(%User{} = user, [_ | _] = identifiers) do
    enqueue_many("blocks_import", user, identifiers)
  end

  defp enqueue_many(op, user, identifiers) do
    Enum.map(
      identifiers,
      fn identifier ->
        enqueue([queue: :import], %{"op" => op, "user_id" => user.id, "identifier" => identifier})
      end
    )
    |> debug()
    |> Enum.frequencies_by(fn
      {:ok, %Oban.Job{}} -> :ok
      _ -> :error
    end)
  end

  def enqueue(spec, worker_args \\ []), do: Oban.insert(job(spec, worker_args))

  def job(spec, worker_args \\ []), do: new(worker_args, spec)

  def perform(%{args: %{"op" => op, "user_id" => user_id, "identifier" => identifier} = _args}) do
    # debug(args, op)
    with {:ok, user} <- Users.by_username(user_id) do
      perform(op, user, identifier)
    end
  end

  @spec perform(atom(), User.t(), list()) :: :ok | list() | {:error, any()}
  def perform("silences_import" = op, %User{} = user, identifier) do
    with {:ok, %{} = silence} <- AdapterUtils.get_by_url_ap_id_or_username(identifier),
         {:ok, _} <- Blocks.block(silence, [:silence], current_user: user) do
      :ok
    else
      error -> handle_error(op, identifier, error)
    end
  end

  def perform("ghosts_import" = op, %User{} = user, identifier) do
    with {:ok, %{} = ghost} <- AdapterUtils.get_by_url_ap_id_or_username(identifier),
         {:ok, ghost} <- Blocks.block(ghost, [:ghost], current_user: user) do
      :ok
    else
      error -> handle_error(op, identifier, error)
    end
  end

  def perform("blocks_import" = op, %User{} = user, identifier) do
    with {:ok, %{} = ghost} <- AdapterUtils.get_by_url_ap_id_or_username(identifier),
         {:ok, _ghost} <- Blocks.block(ghost, [:ghost, :silence], current_user: user) do
      :ok
    else
      error -> handle_error(op, identifier, error)
    end
  end

  def perform("follows_import" = op, %User{} = user, identifier) do
    with {:ok, %{} = followed} <- AdapterUtils.get_by_url_ap_id_or_username(identifier),
         {:ok, _followed} <- Follows.follow(user, followed) do
      :ok
    else
      error -> handle_error(op, identifier, error)
    end
  end

  def perform(_, _, _), do: :ok

  defp handle_error(op, identifier, {:error, error}) do
    handle_error(op, identifier, error)
  end

  defp handle_error(op, identifier, error) when is_binary(error) or is_atom(error) do
    {:error, error}
  end

  defp handle_error(op, identifier, error) do
    error(error, "#{op} failed for #{identifier}")
  end
end
