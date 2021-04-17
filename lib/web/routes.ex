defmodule Bonfire.Social.Web.Routes do
  defmacro __using__(_) do

    quote do

      alias Bonfire.Social.Web.Routes.Helpers, as: SocialRoutes

      # pages anyone can view
      scope "/", Bonfire.Social.Web do
        pipe_through :browser

        live "/browse/", Feeds.BrowseLive
        live "/browse/:tab", Feeds.BrowseLive

        live "/post/:id", PostLive
        live "/discussion/:id", DiscussionLive
        live "/discussion/:id/reply/:reply_id", DiscussionLive
        live "/message/:id", MessageLive
        live "/message/:id/reply/:reply_id", MessageLive

      end

      # pages you need an account to view
      scope "/", Bonfire.Social.Web do
        pipe_through :browser
        pipe_through :account_required

        live "/notifications", Feeds.NotificationsLive

    end

      # pages you need to view as a user
      scope "/", Bonfire.Social.Web do
        pipe_through :browser
        pipe_through :user_required


        live "/private", PrivateLive

      end

    end
  end
end
