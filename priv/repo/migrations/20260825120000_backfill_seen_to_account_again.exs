defmodule Bonfire.Social.Repo.Migrations.BackfillSeenToAccountAgain do
  @moduledoc """
  Backfill migration to change seen/read status tracking from User to Account.

  This migration updates existing seen edges in the database to use Account as the subject instead of User, enabling unified seen status across profiles under the same account.
  """
  alias EctoSparkles.DataMigration
  use DataMigration
  alias Bonfire.Social.DataMigrations.SeenToAccountBackfill

  # logic lives in the shared module so re-runs (see issue #2220) don't duplicate it
  @impl DataMigration
  defdelegate base_query, to: SeenToAccountBackfill
  @impl DataMigration
  defdelegate config, to: SeenToAccountBackfill
  @impl DataMigration
  defdelegate migrate(results), to: SeenToAccountBackfill
end