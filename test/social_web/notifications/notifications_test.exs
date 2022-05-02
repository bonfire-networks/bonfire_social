defmodule Bonfire.Social.Notifications.Test do

  use Bonfire.Social.ConnCase
  alias Bonfire.Social.Fake
  alias Bonfire.Social.Posts
  alias Bonfire.Social.Follows


  describe "show" do

    # test "with account" do
    #   account = fake_account!()
    #   conn = conn(account: account)
    #   next = "/notifications"
    #   {view, doc} = floki_live(conn, next) #|> IO.inspect
    #   assert [_] = Floki.find(doc, ".feed")
    # end

    test "with user" do
      account = fake_account!()
      user = fake_user!(account)
      conn = conn(user: user, account: account)
      next = "/notifications"
      {view, doc} = floki_live(conn, next) #|> IO.inspect
      assert [_] = Floki.find(doc, ".feed")
    end

  end

  describe "DO NOT show" do

    test "when not logged in" do
      conn = conn()
      conn = get(conn, "/notifications")
      assert redirected_to(conn) =~ "/login"
    end

    test "with account only" do
      account = fake_account!()
      conn = conn(account: account)
      next = "/notifications"
      {view, doc} = floki_live(conn, next) #|> IO.inspect
      assert [] = Floki.find(doc, ".feed") # TODO: what to show in this case?
    end

  end
end
