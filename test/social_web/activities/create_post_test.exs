defmodule Bonfire.Social.Activities.CreatePost.Test do

  use Bonfire.Social.ConnCase
  alias Bonfire.Social.Fake
  alias Bonfire.Social.Posts
  alias Bonfire.Social.Follows


  describe "create a post" do

    test "works" do

      some_account = fake_account!()
      someone = fake_user!(some_account)

      content = "here is an epic html post"

      conn = conn(user: someone, account: some_account)

      next = "/home"
      {view, doc} = floki_live(conn, next) #|> IO.inspect
      assert view
      |> form(".create_activity form")
      |> render_submit(%{"post" => %{"post_content" => %{"html_body" => content}}})
      |> Floki.text() =~ "Posted"

      # TODO: check if post appears instantly (websocket)

      next = "/user"
      {view, doc} = floki_live(conn, next) #|> IO.inspect
      assert [feed] = Floki.find(doc, ".feed")
      assert Floki.text(feed) =~ content
    end

  end

end
