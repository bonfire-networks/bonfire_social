defmodule Bonfire.Social.PostContents do
  @moduledoc """
  Query, manipulate, and federate post contents. See also `Bonfire.Social.Posts` for directly handling posts.

  Context for `Bonfire.Data.Social.PostContent` which has the following fields:
  - name (eg. title)
  - summary (eg. description)
  - html_body (NOTE: can also contain markdown or plaintext)
  """
  use Arrows

  alias Bonfire.Data.Social.PostContent
  alias Bonfire.Social
  import Bonfire.Common.Extend
  use Bonfire.Common.Utils
  use Bonfire.Common.Repo

  # @behaviour Bonfire.Federate.ActivityPub.FederationModules
  # def federation_module,
  #   do: [
  #     {"Update", "Note"},
  #     {"Update", "Article"},
  #     {"Update", "ChatMessage"}
  #   ]

  @doc """
  Given a set of filters, returns an Ecto.Query for matching post contents.

  ## Examples

      iex> Bonfire.Social.PostContents.query(%{name: "Test Post"})
      #Ecto.Query<from p0 in Bonfire.Data.Social.PostContent, where: p0.name == ^"Test Post">
  """
  def query(filters, _opts \\ []) do
    PostContent
    |> query_filter(filters)
  end

  @doc """
  Given a set of filters, returns a single post content matching those filters.

  ## Examples

      iex> Bonfire.Social.PostContents.one(%{name: "Test Post"})
      %Bonfire.Data.Social.PostContent{name: "Test Post", ...}
  """
  def one(filters, opts \\ []) do
    query(filters, opts)
    |> repo().single()
  end

  @doc """
  Given a post content ID, returns the corresponding post content.

  ## Examples

      iex> Bonfire.Social.PostContents.get("01FXYZ123ABC")
      %Bonfire.Data.Social.PostContent{id: "01FXYZ123ABC", ...}
  """
  def get(id, opts \\ []) do
    if is_uid?(id), do: one([id: id], opts)
  end

  @doc """
  Returns the base query for post contents.

  ## Examples

      iex> Bonfire.Social.PostContents.base_query()
      #Ecto.Query<from p0 in Bonfire.Data.Social.PostContent>
  """
  def base_query do
    Needle.Pointers.query_base()
  end

  @doc """
  Performs a search query on post contents based on the given text.

  ## Examples

      iex> Bonfire.Social.PostContents.search_query("test", %{})
      #Ecto.Query<from p0 in Bonfire.Data.Social.PostContent, ...>
  """
  def search_query(text, opts) do
    (opts[:query] || base_query())
    |> proload([:post_content, :named])
    |> or_where(
      [post_content: c, named: n],
      ilike(n.name, ^"#{text}%") or
        ilike(n.name, ^"% #{text}%") or
        ilike(c.name, ^"#{text}%") or
        ilike(c.name, ^"% #{text}%") or
        ilike(c.summary, ^"#{text}%") or
        ilike(c.summary, ^"% #{text}%")
      # or
      # ilike(c.html_body, ^"#{text}%") or
      # ilike(c.html_body, ^"% #{text}%")
    )
    |> prepend_order_by([post_content: pc, named: n], [
      {:desc,
       fragment(
         "(? <% ?)::int + (? <% ?)::int + (? <% ?)::int",
         ^text,
         n.name,
         ^text,
         pc.name,
         ^text,
         pc.summary
       )}
    ])
  end

  @doc """
  Given a changeset, post content attributes, creator, boundary and options, returns a changeset prepared with relevant attributes and associations.

  ## Examples

      iex> attrs = %{name: "Test Post", html_body: "Content"}
      iex> creator = %Bonfire.Data.Identity.User{id: "01FXYZ123ABC"}
      iex> boundary = "public"
      iex> opts = []
      iex> changeset = %Ecto.Changeset{}
      iex> Bonfire.Social.PostContents.cast(changeset, attrs, creator, boundary, opts)
      #Ecto.Changeset<...>
  """
  def cast(changeset, attrs, creator, boundary, opts) do
    has_media = not is_nil(e(attrs, :uploaded_media, nil) || e(attrs, :links, nil))

    changeset
    |> repo().maybe_preload(:post_content)
    |> Changeset.cast(%{post_content: maybe_prepare_contents(attrs, creator, boundary, opts)}, [])
    |> Changeset.cast_assoc(:post_content,
      required: !has_media,
      with: &changeset/2
      # with: (if changeset.action==:upsert, do: &changeset_update/2, else: &changeset/2)
    )

    # |> debug()
  end

  @doc """
  Creates a changeset for a PostContent struct.

  ## Examples

      iex> attrs = %{name: "Test Post", html_body: "Content"}
      iex> Bonfire.Social.PostContents.changeset(%Bonfire.Data.Social.PostContent{}, attrs)
      #Ecto.Changeset<...>
  """
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

  # post from local user
  def maybe_prepare_contents(attrs, creator, _boundary, opts) do
    if module_enabled?(Bonfire.Social.Tags, creator) do
      # set input format to eg. markdown for parsing
      opts = Keyword.put_new(opts, :output_format, editor_output_content_type(creator))

      parse_and_prepare_contents(attrs, creator, opts)
    else
      only_prepare_content(attrs, creator, opts)
    end
    |> debug()
  end

  def parse_and_prepare_contents(attrs, creator, opts) do
    debug("process post contents for tags/mentions")

    do_not_strip_html? = e(opts, :do_not_strip_html, nil)
    output_format = opts[:output_format]

    # TODO: refactor this?
    with {:ok,
          %{
            text: html_body,
            mentions: mentions1,
            hashtags: hashtags1,
            urls: urls1
          }} <-
           process_local_input(
             :html_body,
             creator,
             attrs,
             do_not_strip_html?,
             output_format,
             opts
           ),
         {:ok, %{text: name, mentions: mentions2, hashtags: hashtags2, urls: urls2}} <-
           process_local_input(:name, creator, attrs, do_not_strip_html?, output_format, opts),
         {:ok,
          %{
            text: summary,
            mentions: mentions3,
            hashtags: hashtags3,
            urls: urls3
          }} <-
           process_local_input(:summary, creator, attrs, do_not_strip_html?, output_format, opts) do
      # # little easter egg to test error handling
      # if String.contains?(html_body, "/crash!"), do: raise("User-triggered crash")

      merge_with_body_or_nil(
        attrs,
        %{
          name:
            normalise_input(name, do_not_strip_html?, output_format)
            |> prepare_text(creator, opts ++ [do_not_strip_html: true]),
          summary:
            normalise_input(summary, do_not_strip_html?, output_format)
            |> prepare_text(creator, opts ++ [do_not_strip_html: true]),
          html_body:
            normalise_input(html_body, do_not_strip_html?, output_format)
            |> prepare_text(creator, opts ++ [do_not_strip_html: true]),
          mentions: e(attrs, :mentions, []) ++ mentions1 ++ mentions2 ++ mentions3,
          hashtags: e(attrs, :hashtags, []) ++ hashtags1 ++ hashtags2 ++ hashtags3,
          urls: urls1 ++ urls2 ++ urls3,
          # TODO: show languages to user, then save the one they confirm
          languages: maybe_detect_languages(attrs)
        }
      )
      |> debug("parsed and prepared contents")
    end
  end

  defp process_local_input(field, creator, attrs, do_not_strip_html?, output_format, opts) do
    Bonfire.Social.Tags.maybe_process(
      creator,
      get_attr(attrs, field),
      #  |> normalise_input(do_not_strip_html?, output_format),
      opts
    )
    |> debug("processed local input")
  end

  @doc "Given attributes of a remote post, prepares it for processing by detecting languages, and rewriting mentions, hashtags, and urls"
  defp prepare_remote_content(attrs, creator, opts) do
    # debug(creator)

    parse_remote_links? = opts[:parse_remote_links]

    mentions = e(attrs, :mentions, %{})
    hashtags = e(attrs, :hashtags, %{})

    mentions_and_hashtags = Map.merge(mentions, hashtags)
    exclude_urls = Map.keys(mentions_and_hashtags)

    with {:ok,
          %{
            html: html_body,
            urls: urls1
          }} <-
           get_attr(attrs, :html_body)
           |> process_remote_input(parse_remote_links?, mentions_and_hashtags),
         {:ok, %{html: name, urls: urls2}} <-
           get_attr(attrs, :name)
           |> process_remote_input(parse_remote_links?, mentions_and_hashtags),
         {:ok,
          %{
            html: summary,
            urls: urls3
          }} <-
           get_attr(attrs, :summary)
           |> process_remote_input(parse_remote_links?, mentions_and_hashtags) do
      urls =
        (urls1 ++ urls2 ++ urls3)
        |> debug("extracted urls")
        |> Enum.reject(fn url ->
          url in exclude_urls
        end)
        |> Enum.uniq()
        |> debug("filtered urls")

      merge_with_body_or_nil(attrs, %{
        html_body: prepare_text(html_body, creator, opts),
        name: prepare_text(name, creator, opts),
        summary: prepare_text(summary, creator, opts),
        languages: maybe_detect_languages(attrs),
        mentions: Map.values(mentions) || [],
        hashtags: Map.values(hashtags) || [],
        urls: urls || []
      })
      |> debug("prepared remote content")
    end
  end

  defp process_remote_input(input, true = _parse_remote_links?, mentions_and_hashtags) do
    input
    # first do all the other parsing
    |> do_process_remote_input(nil)
    # then when enabled, extract URLs
    |> Text.extract_urls_from_html() || {:ok, %{html: nil, urls: []}}
  end

  defp process_remote_input(input, _false, mentions_and_hashtags) do
    {:ok,
     %{
       html:
         input
         |> do_process_remote_input(mentions_and_hashtags),
       urls: []
     }}
  end

  defp do_process_remote_input(input, mentions_and_hashtags) do
    input
    |> normalise_input(false, :html)
    |> Text.replace_links(mentions_and_hashtags)

    # |> normalise_ap_links(:html)
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

  def maybe_detect_languages(_attrs, fields \\ [:name, :summary, :html_body]) do
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
    ed(attrs, key, nil) || ed(attrs, :post, :post_content, key, nil) ||
      e(attrs, :post_content, key, nil) || e(attrs, :post, key, nil)
  end

  defp normalise_input(text, do_not_strip_html? \\ false, fix_wysiwyg_input \\ false)
  defp normalise_input(nil, _, _), do: nil

  defp normalise_input(text, do_not_strip_html?, :markdown) when is_binary(text) do
    text
    # special for MD links coming from milkdown
    |> Regex.replace(~r/<(http[^>]+)>/U, ..., " \\1 ")
    |> Regex.replace(~r/@<([^>]+)>/U, ..., " @\\1 ")
    # for @user@domain.tld
    |> String.replace("\\@", "@")
    |> normalise_input(do_not_strip_html?, nil)
  end

  defp normalise_input(text, true, format) do
    text
  end

  defp normalise_input(text, _, format) do
    text
    # maybe remove potentially dangerous or dirty markup
    |> Text.maybe_sane_html()
  end

  def prepare_text(nil, _, _opts), do: nil
  def prepare_text("", _, _opts), do: nil
  # def prepare_text(text, creator, opts) when is_binary(text) do
  #   text
  #   # if not using an HTML-based WYSIWYG editor, we store the raw markdown
  #   # |> maybe_process_markdown(creator)
  #   # |> Text.normalise_ap_links(:markdown)
  #   # |> normalise_input(e(opts, :do_not_strip_html, nil))
  #   # transform emoticons to emojis
  #   |> Text.maybe_emote(creator, opts)
  #   # make sure we end up with valid HTML
  #   |> debug("prepared html")
  # end
  def prepare_text(other, creator, opts) do
    case other
         # |> debug("pre-normalise_ap_links")
         |> normalise_ap_links(opts[:output_format] || :markdown)
         # |> debug("post normalise_ap_links")
         |> Text.as_html() do
      html when is_binary(html) ->
        html
        |> Text.maybe_emote(creator, opts)

      nil ->
        nil
    end
    |> debug("prepared html")
  end

  @doc """
  Normalizes AP links in the content based on format.

  ## Examples

      > normalise_ap_links("<a href=\"/pub/actors/foo\">Actor</a>", :markdown)
      "<a href=\"/character/foo\">Actor</a>"
  """
  def normalise_ap_links(input, format)

  def normalise_ap_links(input, :html) do
    local_instance = Bonfire.Common.URIs.base_url()

    input
    |> Text.as_html_tree()
    |> LazyHTML.Tree.postwalk(fn
      {"a", attrs, children} = node ->
        case List.keyfind(attrs, "href", 0) do
          {"href", href} ->
            new_href =
              href
              |> String.replace_leading(local_instance, "")

            new_href =
              new_href
              |> String.replace_leading("/pub/actors/", "/character/")
              |> String.replace_leading("/pub/objects/", "/discussion/")

            if new_href != href do
              new_attrs = List.keyreplace(attrs, "href", 0, {"href", new_href})
              {"a", new_attrs, children}
            else
              node
            end

          nil ->
            node
        end

      node ->
        node
    end)
  end

  def normalise_ap_links(content, :markdown)
      when is_binary(content) and byte_size(content) > 20 do
    local_instance = Bonfire.Common.URIs.base_url()

    content
    # handle AP actors
    |> Regex.replace(
      md_ap_actors_regex(local_instance),
      ...,
      "\\1/character/\\2"
    )
    # handle AP objects
    |> Regex.replace(
      md_ap_objects_regex(local_instance),
      ...,
      "\\1/discussion/\\2"
    )
    # handle local links
    |> Regex.replace(
      md_local_links_regex(local_instance),
      ...,
      "\\1\\2"
    )

    # |> debug(content)
  end

  def normalise_ap_links(content, _format), do: content

  # Regex patterns for normalizing links
  defp md_ap_actors_regex(local_instance), do: ~r/(\()#{local_instance}\/pub\/actors\/(.+\))/U
  defp md_ap_objects_regex(local_instance), do: ~r/(\()#{local_instance}\/pub\/objects\/(.+\))/U
  defp md_local_links_regex(local_instance), do: ~r/(\]\()#{local_instance}(.+\))/U

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

  def versioning_enabled?(opts) do
    case opts[:versioning_enabled] do
      nil -> module_enabled?(PaperTrail, opts)
      versioning_enabled? -> versioning_enabled? && module_enabled?(PaperTrail, opts)
    end
  end

  def get_versions(post_content, opts) do
    if versioning_enabled?(opts) do
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
    else
      []
    end
  end

  def get_versions_diffed(post_content, opts) do
    for %{} = version <- get_versions(post_content, opts) do
      # TODO: make more flexble so the fields aren't hardcoded and put somewhere reusable by other objects/mixins

      prev_length =
        version.previous_version
        |> Map.take(["name", "summary", "html_body"])
        |> Map.values()
        |> Enum.join()
        |> String.length()
        |> debug("Sss")

      diffed = %{
        name:
          diff(ed(version.previous_version, :name, ""), ed(version.current_version, :name, "")),
        summary:
          diff(
            ed(version.previous_version, :summary, ""),
            ed(version.current_version, :summary, "")
          ),
        html_body:
          diff(
            ed(version.previous_version, :html_body, ""),
            ed(version.current_version, :html_body, "")
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
         changeset =
           attrs
           # TODO: apply the preparation/sanitation functions?
           |> debug()
           |> PostContent.changeset(post_content, ...),
         #  create the v1 entry if this is the first edit
         {:ok, updated_post_content} <-
           save_edit(current_user, post_content, changeset)
           |> debug() do
      post =
        Bonfire.Common.Needles.get(id(post_content),
          current_user: current_user,
          verbs: [:edit]
        )
        ~> Map.put(:post_content, updated_post_content)

      # WIP: hook to edit special types based on verb
      post = repo().maybe_preload(post, [:activity])

      if verb = e(post, :activity, :verb_id, nil) |> debug() do
        if verb_slug = Bonfire.Boundaries.Verbs.get_slug(verb) |> debug() do
          with {:ok, verb_context} <-
                 Bonfire.Common.ContextModule.context_module(verb_slug) |> debug() do
            maybe_apply(
              verb_context,
              :edit_post_content,
              [post, current_user: current_user]
            )
          end
        end
      end

      if post && Social.federate_outgoing?(current_user),
        do:
          Social.maybe_federate(
            current_user,
            :edit,
            post,
            nil
          )

      # Update search index after editing
      # Determine if content is public or not based on boundaries

      # Use the appropriate index based on content privacy
      maybe_apply(Bonfire.Search, :maybe_index, [post, nil, current_user: current_user],
        current_user: current_user
      )

      {:ok, updated_post_content || post}
      # {:ok, updated_post_content}
    end
  end

  defp save_edit(current_user, %PostContent{} = post_content, changeset) do
    if versioning_enabled?(current_user) do
      #  create the v1 entry if this is the first edit
      with :ok <-
             PaperTrail.initialise(post_content,
               user: %{id: e(post_content, :created, :creator_id, nil) || uid(current_user)}
             ),
           # update the PostContent
           {:ok, %{model: updated}} <-
             PaperTrail.update(changeset, user: current_user)
             |> debug() do
        {:ok, updated}
      end
    else
      with {:ok, updated} <-
             repo().update(changeset, user: current_user)
             |> debug() do
        {:ok, updated}
      end
    end
  end

  @doc "Prepare an outgoing ActivityPub Note object for publishing."
  def ap_prepare_object_note(subject, verb, post, actor, mentions, context, reply_to) do
    html_body = e(post, :post_content, :html_body, nil)

    hashtags =
      Bonfire.Social.Tags.list_tags_hashtags(post)
      # TODO: check why we're doing this?
      |> Bonfire.Common.Needles.list!(skip_boundary_check: true)
      #  |> repo().maybe_preload(:named)
      |> debug("include_as_hashtags")

    quoted_objects =
      Bonfire.Social.Tags.list_tags_quote(post)
      |> debug("include_as_quotes")

    %{primary_image: primary_image, images: images, links: _links} =
      Bonfire.Files.split_media_by_type(e(post, :media, nil))
      |> debug("media_splits")

    # Look up QuoteAuthorization for any quoted objects
    {primary_quote, quote_authorization} =
      case quoted_objects do
        [first_quote | _] ->
          quoted_object_ap_id = Bonfire.Common.URIs.canonical_url(first_quote)
          quote_post_ap_id = Bonfire.Common.URIs.canonical_url(post)

          # Try to find existing QuoteAuthorization
          {
            quoted_object_ap_id,
            case ActivityPub.quote_authorization(actor, quoted_object_ap_id, quote_post_ap_id) do
              {:ok, %{data: %{"type" => "QuoteAuthorization", "id" => id}}} ->
                id

              e ->
                err(e, "error looking up or creating QuoteAuthorization")
                nil
            end
          }

        [] ->
          {nil, nil}
      end
      |> debug("quote_and_QuoteAuthorization")

    %{
      "type" => "Note",
      #  "actor" => actor.ap_id,
      "attributedTo" => actor.ap_id,
      #  "to" => to,
      #  "cc" => cc,
      # TODO: put somewhere reusable by other types:
      "indexable" => Bonfire.Common.Extend.module_enabled?(Bonfire.Search.Indexer, subject),
      # TODO: put somewhere reusable by other types:
      "sensitive" => e(post, :sensitive, :is_sensitive, false),
      "name" => e(post, :post_content, :name, nil),
      "summary" => e(post, :post_content, :summary, nil),
      "content" =>
        Text.maybe_markdown_to_html(
          html_body,
          # we don't want to escape HTML in local content
          sanitize: true
        ),
      "source" => %{
        "content" => html_body,
        "mediaType" => "text/markdown"
      },
      "image" =>
        maybe_apply(Bonfire.Files, :ap_publish_activity, [primary_image], fallback_return: nil),
      "attachment" =>
        maybe_apply(Bonfire.Files, :ap_publish_activity, [images], fallback_return: nil),
      "inReplyTo" => reply_to,
      "context" => context,
      # Add Mastodon-style quote field for compatibility
      "quote" => primary_quote,
      "quoteAuthorization" => quote_authorization,
      # # Add quote objects as Link tags with proper rel value
      #     Enum.map(links, fn link ->
      #       %{
      #         "href" => e(link, :path, nil),
      #         "name" => Bonfire.Files.Media.media_label(link),
      #         "mediaType" => e(link, :metadata, "content_type", nil) || e(link, :media_type, nil),
      #         "type" => "Link"
      #       }
      #     end) ++
      "tag" =>
        Enum.map(mentions, fn actor ->
          %{
            "href" => actor.ap_id,
            "name" => actor.username,
            "type" => "Mention"
          }
        end) ++
          Enum.map(hashtags, fn tag ->
            %{
              "href" => URIs.canonical_url(tag),
              "name" => "##{e(tag, :name, nil) || e(tag, :named, :name, nil)}",
              "type" => "Hashtag"
            }
          end) ++
          Enum.map(quoted_objects, fn quoted_object ->
            %{
              "href" => Bonfire.Common.URIs.canonical_url(quoted_object),
              "type" => "Link",
              "rel" => "https://misskey-hub.net/ns#_misskey_quote",
              "mediaType" =>
                "application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\""
            }
          end)
    }
    |> Enum.filter(fn {_, v} -> not is_nil(v) end)
    |> Enum.into(%{})
  end

  # edit an existing post
  def ap_receive_activity(creator, %{data: activity_data}, object) do
    ap_receive_activity(creator, activity_data, object)
  end

  def ap_receive_activity(creator, activity_data, %{data: post_data}) do
    ap_receive_activity(creator, activity_data, post_data)
  end

  def ap_receive_attrs_prepare(creator, activity_data, post_data, direct_recipients \\ []) do
    tags =
      (List.wrap(activity_data["tag"]) ++
         List.wrap(post_data["tag"]))
      |> Enum.uniq()

    #  TODO: put somewhere reusable by other types
    hashtags =
      for %{"type" => "Hashtag", "name" => name} = tag <- tags do
        with {:ok, hashtag} <- Bonfire.Tag.get_or_create_hashtag(name) do
          {tag["href"] || name, hashtag}
        else
          none ->
            warn(none, "could not create Hashtag for #{tag["name"]}")
            nil
        end
      end
      |> filter_empty([])
      |> Map.new()

    # |> debug("incoming hashtags")

    #  TODO: put somewhere reusable by other types
    mentions =
      for %{"type" => "Mention"} = mention <- tags do
        url =
          (mention["href"] || "")
          # workaround for Mastodon using different URLs in text
          |> String.replace("/users/", "/@")

        with %{} = character <-
               e(direct_recipients, mention["href"], nil) ||
                 from_ok(
                   Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_character_by_ap_id(
                     mention["href"] || mention["name"]
                   )
                 ),
             # with {:ok, %{} = character} <-
             #        e(direct_recipients, mention["href"], nil) ||
             #          Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_character_by_ap_id(
             #            mention["href"] || mention["name"]
             #          ),
             true <- Bonfire.Social.federating?(character) do
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
      |> debug("incoming mentions")

    # Handle quote posts and regular links separately
    {quote_tags, regular_links} =
      for %{"type" => "Link", "href" => url} = tag <- tags, reduce: {[], []} do
        {quotes, links} ->
          case tag["rel"] do
            # All quote formats are now standardized as Link tags with quote-related rel values
            "https://misskey-hub.net/ns#_misskey_quote" ->
              case Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_and_create_by_uri(url) do
                {:ok, quoted_object} ->
                  debug(quoted_object, "fetched quoted object for link tag")
                  {[quoted_object | quotes], links}

                e ->
                  error(e, "could not fetch quoted object from #{url}")
                  {quotes, links}
              end

            # Regular link
            _ ->
              {quotes, [tag | links]}
          end
      end
      |> debug("separated quote tags and regular links")

    debug(
      %{
        local: false,
        canonical_url: nil,
        mentions: mentions,
        hashtags: hashtags,
        # Add quote tags here
        tags: quote_tags,
        post_content: %{
          name: post_data["name"],
          summary: post_data["summary"],
          html_body: post_data["content"]
        },
        created: %{
          date: post_data["published"]
        },
        sensitive: post_data["sensitive"],
        primary_image: e(post_data, "image", nil) || e(post_data, "icon", nil),
        attachments: List.wrap(e(post_data, "attachment", [])) ++ regular_links,
        opts: [
          emoji: e(post_data, "emoji", nil),
          do_not_strip_html: e(post_data, "source", "mediaType", nil) == "text/x.misskeymarkdown",
          parse_remote_links: regular_links == []
        ]
      },
      "remote post attrs"
    )
  end

  def ap_receive_update(
        creator,
        activity_data,
        post_data,
        pointer_id
      ) do
    attrs = ap_receive_attrs_prepare(creator, activity_data, post_data)

    with {:ok, edited} <- edit(creator, pointer_id, attrs) do
      {:ok, attrs, edited}
    end
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

  def indexing_object_format(%{name: _} = obj) do
    # obj = repo().maybe_preload(obj, [:icon, :image])

    # icon = Bonfire.Files.IconUploader.remote_url(obj.icon)
    # image = Bonfire.Files.ImageUploader.remote_url(obj.image)

    %{
      # "index_type" => Types.module_to_str(Bonfire.Data.Social.PostContent), # no need as can be inferred later by `Enums.maybe_to_structs/1`
      "name" => e(obj, :name, nil),
      "summary" => e(obj, :summary, nil),
      "html_body" => e(obj, :html_body, nil)

      # "icon" => %{"url"=> icon},
      # "image" => %{"url"=> image},
    }
  end

  def indexing_object_format(_), do: nil
end
