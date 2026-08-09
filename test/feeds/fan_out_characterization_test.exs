defmodule Bonfire.Social.Feeds.FanOutCharacterizationTest do
  @moduledoc """
  Characterizes where the two duplicate fan-out implementations disagree, per boundary preset,BEFORE merging them. The two:

    * `Feeds.feed_ids_to_publish/4` — the Epic Act path (`acts/activity_act.ex`), fed by the epic's `assigns` (reply_to + mentions) because its changeset isn't inserted yet.
    * `Feeds.target_feeds/3` — the `FeedActivities.publish`/federation-ingest path, which extracts the same context (mentions, reply_to_creator, thread_id) from a changeset/object.

  Both funnel into the same logical decision "boundary + context → feed ids", so for a fixed scenario they SHOULD return the same feed-id set. Failures here are recorded DECISIONS for the merge (which behavior is correct), not bugs to silently paper over. 
  """
  use Bonfire.Social.DataCase, async: true
  use Bonfire.Common.Utils

  alias Bonfire.Social.Feeds
  alias Bonfire.Posts
  alias Bonfire.Me.Fake

  # the boundary presets the two impls branch on
  @boundaries ["public", "public_remote", "local", "mentions", "admins", "custom"]

  setup do
    author = Fake.fake_user!()
    other = Fake.fake_user!()

    # a root post by `other`, so the author's reply has a thread + a reply_to creator to notify.
    # NOTE: deliberately NO mention here — a mention exposes a SEPARATE divergence (the publish
    # path's `do_target_feeds` builds a heterogeneous notify list of `[reply_to_creator %User{}]`
    # ++ tag `%Pointer{}`s that trips preload-recovery, while the Act path's `assigns.mentions`
    # are `%User{}`s; recorded as a Phase-0 decision). The no-mention matrix isolates the CORE
    # per-boundary structure and still surfaces the `mentions`-boundary disagreement (that branch
    # omits thread+outbox regardless of whether a mention exists).
    {:ok, reply_target} =
      Posts.publish(
        current_user: other,
        post_attrs: %{post_content: %{html_body: "root post"}},
        boundary: "public"
      )

    {:ok, reply} =
      Posts.publish(
        current_user: author,
        post_attrs: %{
          post_content: %{html_body: "a reply"},
          reply_to_id: reply_target.id
        },
        boundary: "public"
      )

    # preload the assocs both paths read, with character.peered on the reply_to creator that the
    # notify/is_local? paths classify (else they fall into preload-recovery)
    reply_target =
      repo().preload(reply_target,
        created: [creator: [character: [:peered]]],
        replied: [:thread]
      )

    reply =
      repo().preload(reply,
        replied: [:thread, reply_to: [created: [creator: [character: [:peered]]]]]
      )

    # the Act path's `assigns`, mirroring what the epic builds for the SAME scenario (no mentions)
    assigns = %{reply_to: reply_target, mentions: []}

    %{
      author: author,
      other: other,
      reply_target: reply_target,
      reply: reply,
      assigns: assigns
    }
  end

  for boundary <- @boundaries do
    test "both fan-out impls agree for boundary #{boundary} (reply, no mention)", ctx do
      boundary = unquote(boundary)

      act_path =
        Feeds.feed_ids_to_publish(ctx.author, boundary, ctx.assigns)
        |> MapSet.new()

      publish_path =
        Feeds.target_feeds(ctx.reply, ctx.author, boundary: boundary)
        |> MapSet.new()

      assert act_path == publish_path,
             """
             fan-out mismatch for boundary #{inspect(boundary)}:
               act-only (feed_ids_to_publish adds): #{inspect(MapSet.difference(act_path, publish_path) |> MapSet.to_list())}
               publish-only (target_feeds adds):    #{inspect(MapSet.difference(publish_path, act_path) |> MapSet.to_list())}
             """
    end
  end

  # Regression for the divergence found during Phase 0a: the OLD `do_target_feeds` object-variant
  # built a heterogeneous notify list — `[reply_to_creator %User{}] ++ tag %Pointer{}s` — and fed it
  # to `feed_ids(:notifications, ...)`, which tripped preload-recovery (raised in test env). The merged
  # `fan_out_feed_ids` routes it through `reply_and_or_mentions_notifications_feeds`/`users_to_notify`,
  # which resolves per-schema, so `target_feeds(object)` with a real @mention must NOT crash and must
  # still notify the mentioned user (plan: local-remote-feeds.md Phase 0).
  test "target_feeds/3 object-variant handles a real @mention (Pointer tags) without crashing" do
    author = Fake.fake_user!()
    mentioned = Fake.fake_user!()

    {:ok, post} =
      Posts.publish(
        current_user: author,
        post_attrs: %{
          post_content: %{html_body: "hey @#{mentioned.character.username}"}
        },
        boundary: "public"
      )

    # preload the tag's character so the notify pipeline can resolve its notifications feed
    post = repo().preload(post, tags: [character: [:peered]])

    feeds = Feeds.target_feeds(post, author, boundary: "public")

    # no crash (returns a list) + the mentioned user's notifications feed is included
    assert is_list(feeds)
    assert Feeds.feed_id(:notifications, mentioned) in feeds
    # and the public instance feeds are present, without the author self-notifying
    assert Feeds.named_feed_id(:guest) in feeds
    refute Feeds.feed_id(:notifications, author) in feeds
  end
end
