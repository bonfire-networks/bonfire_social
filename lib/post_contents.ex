defmodule Bonfire.Social.PostContents do
  use Arrows

  alias Bonfire.Data.Social.PostContent
  import Bonfire.Common.Extend
  use Bonfire.Common.Utils
  alias Ecto.Changeset

  def cast(changeset, attrs, creator, boundary) do
    has_images = is_list(attrs[:uploaded_media]) and length(attrs[:uploaded_media])>0

    %{post_content: maybe_prepare_contents(attrs, creator, boundary)}
    |> Changeset.cast(changeset, ..., [])
    |> Changeset.cast_assoc(:post_content, required: !has_images, with: &changeset/2)
    # |> debug()
  end

  def maybe_prepare_contents(%{local: false} = attrs, creator, _boundary) do
    debug("do not process remote contents or messages for tags/mentions")
    only_prepare_content(attrs, creator)
  end

  def maybe_prepare_contents(attrs, creator, boundary) when boundary in ["message"] do
    debug("do not process messages for tags/mentions")
    only_prepare_content(attrs, creator)
  end

  def maybe_prepare_contents(attrs, creator, _boundary) do
    if module_enabled?(Bonfire.Social.Tags) do
      debug("process post contents for tags/mentions")
      # TODO: refactor this function?
      with {:ok, %{text: html_body, mentions: mentions1, hashtags: hashtags1}} <- Bonfire.Social.Tags.maybe_process(creator, prepare_text(get_attr(attrs, :html_body), creator)),
          {:ok, %{text: name, mentions: mentions2, hashtags: hashtags2}} <- Bonfire.Social.Tags.maybe_process(creator, prepare_text(get_attr(attrs, :name), creator)),
          {:ok, %{text: summary, mentions: mentions3, hashtags: hashtags3}} <- Bonfire.Social.Tags.maybe_process(creator, prepare_text(get_attr(attrs, :summary), creator)) do

        merge_with_body_or_nil(
          attrs,
          %{
            html_body: html_body,
            name: name,
            summary: summary,
            mentions: (mentions1 ++ mentions2 ++ mentions3),
            hashtags: (hashtags1 ++ hashtags2 ++ hashtags3)
        })
      end
    else
      only_prepare_content(attrs, creator)
    end
  end

  def only_prepare_content(attrs, creator) do
    merge_with_body_or_nil(attrs, %{
      html_body: prepare_text(get_attr(attrs, :html_body), creator),
      name: prepare_text(get_attr(attrs, :name), creator),
      summary: prepare_text(get_attr(attrs, :summary), creator)
    })
  end

  def merge_with_body_or_nil(_, %{html_body: html_body}) when is_nil(html_body) or html_body =="" do
    nil
  end
  def merge_with_body_or_nil(attrs, map) do
    Map.merge(attrs, map)
  end

  defp get_attr(attrs, key) do
    e(attrs, key, nil) || e(attrs, :post, :post_content, key, nil) || e(attrs, :post_content, key, nil) || e(attrs, :post, key, nil)
  end

  def prepare_text(text, creator) when is_binary(text) and text !="" do

    if String.contains?(text, "/crash!"), do: throw("User-triggered crash") # little trick to test error handling

    text
    |> maybe_process_markdown(creator) # if not using an HTML-based WYSIWYG editor, then we convert any markdown to HTML
    |> Text.maybe_emote() # transform emoticons to emojis
    |> Text.maybe_sane_html() # remove potentially dangerous or dirty markup
    |> Text.maybe_normalize_html() # make sure we end up with proper HTML
  end
  def prepare_text("", _), do: nil
  def prepare_text(other, _), do: other

  def maybe_process_markdown(text, creator) do
    if Bonfire.Me.Settings.get([:ui, :rich_text_editor_disabled], false, creator) ||  maybe_apply(Bonfire.Me.Settings.get([:ui, :rich_text_editor], nil, creator), :output_format, [], &no_known_output/2)==:markdown do
      Text.maybe_markdown_to_html(text)
    else
      text
    end
  end

  def no_known_output(error, args) do
    error("maybe_process_markdown: #{error} - don't know what editor is being used or what output format it uses (expect a module configured under [:bonfire, :ui, :rich_text_editor] which should have an output_format/0 function returning an atom (eg. :markdown, :html)")

    nil
  end

  def indexing_object_format(%{post_content: obj}), do: indexing_object_format(obj)
  def indexing_object_format(%PostContent{id: _} = obj) do

    # obj = Bonfire.Common.Repo.maybe_preload(obj, [:icon, :image])

    # icon = Bonfire.Files.IconUploader.remote_url(obj.icon)
    # image = Bonfire.Files.ImageUploader.remote_url(obj.image)

    %{
      "index_type" => "Bonfire.Data.Social.PostContent",
      "name" => obj.name,
      "summary" => obj.summary,
      "html_body" => obj.html_body,
      # "icon" => %{"url"=> icon},
      # "image" => %{"url"=> image},
   }
  end

  def indexing_object_format(_), do: nil

  def changeset(%PostContent{} = cs \\ %PostContent{}, attrs) do
    PostContent.changeset(cs, attrs)
    |> Changeset.cast(attrs, [:hashtags, :mentions])
  end

end
