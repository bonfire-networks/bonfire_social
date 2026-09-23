defmodule Bonfire.Social.NotificationCategoriesEquivalenceTest do
  @moduledoc """
  What a notification category is, read the two ways it has to be read, must agree.

  A category is defined twice, because it is read in two places that cannot share code. A feed query selects rows in SQL: `Bonfire.Social.Notifications.query_filters_for/2`, which chips apply directly and the centre's switches and both APIs reach through the `notification_categories` feed filters. A single activity is judged in memory: `Bonfire.Social.Activities.experienced_as/2` with each category's `experiences:`, which is what push, email, a row's wording and the Mastodon type go by, since fan-out decides per recipient without a query each.

  This test is what holds the two together. For each kind of notification, the category push resolves it to has to be the one category whose query selects it, and only that one. Change what a category selects, or what `experienced_as/2` answers, and this says whether the other side needs the same change.

  Each activity is found by its own id rather than with `feed_contains?/3`, which matches by object: a like and a boost of the same post share one, and would each be "found" in the other's category.
  """
  use Bonfire.Social.DataCase, async: true
  @moduletag :backend

  alias Bonfire.Social.Activities
  alias Bonfire.Social.FeedLoader
  alias Bonfire.Social.Notifications
  alias Bonfire.Social.{Likes, Boosts}
  alias Bonfire.Social.Graph.Follows
  alias Bonfire.Posts
  alias Bonfire.Me.Fake
  import Bonfire.Posts.Fake

  setup do
    Process.put([:bonfire, :default_pagination_limit], 20)

    me = Fake.fake_user!()
    other = Fake.fake_user!()
    bystander = Fake.fake_user!()

    my_post = fake_post!(me, "public", %{post_content: %{html_body: "my post"}})

    {:ok, naming_me} =
      Posts.publish(
        current_user: other,
        boundary: "public",
        post_attrs: %{post_content: %{html_body: "hey @#{me.character.username}"}}
      )

    {:ok, reply_naming_me} =
      Posts.publish(
        current_user: other,
        boundary: "public",
        post_attrs: %{
          post_content: %{html_body: "answering @#{me.character.username}"},
          reply_to_id: id(my_post)
        }
      )

    {:ok, reply_naming_somebody_else} =
      Posts.publish(
        current_user: other,
        boundary: "public",
        post_attrs: %{
          post_content: %{html_body: "answering @#{bystander.character.username}"},
          reply_to_id: id(my_post)
        }
      )

    {:ok, like} = Likes.like(other, my_post)
    {:ok, boost} = Boosts.boost(other, my_post)
    {:ok, follow} = Follows.follow(other, me)

    {:ok,
     me: me,
     kinds: %{
       post_naming_me: naming_me,
       reply_naming_me: reply_naming_me,
       reply_naming_somebody_else: reply_naming_somebody_else,
       like: like,
       boost: boost,
       follow: follow
     }}
  end

  # the in-memory side, as fan-out asks it, from an activity loaded with what `experienced_as/2` reads
  defp push_category(thing, reader) do
    thing.activity
    |> repo().maybe_preload([:verb, :replied, :tags, :object])
    |> Activities.experienced_as(reader)
    |> Notifications.category_for()
  end

  # the query side: every category with a switch whose query selects this activity
  defp query_categories(thing, reader) do
    for {key, _category} <- Notifications.categories_shown(:row),
        id(thing.activity) in activity_ids(key, reader),
        do: key
  end

  defp activity_ids(key, reader) do
    %{edges: edges} =
      FeedLoader.feed(:notifications, %{notification_categories: [key]}, current_user: reader)

    MapSet.new(edges, &(e(&1, :activity, :id, nil) || e(&1, :id, nil)))
  end

  test "every kind of notification belongs to one category, the same one both ways", %{
    me: me,
    kinds: kinds
  } do
    for {kind, thing} <- kinds do
      pushed_as = push_category(thing, me)

      assert query_categories(thing, me) == [pushed_as],
             "#{kind}: push resolves it to #{inspect(pushed_as)}, the queries select it as #{inspect(query_categories(thing, me))}"
    end
  end

  test "the two kinds of reply land on either side of the line push draws", %{
    me: me,
    kinds: kinds
  } do
    # spelled out because this is the line most likely to be moved on one side only
    assert push_category(kinds.reply_naming_me, me) == :mention
    assert push_category(kinds.reply_naming_somebody_else, me) == :extra_replies
  end

  @tag skip:
         "asks are one `:request` verb, and neither Follow requests nor Quote requests can yet ask the edge what was asked for, so both select every ask; needs a filter on the edge's table, as the `quote_request` category's TODO says"
  test "a follow ask is Follow requests alone, and a quote ask is Quote requests alone" do
    account = fake_account!()
    asked = Fake.fake_user!(account, %{}, request_before_follow: true)
    {:ok, ask} = Follows.follow(Fake.fake_user!(account), asked)

    assert query_categories(%{activity: ask}, asked) == [push_category(%{activity: ask}, asked)]
  end
end
