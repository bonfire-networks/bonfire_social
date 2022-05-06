defmodule Bonfire.Social.Migrations do
  use Ecto.Migration
  # import Pointers.Migration

  def ms(:up) do
    quote do
      require Bonfire.Data.Social.Block.Migration
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

      Bonfire.Data.Social.Block.Migration.migrate_block()
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
      Bonfire.Data.Social.Boost.Migration.migrate_boost()
      Bonfire.Data.Social.Flag.Migration.migrate_flag()
      Bonfire.Data.Social.Message.Migration.migrate_message()
      Bonfire.Data.Social.Request.Migration.migrate_request()
    end
  end

  def ms(:down) do
    quote do
      require Bonfire.Data.Social.Block.Migration
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
      Bonfire.Data.Social.Block.Migration.migrate_block()
      Bonfire.Data.Social.Created.Migration.migrate_created()
      Bonfire.Data.Social.Activity.Migration.migrate_activity()
      Bonfire.Data.Social.Feed.Migration.migrate_feed()
      Bonfire.Data.Social.Request.Migration.migrate_request()
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


end
