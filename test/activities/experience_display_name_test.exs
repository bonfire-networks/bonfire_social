defmodule Bonfire.Social.ExperienceDisplayNameTest do
  @moduledoc """
  That naming a notification from what it *is* says the same thing as naming it from what it was called.

  `verb_maybe_modify/2` decides the wording from a display string, which means it decides nothing at all in another language. The unit cases live in the doctests on `experience_display_name/2`; these hold the new path to the old one's answers for activities as they are actually written, so replacing it cannot quietly change what somebody reads.
  """
  use Bonfire.DataCase, async: true
  @moduletag :backend

  import Bonfire.Posts.Fake, only: [fake_post!: 3]

  alias Bonfire.Social.Activities
  alias Bonfire.Posts
  alias Bonfire.Me.Fake

  defp activity_for(thing) do
    thing.activity
    |> Bonfire.Common.Repo.maybe_preload([
      :verb,
      :tags,
      :object,
      replied: [reply_to: [:post_content]]
    ])
  end

  # what `ActivityLive` did before the atom became the source
  defp old_name(activity),
    do: Activities.verb_maybe_modify(Activities.verb_name(activity), activity)

  defp new_name(activity, recipient \\ nil),
    do:
      Activities.experience_display_name(Activities.experienced_as(activity, recipient), activity)

  test "a plain post reads the same either way" do
    author = Fake.fake_user!()

    {:ok, post} =
      Posts.publish(
        current_user: author,
        boundary: "public",
        post_attrs: %{post_content: %{html_body: "a post"}}
      )

    activity = activity_for(post)
    assert new_name(activity) == old_name(activity)
  end

  test "a reply to a post reads the same either way" do
    me = Fake.fake_user!()
    other = Fake.fake_user!()

    mine = fake_post!(me, "public", %{post_content: %{html_body: "the first word"}})

    {:ok, answer} =
      Posts.publish(
        current_user: other,
        boundary: "public",
        post_attrs: %{
          post_content: %{html_body: "answering"},
          reply_to_id: id(mine)
        }
      )

    activity = activity_for(answer)
    assert new_name(activity, me) == old_name(activity)
  end

  test "a like reads the same either way" do
    me = Fake.fake_user!()
    other = Fake.fake_user!()

    post = fake_post!(me, "public", %{post_content: %{html_body: "likeable"}})
    {:ok, like} = Bonfire.Social.Likes.like(other, post)

    activity = activity_for(like)
    assert new_name(activity, me) == old_name(activity)
  end

  test "a direct message reads as sent, which the old path only managed with the object loaded as a struct" do
    me = Fake.fake_user!()
    other = Fake.fake_user!()

    {:ok, message} =
      Bonfire.Messages.send(other, %{post_content: %{html_body: "just for you"}}, [id(me)])

    activity = activity_for(message)

    assert new_name(activity, me) == "Send"

    # the old clause matches `%Bonfire.Data.Social.Message{}` itself, so a message read back as a pointer read as "Create"
    assert old_name(activity) == "Create"
  end

  test "a mention is the one the old path cannot see, since only a recipient makes it one" do
    me = Fake.fake_user!()
    other = Fake.fake_user!()

    {:ok, post} =
      Posts.publish(
        current_user: other,
        boundary: "public",
        post_attrs: %{post_content: %{html_body: "hey @#{me.character.username}"}}
      )

    activity = activity_for(post)

    assert Activities.experienced_as(activity, me) == :mention

    # what marks it as a mention is said by the phrase around the word, so the word still says what the thing is
    assert new_name(activity, me) == old_name(activity)
  end

  test "an ask names what was asked for, whether or not that kind of ask has a key of its own" do
    follow_edge = %{
      verb: %{verb: "Request"},
      edge: %{table_id: Bonfire.Common.Types.table_id(Bonfire.Data.Social.Follow)}
    }

    quote_edge = %{
      verb: %{verb: "Request"},
      edge: %{table_id: Bonfire.Social.Quotes.quote_verb_id()}
    }

    # named by config, since a category distinguishes these two
    assert new_name(follow_edge) == "Request to follow"
    assert new_name(quote_edge) == "Request to quote"

    # any other ask stays `:request` and is named from its edge, in the form the extractor emits
    boost_edge = %{
      verb: %{verb: "Request"},
      edge: %{table_id: Bonfire.Common.Types.table_id(Bonfire.Data.Social.Boost)}
    }

    assert Activities.experienced_as(boost_edge) == :request
    assert new_name(boost_edge) == "Request to boost"

    # and an ask whose edge says nothing is just an ask
    assert new_name(%{verb: %{verb: "Request"}}) == "Request"
  end
end
