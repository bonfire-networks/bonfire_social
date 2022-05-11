defmodule Bonfire.Social.Web.Routes do
  defmacro __using__(_) do

    quote do

      # pages anyone can view
      scope "/", Bonfire.Social.Web do
        pipe_through :browser
        live "/local", Feeds.LocalLive, as: :local
        live "/federation", Feeds.FederationLive, as: :federation

        live "/write", WriteLive, as: :write

        # live "/post", PostLive, as: Bonfire.Data.Social.Post
        live "/post/:id", PostLive, as: Bonfire.Data.Social.Post
        live "/discussion/:id", DiscussionLive, as: Pointers.Pointer
        live "/discussion/:id/reply/:reply_to_id", DiscussionLive, as: Pointers.Pointer

      end

      # pages you need an account to view
      scope "/", Bonfire.Social.Web do
        pipe_through :browser
        pipe_through :account_required
        live "/feed", HomeLive, as: :feed
        live "/feed/:tab", HomeLive, as: :feed
        live "/notifications", Feeds.NotificationsLive, as: :notifications
        # live "/flags", FlagsLive, as: :flags

    end

      # pages you need to view as a user
      scope "/", Bonfire.Social.Web do
        pipe_through :browser
        pipe_through :user_required

        live "/my/likes/", Feeds.LikesLive, as: Bonfire.Data.Social.Like
        live "/messages/:id", MessagesLive, as: Bonfire.Data.Social.Message
        live "/messages/:id/reply/:reply_to_id", MessagesLive, as: Bonfire.Data.Social.Message
        live "/messages/@:username", MessagesLive, as: Bonfire.Data.Social.Message
        live "/messages", MessagesLive, as: Bonfire.Data.Social.Message

      end

    end
  end
end
