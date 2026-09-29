defmodule Bonfire.Social.API.GraphQLLogNoiseTest do
  @moduledoc """
  What a request logs when nothing is wrong: nothing about query modules, and never the request's whole context.

  In production every Mastodon notifications request logged several kilobytes of warnings: the GraphQL Dataloader asked for a query module that `Edge` and `Media` don't have, then warned with its arguments inspected, the Dataloader and the user included. A schema without a query module is the normal case, answered by the generic query.
  """
  use Bonfire.Social.MastoApiCase, async: false
  import ExUnit.CaptureLog

  @moduletag :masto_api

  setup %{conn: conn} do
    account = Bonfire.Me.Fake.fake_account!()
    author = Bonfire.Me.Fake.fake_user!(account)
    reactor = Bonfire.Me.Fake.fake_user!()

    {:ok, post} =
      Bonfire.Posts.publish(
        current_user: author,
        post_attrs: %{post_content: %{html_body: "a post to react to"}},
        boundary: "public"
      )

    {:ok, _} = Bonfire.Social.Likes.like(reactor, post)
    {:ok, _} = Bonfire.Social.Boosts.boost(reactor, post)

    {:ok, author: author, conn: masto_api_conn(conn, user: author, account: account)}
  end

  test "the notification list logs nothing about query modules, and not its context", %{
    conn: conn,
    author: author
  } do
    log =
      capture_log([level: :warning], fn ->
        # the positive first: it answered, with the like and the boost
        assert [_ | _] = conn |> get("/api/v1/notifications") |> json_response(200)
      end)

    refute log =~ "no known query module"
    refute log =~ "None of the functions [:query]"
    refute log =~ "there's no context module declared"
    refute log =~ "could not query with args"
    # whatever is logged, the request's context never is: the user's struct is the tell
    refute log =~ "%Bonfire.Data.Identity.User{" and log =~ author.id
  end
end
