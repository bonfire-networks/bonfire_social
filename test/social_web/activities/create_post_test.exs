defmodule Bonfire.Social.Activities.CreatePost.Test do

  use Bonfire.Social.ConnCase, async: true
  alias Bonfire.Social.Fake
  alias Bonfire.Social.Posts
  alias Bonfire.Social.Follows


  describe "create a post" do

    @tag :fixme
    test "shows a confirmation flash message" do

      some_account = fake_account!()
      someone = fake_user!(some_account)

      content = "here is an epic html post"

      conn = conn(user: someone, account: some_account)

      next = "/feed"
      {view, doc} = floki_live(conn, next) #|> IO.inspect

      assert view = view
      |> form("#smart_input form")
      |> render_submit(%{"boundary_selected" => "public", "post" => %{"post_content" => %{"html_body" => content}}})
      # |> Floki.text() =~ "Posted"

      assert [ok] = find_flash(view)
      assert ok |> Floki.text() =~ "Posted"

    end

    test "works" do

      some_account = fake_account!()
      someone = fake_user!(some_account)

      content = "here is an epic html post"

      conn = conn(user: someone, account: some_account)

      next = "/feed"
      {view, doc} = floki_live(conn, next) #|> IO.inspect

      assert view
      |> form("#smart_input form")
      |> render_submit(%{"boundary_selected" => "public", "post" => %{"post_content" => %{"html_body" => content}}})
      # |> Floki.text() =~ "Posted"

      # TODO: check if post appears instantly (pubsub)

      next = "/user"
      {view, doc} = floki_live(conn, next) #|> IO.inspect
      assert [feed] = Floki.find(doc, "[data-id=feed]")
      assert Floki.text(feed) =~ content
    end

  end

end
