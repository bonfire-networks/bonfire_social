defmodule Bonfire.Social.DataMigrations.SeenToAccountBackfill do
  @moduledoc """
  Shared backfill logic that maps user-subject Seen edges to the user's account (deleting on unique conflict). Seen is tracked per-account, so any edge whose `subject_id` is a user is a straggler.

  Lives in one place and is called (via `defdelegate`) by the dated migrations that run it, so the original `20260128075255_backfill_seen_to_account` and any re-run needed after new stragglers appear (see issue #2220). Implements the `EctoSparkles.DataMigration` callbacks; uses `Bonfire.Common.Repo` directly since a plain module has no migration-scoped `repo/0`.
  """
  import Ecto.Query
  alias EctoSparkles.DataMigration

  # Needle table_id of `Bonfire.Data.Social.Seen`
  @seen_table_id "1A1READYSAW0RREADTH1STH1NG"

  def base_query do
    # user-subject Seen edges, joined through `accounted` to get the user's account_id; after the
    # update they no longer match (subject_id becomes the account), so the runner can page to empty
    from(e in "bonfire_data_edges_edge",
      join: a in "bonfire_data_identity_accounted",
      on: e.subject_id == a.id,
      where: e.table_id == ^Needle.ULID.dump!(@seen_table_id),
      where: not is_nil(a.account_id),
      select: %{id: e.id, account_id: a.account_id}
    )
  end

  def config do
    %DataMigration.Config{batch_size: 100, throttle_ms: 100, repo: Bonfire.Common.Repo}
  end

  def migrate(results) do
    Enum.each(results, fn %{id: id, account_id: account_id} ->
      # point the edge at the account; on unique conflict (account already saw this object) delete the
      # user-level edge since the account-level one takes precedence
      case Bonfire.Common.Repo.query(
             "UPDATE bonfire_data_edges_edge SET subject_id = $1 WHERE id = $2",
             [account_id, id]
           ) do
        {:ok, _} ->
          :ok

        {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} ->
          Bonfire.Common.Repo.query("DELETE FROM bonfire_data_edges_edge WHERE id = $1", [id])

        {:error, reason} ->
          IO.warn("Failed to migrate Seen edge #{id}: #{inspect(reason)}")
      end
    end)
  end
end
