if Application.compile_env(:bonfire_social, :modularity) != :disabled do
  defmodule Bonfire.Social.Web.MastoTimelineController do
    @moduledoc "Mastodon-compatible timeline endpoints with pagination support."

    use Bonfire.UI.Common.Web, :controller

    alias Bonfire.Social.API.GraphQLMasto.Adapter
    alias Bonfire.Boundaries.API.GraphQLMasto.Adapter, as: BoundariesAdapter
    alias Bonfire.API.MastoCompat.{PaginationHelpers, Helpers}

    # `Markers.timeline_feed_name/1` is the canonical home↔my mapping, shared
    # with the markers API so reading positions stay on the same feed.
    def home(conn, params),
      do: feed_by_name(conn, Bonfire.Social.Markers.timeline_feed_name("home"), params)

    def public(conn, params) do
      feed_name = if params["local"] == "true", do: "local", else: "explore"
      feed_by_name(conn, feed_name, params)
    end

    def local(conn, params), do: feed_by_name(conn, "local", params)

    @masto_feed_preloads ["with_subject", "with_object_more", "with_post_content", "with_replied"]

    def feed_by_name(conn, feed_name, params) do
      params
      |> PaginationHelpers.build_feed_params(%{
        "feed_name" => feed_name,
        "preload" => @masto_feed_preloads
      })
      |> then(&Adapter.feed(&1, conn))
    end

    def hashtag(conn, %{"hashtag" => hashtag} = params) do
      feed_name = if params["local"] == "true", do: "local", else: "explore"
      normalized_tag = Helpers.normalize_hashtag(hashtag)

      params
      |> PaginationHelpers.build_feed_params(%{
        "feed_name" => feed_name,
        "tags" => [normalized_tag],
        "preload" => @masto_feed_preloads
      })
      |> then(&Adapter.feed(&1, conn))
    end

    def timeline(conn, %{"feed" => feed_name} = params), do: feed_by_name(conn, feed_name, params)

    def list_timeline(conn, %{"list_id" => list_id} = params),
      do: BoundariesAdapter.list_timeline(list_id, params, conn)

    def notification(conn, %{"id" => id}), do: Adapter.notification(id, conn)
    def clear_notifications(conn, _params), do: Adapter.clear_notifications(conn)
    def dismiss_notification(conn, %{"id" => id}), do: Adapter.dismiss_notification(id, conn)

    def notifications(conn, params) do
      params
      |> PaginationHelpers.build_feed_params(%{
        "feed_name" => "notifications",
        "preload" => @masto_feed_preloads
      })
      |> then(&Adapter.notifications(&1, conn))
    end

    def notification_requests(conn, _params) do
      # Mastodon 4.2+ feature - not yet implemented in Bonfire
      Phoenix.Controller.json(conn, [])
    end

    def bookmarks(conn, params) do
      params
      |> PaginationHelpers.build_feed_params(%{
        "feed_name" => "bookmarks",
        "preload" => @masto_feed_preloads
      })
      |> then(&Adapter.feed(&1, conn))
    end

    def favourites(conn, params) do
      params
      |> PaginationHelpers.build_feed_params(%{"preload" => @masto_feed_preloads})
      |> then(&Adapter.favourites(&1, conn))
    end

    def user_statuses(conn, %{"id" => user_id} = params) do
      if params["pinned"] == "true" do
        Adapter.pinned_statuses(user_id, params, conn)
      else
        # The `user_activities` preset is filtered by subject (the actor) and excludes
        # likes/follows, so the account's posts AND boosts/reblogs both appear — which
        # the previous `creators` (object author) filter excluded boosts from.
        params
        |> PaginationHelpers.build_feed_params(%{
          "feed_name" => "user_activities",
          "preload" => @masto_feed_preloads
        })
        |> then(&Adapter.user_activities_feed(user_id, &1, conn))
      end
    end
  end
end
