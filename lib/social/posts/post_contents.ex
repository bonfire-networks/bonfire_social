defmodule Bonfire.Social.PostContents do
  use Arrows

  alias Bonfire.Data.Social.PostContent
  import Bonfire.Common.Extend
  use Bonfire.Common.Utils
  alias Ecto.Changeset

  def cast(changeset, attrs, creator, boundary) do
    %{post_content: maybe_prepare_contents(attrs, creator, boundary)}
    |> Changeset.cast(changeset, ..., [])
    |> Changeset.cast_assoc(:post_content, required: true, with: &changeset/2)
    # |> debug()
  end

  def maybe_prepare_contents(%{local: false} = attrs, _creator, _boundary) do
    debug("do not process remote contents or messages for tags/mentions")
    only_prepare_content(attrs)
  end

  def maybe_prepare_contents(attrs, _creator, boundary) when boundary in ["message"] do
    debug("do not process messages for tags/mentions")
    only_prepare_content(attrs)
  end

  def maybe_prepare_contents(attrs, creator, _boundary) do
    debug("process post contents for tags/mentions")
    # TODO: refactor this function?
    with {:ok, %{text: html_body, mentions: mentions1, hashtags: hashtags1}} <- Bonfire.Social.Tags.maybe_process(creator, prepare_text(get_attr(attrs, :html_body))),
         {:ok, %{text: name, mentions: mentions2, hashtags: hashtags2}} <- Bonfire.Social.Tags.maybe_process(creator, prepare_text(get_attr(attrs, :name))),
         {:ok, %{text: summary, mentions: mentions3, hashtags: hashtags3}} <- Bonfire.Social.Tags.maybe_process(creator, prepare_text(get_attr(attrs, :summary))) do
      attrs
      |> Map.merge(
      %{
        html_body: html_body,
        name: name,
        summary: summary,
        mentions: (mentions1 ++ mentions2 ++ mentions3),
        hashtags: (hashtags1 ++ hashtags2 ++ hashtags3)
      })
    end
  end

  def only_prepare_content(attrs) do
    Map.merge(attrs, %{
      html_body: prepare_text(get_attr(attrs, :html_body)),
      name: prepare_text(get_attr(attrs, :name)),
      summary: prepare_text(get_attr(attrs, :summary))
    })
  end

  defp get_attr(attrs, key) do
    e(attrs, key, nil) || e(attrs, :post, :post_content, key, nil) || e(attrs, :post_content, key, nil) || e(attrs, :post, key, nil)
  end

  def prepare_text(text) when is_binary(text) and text !="" do
    text
    |> Text.maybe_emote() # transform emoticons to emojis
    |> Text.maybe_sane_html() # remove potentially dangerous or dirty markup
  end
  def prepare_text(other), do: other


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
