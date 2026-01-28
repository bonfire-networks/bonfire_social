defmodule Bonfire.Social.Repo.Migrations.BackfillSeenToAccount do
  @moduledoc """
  Backfill migration to change seen/read status tracking from User to Account.

  This migration updates existing seen edges in the database to use Account as the subject
  instead of User, enabling unified seen status across profiles under the same account.
  """
  use Ecto.Migration
  alias EctoSparkles.DataMigration
  import Ecto.Query
  use DataMigration

  @impl DataMigration
  def base_query do
    # Query seen edges where subject_id points to a user (not an account)
    # After migration, these will no longer match because subject_id will be account_id
    # Join through accounted table to get account_id (accounted.id == user.id, accounted.account_id is what we need)
    from(e in "bonfire_data_edges_edge",
      join: a in "bonfire_data_identity_accounted",
      on: e.subject_id == a.id,
      where: e.table_id == ^Needle.ULID.dump!("1A1READYSAW0RREADTH1STH1NG"),
      where: not is_nil(a.account_id),
      select: %{
        id: e.id,
        # user_id: a.id,
        account_id: a.account_id
      }
    )
  end

  @impl DataMigration
  def config do
    %DataMigration.Config{
      batch_size: 100,
      throttle_ms: 100,
      repo: Bonfire.Common.Repo
    }
  end

  @impl DataMigration
  def migrate(results) do
    Enum.each(results, fn %{id: id, account_id: account_id} ->
      # Try to update the edge to point to account instead of user
      # If it fails due to unique constraint (account already has an edge for this object),
      # delete the user's edge since the account-level edge takes precedence
      case repo().query(
             "UPDATE bonfire_data_edges_edge SET subject_id = $1 WHERE id = $2",
             [account_id, id]
           ) do
        {:ok, _} ->
          :ok

        {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} ->
          # Delete the user-level edge since account-level edge already exists
          repo().query(
            "DELETE FROM bonfire_data_edges_edge WHERE id = $1",
            [id]
          )

        {:error, reason} ->
          IO.warn("Failed to migrate edge #{id}: #{inspect(reason)}")
      end
    end)
  end
end
