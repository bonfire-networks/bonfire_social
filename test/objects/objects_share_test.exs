defmodule Bonfire.Social.Objects.ShareTest do
  @moduledoc """
  The "share to a boundary/circle" business logic extracted out of the LiveView
  `handle_event("share", ...)` handler (objects_live_handler.ex) into the `Objects` context.
  The rule: only the object's own creator/caretaker may share it, and sharing re-publishes it as a
  `:boost` into the chosen boundary/circles — EXTENDING who can see it. TDD: written to lock in the
  current behavior (incl. the `caretaker` resolution branch that a share-a-circle exercises) before
  refactoring the inline creator resolution to `object_creator/1`.
  """
  use Bonfire.Social.DataCase, async: true

  alias Bonfire.Social.Objects
  alias Bonfire.Social.FeedLoader
  alias Bonfire.Posts
  alias Bonfire.Me.Fake
  alias Bonfire.Boundaries
  alias Bonfire.Boundaries.Circles

  # a "mentions"-boundary post with no @mention is author-only — a clean restricted starting point
  defp author_only_post(author) do
    {:ok, post} =
      Posts.publish(
        current_user: author,
        post_attrs: %{post_content: %{html_body: "starts restricted"}},
        boundary: "mentions"
      )

    post
  end

  test "a non-creator cannot share someone else's object" do
    author = Fake.fake_user!()
    other = Fake.fake_user!()

    post = author_only_post(author)

    assert {:error, _} = Objects.share(other, post, to_boundaries: "public")
  end

  test "sharing a nil object returns an error" do
    author = Fake.fake_user!()
    assert {:error, _} = Objects.share(author, nil, to_boundaries: "public")
  end

  test "sharing a restricted post with the \"local\" boundary makes it visible to local users (but not guests)" do
    author = Fake.fake_user!()
    local_reader = Fake.fake_user!()

    post = author_only_post(author)

    refute Boundaries.can?(local_reader, :read, post),
           "a local user can't see the author-only post before it's shared"

    refute Boundaries.can?(:guest, :read, post),
           "a guest can't read it"

    assert {:ok, _} = Objects.share(author, post, to_boundaries: "local")

    assert Boundaries.can?(local_reader, :read, post),
           "a local user can read it after it's shared to the local boundary"

    assert FeedLoader.feed_contains?(:local, post, current_user: local_reader),
           "the shared post shows up in the local feed"

    refute Boundaries.can?(:guest, :read, post),
           "a guest still can't read it (local is not public)"
  end

  test "sharing a restricted post to a specific user grants only that user access" do
    author = Fake.fake_user!()
    recipient = Fake.fake_user!()
    other = Fake.fake_user!()

    post = author_only_post(author)

    refute Boundaries.can?(recipient, :read, post),
           "the recipient can't see the author-only post before it's shared to them"

    refute Boundaries.can?(:guest, :read, post),
           "a guest can't read it"

    assert {:ok, _} =
             Objects.share(author, post, to_circles: [recipient], notify_to_circles: true)

    assert Boundaries.can?(recipient, :read, post),
           "the targeted user can read it after it's shared to them"

    assert FeedLoader.feed_contains?(:my, post, current_user: recipient),
           "the shared post shows up in the recipient's feed"

    refute Boundaries.can?(other, :read, post),
           "a different (untargeted) user still can't see it"

    refute Boundaries.can?(:guest, :read, post),
           "a guest still can't see it (sharing to a user defaults to a restrictive boundary, not public)"
  end

  # a circle owned by `author`, caretaker preloaded (as the share handler's `thing` would be). Circles
  # have a `caretaker` rather than a `created.creator`, which exercises that resolution branch.
  defp owned_circle(author) do
    {:ok, circle} = Circles.create(author, %{named: %{name: "a list to share"}})
    repo().preload(circle, caretaker: [:caretaker])
  end

  test "only the caretaker may share a circle (exercises the caretaker resolution branch)" do
    author = Fake.fake_user!()
    other = Fake.fake_user!()

    assert {:error, _} = Objects.share(other, owned_circle(author), to_boundaries: "local")
  end

  test "sharing a circle with the \"local\" boundary makes it visible to local users (but not guests)" do
    author = Fake.fake_user!()
    local_reader = Fake.fake_user!()

    circle = owned_circle(author)

    refute Boundaries.can?(local_reader, :read, circle),
           "a circle is private to its owner before being shared"

    assert {:ok, _} = Objects.share(author, circle, to_boundaries: "local")

    assert Boundaries.can?(local_reader, :read, circle),
           "a local user can see the circle after it's shared to the local boundary"

    assert FeedLoader.feed_contains?(:local, circle, current_user: local_reader),
           "the shared circle shows up in the local feed"

    refute Boundaries.can?(:guest, :read, circle),
           "a guest still can't see it (local is not public)"
  end

  test "sharing a circle to a specific user grants only that user access" do
    author = Fake.fake_user!()
    recipient = Fake.fake_user!()
    other = Fake.fake_user!()

    circle = owned_circle(author)

    refute Boundaries.can?(recipient, :read, circle),
           "the recipient can't see the circle before it's shared to them"

    assert {:ok, _} =
             Objects.share(author, circle, to_circles: [recipient], notify_to_circles: true)

    assert Boundaries.can?(recipient, :read, circle),
           "the targeted user can see the circle after it's shared to them"

    assert FeedLoader.feed_contains?(:my, circle, current_user: recipient),
           "the shared circle shows up in the recipient's feed"

    refute Boundaries.can?(other, :read, circle),
           "a different (untargeted) user still can't see it"

    refute Boundaries.can?(:guest, :read, circle),
           "a guest still can't see it (sharing to a user defaults to a restrictive boundary, not public)"
  end
end
