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

  def maybe_boostable_categories(creator, mentions) do
    mentions
    |> Enum.map(&maybe_boostable_category(creator, &1))
    |> filter_empty([])
  end

  defp maybe_boostable_category(creator, %{table_id: "2AGSCANBECATEG0RY0RHASHTAG"} = character) do
    case Bonfire.Boundaries.load_pointer(character, current_user: creator, verbs: [:tag]) do
      %{id: _} ->
        debug(character, "boostable")
        character
      _ ->
        debug("we don't have tag permission, so category auto-boosting will be skipped")
        nil
    end
  end
  # defp maybe_boostable_category(creator, {"+"<> _name, character}) do
  #   debug(character, "boostable")
  #   character
  # end
  defp maybe_boostable_category(_, _mention) do
    # debug(mention, "skip")
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

  def maybe_tag(creator, post, tags, mentions_are_private? \\ true) do
    if module_enabled?(Bonfire.Tag.Tags),
      do: Bonfire.Tag.Tags.maybe_tag(creator, post, tags, mentions_are_private?),
    else: {:ok, post}
  end

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
