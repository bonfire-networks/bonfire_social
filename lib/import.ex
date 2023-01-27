defmodule Bonfire.Social.Import do
  use Oban.Worker,
    max_attempts: 1

  import Untangle
  alias Bonfire.Data.Identity.User
  alias Bonfire.Me.Characters
  alias Bonfire.Me.Users
  alias Bonfire.Social.Follows
  alias Bonfire.Boundaries.Blocks
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  def follows_from_csv_file(user, path) do
    follows_from_csv(user, File.read!(path))
    # TODO: delete file
  end

  def follows_from_csv(user, list) when is_binary(list) do
    follows_from_list(user, prepare_csv(list))
  end

  def ghosts_from_csv_file(user, path) do
    ghosts_from_csv_file(user, File.read!(path))
    # TODO: delete file
  end

  def ghosts_from_csv(user, list) when is_binary(list) do
    ghosts_from_list(user, prepare_user_identifiers(list))
  end

  def silences_from_csv_file(user, path) do
    silences_from_csv(user, File.read!(path))
    # TODO: delete file
  end

  def silences_from_csv(user, list) when is_binary(list) do
    silences_from_list(user, prepare_csv(list))
  end

  defp prepare_csv(list) do
    list
    |> String.split("\n")
    |> Enum.map(&(&1 |> String.split(",") |> List.first()))
    |> List.delete("Account address")
    |> Enum.map(&(&1 |> String.trim() |> String.trim_leading("@")))
    |> Enum.reject(&(&1 == ""))
  end

  defp prepare_user_identifiers(list) do
    list
    |> String.split()
    |> Enum.map(&String.trim_leading(&1, "@"))
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

  defp enqueue_many(op, user, identifiers) do
    Enum.map(
      identifiers,
      fn identifier ->
        enqueue([queue: op], %{"user_id" => user.id, "identifier" => identifier})
      end
    )
  end

  def job(spec, worker_args \\ []), do: new(worker_args, spec)

  def enqueue(spec, worker_args \\ []), do: Oban.insert(job(spec, worker_args))

  def perform(%{queue: queue, args: %{"user_id" => user_id, "identifier" => identifier}}) do
    with {:ok, user} <- Users.by_username(user_id) do
      perform(queue, user, identifier)
    end
  end

  @spec perform(atom(), User.t(), list()) :: :ok | list() | {:error, any()}
  def perform("silences_import" = op, %User{} = user, identifier) do
    with {:ok, %{} = silence} <- AdapterUtils.get_by_url_ap_id_or_username(identifier),
         {:ok, _} <- Blocks.block(silence, [:silence], current_user: user) do
      silence
    else
      error -> handle_error(op, identifier, error)
    end
  end

  def perform("ghosts_import" = op, %User{} = user, identifier) do
    with {:ok, %{} = ghost} <- AdapterUtils.get_by_url_ap_id_or_username(identifier),
         {:ok, _ghost} <- Blocks.block(ghost, [:ghost], current_user: user) do
      ghost
    else
      error -> handle_error(op, identifier, error)
    end
  end

  def perform("follows_import" = op, %User{} = user, identifier) do
    with {:ok, %{} = followed} <- AdapterUtils.get_by_url_ap_id_or_username(identifier),
         {:ok, _} <- Follows.follow(user, followed) do
      followed
    else
      error -> handle_error(op, identifier, error)
    end
  end

  def perform(_, _, _), do: :ok

  defp handle_error(op, identifier, error) do
    error(error, "#{op} failed for #{identifier}")
  end
end
