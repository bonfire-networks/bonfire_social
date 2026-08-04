defmodule Bonfire.Social.LivePushPayloadTest do
  @moduledoc """
  What a live-pushed `:new_activity` payload carries.

  `LivePush.push_activity/3`'s object clause builds the payload via `activity_from_object/1`, which merges the object into the activity with `maybe_merge_to_struct/2`. Both sides are structs sharing mixins (`:replied`, `:created`, `:sensitive`, `:named`), and a struct precedence is copied verbatim — `%NotLoaded{}` included — so an assoc unloaded on the object can in principle replace one loaded on the activity. This test exists to establish whether that actually reaches subscribers, or whether `prepare_activity/2`'s preloading repairs it first: the answer decides whether `Enums.maybe_merge_to_struct/3`'s shared default needs changing (see the plan's Task D) or whether the per-site fix in `activity_under_object/1` is the whole story.
  """
  use Bonfire.Social.DataCase, async: true
  use Bonfire.Common.Utils

  import Bonfire.Posts.Fake, only: [fake_post!: 3]

  alias Bonfire.Common.PubSub
  alias Bonfire.Data.Social.Post
  alias Bonfire.Data.Social.Replied
  alias Bonfire.Data.Social.Sensitive
  alias Bonfire.Posts
  alias Bonfire.Social.LivePush

  @moduletag :backend

  test "the pushed activity keeps an assoc loaded on it that is unloaded on the object" do
    me = fake_user!()
    parent = fake_post!(me, "public", %{post_content: %{html_body: "parent post"}})

    assert {:ok, reply} =
             Posts.publish(
               current_user: me,
               boundary: "public",
               post_attrs: %{
                 post_content: %{html_body: "a reply, so :replied exists"},
                 reply_to_id: id(parent)
               }
             )

    activity = Bonfire.Common.Repo.Preload.maybe_preload(reply.activity, :replied)

    # precondition: `:replied` is loaded on the activity...
    assert %Replied{} = activity.replied

    # ...and unloaded on the object, as a partially-preloaded read would hand it over
    object =
      reply
      |> Map.put(:activity, activity)
      |> Map.put(:replied, %Ecto.Association.NotLoaded{
        __field__: :replied,
        __owner__: Post,
        __cardinality__: :one
      })

    feed_id = "live_push_merge_retention_test"
    :ok = PubSub.subscribe(feed_id, current_user: me)

    LivePush.push_activity(feed_id, object)

    assert_receive {
      {Bonfire.Social.Feeds, :new_activity},
      [feed_ids: ^feed_id, activity: pushed]
    }

    assert %Replied{} = pushed.replied
  end

  test "the pushed activity keeps a loaded assoc that prepare_activity/2 does NOT re-preload" do
    # `:replied` (above) is covered by `:with_reply_to`/`:with_thread_name` in the live-push preload
    # sets, so any merge damage to it is repaired before broadcast. `:sensitive` is NOT in
    # `feed_metadata`/`feed_postload` (see `Bonfire.Social.RuntimeConfig`), so if the merge blanks it
    # nothing puts it back — and a content warning silently disappearing from a live-pushed feed item
    # is exactly the kind of quiet loss this is about.
    me = fake_user!()

    assert {:ok, post} =
             Posts.publish(
               current_user: me,
               boundary: "public",
               post_attrs: %{
                 post_content: %{html_body: "sensitive body", summary: "CW"},
                 sensitive: true
               }
             )

    activity = Bonfire.Common.Repo.Preload.maybe_preload(post.activity, :sensitive)

    # precondition: only meaningful if `:sensitive` really is loaded on the activity to begin with
    assert %Sensitive{} = activity.sensitive

    object =
      post
      |> Map.put(:activity, activity)
      |> Map.put(:sensitive, %Ecto.Association.NotLoaded{
        __field__: :sensitive,
        __owner__: Post,
        __cardinality__: :one
      })

    feed_id = "live_push_unrepaired_assoc_test"
    :ok = PubSub.subscribe(feed_id, current_user: me)

    LivePush.push_activity(feed_id, object)

    assert_receive {
      {Bonfire.Social.Feeds, :new_activity},
      [feed_ids: ^feed_id, activity: pushed]
    }

    assert %Sensitive{} = pushed.sensitive
  end
end
