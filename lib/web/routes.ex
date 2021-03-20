defmodule Bonfire.Social.Web.Routes do
  defmacro __using__(_) do

    quote do

      alias Bonfire.Social.Web.Routes.Helpers, as: SocialRoutes

      # pages anyone can view
      scope "/", Bonfire.Social.Web do
        pipe_through :browser

        live "/instance", Feeds.InstanceLive

        live "/post/:id", PostLive
        live "/discussion/:id", DiscussionLive
        live "/discussion/:id/reply/:reply_id", DiscussionLive

      end

      # pages you need an account to view
      scope "/", Bonfire.Social.Web do
        pipe_through :browser
        pipe_through :account_required

        live "/fediverse", Feeds.FediverseLive
        live "/notifications", Feeds.InboxLive

    end

      # pages you need to view as a user
      scope "/", Bonfire.Social.Web do
        pipe_through :browser
        pipe_through :user_required

        live "/feed", Feeds.MyFeedLive

      end

    end
  end
end
