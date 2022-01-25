defmodule Bonfire.Social.Notifications.Likes.Test do

  use Bonfire.Social.ConnCase
  alias Bonfire.Social.Fake
  alias Bonfire.Social.Likes
  alias Bonfire.Social.Posts


  describe "show" do

    test "likes on my posts (even from people I'm not following) in my notifications" do

      some_account = fake_account!()
      someone = fake_user!(some_account)

      attrs = %{post_content: %{html_body: "<p>here is an epic html post</p>"}}
      assert {:ok, post} = Posts.publish(someone, attrs, "public")

      liker = fake_user!()

      Likes.like(liker, post)

      conn = conn(user: someone, account: some_account)
      next = "/notifications"
      {view, doc} = floki_live(conn, next) #|> IO.inspect
      assert [feed] = Floki.find(doc, ".feed")
      assert Floki.text(feed) =~ "epic html post"
      assert Floki.text(feed) =~ liker.profile.name
      assert Floki.text(feed) =~ "Liked"
    end

  end

end
