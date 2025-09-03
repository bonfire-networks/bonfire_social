defmodule Bonfire.Social.DeleteTest do
  use Bonfire.Social.DataCase, async: true
  use Bonfire.Common.Utils

  import Bonfire.Files.Simulation
  alias Bonfire.Files
  alias Bonfire.Files.ImageUploader

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
          html_body: "epic html"
        }
      })

    {:ok, _} =
      Objects.delete(post, current_user: user)
      |> debug()

    assert {:error, _} = Posts.read(post.id, skip_boundary_check: true)
  end

  test "when post is deleted, also delete attached media" do
    user = Fake.fake_user!()
    assert {:ok, upload} = Files.upload(ImageUploader, user, icon_file())

    if path = Files.local_path(ImageUploader, upload) do
      assert File.exists?(path)
    end || assert Bonfire.Common.Media.image_url(upload)

    post =
      fake_post!(
        user,
        "public",
        %{
          post_content: %{
            summary: "summary",
            name: "name",
            html_body: "epic html"
          }
        },
        uploaded_media: [upload]
      )
      |> repo().maybe_preload([:media])

    assert path == e(post, :media, []) |> List.first() |> Files.local_path(ImageUploader, ...)
    assert File.exists?(path)

    assert {:ok, _} = Bonfire.Me.DeleteWorker.delete_structs_now(post)
    refute File.exists?(path)
  end

  test "deletion of a user deletes its posts" do
    user = Fake.fake_user!()

    post =
      fake_post!(user, "public", %{
        post_content: %{
          summary: "summary",
          html_body: "epic html"
        }
      })

    # Oban.Testing.with_testing_mode(:inline, fn ->
    #   {:ok, _} =
    #     Users.enqueue_delete(user)
    #     |> debug("del?")
    # end)
    assert {:ok, _} = Bonfire.Me.DeleteWorker.delete_structs_now(user)

    refute Users.get_current(user.id)
    assert {:error, _} = Posts.read(post.id, skip_boundary_check: true)

    # TODO: check if we also delete likes/boosts/etc
  end

  test "deletion of a user deletes its posts (and media attached to those)" do
    user = Fake.fake_user!()

    assert {:ok, upload} = Files.upload(ImageUploader, user, icon_file())

    if path = Files.local_path(ImageUploader, upload) do
      assert File.exists?(path)
    end || assert Bonfire.Common.Media.image_url(upload)

    post =
      fake_post!(
        user,
        "public",
        %{
          post_content: %{
            summary: "summary",
            name: "name",
            html_body: "epic html"
          }
        },
        uploaded_media: [upload]
      )
      |> repo().maybe_preload([:media])

    # assert path == e(post, :media, []) |> List.first() |> Files.local_path(ImageUploader, ...)
    # assert File.exists?(path)

    assert {:ok, _} = Bonfire.Me.DeleteWorker.delete_structs_now(user)

    refute Users.get_current(user.id)
    assert {:error, _} = Posts.read(post.id, skip_boundary_check: true)
    refute path && File.exists?(path)

    # TODO: check if we also delete likes/boosts/etc
  end
end
