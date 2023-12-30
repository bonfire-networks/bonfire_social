defmodule Bonfire.Social.DeleteTest do
  use Bonfire.Social.DataCase, async: true
  use Bonfire.Common.Utils

  alias Bonfire.Social.FeedActivities
  alias Bonfire.Posts
  alias Bonfire.Social.Objects

  alias Bonfire.Me.Users
  alias Bonfire.Me.Fake
  import Bonfire.Social.Fake
  import Bonfire.Posts.Fake
  use Bonfire.Common.Utils
  import Tesla.Mock

  test "post deletion works" do
    user = Fake.fake_user!()

    post =
      fake_post!(user, "public", %{
        post_content: %{
          summary: "summary",
          name: "name",
          html_body: "epic html"
        }
      })

    {:ok, _} =
      Objects.delete(post, current_user: user)
      |> debug()

    assert {:error, _} = Posts.read(post.id, skip_boundary_check: true)
  end

  test "deletion of a user deletes its posts" do
    user = Fake.fake_user!()

    post =
      fake_post!(user, "public", %{
        post_content: %{
          summary: "summary",
          name: "name",
          html_body: "epic html"
        }
      })

    Oban.Testing.with_testing_mode(:inline, fn ->
      {:ok, _} =
        Users.enqueue_delete(user)
        |> debug("del?")
    end)

    refute Users.get_current(user.id)
    assert {:error, _} = Posts.read(post.id, skip_boundary_check: true)

    # TODO: test that we also delete likes/boosts/etc
  end
end
