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

  def maybe_prepare_contents(%{post_content: %{} = attrs}, creator, boundary), do: maybe_prepare_contents(attrs, creator, boundary)
  def maybe_prepare_contents(%{post: %{} = attrs}, creator, boundary), do: maybe_prepare_contents(attrs, creator, boundary)

  def maybe_prepare_contents(attrs, _creator, boundary) when boundary in ["message"] do
    debug("do not process messages for tags/mentions")
    only_prepare_content(attrs)
  end

  def maybe_prepare_contents(attrs, creator, _boundary) do
    debug("process post contents for tags/mentions")
    # TODO: process tags within the prepare_text function instead (so tags can be used in all html_body/title/summary fields at once)
    with {:ok, tags} <- Bonfire.Social.Tags.maybe_process(creator, attrs) do
      tags
      |> Map.merge(prepare_content(attrs, Utils.e(tags, :text, nil)))
      # |> debug()
    else
      _ -> prepare_content(attrs)
    end
  end

  def only_prepare_content(attrs) do
    prepare_content(e(attrs, :post, :post_content, nil) || e(attrs, :post_content, nil) || e(attrs, :post, nil) || attrs)
  end

  def prepare_content(attrs, text \\ nil)
  def prepare_content(attrs, text) when is_binary(text) and text !="" do
    # use seperate text param if provided directly
    Map.merge(attrs, %{
      html_body: prepare_text(text),
      name: prepare_text(Map.get(attrs, :name)),
      summary: prepare_text(Map.get(attrs, :summary))
    })
  end
  def prepare_content(%{summary: summary, html_body: body} = attrs, _) when (not is_binary(body) or body=="") and not (is_nil(summary) or summary=="") do
    # use summary as body if no body entered
    Map.merge(attrs, %{
      html_body: prepare_text(summary),
      summary: nil,
      name: prepare_text(Map.get(attrs, :name))
    })
  end
  def prepare_content(%{name: name, html_body: body} = attrs, _) when (not is_binary(body) or body=="") and not (is_nil(name) or name=="") do
    # use title as body if no body entered
    Map.merge(attrs, %{
      html_body: prepare_text(name),
      name: nil,
      summary: prepare_text(Map.get(attrs, :summary))
    })
  end
  def prepare_content(%{} = attrs, _) do
    Map.merge(attrs, %{
      html_body: prepare_text(Map.get(attrs, :html_body)),
      name: prepare_text(Map.get(attrs, :name)),
      summary: prepare_text(Map.get(attrs, :summary))
    })
  end
  def prepare_content(attrs, _), do: attrs

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
