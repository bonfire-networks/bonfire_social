defmodule Bonfire.Social.ExperiencedAsTest do
  @moduledoc """
  What an activity is *for the person being told about it*, which the stored verb cannot say on its own.

  One `:create` row is a reply to the person whose post it answers, a mention of the person it names, and something they just wrote to somebody who got it through a circle. One `:request` row is a follow request or a quote request depending on its edge. Everything downstream agrees only if one function answers this, so these pin the answers rather than the feed, the push and the Mastodon API each pinning their own.
  """
  use Bonfire.DataCase, async: true
  @moduletag :backend

  import Bonfire.Posts.Fake, only: [fake_post!: 3]

  alias Bonfire.Social.Activities
  alias Bonfire.Posts
  alias Bonfire.Me.Fake

  # the object is preloaded because whether a create carries written content is read from it: the same row answers `:write` or `:create` depending on what is loaded, which is why the pair of tests at the bottom exists
  defp activity_for(post) do
    post.activity
    |> Bonfire.Common.Repo.maybe_preload([:verb, :replied, :tags, :object])
  end

  test "a post that answers another is stored as a reply, so it reads as one for anybody" do
    me = Fake.fake_user!()
    other = Fake.fake_user!()
    bystander = Fake.fake_user!()

    mine = fake_post!(me, "public", %{post_content: %{html_body: "the first word"}})

    {:ok, answer} =
      Posts.publish(
        current_user: other,
        boundary: "public",
        post_attrs: %{
          post_content: %{html_body: "answering you"},
          reply_to_id: id(mine)
        }
      )

    activity = activity_for(answer)

    # `Bonfire.Social.Acts.Threaded` turns a `:create` with a `reply_to` into a `:reply` as it is written, so the verb already says this much and no recipient is needed to read it
    assert Activities.experienced_as(activity, me) == :reply
    assert Activities.experienced_as(activity, bystander) == :reply
  end

  test "a post that is neither a reply nor a mention is something somebody wrote, whoever reads it" do
    author = Fake.fake_user!()
    bystander = Fake.fake_user!()

    {:ok, post} =
      Posts.publish(
        current_user: author,
        boundary: "public",
        post_attrs: %{post_content: %{html_body: "to nobody in particular"}}
      )

    # what somebody gets through a circle or a followed author, which is not a notification about them
    assert Activities.experienced_as(activity_for(post), bystander) == :write
    assert Activities.experienced_as(activity_for(post)) == :write
  end

  test "a post that names me is a mention of me, which beats having been written" do
    me = Fake.fake_user!()
    other = Fake.fake_user!()

    {:ok, post} =
      Posts.publish(
        current_user: other,
        boundary: "public",
        post_attrs: %{post_content: %{html_body: "hey @#{me.character.username}"}}
      )

    assert Activities.experienced_as(activity_for(post), me) == :mention
  end

  test "answering my post while naming me reads as the reply, which is the more specific thing" do
    me = Fake.fake_user!()
    other = Fake.fake_user!()

    mine = fake_post!(me, "public", %{post_content: %{html_body: "the first word"}})

    {:ok, answer} =
      Posts.publish(
        current_user: other,
        boundary: "public",
        post_attrs: %{
          post_content: %{html_body: "answering you @#{me.character.username}"},
          reply_to_id: id(mine)
        }
      )

    assert Activities.experienced_as(activity_for(answer), me) == :reply
  end

  test "a verb that says what it is needs no recipient to be read" do
    me = Fake.fake_user!()
    other = Fake.fake_user!()

    post = fake_post!(me, "public", %{post_content: %{html_body: "something to like"}})

    {:ok, like} = Bonfire.Social.Likes.like(other, post)

    assert Activities.experienced_as(activity_for(like), me) == :like
    assert Activities.experienced_as(activity_for(like)) == :like
  end

  test "a follow is a follow" do
    me = Fake.fake_user!()
    other = Fake.fake_user!()

    {:ok, follow} = Bonfire.Social.Graph.Follows.follow(other, me)

    assert Activities.experienced_as(activity_for(follow), me) == :follow
  end

  test "asking is told apart by what was asked for, and an unnamed ask stays a plain request" do
    request = fn table_id ->
      Activities.experienced_as(%{verb: %{verb: "Request"}, edge: %{table_id: table_id}})
    end

    assert request.(Bonfire.Common.Types.table_id(Bonfire.Data.Social.Follow)) == :follow_request
    assert request.(Bonfire.Social.Quotes.quote_verb_id()) == :quote_request

    # asking for something nothing names here: the verb is all there is to say, rather than calling it a kind of ask it isn't
    assert request.(Bonfire.Common.Types.table_id(Bonfire.Data.Social.Flag)) == :request
    assert request.(nil) == :request
  end

  test "an emoji makes it a reaction, whatever verb carried it" do
    for verb <- ["Like", "Boost"] do
      assert Activities.experienced_as(%{verb: %{verb: verb}, emoji: %{media_type: "emoji"}}) ==
               :react

      # a custom emoji names itself in its summary rather than carrying a media type
      assert Activities.experienced_as(%{verb: %{verb: verb}, emoji: %{summary: ":party:"}}) ==
               :react
    end

    # no emoji, so it is the plain verb again
    assert Activities.experienced_as(%{verb: %{verb: "Like"}, emoji: nil}) == :like
    assert Activities.experienced_as(%{verb: %{verb: "Like"}, emoji: %{summary: nil}}) == :like
  end

  test "a direct message is read from what it is, not from the feed it arrived in" do
    me = Fake.fake_user!()
    other = Fake.fake_user!()

    {:ok, message} =
      Bonfire.Messages.send(other, %{post_content: %{html_body: "just for you"}}, [id(me)])

    assert Activities.experienced_as(activity_for(message), me) == :message
  end

  test "reading a write needs the object, and says the plainer thing without it" do
    author = Fake.fake_user!()

    {:ok, post} =
      Posts.publish(
        current_user: author,
        boundary: "public",
        post_attrs: %{post_content: %{html_body: "written all the same"}}
      )

    # what a row carries when only the activity was read: an id for the object and nothing that says what kind of thing it is
    bare =
      Bonfire.Data.Social.Activity
      |> Bonfire.Common.Repo.get(uid(post.activity))
      |> Bonfire.Common.Repo.maybe_preload([:verb])

    # a preload to get right at the call site rather than a bug to fix here, since nothing but the object can say whether something was written. Every caller that renders a row has it loaded
    assert Activities.experienced_as(bare) == :create
    assert Activities.experienced_as(activity_for(post)) == :write
  end
end
