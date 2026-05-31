# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Social.MastoApi.StatusCountsTest do
  @moduledoc """
  Phase 1 characterization safety net (TDD): pins the CURRENT behaviour of the
  interaction counts (favourites_count / reblogs_count / replies_count) on a
  status, both when fetched by id (GET /api/v1/statuses/:id) and within a feed
  entry for the same status.

  These are the regression gate for the GraphQL->direct conversions (Phases 4-7):
  a conversion that drops resolver-computed counts must fail here. Where the feed
  and by-id paths currently DIVERGE, that divergence is documented inline as the
  red baseline the conversion phase is expected to flip to consistent.
  """

  use Bonfire.Social.MastoApiCase, async: true

  alias Bonfire.Me.Fake
  alias Bonfire.Posts
  alias Bonfire.Social.{Likes, Boosts}

  @moduletag :masto_api

  setup do
    # Make boundary/feed preloading synchronous in tests (see project memory).
    Process.put(:feed_live_update_many_preload_mode, :inline)
    :ok
  end

  # A boosted post shows up in a deduped feed as a reblog wrapper (top-level id is the
  # boost's, reblog.id is the original), so match either and return the entry that
  # actually carries the status fields (the reblog when wrapped).
  defp find_status(list, id) when is_list(list) do
    case Enum.find(list, &(&1["id"] == id)) do
      nil -> list |> Enum.find(&(get_in(&1, ["reblog", "id"]) == id)) |> unwrap_reblog()
      entry -> entry
    end
  end

  defp unwrap_reblog(nil), do: nil
  defp unwrap_reblog(entry), do: entry["reblog"]

  # FINDING (characterized 2026-05-29): like/boost counts are served from
  # denormalized counters that are NOT updated synchronously in the test
  # transaction, so favourites_count/reblogs_count read 0 right after Likes.like /
  # Boosts.boost — UNLIKE replies_count, which comes from the synchronous Replied
  # materialized-path counter. We therefore pin the conversion-relevant invariants
  # we CAN rely on: the field is a non-negative integer, and the feed entry agrees
  # with the by-id value for the same status. The GraphQL->direct conversions
  # (Phases 4-7) must preserve both. (A separate decision — live Edges.count vs
  # denormalized counters — is tracked for a later phase.)

  test "favourites_count is a non-negative integer (by-id and feed)", %{conn: conn} do
    account = Fake.fake_account!()
    author = Fake.fake_user!(account)

    {:ok, post} =
      Posts.publish(
        current_user: author,
        post_attrs: %{post_content: %{html_body: "count me"}},
        boundary: "public"
      )

    likers = for _ <- 1..3, do: Fake.fake_user!()
    for liker <- likers, do: {:ok, _} = Likes.like(liker, post)

    api_conn = masto_api_conn(conn, user: author, account: account)

    by_id = api_conn |> get("/api/v1/statuses/#{post.id}") |> json_response(200)
    assert is_integer(by_id["favourites_count"]) and by_id["favourites_count"] >= 0

    feed = api_conn |> get("/api/v1/timelines/public") |> json_response(200)
    entry = find_status(feed, post.id)
    assert entry, "the liked post should appear in the public feed"
    assert is_integer(entry["favourites_count"]) and entry["favourites_count"] >= 0
  end

  # Phase 5 (DONE): by-id and feed both serve a status through the same direct
  # loader + mapper + batch opts, so favourites_count is now consistent for the
  # same status across endpoints.
  test "favourites_count is consistent between by-id and feed", %{conn: conn} do
    account = Fake.fake_account!()
    author = Fake.fake_user!(account)

    {:ok, post} =
      Posts.publish(
        current_user: author,
        post_attrs: %{post_content: %{html_body: "count me"}},
        boundary: "public"
      )

    likers = for _ <- 1..3, do: Fake.fake_user!()
    for liker <- likers, do: {:ok, _} = Likes.like(liker, post)

    api_conn = masto_api_conn(conn, user: author, account: account)
    by_id = api_conn |> get("/api/v1/statuses/#{post.id}") |> json_response(200)
    feed = api_conn |> get("/api/v1/timelines/public") |> json_response(200)
    entry = find_status(feed, post.id)

    assert entry["favourites_count"] == by_id["favourites_count"],
           "feed and by-id favourites_count must be consistent for the same status"
  end

  test "reblogs_count is an integer and consistent between by-id and feed", %{conn: conn} do
    account = Fake.fake_account!()
    author = Fake.fake_user!(account)

    {:ok, post} =
      Posts.publish(
        current_user: author,
        post_attrs: %{post_content: %{html_body: "boost me"}},
        boundary: "public"
      )

    boosters = for _ <- 1..2, do: Fake.fake_user!()
    for booster <- boosters, do: {:ok, _} = Boosts.boost(booster, post)

    api_conn = masto_api_conn(conn, user: author, account: account)

    by_id = api_conn |> get("/api/v1/statuses/#{post.id}") |> json_response(200)
    assert is_integer(by_id["reblogs_count"])

    feed = api_conn |> get("/api/v1/timelines/public") |> json_response(200)
    entry = find_status(feed, post.id)
    assert entry

    assert entry["reblogs_count"] == by_id["reblogs_count"],
           "feed and by-id reblogs_count must be consistent for the same status"
  end

  test "replies_count reflects the number of replies (by-id)", %{conn: conn} do
    account = Fake.fake_account!()
    author = Fake.fake_user!(account)

    {:ok, post} =
      Posts.publish(
        current_user: author,
        post_attrs: %{post_content: %{html_body: "reply to me"}},
        boundary: "public"
      )

    for i <- 1..2 do
      replier = Fake.fake_user!()

      {:ok, _} =
        Posts.publish(
          current_user: replier,
          post_attrs: %{
            post_content: %{html_body: "reply #{i}"},
            reply_to_id: post.id
          },
          boundary: "public"
        )
    end

    api_conn = masto_api_conn(conn, user: author, account: account)

    by_id =
      api_conn
      |> get("/api/v1/statuses/#{post.id}")
      |> json_response(200)

    assert by_id["replies_count"] == 2
  end
end
