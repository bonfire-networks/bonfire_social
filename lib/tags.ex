defmodule Bonfire.Social.Tags do
  @moduletag "Helpers for tagging things. Mostly wrappers around functions in `Bonfire.Tag` and `Bonfire.Classify` extensions."
  use Bonfire.Common.Repo
  use Arrows
  use Bonfire.Common.Utils

  # alias Bonfire.Common.Config
  # alias Bonfire.Tag.Tags
  # alias Bonfire.Social.PostContents
  # alias Bonfire.Data.Social.PostContent
  # alias Ecto.Changeset

  def maybe_cast(changeset, attrs, creator, opts) do
    with true <- module_enabled?(Bonfire.Tag.Tags, creator) do
      Bonfire.Tag.Tags.cast(changeset, attrs, creator, opts)
    else
      _ -> changeset
    end
  end

  def maybe_process(creator, text, opts) do
    output_format =
      (opts[:output_format] || Bonfire.Social.PostContents.editor_output_content_type(creator))
      |> debug("output_format")

    debug(text, "hmmmm")

    # debug(text)
    with true <- is_binary(text) and text != "",
         true <- module_enabled?(Bonfire.Tag, creator),
         {text, mentions, hashtags, urls} <-
           Bonfire.Tag.TextContent.Process.process(
             creator,
             text,
             output_format
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

  def maybe_boostable_categories(creator, categories) when is_list(categories) do
    # TODO: optimise, maybe using Bonfire.Boundaries.load_pointers ?
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
      debug("we don't have tag permission, so category auto-boosting will be skipped")
      nil
    end
  end

  defp maybe_boostable_category(creator, %{table_id: "2AGSCANBECATEG0RY0RHASHTAG"} = category) do
    if Bonfire.Boundaries.can?(creator, :tag, category) do
      debug(category, "boostable :-)")
      category
    else
      debug("we don't have tag permission, so category auto-boosting will be skipped")
      nil
    end
  end

  # defp maybe_boostable_category(creator, {"+"<> _name, character}) do
  #   debug(character, "boostable")
  #   character
  # end
  defp maybe_boostable_category(creator, id) when is_binary(id) do
    with {:ok, category} <- Bonfire.Common.Needles.get(id, current_user: creator, verbs: [:tag]) do
      debug(category, "queried as boostable :-)")
      category
    else
      _ ->
        debug("we don't have tag permission, so auto-boosting will be skipped")
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
    |> if(preload?, do: repo().maybe_preload(..., [:character]), else: ...)
  end

  def maybe_auto_boost(creator, category_or_categories, object) do
    maybe_boostable_categories(creator, category_or_categories)
    |> debug()
    |> auto_boost(..., object)
  end

  def auto_boost(categories_auto_boost, object) when is_list(categories_auto_boost) do
    categories_auto_boost
    |> Enum.each(&auto_boost(&1, object))
  end

  def auto_boost(%{} = category, object) do
    category =
      category
      |> repo().maybe_preload(:character)

    if e(category, :character, nil) do
      # category
      # |> debug("auto_boost_object")

      Bonfire.Social.Boosts.maybe_boost(category, object, notify_creator: false)

      inbox_id =
        e(category, :character, :notifications_id, nil)
        |> debug()

      # remove it from the inbox ("Submitted" tab)
      if inbox_id,
        do: Bonfire.Social.FeedActivities.delete(feed_id: inbox_id, id: ulid(object)) |> debug(),
        else: debug("no inbox ID")
    else
      debug("skip boosting, because not a character")
    end
  end

  def auto_boost(_, _), do: debug("not auto-boosting (invalid inputs)")

  def indexing_format_tags(tags) when is_list(tags) do
    if Bonfire.Common.Extend.module_enabled?(Bonfire.Tag.Tags) do
      tags
      |> Enum.map(&Bonfire.Tag.Tags.indexing_object_format_name/1)
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
end
