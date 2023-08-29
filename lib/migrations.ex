defmodule Bonfire.Social.Migrations do
  @moduledoc false
  use Ecto.Migration
  import Pointers.Migration

  def ms(:up) do
    quote do
      # require Bonfire.Data.Social.Block.Migration
      require Bonfire.Data.Social.Bookmark.Migration
      require Bonfire.Data.Social.Follow.Migration
      require Bonfire.Data.Social.Like.Migration
      require Bonfire.Data.Social.Post.Migration
      require Bonfire.Data.Social.PostContent.Migration
      require Bonfire.Data.Social.Profile.Migration
      require Bonfire.Data.Social.Created.Migration
      require Bonfire.Data.Social.Activity.Migration
      require Bonfire.Data.Social.Feed.Migration
      require Bonfire.Data.Social.FeedPublish.Migration
      require Bonfire.Data.Social.Replied.Migration
      require Bonfire.Data.Social.Boost.Migration
      require Bonfire.Data.Social.Flag.Migration
      require Bonfire.Data.Social.Message.Migration
      require Bonfire.Data.Social.Request.Migration
      require Bonfire.Data.Social.Seen.Migration
      require Bonfire.Data.Social.Pin.Migration
      require Bonfire.Data.Social.Sensitive.Migration

      # Bonfire.Data.Social.Block.Migration.migrate_block()
      Bonfire.Data.Social.Bookmark.Migration.migrate_bookmark()
      Bonfire.Data.Social.Follow.Migration.migrate_follow()
      Bonfire.Data.Social.Like.Migration.migrate_like()
      Bonfire.Data.Social.Post.Migration.migrate_post()
      Bonfire.Data.Social.PostContent.Migration.migrate_post_content()
      Bonfire.Data.Social.Profile.Migration.migrate_profile()
      Bonfire.Data.Social.Created.Migration.migrate_created()
      Bonfire.Data.Social.Activity.Migration.migrate_activity()
      Bonfire.Data.Social.Feed.Migration.migrate_feed()
      Bonfire.Data.Social.FeedPublish.Migration.migrate_feed_publish()
      Bonfire.Data.Social.Replied.Migration.migrate_replied()
      Bonfire.Data.Social.Replied.Migration.migrate_functions()
      Bonfire.Data.Social.Replied.Migration.add_generated_total_column()
      Bonfire.Data.Social.Boost.Migration.migrate_boost()
      Bonfire.Data.Social.Flag.Migration.migrate_flag()
      Bonfire.Data.Social.Message.Migration.migrate_message()
      Bonfire.Data.Social.Request.Migration.migrate_request()
      Bonfire.Data.Social.Seen.Migration.migrate_seen()
      Bonfire.Data.Social.Pin.Migration.migrate_pin()
      Bonfire.Data.Social.Sensitive.Migration.migrate_sensitive()
      add_paper_trail()
      add_array_reverse_fn()
    end
  end

  def ms(:down) do
    quote do
      # require Bonfire.Data.Social.Block.Migration
      require Bonfire.Data.Social.Bookmark.Migration
      require Bonfire.Data.Social.Follow.Migration
      require Bonfire.Data.Social.Like.Migration
      require Bonfire.Data.Social.Post.Migration
      require Bonfire.Data.Social.PostContent.Migration
      require Bonfire.Data.Social.Profile.Migration
      require Bonfire.Data.Social.Created.Migration
      require Bonfire.Data.Social.Activity.Migration
      require Bonfire.Data.Social.Feed.Migration
      require Bonfire.Data.Social.FeedPublish.Migration
      require Bonfire.Data.Social.Replied.Migration
      require Bonfire.Data.Social.Boost.Migration
      require Bonfire.Data.Social.Flag.Migration
      require Bonfire.Data.Social.Message.Migration
      require Bonfire.Data.Social.Request.Migration
      require Bonfire.Data.Social.Seen.Migration
      require Bonfire.Data.Social.Pin.Migration
      require Bonfire.Data.Social.Sensitive.Migration

      Bonfire.Data.Social.Sensitive.Migration.migrate_sensitive()
      Bonfire.Data.Social.Pin.Migration.migrate_pin()
      Bonfire.Data.Social.Seen.Migration.migrate_seen()
      Bonfire.Data.Social.Request.Migration.migrate_request()
      Bonfire.Data.Social.Message.Migration.migrate_message()
      Bonfire.Data.Social.FeedPublish.Migration.migrate_feed_publish()
      # Bonfire.Data.Social.Replied.Migration.migrate_functions()
      Bonfire.Data.Social.Replied.Migration.migrate_replied()
      Bonfire.Data.Social.Boost.Migration.migrate_boost()
      Bonfire.Data.Social.Flag.Migration.migrate_flag()
      Bonfire.Data.Social.Profile.Migration.migrate_profile()
      Bonfire.Data.Social.PostContent.Migration.migrate_post_content()
      Bonfire.Data.Social.Post.Migration.migrate_post()
      Bonfire.Data.Social.Like.Migration.migrate_like()
      Bonfire.Data.Social.Follow.Migration.migrate_follow()
      Bonfire.Data.Social.Bookmark.Migration.migrate_bookmark()
      # Bonfire.Data.Social.Block.Migration.migrate_block()
      Bonfire.Data.Social.Created.Migration.migrate_created()
      Bonfire.Data.Social.Activity.Migration.migrate_activity()
      Bonfire.Data.Social.Feed.Migration.migrate_feed()
    end
  end

  defmacro migrate_social() do
    quote do
      if Ecto.Migration.direction() == :up,
        do: unquote(ms(:up)),
        else: unquote(ms(:down))
    end
  end

  defmacro migrate_social(dir), do: ms(dir)

  def add_paper_trail do
    create_if_not_exists table(:versions) do
      add(:event, :string, null: false, size: 10)
      add(:item_type, :string, null: false)
      add(:item_id, :uuid)
      add(:item_changes, :map, null: false)
      add(:originator_id, weak_pointer())
      add(:origin, :string, size: 50)
      add(:meta, :map)

      # Configure timestamps type in config.ex :paper_trail :timestamps_type
      add(:inserted_at, :utc_datetime, null: false)
    end

    create_if_not_exists(index(:versions, [:originator_id]))
    create_if_not_exists(index(:versions, [:item_id, :item_type]))
    # Uncomment if you want to add the following indexes to speed up special queries:
    # create_if_not_exists index(:versions, [:event, :item_type])
    # create_if_not_exists index(:versions, [:item_type, :inserted_at])
  end

  def add_array_reverse_fn do
    execute("CREATE OR REPLACE FUNCTION array_reverse(anyarray) RETURNS anyarray AS $$
      SELECT ARRAY(
          SELECT $1[i]
          FROM generate_subscripts($1,1) AS s(i)
          ORDER BY i DESC
      );
      $$ LANGUAGE 'sql' STRICT IMMUTABLE;")
  end
end
