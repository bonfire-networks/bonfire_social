defmodule Bonfire.Social.Repo.Migrations.AddActivityFeedLookupIndex do
  @moduledoc false
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    Bonfire.Data.Social.Activity.Migration.add_activity_feed_lookup_index(
      concurrently: concurrently?()
    )
  end

  def down do
    Bonfire.Data.Social.Activity.Migration.drop_activity_feed_lookup_index(
      concurrently: concurrently?()
    )
  end

  defp concurrently?, do: System.get_env("DB_MIGRATE_INDEXES_CONCURRENTLY") != "false"
end
