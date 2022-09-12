defmodule Bonfire.Social.APIntegrationTest do
  use Bonfire.Social.DataCase
  use Oban.Testing, repo: Bonfire.Common.Repo

  alias Bonfire.Me.Fake
  alias Bonfire.Social.Follows
  alias Bonfire.Social.Posts
  alias Bonfire.Social.Likes
  alias Bonfire.Social.Boosts
  alias Bonfire.Social.Messages

  alias Bonfire.Federate.ActivityPub.APPublishWorker

  test "follows get queued to federate" do
    me = Fake.fake_user!()
    followed = Fake.fake_user!()
    assert {:ok, follow} = Follows.follow(me, followed)

    assert_enqueued(
      worker: APPublishWorker,
      args: %{"context_id" => follow.id, "op" => "create", "user_id" => me.id}
    )
  end

  test "posts get queued to federate" do
    attrs = %{
      post_content: %{
        summary: "summary",
        name: "name",
        html_body: "<p>epic html message</p>"
      }
    }

    user = Fake.fake_user!()

    assert {:ok, post} =
             Posts.publish(
               current_user: user,
               post_attrs: attrs,
               boundary: "public"
             )

    assert_enqueued(
      worker: APPublishWorker,
      args: %{"context_id" => post.id, "op" => "create", "user_id" => user.id}
    )
  end

  test "likes get queued to federate" do
    me = Fake.fake_user!()
    post_creator = Fake.fake_user!()

    attrs = %{
      post_content: %{
        summary: "summary",
        name: "name",
        html_body: "<p>epic html message</p>"
      }
    }

    assert {:ok, post} =
             Posts.publish(
               current_user: post_creator,
               post_attrs: attrs,
               boundary: "public"
             )

    assert {:ok, like} = Likes.like(me, post)

    assert_enqueued(
      worker: APPublishWorker,
      args: %{"context_id" => like.id, "op" => "create", "user_id" => me.id}
    )
  end

  test "boosts get queued to federate" do
    me = Fake.fake_user!()
    post_creator = Fake.fake_user!()

    attrs = %{
      post_content: %{
        summary: "summary",
        name: "name",
        html_body: "<p>epic html message</p>"
      }
    }

    assert {:ok, boosted} =
             Posts.publish(
               current_user: post_creator,
               post_attrs: attrs,
               boundary: "public"
             )

    assert {:ok, boost} = Boosts.boost(me, boosted)

    assert_enqueued(
      worker: APPublishWorker,
      args: %{"context_id" => boost.id, "op" => "create", "user_id" => me.id}
    )
  end

  test "messages get queued to federate" do
    me = Fake.fake_user!()
    messaged = Fake.fake_user!()

    msg = "hey you have an epic text message"
    attrs = %{to_circles: [messaged.id], post_content: %{html_body: msg}}

    assert {:ok, message} = Messages.send(me, attrs)

    assert_enqueued(
      worker: APPublishWorker,
      args: %{"context_id" => message.id, "op" => "create", "user_id" => me.id}
    )
  end

  # Maybe move this to adapter tests?
  describe "locality checks" do
    test "federates activities from local actors" do
      attrs = %{
        post_content: %{
          summary: "summary",
          name: "name",
          html_body: "<p>epic html message</p>"
        }
      }

      user = Fake.fake_user!()

      assert {:ok, post} =
               Posts.publish(
                 current_user: user,
                 post_attrs: attrs,
                 boundary: "public"
               )

      assert {:ok, _} =
               perform_job(APPublishWorker, %{
                 "context_id" => post.id,
                 "op" => "create",
                 "user_id" => user.id
               })
    end
  end
end
