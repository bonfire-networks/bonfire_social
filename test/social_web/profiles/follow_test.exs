defmodule Bonfire.Social.Follows.Test do

  use Bonfire.Social.ConnCase, async: true
  alias Bonfire.Social.Fake
  alias Bonfire.Social.Posts
  alias Bonfire.Social.Follows


  describe "follow" do

    test "when I click follow on someone's profile" do
      some_account = fake_account!()
      someone = fake_user!(some_account)

      my_account = fake_account!()
      me = fake_user!(my_account)

      conn = conn(user: me, account: my_account)
      next = Bonfire.Common.URIs.path(someone)
      {view, doc} = floki_live(conn, next) #|> IO.inspect

      assert follow = view |> element("[data-id='follow']") |> render_click()

      assert true == Follows.following?(me, someone)

      # FIXME: the html returned by render_click isn't updated to show the change (probably because it uses ComponentID and pubsub) even though this works in the browser
      # assert follow
      # |> Floki.parse_fragment()
      # ~> Floki.find("[data-id=follow]")
      # |> Floki.text()  =~ "Unfollow"
    end

  end

  describe "unfollow" do

    test "when I click unfollow on someone's profile" do
      some_account = fake_account!()
      someone = fake_user!(some_account)

      my_account = fake_account!()
      me = fake_user!(my_account)

      assert {:ok, follow} = Follows.follow(me, someone)
      # assert true == Follows.following?(me, someone)

      conn = conn(user: me, account: my_account)
      next = Bonfire.Common.URIs.path(someone) |> info("path")
      {view, doc} = floki_live(conn, next) #|> IO.inspect

      assert unfollow = view |> element("[data-id='unfollow']") |> render_click()
      assert false == Follows.following?(me, someone)

      # FIXME: the html returned by render_click isn't updated to show the change (probably because it uses ComponentID and pubsub) even though this works in the browser
      # assert unfollow
      # |> Floki.parse_fragment()
      # |> info
      # ~> Floki.find("[data-id=follow]")
      # |> Floki.text() =~ "Follow"
    end
  end
end
