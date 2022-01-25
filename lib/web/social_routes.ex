defmodule Bonfire.Social.Web.Routes do
  defmacro __using__(_) do

    quote do

      # pages anyone can view
      scope "/", Bonfire.Social.Web do
        pipe_through :browser

        live "/home", HomeLive, as: :home
        live "/home/:tab", HomeLive, as: :home
        live "/local", Feeds.LocalLive, as: :local
        live "/federation", Feeds.FederationLive, as: :federation

        live "/write", WriteLive, as: :write

        live "/post", PostLive, as: Bonfire.Data.Social.Post
        live "/post/:id", PostLive, as: Bonfire.Data.Social.Post
        live "/discussion/:id", DiscussionLive, as: Bonfire.Data.Social.PostContent
        live "/discussion/:id/reply/:reply_id", DiscussionLive

      end

      # pages you need an account to view
      scope "/", Bonfire.Social.Web do
        pipe_through :browser
        pipe_through :account_required

        live "/notifications", Feeds.NotificationsLive, as: :notifications
        live "/flags", FlagsLive, as: :flags

    end

      # pages you need to view as a user
      scope "/", Bonfire.Social.Web do
        pipe_through :browser
        pipe_through :user_required

        live "/favourited/", Feeds.FavouritedLive, as: :favourited

        live "/message/:id", MessageLive, as: Bonfire.Data.Social.Message
        live "/message/:id/reply/:reply_id", MessageLive

      end

    end
  end
end
