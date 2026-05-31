# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Social.MastoApi.PaginationLimitTest do
  @moduledoc """
  The Mastodon `limit` param must cap the page size on every timeline. Previously the
  GraphQL `feedActivitiesPreloaded` resolver ignored the Relay `first`/`last` args (Paginator
  reads `:limit`), so feeds returned a fixed default regardless of `limit` — making clients
  that request a larger page (e.g. Ice Cubes) see a short page and assume the feed had ended,
  breaking "load more" on shorter feeds like profiles.
  """
  use Bonfire.Social.MastoApiCase, async: true

  alias Bonfire.Me.Fake
  alias Bonfire.Posts

  @moduletag :masto_api

  test "profile statuses honor the requested limit and expose a next-page link", %{conn: conn} do
    account = Fake.fake_account!()
    user = Fake.fake_user!(account)

    for i <- 1..5 do
      {:ok, _} =
        Posts.publish(
          current_user: user,
          post_attrs: %{post_content: %{html_body: "post #{i}"}},
          boundary: "public"
        )
    end

    resp =
      conn
      |> masto_api_conn(user: user, account: account)
      |> get("/api/v1/accounts/#{user.id}/statuses?limit=2")

    statuses = json_response(resp, 200)

    assert length(statuses) == 2,
           "limit=2 should return exactly 2 statuses, got #{length(statuses)}"

    assert [link] = get_resp_header(resp, "link")

    assert link =~ "max_id=",
           "a `next` Link header (max_id) should be present so clients can page"
  end

  test "profile cursor round-trips: the next link returns the next, non-overlapping page", %{
    conn: conn
  } do
    account = Fake.fake_account!()
    user = Fake.fake_user!(account)

    for i <- 1..6 do
      {:ok, _} =
        Posts.publish(
          current_user: user,
          post_attrs: %{post_content: %{html_body: "post #{i}"}},
          boundary: "public"
        )
    end

    api = masto_api_conn(conn, user: user, account: account)

    page1 = get(api, "/api/v1/accounts/#{user.id}/statuses?limit=3")
    ids1 = page1 |> json_response(200) |> Enum.map(& &1["id"])
    assert length(ids1) == 3

    [link] = get_resp_header(page1, "link")
    [_, max_id] = Regex.run(~r/max_id=([^&>;]+)/, link)
    max_id = URI.decode(max_id)

    ids2 =
      api
      |> get("/api/v1/accounts/#{user.id}/statuses?limit=3&max_id=#{max_id}")
      |> json_response(200)
      |> Enum.map(& &1["id"])

    assert length(ids2) > 0, "the next page should not be empty"

    assert MapSet.disjoint?(MapSet.new(ids1), MapSet.new(ids2)),
           "page 2 must not repeat page 1 (the cursor must advance, not return the same items)"
  end
end
