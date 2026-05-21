defmodule Bonfire.Social.Repo.Migrations.AddFeedPublishFeedIdIdIndex do
  @moduledoc false
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    Bonfire.Data.Social.FeedPublish.Migration.add_feed_publish_feed_id_id_index(
      concurrently: concurrently?()
    )
  end

  def down do
    Bonfire.Data.Social.FeedPublish.Migration.drop_feed_publish_feed_id_id_index(
      concurrently: concurrently?()
    )
  end

  defp concurrently?, do: System.get_env("DB_MIGRATE_INDEXES_CONCURRENTLY") != "false"
end
