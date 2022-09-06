defmodule Bonfire.Social.Tags do
  use Bonfire.Common.Repo
  use Arrows
  use Bonfire.Common.Utils

  alias Bonfire.Common.Config
  alias Bonfire.Tag.Tags
  alias Bonfire.Social.PostContents
  alias Bonfire.Data.Social.PostContent
  alias Ecto.Changeset

  def cast(changeset, attrs, creator, opts) do
    with true <- module_enabled?(Bonfire.Tag),
         tags when is_list(tags) and length(tags)>0 <-
          (
            e(changeset, :changes, :post_content, :changes, :mentions, []) # tag any mentions that were found in the text and injected into the changeset by PostContents (NOTE: this doesn't necessarly mean they should be included in boundaries or notified)
            ++ e(changeset, :changes, :post_content, :changes, :hashtags, []) # tag any hashtags that were found in the text and injected into the changeset by PostContents
            ++ e(attrs, :tags, [])
          )
          |> filter_empty([])
          |> uniq_by_id()
          |> debug("cast tags")
    do
      changeset
      |> Changeset.cast(%{tagged: tags_preloads(tags, opts)}, [])
      # |> debug("before cast assoc")
      |> Changeset.cast_assoc(:tagged, with: &Bonfire.Tag.Tagged.changeset/2)
    else
      _ -> changeset
    end
    # |> debug("changeset")
  end

  def maybe_process(creator, text) do
    # debug(text)
    with true <- is_binary(text) and text !="",
         true <- module_enabled?(Bonfire.Tag),
         {text, mentions, hashtags, urls} <- Bonfire.Tag.TextContent.Process.process(creator, text, editor_output_content_type(creator)) do

      {:ok, %{text: text, mentions: Keyword.values(mentions), hashtags: Keyword.values(hashtags), urls: Keyword.values(urls)}}
    else _ ->
      {:ok, %{text: text, mentions: [], hashtags: [], urls: []}}
    end
  end

  def maybe_boostable_categories(creator, categories) when is_list(categories) do
    Enum.map(categories, &maybe_boostable_categories(creator, &1)) # TODO: optimise, maybe using Bonfire.Boundaries.load_pointers ?
    |> filter_empty([])
  end

  def maybe_boostable_categories(creator, %{table_id: "2AGSCANBECATEG0RY0RHASHTAG"} = category) do
    if Bonfire.Boundaries.can?(creator, :tag, category) do
      debug(category, "boostable :-)")
      category
    else
      debug("we don't have tag permission, so category auto-boosting will be skipped")
      nil
    end
  end
  # def maybe_boostable_categories(creator, {"+"<> _name, character}) do
  #   debug(character, "boostable")
  #   character
  # end
  def maybe_boostable_categories(creator, id) when is_binary(id) do
    with {:ok, category} <- Bonfire.Common.Pointers.get(id, current_user: creator, verbs: [:tag]) do
      debug(category, "queried as boostable :-)")
      category
    else _ ->
      debug("we don't have tag permission, so auto-boosting will be skipped")
      nil
    end
  end
  def maybe_boostable_categories(_, mention) do
    debug(mention, "not a category?")
    nil
  end

  def editor_output_content_type(user) do
    Bonfire.Common.Utils.maybe_apply(Bonfire.Me.Settings.get([:ui, :rich_text_editor], nil, user), :output_format, [], &no_known_output/2)
  end

  def no_known_output(error, args) do
    warn("#{error} - don't know what editor is being used or what output format it uses (expect a module configured under [:bonfire, :ui, :rich_text_editor] which should have an output_format/0 function returning an atom (eg. :markdown, :html)")

    @default_content_type
  end

  defp tags_preloads(mentions, _preset_or_custom_boundary) do
    preload? = true # preset in ["public", "mentions"] # we want to mention local characters too if using the "local" preset
    mentions
    |> if(preload?, do: repo().maybe_preload(..., [:character]), else: ...)
  end

  def maybe_tag(creator, object, tags, mentions_are_private? \\ false) do
    if module_enabled?(Bonfire.Tag.Tags) do
      boost_category_tags = !mentions_are_private?
      Bonfire.Tag.Tags.maybe_tag(creator, object, tags, boost_category_tags)
      |> debug
      # ~> maybe_boostable_categories(creator, e(..., :tags, [])) # done in Bonfire.Tag.Tags instead
      # ~> auto_boost(..., object)
    else
      error("No tagging extension available.")
    end
  end

  def maybe_auto_boost(creator, category_or_categories, object) do
    maybe_boostable_categories(creator, category_or_categories)
    |> debug
    |> auto_boost(..., object)
  end

  def auto_boost(categories_auto_boost, object) when is_list(categories_auto_boost) do
    Enum.each(categories_auto_boost, &auto_boost(&1, object))
  end

  def auto_boost(%{} = category, object) do
    Bonfire.Social.Boosts.do_boost(category, object)

    inbox_id = e(category, :character, :notifications_id, nil)
    |> debug()

    if inbox_id, do: Bonfire.Social.FeedActivities.delete(feed_id: inbox_id, id: ulid(object)) |> debug(), else: debug("no inbox ID") # remove it from the "Submitted" tab
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
