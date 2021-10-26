defmodule Bonfire.Social.Activities.BoostPost.Test do

  use Bonfire.Social.ConnCase
  alias Bonfire.Social.Fake
  alias Bonfire.Social.Posts
  alias Bonfire.Social.Boosts


  describe "boost a post" do

    test "and it appears on my feed" do
      poster = fake_user!()
      content = "here is an epic html post"
      attrs = %{to_circles: [:local], post_content: %{html_body: content}}
      assert {:ok, post} = Posts.publish(poster, attrs)

      some_account = fake_account!()
      someone = fake_user!(some_account)
      conn = conn(user: someone, account: some_account)

      next = "/browse/instance"
      {view, doc} = floki_live(conn, next) #|> IO.inspect
      assert view
      |> element(".feed .boost")
      |> render_click()
      |> Floki.text() =~ "Boosted"

      # TODO: check if boost appears instantly (websocket)

      next = "/user"
      {view, doc} = floki_live(conn, next) #|> IO.inspect
      assert [feed] = Floki.find(doc, ".feed")
      assert Floki.text(feed) =~ content
    end

  end


  describe "unboost a post" do

    test "works" do
      poster = fake_user!()
      content = "here is an epic html post"
      attrs = %{to_circles: [:local], post_content: %{html_body: content}}
      assert {:ok, post} = Posts.publish(poster, attrs)

      some_account = fake_account!()
      someone = fake_user!(some_account)
      conn = conn(user: someone, account: some_account)

      assert {:ok, like} = Boosts.boost(someone, post)
      assert true == Boosts.boosted?(someone, post)

      next = "/browse/instance"
      {view, doc} = floki_live(conn, next) #|> IO.inspect
      assert view
      |> element(".feed .boost")
      |> render_click()
      |> Floki.text() =~ "Boost"

      assert false == Boosts.boosted?(someone, post)

      next = "/user"
      {view, doc} = floki_live(conn, next) #|> IO.inspect
      assert [feed] = Floki.find(doc, ".feed")
      refute Floki.text(feed) =~ content

    end

  end
end
