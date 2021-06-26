defmodule Bonfire.Social.Notifications.Follows.Test do

  use Bonfire.Social.ConnCase
  alias Bonfire.Social.Fake
  alias Bonfire.Social.Posts
  alias Bonfire.Social.Follows


  describe "show" do

    test "when someone follows me in my notifications" do
      some_account = fake_account!()
      someone = fake_user!(some_account)

      me = fake_user!()
      assert {:ok, follow} = Follows.follow(me, someone)
      assert true == Follows.following?(me, someone)

      conn = conn(user: someone, account: some_account)
      next = "/notifications"
      {view, doc} = floki_live(conn, next) #|> IO.inspect
      assert [feed] = Floki.find(doc, ".feed")
      assert Floki.text(feed) =~ me.profile.name
      assert Floki.text(feed) =~ "followed" # FIXME
    end

  end

  describe "DO NOT show" do

    test "when I follow someone in my notifications" do
      some_account = fake_account!()
      someone = fake_user!(some_account)

      me = fake_user!()
      assert {:ok, follow} = Follows.follow(someone, me)
      assert true == Follows.following?(someone, me)

      conn = conn(user: someone, account: some_account)
      next = "/notifications"
      {view, doc} = floki_live(conn, next) #|> IO.inspect
      assert [feed] = Floki.find(doc, ".feed")
      refute Floki.text(feed) =~ me.profile.name
    end
  end
end
