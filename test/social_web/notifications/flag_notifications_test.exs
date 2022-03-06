defmodule Bonfire.Social.Notifications.Flag.Test do

  use Bonfire.Social.ConnCase
  alias Bonfire.Me.Users
  alias Bonfire.Social.Fake
  alias Bonfire.Social.Flags
  alias Bonfire.Social.Posts


  describe "show" do

    test "flags on a post (which admin has permission to see) in admin's notifications" do

      some_account = fake_account!()
      {:ok, someone} = Users.make_admin(fake_user!(some_account))
      #|> debug()

      poster = fake_user!()
      attrs = %{post_content: %{html_body: "<p>here is an epic html post</p>"}}
      assert {:ok, post} = Posts.publish(current_user: poster, post_attrs: attrs, boundary: "public")

      flagger = fake_user!()
      Flags.flag(flagger, post)

      conn = conn(user: someone, account: some_account)
      next = "/notifications"
      {view, doc} = floki_live(conn, next) #|> IO.inspect
      assert [feed] = Floki.find(doc, ".feed")
      text = Floki.text(feed)
      assert text =~ "epic html post"
      assert text =~ flagger.profile.name
      assert text =~ "flagged"
    end

    test "flags on a post (which admin does not explicitly have permission to see) in admin's notifications" do

      alice_account = fake_account!()
      {:ok, alice} = Users.make_admin(fake_user!(alice_account))

      bob = fake_user!()
      attrs = %{post_content: %{html_body: "<p>here is an epic html post</p>"}}
      assert {:ok, post} = Posts.publish(current_user: bob, post_attrs: attrs, boundary: "mentions")

      flagger = fake_user!()
      Flags.flag(flagger, post)

      conn = conn(user: alice, account: alice_account)
      next = "/notifications"
      {view, doc} = floki_live(conn, next) #|> IO.inspect
      assert [feed] = Floki.find(doc, ".feed")
      text = Floki.text(feed)
      assert text =~ "epic html post"
      assert text =~ flagger.profile.name
      assert text =~ "flagged"
    end

  end

end
 
