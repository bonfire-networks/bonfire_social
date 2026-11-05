defmodule Bonfire.Social.SavedFeedBasePresetTest do
  @moduledoc """
  A custom feed saved from a feed behaves as that feed with the reader's changes on top. The saved filters hold the feed they came from as `feed_name`, and loading the saved feed by its own name keeps that base, rather than letting the saved feed's name replace it.
  """
  use Bonfire.Social.DataCase, async: true
  @moduletag :backend

  alias Bonfire.Common.Enums
  alias Bonfire.Common.Settings
  alias Bonfire.Social.FeedFilters
  alias Bonfire.Social.FeedLoader
  alias Bonfire.Social.Graph.Follows
  alias Bonfire.Posts.Fake, as: PostsFake

  setup do
    user = fake_user!("saver")
    other = fake_user!("followed")
    stranger = fake_user!("stranger")

    {:ok, _} = Follows.follow(user, other)

    %{user: user, other: other, stranger: stranger}
  end

  # puts a preset in the shape `preset_create` writes: the open feed's prepared filters (its `feed_name` included), with the reader's change, here "Replies" off as `set_filter_overrides` writes it
  defp save_preset(user, base, slug) do
    {:ok, filters} = FeedLoader.prepare_feed_filters(base, current_user: user)

    filters =
      filters
      |> Enums.nested_structs_to_maps()
      |> Map.take(FeedFilters.supported_filters())
      |> Map.update(:exclude_activity_types, [:reply], &Enum.uniq(List.wrap(&1) ++ [:reply]))

    {:ok, _} =
      Settings.put(
        [:bonfire_social, Bonfire.Social.Feeds, :feed_presets, slug],
        %{name: to_string(slug), filters: filters},
        current_user: user
      )

    # read the settings back from the database, as a page visit does: the user a settings write returns holds what it wrote as keyword lists, while stored settings load as maps
    Bonfire.Common.Repo.preload(user, :settings, force: true)
  end

  defp post!(author, text),
    do: PostsFake.fake_post!(author, "public", %{post_content: %{html_body: text}})

  # `expected` names the base's own filters besides the excluded types that the saved feed must keep, compared with the base's prepared value
  for {base, slug, expected} <- [
        {:local, :saved_from_local, [:origin]},
        {:my, :saved_from_following, []},
        {:explore, :saved_from_explore, []}
      ] do
    test "a feed saved from #{base} loads with #{base}'s feed name and filters", %{user: user} do
      base = unquote(base)
      user = save_preset(user, base, unquote(slug))

      {:ok, base_filters} = FeedLoader.prepare_feed_filters(base, current_user: user)

      assert {:ok, filters} =
               FeedLoader.prepare_feed_filters(unquote(slug), current_user: user)

      assert filters.feed_name == base

      for key <- unquote(expected) do
        assert Map.get(base_filters, key)
        assert Map.get(filters, key) == Map.get(base_filters, key)
      end

      for type <- List.wrap(base_filters.exclude_activity_types) do
        assert type in List.wrap(filters.exclude_activity_types)
      end

      assert :reply in List.wrap(filters.exclude_activity_types)
    end
  end

  test "a feed saved from Following shows the people I follow, and not a stranger", %{
    user: user,
    other: other,
    stranger: stranger
  } do
    user = save_preset(user, :my, :saved_from_following)

    followed_post = post!(other, "a post by someone I follow")
    stranger_post = post!(stranger, "a post by a stranger")

    assert FeedLoader.feed_contains?(:saved_from_following, followed_post, current_user: user)
    refute FeedLoader.feed_contains?(:saved_from_following, stranger_post, current_user: user)
  end

  test "a feed saved from Following shows someone I follow after saving", %{user: user} do
    user = save_preset(user, :my, :saved_from_following)

    later = fake_user!("followed later")
    {:ok, _} = Follows.follow(user, later)
    later_post = post!(later, "a post by someone I followed after saving")

    assert FeedLoader.feed_contains?(:saved_from_following, later_post, current_user: user)
  end

  test "a feed saved from Local shows local posts, not remote ones", %{user: user, other: other} do
    user = save_preset(user, :local, :saved_from_local)

    local_post = post!(other, "a local post")

    {remote_post, _} =
      Bonfire.Social.Fake.create_test_content(:remote, user, other)

    assert FeedLoader.feed_contains?(:saved_from_local, local_post, current_user: user)
    refute FeedLoader.feed_contains?(:saved_from_local, remote_post, current_user: user)
  end
end
