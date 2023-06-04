defmodule Bonfire.Social.Tags do
  use Bonfire.Common.Repo
  use Arrows
  use Bonfire.Common.Utils

  # alias Bonfire.Common.Config
  # alias Bonfire.Tag.Tags
  alias Bonfire.Social.PostContents
  # alias Bonfire.Data.Social.PostContent
  alias Ecto.Changeset

  def cast(changeset, attrs, creator, opts) do
    with true <- module_enabled?(Bonfire.Tag, creator),
         # tag any mentions that were found in the text and injected into the changeset by PostContents (NOTE: this doesn't necessarly mean they should be included in boundaries or notified)
         # tag any hashtags that were found in the text and injected into the changeset by PostContents
         tags when is_list(tags) and length(tags) > 0 <-
           (e(changeset, :changes, :post_content, :changes, :mentions, []) ++
              e(changeset, :changes, :post_content, :changes, :hashtags, []) ++
              e(attrs, :tags, []))
           |> Enum.map(fn
             %{} = obj ->
               obj

             id when is_binary(id) ->
               %{tag_id: id}

             other ->
               warn(other, "unsupported")
               nil
           end)
           |> filter_empty([])
           |> Enums.uniq_by_id()
           #  |> tags_preloads(opts)
           |> debug("cast tags") do
      changeset
      |> Changeset.cast(%{tagged: tags}, [])
      |> debug("before cast assoc")
      |> Changeset.cast_assoc(:tagged, with: &Bonfire.Tag.Tagged.changeset/2)
    else
      _ -> changeset
    end
    |> debug("changeset with :tagged")
  end

  def maybe_process(creator, text, opts) do
    # debug(text)
    with true <- is_binary(text) and text != "",
         true <- module_enabled?(Bonfire.Tag, creator),
         {text, mentions, hashtags, urls} <-
           Bonfire.Tag.TextContent.Process.process(
             creator,
             text,
             opts[:output_format] || PostContents.editor_output_content_type(creator)
           ) do
      {:ok,
       %{
         text: text,
         mentions: Keyword.values(mentions),
         hashtags: Keyword.values(hashtags),
         urls: Keyword.values(urls)
       }}
    else
      _ ->
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
    with {:ok, category} <- Bonfire.Common.Pointers.get(id, current_user: creator, verbs: [:tag]) do
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

  def maybe_tag(creator, object, tags, mentions_are_private? \\ false) do
    if module_enabled?(Bonfire.Tag.Tags, creator) do
      boost_category_tags = !mentions_are_private?

      Bonfire.Tag.Tags.maybe_tag(creator, object, tags, boost_category_tags)
      |> debug()

      # ~> maybe_boostable_categories(creator, e(..., :tags, [])) # done in Bonfire.Tag.Tags instead
      # ~> auto_boost(..., object)
    else
      error("No tagging extension available.")
    end
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
    if e(category, :character, nil) do
      # category
      # |> debug("auto_boost_object")

      Bonfire.Social.Boosts.maybe_boost(category, object)

      inbox_id =
        e(category, :character, :notifications_id, nil)
        |> debug()

      # remove it from the inbox ("Submitted" tab)
      if inbox_id,
        do: Bonfire.Social.FeedActivities.delete(feed_id: inbox_id, id: ulid(object)) |> debug(),
        else: debug("no inbox ID")
    else
      debug("not a character")
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
