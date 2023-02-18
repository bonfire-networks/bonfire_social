defmodule Bonfire.Social.PostContents do
  use Arrows

  alias Bonfire.Data.Social.PostContent
  import Bonfire.Common.Extend
  use Bonfire.Common.Utils
  use Bonfire.Common.Repo

  def query(filters, _opts \\ []) do
    PostContent
    |> query_filter(filters)
  end

  def one(filters, opts \\ []) do
    query(filters, opts)
    |> repo().single()
  end

  def get(id, opts \\ []) do
    if is_ulid?(id), do: one([id: id], opts)
  end

  def cast(changeset, attrs, creator, boundary, opts) do
    has_images = is_list(attrs[:uploaded_media]) and length(attrs[:uploaded_media]) > 0

    changeset
    |> repo().maybe_preload(:post_content)
    |> Changeset.cast(%{post_content: maybe_prepare_contents(attrs, creator, boundary, opts)}, [])
    |> Changeset.cast_assoc(:post_content,
      required: !has_images,
      with: &changeset/2
      # with: (if changeset.action==:upsert, do: &changeset_update/2, else: &changeset/2)
    )

    # |> debug()
  end

  def changeset(%PostContent{} = cs \\ %PostContent{}, attrs) do
    PostContent.changeset(cs, attrs)
    |> Changeset.cast(attrs, [:hashtags, :mentions, :urls])
  end

  #   defp changeset_update(%PostContent{} = cs \\ %PostContent{}, attrs) do
  #     changeset(cs, attrs)
  #     |> Map.put(:action, :update)
  #   end

  def maybe_prepare_contents(%{local: false} = attrs, creator, _boundary, opts) do
    debug("do not process remote contents or messages for tags/mentions")
    only_prepare_content(attrs, creator, opts)
  end

  def maybe_prepare_contents(attrs, creator, boundary, opts)
      when boundary in ["message"] do
    debug("do not process messages for tags/mentions")
    only_prepare_content(attrs, creator, opts)
  end

  def maybe_prepare_contents(attrs, creator, _boundary, opts) do
    if module_enabled?(Bonfire.Social.Tags, creator) do
      debug("process post contents for tags/mentions")

      # TODO: refactor this?
      with {:ok,
            %{
              text: html_body,
              mentions: mentions1,
              hashtags: hashtags1,
              urls: urls1
            }} <-
             Bonfire.Social.Tags.maybe_process(
               creator,
               prepare_text(get_attr(attrs, :html_body), creator, opts),
               opts
             ),
           {:ok, %{text: name, mentions: mentions2, hashtags: hashtags2, urls: urls2}} <-
             Bonfire.Social.Tags.maybe_process(
               creator,
               prepare_text(get_attr(attrs, :name), creator, opts),
               opts
             ),
           {:ok,
            %{
              text: summary,
              mentions: mentions3,
              hashtags: hashtags3,
              urls: urls3
            }} <-
             Bonfire.Social.Tags.maybe_process(
               creator,
               prepare_text(get_attr(attrs, :summary), creator, opts),
               opts
             ) do
        merge_with_body_or_nil(
          attrs,
          %{
            html_body: html_body,
            name: name,
            summary: summary,
            mentions: mentions1 ++ mentions2 ++ mentions3,
            hashtags: hashtags1 ++ hashtags2 ++ hashtags3,
            urls: urls1 ++ urls2 ++ urls3,
            # TODO: show languages to user, then save the one they confirm
            languages: maybe_detect_languages(attrs)
          }
        )
      end
    else
      only_prepare_content(attrs, creator, opts)
    end
  end

  def only_prepare_content(attrs, creator, opts) do
    merge_with_body_or_nil(attrs, %{
      html_body: prepare_text(get_attr(attrs, :html_body), creator, opts),
      name: prepare_text(get_attr(attrs, :name), creator, opts),
      summary: prepare_text(get_attr(attrs, :summary), creator, opts),
      languages: maybe_detect_languages(attrs),
      mentions: e(attrs, :mentions, [])
    })
  end

  def all_text_content(attrs, creator, opts) do
    "#{get_attr(attrs, :name)}\n#{get_attr(attrs, :summary)}\n#{get_attr(attrs, :html_body)}\n#{get_attr(attrs, :note)}"
  end

  def merge_with_body_or_nil(_, %{html_body: html_body})
      when is_nil(html_body) or html_body == "" do
    nil
  end

  def merge_with_body_or_nil(attrs, map) do
    Map.merge(attrs, map)
  end

  def maybe_detect_languages(attrs, fields \\ [:name, :summary, :html_body]) do
    if module_enabled?(Elixir.Text) do
      fields
      |> Enum.map(&get_attr(attrs, &1))
      |> Enum.join("\n\n")
      |> Text.text_only()
      |> String.trim()
      |> do_maybe_detect_languages()
      |> debug()
    end
  end

  defp do_maybe_detect_languages(text)
       when is_binary(text) and text != "" and byte_size(text) > 5 do
    Elixir.Text.Language.classify(text)
  end

  defp do_maybe_detect_languages(_) do
    nil
  end

  defp get_attr(attrs, key) do
    e(attrs, key, nil) || e(attrs, :post, :post_content, key, nil) ||
      e(attrs, :post_content, key, nil) || e(attrs, :post, key, nil)
  end

  def prepare_text(text, _creator, opts) when is_binary(text) and text != "" do
    # little trick to test error handling
    if String.contains?(text, "/crash!"), do: raise("User-triggered crash")

    text
    # if not using an HTML-based WYSIWYG editor, we store the raw markdown
    # |> maybe_process_markdown(creator)
    # transform emoticons to emojis
    # |> debug()
    |> Text.maybe_emote()
    # |> debug()
    # maybe remove potentially dangerous or dirty markup
    |> maybe_sane_html(e(opts, :do_not_strip_html, nil))
    # make sure we end up with valid HTML
    |> Text.maybe_normalize_html()
    |> debug()
  end

  def prepare_text("", _, _opts), do: nil
  def prepare_text(other, _, _opts), do: other

  defp maybe_sane_html(text, true), do: text

  defp maybe_sane_html(text, _) do
    text
    |> Text.maybe_sane_html()

    # |> debug()
  end

  def editor_output_content_type(user) do
    if Bonfire.Me.Settings.get(
         [:ui, :rich_text_editor_disabled],
         nil,
         user
       ) do
      :markdown
    else
      Bonfire.Common.Utils.maybe_apply(
        Bonfire.Me.Settings.get([:ui, :rich_text_editor], nil, user),
        :output_format,
        [],
        &no_known_output/2
      )
    end
  end

  def no_known_output(error, _args) do
    warn(
      "#{error} - don't know what editor is being used or what output format it uses (expect a module configured under [:bonfire, :ui, :rich_text_editor] which should have an output_format/0 function returning an atom (eg. :markdown, :html)"
    )

    :markdown
  end

  # def maybe_process_markdown(text, creator) do
  #   if editor_output_content_type(creator) == :markdown do
  #     debug("use md")
  #     Text.maybe_markdown_to_html(text)
  #   else
  #     debug("use txt or html")
  #     text
  #   end
  # end

  def indexing_object_format(%{post_content: obj}),
    do: indexing_object_format(obj)

  def indexing_object_format(%PostContent{id: _} = obj) do
    # obj = repo().maybe_preload(obj, [:icon, :image])

    # icon = Bonfire.Files.IconUploader.remote_url(obj.icon)
    # image = Bonfire.Files.ImageUploader.remote_url(obj.image)

    %{
      "index_type" => "Bonfire.Data.Social.PostContent",
      "name" => obj.name,
      "summary" => obj.summary,
      "html_body" => obj.html_body

      # "icon" => %{"url"=> icon},
      # "image" => %{"url"=> image},
    }
  end

  def indexing_object_format(_), do: nil
end
