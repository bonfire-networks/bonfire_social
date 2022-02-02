defmodule Bonfire.Social.Notifications.Boosts.Test do

  use Bonfire.Social.ConnCase
  alias Bonfire.Social.Fake
  alias Bonfire.Social.Boosts
  alias Bonfire.Social.Posts


  describe "show" do

    test "boosts on my posts (even from people I'm not following) in my notifications" do

      some_account = fake_account!()
      someone = fake_user!(some_account)

      attrs = %{post_content: %{html_body: "<p>here is an epic html post</p>"}}
      assert {:ok, post} = Posts.publish(current_user: someone, post_attrs: attrs, boundary: "public")

      booster = fake_user!()

      Boosts.boost(booster, post)

      conn = conn(user: someone, account: some_account)
      next = "/notifications"
      {view, doc} = floki_live(conn, next) #|> IO.inspect
      assert [feed] = Floki.find(doc, ".feed")
      assert Floki.text(feed) =~ "epic html post"
      assert Floki.text(feed) =~ booster.profile.name
      assert Floki.text(feed) =~ "boosted"
    end

  end

end
