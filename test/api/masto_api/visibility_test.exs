# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Social.MastoApi.VisibilityTest do
  @moduledoc """
  Phase 1 characterization safety net (TDD): pins the CURRENT mapping of Bonfire
  boundaries to the Mastodon Status `visibility` field, so the GraphQL->direct
  conversions can't silently change it. The public->unlisted mapping is a known
  lossy round-trip that Phase 9 will turn into a deliberate decision; until then
  this test makes any change to it an intentional test edit.
  """

  use Bonfire.Social.MastoApiCase, async: true

  alias Bonfire.Me.Fake
  alias Bonfire.Posts

  @moduletag :masto_api
  @valid_visibilities ~w(public unlisted private direct)

  setup do
    Process.put(:feed_live_update_many_preload_mode, :inline)
    :ok
  end

  defp find_status(list, id) when is_list(list), do: Enum.find(list, &(&1["id"] == id))

  test "a public-boundary status has a valid visibility, consistent by-id and in feed",
       %{conn: conn} do
    account = Fake.fake_account!()
    author = Fake.fake_user!(account)

    {:ok, post} =
      Posts.publish(
        current_user: author,
        post_attrs: %{post_content: %{html_body: "visibility check"}},
        boundary: "public"
      )

    api_conn = masto_api_conn(conn, user: author, account: account)

    by_id = api_conn |> get("/api/v1/statuses/#{post.id}") |> json_response(200)
    assert by_id["visibility"] in @valid_visibilities

    # Pin the exact current mapping. Bonfire's "public" boundary grants the remote
    # (federated) public ACL, so acl_ids_to_visibility resolves has_remote -> "public".
    assert by_id["visibility"] == "public",
           "public boundary currently maps to 'public' (status.ex acl_ids_to_visibility, has_remote branch)"

    feed = api_conn |> get("/api/v1/timelines/public") |> json_response(200)
    entry = find_status(feed, post.id)
    assert entry

    assert entry["visibility"] == by_id["visibility"],
           "feed and by-id visibility must be consistent for the same status"
  end
end
