defmodule Bonfire.Social.Repo.Migrations.BackfillSeenToAccount do
  @moduledoc """
  Backfill migration to change seen/read status tracking from User to Account.

  This migration updates existing seen edges in the database to use Account as the subject instead of User, enabling unified seen status across profiles under the same account.
  """
  use Ecto.Migration
  alias EctoSparkles.DataMigration
  alias Bonfire.Social.DataMigrations.SeenToAccountBackfill

  # what `use DataMigration` sets, which is not used here so that `up/0` can hand the runner this migration's repo
  @behaviour DataMigration
  @disable_ddl_transaction true
  @disable_migration_lock true

  # the migration's own repo, so the backfill acts on the database being migrated
  def up, do: DataMigration.Runner.run(__MODULE__, repo: repo())

  def down, do: :ok

  # logic lives in the shared module so re-runs (see issue #2220) don't duplicate it
  @impl DataMigration
  defdelegate base_query, to: SeenToAccountBackfill
  @impl DataMigration
  defdelegate config, to: SeenToAccountBackfill
  @impl DataMigration
  defdelegate migrate(results, opts), to: SeenToAccountBackfill
end
