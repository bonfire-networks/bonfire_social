defmodule Bonfire.Social.Feeds.PresetsTest do
  @moduledoc """
  #1586 bucket-list presets — `:public` / `:local_instance_only` / `:custom_boundaries` resolve (at
  query time, via `feed_loader`'s `named_feed_ids`) to their origin×boundary buckets. With feed
  addressing on, published posts land in the buckets and the presets read exactly their slice back
  (the `refute` on non-matching content is what proves the preset resolved to the right buckets rather
  than a broad/unresolved query).
  """
  use Bonfire.Social.DataCase, async: true

  alias Bonfire.Social.FeedLoader
  alias Bonfire.Posts
  alias Bonfire.Me.Fake

  defp enable!, do: Process.put([:bonfire_social, Bonfire.Social.Feeds, :feed_addressing], true)

  defp publish!(author, boundary) do
    {:ok, post} =
      Posts.publish(
        current_user: author,
        post_attrs: %{post_content: %{html_body: "preset #{boundary}"}},
        boundary: boundary
      )

    post
  end

  test ":public shows public content (local + remote buckets), not local-instance-only content" do
    enable!()
    author = Fake.fake_user!()
    reader = Fake.fake_user!()
    public_post = publish!(author, "public")
    local_post = publish!(author, "local")

    assert FeedLoader.feed_contains?(:public, public_post, current_user: reader),
           "public feed shows the public post"

    refute FeedLoader.feed_contains?(:public, local_post, current_user: reader),
           "public feed excludes local-instance-only content"

    assert FeedLoader.feed_contains?(:public, public_post), "public feed works for guests too"
  end

  test ":local_instance_only shows local-boundary content to local users, not public content" do
    enable!()
    author = Fake.fake_user!()
    reader = Fake.fake_user!()
    local_post = publish!(author, "local")
    public_post = publish!(author, "public")

    assert FeedLoader.feed_contains?(:local_instance_only, local_post, current_user: reader),
           "instance feed shows the local-boundary post"

    refute FeedLoader.feed_contains?(:local_instance_only, public_post, current_user: reader),
           "instance feed excludes public content"
  end

  test ":custom_boundaries shows the author's custom-boundary content, not public content" do
    enable!()
    author = Fake.fake_user!()
    custom_post = publish!(author, "mentions")
    public_post = publish!(author, "public")

    assert FeedLoader.feed_contains?(:custom_boundaries, custom_post, current_user: author),
           "custom feed shows the custom-boundary post"

    refute FeedLoader.feed_contains?(:custom_boundaries, public_post, current_user: author),
           "custom feed excludes public content"
  end
end
