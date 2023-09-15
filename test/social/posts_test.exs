defmodule Bonfire.Social.PostsTest do
  use Bonfire.Social.DataCase, async: true
  use Bonfire.Common.Utils

  alias Bonfire.Social.FeedActivities
  alias Bonfire.Social.Posts

  alias Bonfire.Me.Fake
  import Bonfire.Social.Fake
  use Bonfire.Common.Utils
  import Tesla.Mock

  test "creation works" do
    user = Fake.fake_user!()

    post =
      fake_post!(user, "public", %{
        post_content: %{
          summary: "summary",
          name: "name",
          html_body: "epic html"
        }
      })

    assert String.contains?(post.post_content.html_body, "epic html")
    assert post.post_content.name =~ "name"
    assert post.post_content.summary =~ "summary"
    assert post.created.creator_id == user.id
  end

  test "read a public post, ignoring boundaries" do
    user = Fake.fake_user!()

    post = fake_post!(user, "public")

    # debug(post, "post")
    assert {:ok, read} = Posts.read(post.id, skip_boundary_check: true)
    assert post.id == read.id
  end

  test "read a public post as a guest" do
    user = Fake.fake_user!()

    post = fake_post!(user, "public")

    # debug(post, "post")
    assert {:ok, read} = Posts.read(post.id)
    assert post.id == read.id
  end

  test "read my own public post" do
    user = Fake.fake_user!()

    post = fake_post!(user, "public")

    # post = repo().preload(post, [:caretaker, controlled: [acl: [:named, :caretaker]]])
    # user = repo().preload(user, encircles: [circle: [:named]])
    # debug(post, "post")
    # debug(user, "user")
    assert {:ok, read} = Posts.read(post.id, current_user: user)

    # assert post.id == read.id
  end

  test "listing by creator, ignoring boundaries" do
    attrs_1 = %{
      post_content: %{
        summary: "summary",
        name: "name",
        html_body: "<p>epic html message 1</p>"
      }
    }

    attrs_2 = %{
      post_content: %{
        summary: "summary",
        name: "name",
        html_body: "<p>epic html message 2</p>"
      }
    }

    attrs_3 = %{
      post_content: %{
        summary: "summary",
        name: "name",
        html_body: "<p>epic html message 3</p>"
      }
    }

    user = Fake.fake_user!()

    assert {:ok, _} =
             Posts.publish(
               current_user: user,
               post_attrs: attrs_1,
               boundary: "public"
             )

    assert {:ok, _} =
             Posts.publish(
               current_user: user,
               post_attrs: attrs_2,
               boundary: "public"
             )

    assert %{edges: posts} = Posts.list_by(user, skip_boundary_check: true)
    # debug(posts, "posts")
    assert length(posts) == 2
  end

  test "listing by creator, querying with boundaries" do
    attrs_1 = %{
      post_content: %{
        summary: "summary",
        name: "name",
        html_body: "<p>epic html message 1</p>"
      }
    }

    attrs_2 = %{
      post_content: %{
        summary: "summary",
        name: "name",
        html_body: "<p>epic html message 2</p>"
      }
    }

    # attrs_3 = %{
    #   post_content: %{
    #     summary: "summary",
    #     name: "name",
    #     html_body: "<p>epic html message 3</p>"
    #   }
    # }

    user = Fake.fake_user!()

    assert {:ok, _} =
             Posts.publish(
               current_user: user,
               post_attrs: attrs_1,
               boundary: "public"
             )

    assert {:ok, _} =
             Posts.publish(
               current_user: user,
               post_attrs: attrs_2,
               boundary: "public"
             )

    # assert {:ok, _} =
    #          Posts.publish(
    #            current_user: user,
    #            post_attrs: attrs_3,
    #            boundary: "public"
    #          )

    assert %{edges: posts} = Posts.list_by(user, current_user: user)
    assert length(posts) == 2
  end

  test "when i post, it appears in my outbox feed, but not in my notifications or inbox" do
    user = Fake.fake_user!()

    post = fake_post!(user, "public")

    assert FeedActivities.feed_contains?(:outbox, post, current_user: user)
    refute FeedActivities.feed_contains?(:inbox, post, current_user: user)
    refute FeedActivities.feed_contains?(:notifications, post, current_user: user)
  end
end
