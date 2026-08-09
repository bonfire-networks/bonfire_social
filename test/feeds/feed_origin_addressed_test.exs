defmodule Bonfire.Social.Feeds.OriginAddressedTest do
  @moduledoc """
  Test the origin filter's ADDRESSED form. With both flags on (`feed_addressing` write + `feed_origin_strategy: :addressed` query), the `:local` feed must resolve to a pure `fp.feed_id IN [buckets]` probe and still return the correct posts per viewer, so authed local users see all local buckets, guests see only the public bucket. 
  """
  use Bonfire.Social.DataCase, async: true

  alias Bonfire.Social.FeedLoader
  alias Bonfire.Posts
  alias Bonfire.Me.Fake

  defp enable_addressed! do
    Process.put([:bonfire_social, Bonfire.Social.Feeds, :feed_addressing], true)
    Process.put([:bonfire_social, Bonfire.Social.Feeds, :feed_origin_strategy], :addressed)
  end

  defp publish!(author, boundary) do
    {:ok, post} =
      Posts.publish(
        current_user: author,
        post_attrs: %{post_content: %{html_body: "origin #{boundary}"}},
        boundary: boundary
      )

    post
  end

  test "addressed :local returns local public + instance posts to a local user, only public to a guest" do
    enable_addressed!()
    author = Fake.fake_user!()
    local_reader = Fake.fake_user!()

    public_post = publish!(author, "public")
    local_post = publish!(author, "local")

    # authed local user reads all local buckets (local_public + local_instance_only)
    assert FeedLoader.feed_contains?(:local, public_post, current_user: local_reader),
           "local user sees the public post via local_public bucket"

    assert FeedLoader.feed_contains?(:local, local_post, current_user: local_reader),
           "local user sees the local-boundary post via local_instance_only bucket"

    # guest reads only the public bucket → sees public, not the instance-only post
    assert FeedLoader.feed_contains?(:local, public_post),
           "guest sees the public post via local_public bucket"

    refute FeedLoader.feed_contains?(:local, local_post),
           "guest does not see the local-boundary post (not in local_public, and boundary-gated)"
  end
end
