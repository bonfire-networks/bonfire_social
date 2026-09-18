defmodule Bonfire.Social.API.NotificationPreferencesIgnoredTest do
  @moduledoc """
  Mastodon clients get every notification type, whatever the user hid in Bonfire's own UI.

  Mastodon has no stored per-kind preference: `types[]`/`exclude_types[]` are per request, so a
  client choosing what to show is the client's business. Bonfire's own readers apply the saved
  "Show in Latest" categories by default, so this adapter passes the opt-out and this test is what
  keeps it passing it.
  """
  use Bonfire.Social.MastoApiCase, async: false
  @moduletag :masto_api
  @moduletag capture_log: true

  alias Bonfire.Common.Settings
  alias Bonfire.Social.Notifications

  setup %{conn: conn} do
    account = Bonfire.Me.Fake.fake_account!()
    user = Bonfire.Me.Fake.fake_user!(account)

    {:ok, post} =
      Bonfire.Posts.publish(
        current_user: user,
        post_attrs: %{post_content: %{html_body: "a post of mine to boost"}},
        boundary: "public"
      )

    {:ok, _} = Bonfire.Social.Boosts.boost(Bonfire.Me.Fake.fake_user!(), post)

    {:ok, user: user, conn: masto_api_conn(conn, user: user, account: account)}
  end

  test "a category hidden in Bonfire still reaches a Mastodon client", %{conn: conn, user: user} do
    assert [%{"type" => "reblog"}] = conn |> get("/api/v1/notifications") |> json_response(200)

    Settings.put(Notifications.show_in_centre_key(:boost), false, current_user: user)

    assert [%{"type" => "reblog"}] = conn |> get("/api/v1/notifications") |> json_response(200)
  end

  test "the client's own exclude_types still works", %{conn: conn} do
    assert [] =
             conn
             |> get("/api/v1/notifications?exclude_types[]=reblog")
             |> json_response(200)
  end
end
