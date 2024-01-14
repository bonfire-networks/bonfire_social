defmodule Bonfire.Social.PostContents do
  @moduledoc """
  Query and manipulate post contents
  """
  use Arrows

  alias Bonfire.Data.Social.PostContent
  alias Bonfire.Social.Integration
  import Bonfire.Common.Extend
  use Bonfire.Common.Utils
  use Bonfire.Common.Repo

  @behaviour Bonfire.Federate.ActivityPub.FederationModules
  def federation_module,
    do: [
      {"Update", "Note"},
      {"Update", "Article"},
      {"Update", "ChatMessage"}
    ]

  @doc "Given a set of filters, returns an Ecto.Query for matching post contents."
  def query(filters, _opts \\ []) do
    PostContent
    |> query_filter(filters)
  end

  @doc "Given a set of filters, returns a single post content matching those filters"
  def one(filters, opts \\ []) do
    query(filters, opts)
    |> repo().single()
  end

  @doc "Given a post content ID, returns the corresponding post content"
  def get(id, opts \\ []) do
    if is_ulid?(id), do: one([id: id], opts)
  end

  def base_query do
    Needle.Pointers.query_base()
  end

  def search_query(text, opts) do
    (opts[:query] || base_query())
    |> proload([:post_content])
    |> or_where(
      [post_content: c],
      ilike(c.name, ^"#{text}%") or
        ilike(c.name, ^"% #{text}%") or
        ilike(c.summary, ^"#{text}%") or
        ilike(c.summary, ^"% #{text}%")
      # or
      # ilike(c.html_body, ^"#{text}%") or
      # ilike(c.html_body, ^"% #{text}%")
    )
    |> prepend_order_by([post_content: pc], [
      {:desc, fragment("(? <% ?)::int + (? <% ?)::int", ^text, pc.name, ^text, pc.summary)}
    ])
  end

  @doc "Given a changeset, post content attributes, creator, boundary and options, returns a changeset prepared with relevant attributes and associations"
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

  @doc "Given post content attributes, creator, boundary, and options, prepares the post contents for processing by detecting languages, mentions, hashtags, and urls."
  def maybe_prepare_contents(%{local: false} = attrs, creator, _boundary, opts) do
    debug("remote contents")

    prepare_remote_content(attrs, creator, opts)
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
               get_attr(attrs, :html_body)
               |> maybe_sane_html(e(opts, :do_not_strip_html, nil)),
               opts
             ),
           {:ok, %{text: name, mentions: mentions2, hashtags: hashtags2, urls: urls2}} <-
             Bonfire.Social.Tags.maybe_process(
               creator,
               get_attr(attrs, :name) |> maybe_sane_html(e(opts, :do_not_strip_html, nil)),
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
               get_attr(attrs, :summary) |> maybe_sane_html(e(opts, :do_not_strip_html, nil)),
               opts
             ) do
        merge_with_body_or_nil(
          attrs,
          %{
            name: prepare_text(name, creator, opts ++ [do_not_strip_html: true]),
            summary: prepare_text(summary, creator, opts ++ [do_not_strip_html: true]),
            html_body: prepare_text(html_body, creator, opts ++ [do_not_strip_html: true]),
            mentions: e(attrs, :mentions, []) ++ mentions1 ++ mentions2 ++ mentions3,
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
    |> debug()
  end

  @doc "Given attributes of a remote post, prepares it for processing by detecting languages, and rewriting mentions, hashtags, and urls"
  defp prepare_remote_content(attrs, creator, opts) do
    # debug(creator)
    debug(
      opts,
      "WIP: find mentions with `[...] mention` class, and hashtags with `class=\"[...] hashtag\" rel=\"tag\"` and rewrite the URLs to point to local instance OR use the `tags` AS field to know what hashtag/user URLs are likely to be found in the body and just find and replace those?"
    )

    mentions = e(attrs, :mentions, %{})
    hashtags = e(attrs, :hashtags, %{})

    merge_with_body_or_nil(attrs, %{
      html_body:
        get_attr(attrs, :html_body)
        |> rewrite_remote_links(mentions, hashtags)
        |> prepare_text(creator, opts),
      name:
        get_attr(attrs, :name)
        |> rewrite_remote_links(mentions, hashtags)
        |> prepare_text(creator, opts),
      summary:
        get_attr(attrs, :summary)
        |> rewrite_remote_links(mentions, hashtags)
        |> prepare_text(creator, opts),
      languages: maybe_detect_languages(attrs),
      mentions: Map.values(mentions) || [],
      hashtags: Map.values(hashtags) || []
    })
    |> debug()
  end

  @doc "Given post content attributes, prepares it for processing by just cleaning up the text and detecting languages."
  defp only_prepare_content(attrs, creator, opts) do
    merge_with_body_or_nil(attrs, %{
      html_body: get_attr(attrs, :html_body) |> prepare_text(creator, opts),
      name: get_attr(attrs, :name) |> prepare_text(creator, opts),
      summary: get_attr(attrs, :summary) |> prepare_text(creator, opts),
      languages: maybe_detect_languages(attrs),
      mentions: e(attrs, :mentions, [])
    })
  end

  defp rewrite_remote_links(text, mentions, hashtags)
       when is_binary(text) and (mentions != %{} or hashtags != %{}) do
    mention_urls = Map.keys(mentions |> debug)
    hashtag_urls = Map.keys(hashtags |> debug)

    text
    |> String.replace(
      mention_urls,
      &path(e(mentions, &1, nil) || ActivityPub.Actor.format_username(&1))
    )
    |> String.replace(hashtag_urls, &path(e(hashtags, &1, nil)))
  end

  defp rewrite_remote_links(text, _, _), do: text

  def all_text_content(attrs) do
    "#{get_attr(attrs, :name)}\n#{get_attr(attrs, :summary)}\n#{get_attr(attrs, :html_body)}\n#{get_attr(attrs, :note)}"
  end

  def merge_with_body_or_nil(_, %{html_body: html_body, name: nil, summary: nil})
      when is_nil(html_body) or html_body == "" do
    nil
  end

  def merge_with_body_or_nil(attrs, map) do
    Map.merge(attrs, map)
  end

  def maybe_detect_languages(attrs, fields \\ [:name, :summary, :html_body]) do
    # TODO
    # if module_enabled?(Elixir.Text.Language) do
    #   fields
    #   |> Enum.map(&get_attr(attrs, &1))
    #   |> Enum.join("\n\n")
    #   |> Text.text_only()
    #   |> String.trim()
    #   |> do_maybe_detect_languages()
    #   |> debug()
    # end
  end

  defp do_maybe_detect_languages(text)
       when is_binary(text) and text != "" and byte_size(text) > 5 do
    # FIXME: seems to crash when text contains emoji, eg. 🔥
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
    # little easter egg to test error handling
    if String.contains?(text, "/crash!"), do: raise("User-triggered crash")

    text
    # if not using an HTML-based WYSIWYG editor, we store the raw markdown
    # |> maybe_process_markdown(creator)
    # transform emoticons to emojis
    # |> debug()
    |> Text.maybe_emote(opts[:emoji])
    # |> debug()
    # |> Text.normalise_links(:markdown)
    # maybe remove potentially dangerous or dirty markup
    |> maybe_sane_html(e(opts, :do_not_strip_html, nil))
    # make sure we end up with valid HTML
    |> Text.maybe_normalize_html()
    |> debug()
  end

  def prepare_text("", _, _opts), do: nil
  def prepare_text(other, _, _opts), do: other

  defp maybe_sane_html(text, true),
    do:
      text
      |> Text.normalise_links(:markdown)

  defp maybe_sane_html(text, _) do
    text
    #  open remote links in new tab (need to do this before maybe_sane_html)
    # TODO: set format based on current editor
    |> Text.normalise_links(:markdown)
    |> Text.maybe_sane_html()
  end

  def editor_output_content_type(user) do
    if Bonfire.Common.Settings.get(
         [:ui, :rich_text_editor_disabled],
         nil,
         user
       ) do
      :markdown
    else
      Bonfire.Common.Utils.maybe_apply(
        Bonfire.Common.Settings.get([:ui, :rich_text_editor], nil, user),
        :output_format,
        [],
        fallback_fun: &no_known_output/2,
        current_user: user
      )
    end
  end

  def get_versions(post_content) do
    PaperTrail.get_versions(post_content)
    |> repo().maybe_preload(user: [:profile, :character])
    |> Enum.map_reduce(nil, fn
      current, nil ->
        current = %{
          editor: current.user,
          edited_at: current.inserted_at,
          current_version: current.item_changes,
          previous_version: %{}
        }

        {current, current}

      current, %{current_version: previous_version} ->
        current = %{
          editor: current.user,
          edited_at: current.inserted_at,
          current_version: Map.merge(previous_version, current.item_changes),
          previous_version: previous_version
        }

        {current, current}
    end)
    |> elem(0)
    |> debug("vvv")
  end

  def get_versions_diffed(post_content) do
    for %{} = version <- get_versions(post_content) do
      # TODO: make more flexble so the fields aren't hardcoded and put somewhere reusable by other objects/mixins

      prev_length =
        version.previous_version
        |> Map.take(["name", "summary", "html_body"])
        |> Map.values()
        |> Enum.join()
        |> String.length()
        |> debug("Sss")

      diffed = %{
        name: diff(e(version.previous_version, :name, ""), e(version.current_version, :name, "")),
        summary:
          diff(
            e(version.previous_version, :summary, ""),
            e(version.current_version, :summary, "")
          ),
        html_body:
          diff(
            e(version.previous_version, :html_body, ""),
            e(version.current_version, :html_body, "")
          )
      }

      diff_count = Enum.map(diffed, fn {_field, v} -> Map.get(v, :length) end) |> Enum.sum()

      Map.merge(
        %{
          diffed: diffed,
          diff_count: diff_count,
          diff_percent: if(prev_length != 0, do: diff_count / prev_length)
        },
        version
      )
      |> debug("after_diff")
    end
  end

  def diff(previous_version, current_version) do
    # KinoDiff.new(previous_version, current_version, layout: :inline)
    Exdiff.diff(previous_version, current_version, wrapper_tag: "span")
  end

  def edit(current_user, id, attrs) when is_binary(id) do
    # post_content = repo().get!(PostContent, id)
    # if Bonfire.Boundaries.can?(current_user, :edit, post_content) do
    with %PostContent{} = post_content <-
           Bonfire.Boundaries.load_pointer(id,
             verbs: [:edit],
             from: query_base(),
             current_user: current_user
           ) do
      edit(current_user, post_content, attrs)
    end
  end

  def edit(current_user, %{post_content: %PostContent{} = post_content}, attrs),
    do: edit(current_user, post_content, attrs)

  def edit(current_user, post_content, %{post_content: post_content_attrs}),
    do: edit(current_user, post_content, post_content_attrs)

  def edit(current_user, %PostContent{} = post_content, attrs) do
    # post_content = repo().get!(PostContent, id)
    # if Bonfire.Boundaries.can?(current_user, :edit, post_content) do
    with post_content <-
           post_content
           |> repo().maybe_preload(:created),
         #  create the v1 entry if this is the first edir
         :ok <-
           PaperTrail.initialise(post_content,
             user: %{id: e(post_content, :created, :creator_id, nil)}
           ),
         {:ok, %{model: updated}} <-
           attrs
           # TODO: apply the preparation/sanitation functions?
           |> debug()
           |> PostContent.changeset(post_content, ...)
           # |> debug()
           |> PaperTrail.update(user: current_user)
           |> debug do
      if Integration.federate_outgoing?(current_user),
        do:
          Bonfire.Common.Needles.get(id(post_content),
            current_user: current_user,
            verbs: [:edit]
          )
          ~> Map.put(:post_content, updated)
          |> Integration.maybe_federate(
            current_user,
            :edit,
            ...
          )

      {:ok, updated}
    end
  end

  # edit an existing post
  def ap_receive_activity(creator, %{data: activity_data}, object) do
    ap_receive_activity(creator, activity_data, object)
  end

  def ap_receive_activity(creator, activity_data, %{data: post_data}) do
    ap_receive_activity(creator, activity_data, post_data)
  end

  def ap_receive_activity(
        creator,
        %{"type" => "Update"} = activity_data,
        post_data
      ) do
    debug(activity_data, "do_an_update")

    #  with %{pointer_id: pointer_id} = _original_object when is_binary(pointer_id) <-
    #    ActivityPub.Object.get_activity_for_object_ap_id(post_data) do
    with {:ok, %{pointer_id: pointer_id} = _original_object} when is_binary(pointer_id) <-
           ActivityPub.Object.get_cached(ap_id: post_data) do
      debug(pointer_id, "original_object")

      #  TODO: update metadata too:
      #   sensitive
      #   hashtags
      #   mentions (and also notify?)
      #   media

      ap_receive_attrs_prepare(creator, activity_data, post_data)
      |> edit(creator, pointer_id, ...)
    else
      e ->
        error(e, "Could not find the object being updated.")
    end
  end

  def ap_receive_attrs_prepare(creator, activity_data, post_data, direct_recipients \\ []) do
    tags =
      (List.wrap(activity_data["tag"]) ++
         List.wrap(post_data["tag"]))
      |> Enum.uniq()

    #  TODO: put somewhere reusable by other types
    hashtags =
      for %{"type" => "Hashtag"} = tag <- tags do
        with {:ok, hashtag} <- Bonfire.Tag.Hashtag.get_or_create_by_name(tag["name"]) do
          {tag["href"], hashtag}
        else
          none ->
            warn(none, "could not create Hashtag for #{tag["name"]}")
            nil
        end
      end
      |> filter_empty([])
      |> Map.new()
      |> info("incoming hashtags")

    #  TODO: put somewhere reusable by other types
    mentions =
      for %{"type" => "Mention"} = mention <- tags do
        url =
          (mention["href"] || "")
          # workaround for Mastodon using different URLs in text
          |> String.replace("/users/", "/@")

        with %{} = character <-
               e(direct_recipients, mention["href"], nil) ||
                 ok_unwrap(
                   Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_character_by_ap_id(
                     mention["href"] || mention["name"]
                   )
                 ),
             # with {:ok, %{} = character} <-
             #        e(direct_recipients, mention["href"], nil) ||
             #          Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_character_by_ap_id(
             #            mention["href"] || mention["name"]
             #          ),
             true <- Bonfire.Social.Integration.federating?(character) do
          {
            url,
            character
          }
        else
          false ->
            info(
              mention["name"],
              "mentioned character has federation disabled, so skip them"
            )

            {
              url,
              mention["name"]
            }

          e ->
            info(
              e,
              "could not find known character for incoming mention"
            )

            {
              url,
              mention["name"]
            }
        end
      end
      |> filter_empty([])
      |> Map.new()
      |> info("incoming mentions")

    info(
      %{
        local: false,
        # huh?
        canonical_url: nil,
        mentions: mentions,
        hashtags: hashtags,
        post_content: %{
          name: post_data["name"],
          summary: post_data["summary"],
          html_body: post_data["content"]
        },
        created: %{
          date: post_data["published"]
        },
        sensitive: post_data["sensitive"],
        uploaded_media: Bonfire.Files.ap_receive_attachments(creator, post_data["attachment"])
      },
      "remote post attrs"
    )
  end

  def query_base(), do: from(p in PostContent, as: :main_object)

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
