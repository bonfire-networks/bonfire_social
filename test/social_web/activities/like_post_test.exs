defmodule Bonfire.Social.Activities.LikePost.Test do

  use Bonfire.Social.ConnCase
  alias Bonfire.Social.Fake
  alias Bonfire.Social.Posts
  alias Bonfire.Social.Likes


  describe "like a post" do

    test "works" do
      poster = fake_user!()
      content = "here is an epic html post"
      attrs = %{to_circles: [:local], post_content: %{html_body: content}}
      assert {:ok, post} = Posts.publish(poster, attrs)

      some_account = fake_account!()
      someone = fake_user!(some_account)
      conn = conn(user: someone, account: some_account)

      next = "/local"
      {view, doc} = floki_live(conn, next) #|> IO.inspect
      assert view
      |> element(".feed button.like")
      # |> IO.inspect
      |> render_click()
      |> Floki.text() =~ "Liked (1)"

      assert true == Likes.liked?(someone, post)

    end

    test "shows the right number of likes" do
      poster = fake_user!()
      content = "here is an epic html post"
      attrs = %{to_circles: [:local], post_content: %{html_body: content}}
      assert {:ok, post} = Posts.publish(poster, attrs)

      assert {:ok, like} = Likes.like(fake_user!(), post)
      assert {:ok, like} = Likes.like(fake_user!(), post)

      some_account = fake_account!()
      someone = fake_user!(some_account)
      conn = conn(user: someone, account: some_account)

      next = "/local"
      {view, doc} = floki_live(conn, next) #|> IO.inspect

      assert view
      |> element(".feed button.like")
      |> render()
      # |> IO.inspect
      |> Floki.text() =~ "Liked (2)"

      assert view
      |> element(".feed button.like")
      |> render_click()
      |> Floki.text() =~ "Liked (3)"

      assert true == Likes.liked?(someone, post)

    end

  end

  describe "unlike a post" do

    test "works" do
      poster = fake_user!()
      content = "here is an epic html post"
      attrs = %{to_circles: [:local], post_content: %{html_body: content}}
      assert {:ok, post} = Posts.publish(poster, attrs)

      some_account = fake_account!()
      someone = fake_user!(some_account)
      conn = conn(user: someone, account: some_account)

      assert {:ok, like} = Likes.like(someone, post)
      assert true == Likes.liked?(someone, post)

      next = "/local"
      {view, doc} = floki_live(conn, next) #|> IO.inspect
      assert view
      |> element(".feed button.like")
      |> render_click()
      |> Floki.text() =~ "Like"

      assert false == Likes.liked?(someone, post)

    end

  end
end
