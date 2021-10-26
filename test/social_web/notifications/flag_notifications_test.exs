defmodule Bonfire.Social.Notifications.Flag.Test do

  use Bonfire.Social.ConnCase
  alias Bonfire.Social.Fake
  alias Bonfire.Social.Flags
  alias Bonfire.Social.Posts


  describe "show" do

    test "flags on a post (which admin has permission to see) in admin's notifications" do

      some_account = fake_account!() # first account is admin
      someone = fake_user!(some_account) #|> IO.inspect()

      poster = fake_user!()
      attrs = %{to_circles: [:local], post_content: %{html_body: "<p>here is an epic html post</p>"}}
      assert {:ok, post} = Posts.publish(poster, attrs)

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

    test "flags on a post (which admin does not have permission to see) in admin's notifications" do

      some_account = fake_account!() # first account is admin
      someone = fake_user!(some_account) #|> IO.inspect()

      poster = fake_user!()
      attrs = %{post_content: %{html_body: "<p>here is an epic html post</p>"}}
      assert {:ok, post} = Posts.publish(poster, attrs)

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

  end

end
