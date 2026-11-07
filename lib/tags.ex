defmodule Bonfire.Social.Tags do
  @moduledoc """
  Helpers for tagging things. Mostly wrappers around functions in `Bonfire.Tag` and `Bonfire.Classify` extensions.

  This module provides functionality for processing tags, handling categories, and auto-boosting content.
  """

  use Bonfire.Common.Repo
  use Arrows
  use Bonfire.Common.Utils

  @doc """
  Casts tags if the Bonfire.Tag module is enabled for the creator.

  ## Examples

      iex> maybe_cast(%Ecto.Changeset{}, %{tags: ["tag1", "tag2"]}, %User{}, [])
      %Ecto.Changeset{}

  """
  def maybe_cast(changeset, attrs, creator, opts) do
    with true <- module_enabled?(Bonfire.Tag, creator) do
      Bonfire.Tag.cast(changeset, attrs, creator, opts)
    else
      _ -> changeset
    end
  end

  @doc """
  Processes text to extract mentions, hashtags, and URLs if the Bonfire.Tag module is enabled.

  ## Examples

      iex> maybe_process(%User{}, "Hello @user #hashtag https://example.com", [])
      {:ok, %{text: "Hello @user #hashtag https://example.com", mentions: [], hashtags: [], urls: []}}

  """
  def maybe_process(creator, text, opts) do
    output_format =
      (opts[:output_format] || Bonfire.Social.PostContents.editor_output_content_type(creator))
      |> debug("output_format")

    debug(text, "hmmmm")

    with true <- is_binary(text) and text != "",
         true <- module_enabled?(Bonfire.Tag, creator),
         {text, mentions, hashtags, urls} <-
           Bonfire.Tag.TextContent.Process.process(
             creator,
             text,
             output_format,
             opts
           ) do
      {:ok,
       %{
         text: text,
         mentions: Keyword.values(mentions),
         hashtags: Keyword.values(hashtags),
         urls: Keyword.values(urls)
       }}
    else
      _other ->
        {:ok, %{text: text, mentions: [], hashtags: [], urls: []}}
    end
  end

  @doc """
  Filters a list of categories, returning those that are auto-boostable for a user.

  ## Examples

      iex> maybe_boostable_categories(%User{}, [%Bonfire.Classify.Category{id: "123"}])
      [%Bonfire.Classify.Category{id: "123", tree: nil}]

  """
  def maybe_boostable_categories(creator, categories) when is_list(categories) do
    Enum.map(categories, &maybe_boostable_category(creator, &1))
    |> filter_empty([])
    |> repo().maybe_preload(:tree)
  end

  def maybe_boostable_categories(creator, category) do
    maybe_boostable_category(creator, category)
    |> filter_empty([])
    |> repo().maybe_preload(:tree)
  end

  defp maybe_boostable_category(creator, %{__struct__: schema} = category)
       when schema == Bonfire.Classify.Category do
    if Bonfire.Boundaries.can?(creator, :tag, category) do
      debug(category, "boostable :-)")
      category
    else
      # warn rather than debug: this silently keeps a post out of its group, which is otherwise invisible in CI logs
      warn(
        {id(creator), id(category)},
        "no tag permission on this category, so the post is not put in it or boosted there"
      )

      nil
    end
  end

  defp maybe_boostable_category(creator, %{table_id: "2AGSCANBECATEG0RY0RHASHTAG"} = category) do
    if Bonfire.Boundaries.can?(creator, :tag, category) do
      debug(category, "boostable :-)")
      category
    else
      # warn rather than debug: this silently keeps a post out of its group, which is otherwise invisible in CI logs
      warn(
        {id(creator), id(category)},
        "no tag permission on this category, so the post is not put in it or boosted there"
      )

      nil
    end
  end

  # defp maybe_boostable_category(creator, {"+"<> _name, character}) do
  #   debug(character, "boostable")
  #   character
  # end
  defp maybe_boostable_category(creator, id) when is_binary(id) do
    # NOTE: the id may be any object (eg. replies pass the thread root as context_id), and
    # only categories can be tree parents (`category_tree.parent_id` has a strong FK), so
    # anything else must be filtered out here rather than treated as boostable
    case Bonfire.Common.Needles.get(id, current_user: creator, verbs: [:tag]) do
      {:ok, %{__struct__: schema} = category} when schema == Bonfire.Classify.Category ->
        debug(category, "queried as boostable :-)")
        category

      {:ok, %{table_id: "2AGSCANBECATEG0RY0RHASHTAG"} = category} ->
        debug(category, "queried as boostable :-)")
        category

      {:ok, other} ->
        debug(other, "context is not a category, so auto-boosting will be skipped")
        nil

      other ->
        # warn rather than debug: this silently keeps a post out of its group, which is otherwise invisible in CI logs
        warn(
          {id(creator), id, other},
          "no tag permission on this category (or it could not be loaded), so the post is not put in it or boosted there"
        )

        nil
    end
  end

  defp maybe_boostable_category(_, mention) do
    debug(mention, "not a category?")
    nil
  end

  defp tags_preloads(mentions, _preset_or_custom_boundary) do
    # preset in ["public", "mentions"] # we want to mention local characters too if using the "local" preset
    preload? = true

    mentions
    # preload `character.peered` so the "local" preset's `is_local?` filter classifies without an
    # on-demand (raising) preload
    |> if(preload?, do: repo().maybe_preload(..., character: [:peered]), else: ...)
  end

  @doc """
  Attempts to auto-boost an object to categories, based on which ones a user has permission to publish to.

  ## Examples

      iex> maybe_auto_boost(%User{}, [%Bonfire.Classify.Category{id: "123"}], %Post{id: "456"})
      :ok

  """
  def maybe_auto_boost(creator, category_or_categories, object, opts \\ []) do
    maybe_boostable_categories(creator, category_or_categories)
    |> debug()
    |> auto_boost(..., object, opts)
  end

  @doc """
  Auto-boosts an object to some categories' feed.

  ## Examples

      iex> auto_boost([%Bonfire.Classify.Category{id: "123"}], %Post{id: "456"})
      :ok

  """
  def auto_boost(categories_auto_boost, object, opts \\ [])

  def auto_boost(categories_auto_boost, object, opts) when is_list(categories_auto_boost) do
    debug(categories_auto_boost, "many")

    categories_auto_boost
    |> Enum.each(&auto_boost(&1, object, opts))
  end

  def auto_boost(%{} = category, object, opts) when is_struct(object) or is_binary(object) do
    # `prune:` since what is tagged may be a post, which has no `character`
    category =
      category
      |> repo().maybe_preload([character: [:peered]], prune: true)

    inbox_id = e(category, :character, :notifications_id, nil)

    cond do
      is_nil(inbox_id) ->
        debug(id(category), "skip boosting, because not a character")

      # a remote group relays its own posts: its `Announce` is the boost, and one we made in its name would make that real one look like a duplicate
      not Bonfire.Social.is_local?(category) ->
        if relays_to_origin?(category) do
          debug(id(category), "skip boosting, because the group is remote and boosts for itself")
        else
          put_in_mirror_feed(category, object)
        end

      true ->
        do_auto_boost(category, object, inbox_id, opts)
    end
  end

  def auto_boost(_, _, _), do: debug("not auto-boosting (invalid inputs)")

  # whether the software the group's server runs sends its `Announce` of a post back to the server the post came from. Mbin sends it to every follower but that one, so a post made here would never reach our copy of the group's feed. Asked of the server's nodeinfo, which is remembered per server (`ActivityPub.Instances.software/2`); a server whose software can't be told is taken to relay, as before
  defp relays_to_origin?(category) do
    group_software_name(category) not in Config.get(
      [__MODULE__, :software_not_relaying_to_origin],
      ["mbin"],
      name: l("Group software that doesn't relay posts back"),
      description:
        l(
          "Software (by its nodeinfo name) whose groups don't send a post back to the server it was made on, so a post made here into such a group is put in its feed here instead."
        )
    )
  end

  @doc """
  Whether a remote group announces what the users of its own server write in it. Mbin doesn't: such a post or comment goes out only as its author's `Create`, sent to the group's followers, and the group announces only what came from other servers. Asked of the server's nodeinfo, as `relays_to_origin?/1` is; a server whose software can't be told is taken to announce. Expects `character: [:peered]` loaded.
  """
  def announces_own_content?(category) do
    group_software_name(category) not in Config.get(
      [__MODULE__, :software_not_announcing_own_content],
      ["mbin"],
      name: l("Group software that doesn't announce its own users' posts"),
      description:
        l(
          "Software (by its nodeinfo name) whose groups don't announce what users of their own server post in them, so such a post is put in the group's feed here when it arrives."
        )
    )
  end

  # the software the group's server runs, by its nodeinfo name, remembered per server (`ActivityPub.Instances.software/2`), or nil
  defp group_software_name(category) do
    maybe_apply(
      ActivityPub.Instances,
      :software,
      [e(category, :character, :peered, :canonical_uri, nil)],
      fallback_return: nil
    )
    |> e(:name, nil)
  end

  @doc """
  Puts an object in our copy of a remote group's feed as it is, with no boost in the group's name (it never made one) and nothing sent out, which is what the group's `Announce` would have done had it reached us. Expects `:character` loaded.
  """
  def put_in_mirror_feed(category, object) do
    case e(category, :character, :outbox_id, nil) do
      nil ->
        debug(id(category), "no feed to put the post in")

      outbox_id ->
        Bonfire.Social.FeedActivities.put_in_feeds(
          [outbox_id],
          e(object, :activity, nil) || object
        )
    end
  end

  defp do_auto_boost(category, object, inbox_id, opts) do
    category
    |> debug("auto_boost_object to")

    Bonfire.Social.Boosts.maybe_boost(category, object, auto_boost_opts(opts))

    # remove it from the inbox ("Submitted" tab)
    Bonfire.Social.FeedActivities.delete(feed_id: inbox_id, id: uid(object)) |> debug()
  end

  defp auto_boost_opts(opts) do
    opts
    |> Keyword.delete(:auto_boost_at)
    |> Keyword.put(:notify_creator, false)
    |> maybe_put_auto_boost_pointer(opts[:auto_boost_at])
  end

  defp maybe_put_auto_boost_pointer(opts, nil), do: opts

  defp maybe_put_auto_boost_pointer(opts, auto_boost_at) do
    Keyword.put(
      opts,
      :pointer_id,
      Bonfire.Common.DatesTimes.generate_ulid_if_past(auto_boost_at)
    )
  end

  def list_tags_quote(post) do
    post = repo().maybe_preload(post, :tags)

    # a quoted tag may be an actor (mention), a hashtag, or a post: the loaded tags are MIXED concrete structs, so preload the children directly (split per schema + pruned to what each one has, via `prune: true`) rather than nested under the post: a nested `tags: [...]` descends into the mixed loaded list and raises on the first schema lacking an assoc. `character.peered` and `created.creator.character.peered` are needed so the quote-federation `is_local?` checks classify
    tags =
      e(post, :tags, [])
      |> repo().maybe_preload(
        [character: [:peered], created: [creator: [character: [:peered]]]],
        prune: true
      )

    Map.put(post, :tags, tags)
    |> tags_quote()
  end

  @doc "Keeps the quoted objects the viewer in `opts` may read, in one boundary query. A quote shows the post it quotes, so it must not show one its reader is kept out of."
  def readable_quotes([], _opts), do: []

  def readable_quotes(quoted_objects, opts) when is_list(quoted_objects) do
    readable_ids =
      Bonfire.Boundaries.load_pointers(quoted_objects,
        current_user: current_user(opts),
        verbs: [:read],
        ids_only: true
      )
      |> MapSet.new(& &1.id)

    Enum.filter(quoted_objects, &MapSet.member?(readable_ids, id(&1)))
  end

  @doc "From a mix of tags (mentions, hashtags, quoted objects), drops the quoted objects the viewer in `opts` may not read, keeping the rest in order."
  def drop_unreadable_quotes(tags, opts) when is_list(tags) do
    case Enum.filter(tags, &(tag_kind(&1) == :quote)) do
      [] ->
        tags

      quotes ->
        readable_ids = quotes |> readable_quotes(opts) |> MapSet.new(&id/1)

        Enum.reject(tags, &(tag_kind(&1) == :quote and not MapSet.member?(readable_ids, id(&1))))
    end
  end

  def tags_quote(post) do
    post
    |> e(:tags, [])
    |> debug("all tags")
    |> Enum.filter(&(tag_kind(&1) == :quote))
    |> repo().maybe_preload(:sensitive)
  end

  @doc "Partitions tags into `{quotes, hashtags}` in a single pass."
  def tags_quotes_and_hashtags(post) do
    post
    # |> repo().maybe_preload(tags: [:character])
    |> e(:tags, [])
    |> Enum.reduce({[], []}, fn tag, {quotes, hashtags} ->
      case tag_kind(tag) do
        :hashtag ->
          {quotes, [tag | hashtags]}

        :quote ->
          {[tag | quotes], hashtags}

        :mention ->
          {quotes, hashtags}
      end
    end)
    |> then(fn {quotes, hashtags} ->
      {repo().maybe_preload(quotes, [:sensitive, :post_content], prune: true),
       repo().maybe_preload(hashtags, :named)}
    end)
  end

  defp tag_kind(tag) do
    # `only_schemas: true` normalises groups/topics to `Bonfire.Classify.Category`, without it a group resolves to the `:group` and similar atoms and slips past the Category clause below.
    case Types.object_type_schema(tag) do
      Bonfire.Tag.Hashtag ->
        :hashtag

      Bonfire.Data.Identity.User ->
        :mention

      # Groups/topics are characters (audience), never quoted objects. Like the User
      # clause above, this must not depend on `:character` being preloaded: a freshly
      # live-pushed group post carries bare tags, which rendered the group as a quote card.
      Bonfire.Classify.Category ->
        :mention

      _ ->
        if is_nil(e(tag, :character, nil)), do: :quote, else: :mention
    end
  end

  def list_tags_hashtags(post) do
    post
    |> repo().maybe_preload(tags: [:character])
    |> e(:tags, [])
    |> Enum.filter(fn tag ->
      Types.object_type(tag) == Bonfire.Tag.Hashtag
      # is_nil(e(tag, :character, nil))
    end)
  end

  def list_tags_mentions(post, subject) do
    post
    |> repo().maybe_preload(tags: [:character])
    |> e(:tags, [])
    |> Enum.reject(fn tag ->
      # all characters except me
      is_nil(e(tag, :character, nil)) or id(tag) == id(subject)
    end)
  end

  def indexing_format_tags(tags) when is_list(tags) do
    if Bonfire.Common.Extend.module_enabled?(Bonfire.Tag) do
      tags
      |> Enum.map(&Bonfire.Tag.indexing_object_format_name/1)
    end
  end

  def indexing_format_tags(%{tags: tags}) when is_list(tags) do
    indexing_format_tags(tags)
  end

  def indexing_format_tags(%{activity: %{tags: _}} = object) do
    repo().maybe_preload(object, activity: [tags: [:profile]])
    |> e(:activity, :tags, [])
    |> indexing_format_tags()
  end

  def indexing_format_tags(%{tags: _} = object) do
    repo().maybe_preload(object, tags: [:profile])
    |> Map.get(:tags, [])
    |> indexing_format_tags()
  end

  def indexing_format_tags(_), do: []
end
