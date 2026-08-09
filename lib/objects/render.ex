defmodule Bonfire.Social.Objects.Render do
  @moduledoc """
  Renders an object (and optionally its reply tree) as markdown or HTML, for download/export and for serialising a thread into other formats (e.g. the Zenodo metadata in `bonfire_open_science`).

  Type-agnostic on purpose: everything here reads the shared `Bonfire.Data.Social.PostContent` mixin (`name`, `summary`, `html_body`) and the generic `created`/`activity` assocs, so it serialises any object carrying a post content — `Bonfire.Data.Social.Post`, `Bonfire.Articles.Article`, etc. — identically.

  Lives in `bonfire_social` (rather than a UI extension) because it is plain string serialisation with no Phoenix/LiveView involvement, so federation, the API, RSS and export paths can all reach it.
  """
  use Bonfire.Common.Utils
  alias Bonfire.Data.Social.PostContent
  alias Bonfire.Social.Threads

  @doc """
  Serialises an object as markdown, optionally with YAML frontmatter and its reply tree.

  Options:
  - `with_frontmatter`: prepend a YAML frontmatter block (title, description, uri, date, author, image). Note that `URIs.canonical_url/1` requires the object's `:peered` to be preloaded at the source.
  - `with_replies`: append the (public) reply tree, each level quoted one `>` deeper.
  """
  def to_markdown(object, opts \\ []) do
    object_to_markdown(e(object, :activity, nil), object_with_content(object), opts)
  end

  # The struct actually carrying the `PostContent`, which differs by read path: a type-specific read (e.g. `Bonfire.Posts.read/2`) returns the object itself with its activity nested under it, while reply rows loaded by `Threads.list_replies/2` carry it under `activity.object`.
  defp object_with_content(%{post_content: %PostContent{}} = object), do: object

  defp object_with_content(%{activity: %{object: %{post_content: %PostContent{}} = object}}),
    do: object

  defp object_with_content(object), do: object

  @doc "Like `to_markdown/2` but for an object and its activity already separated out."
  def object_to_markdown(activity, object, opts) do
    with_replies = opts[:with_replies]
    with_frontmatter = opts[:with_frontmatter]

    root_content =
      if with_frontmatter do
        # the title/summary are already in the frontmatter, so only the body here
        render_markdown_content(object, 0, only_body: true)
      else
        render_markdown_content(object, 0, include_author: false)
      end

    replies =
      if with_replies do
        render_replies(id(object), :markdown, include_author: true, init_level: 1)
      else
        []
      end

    content =
      ([root_content] ++ replies)
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n\n")

    if with_frontmatter do
      # TODO: tags
      """
      ---
      title: "#{e(object, :post_content, :name, nil)}"
      description: "#{e(object, :post_content, :summary, "") |> String.replace(~r/[\r\n]+/, " ") |> String.replace("\"", "'")}"
      uri: #{URIs.canonical_url(object)}
      date: #{DatesTimes.format(id(object))}
      author: "#{e(object, :created, :creator, :profile, :name, nil) || e(object, :created, :creator, :character, :username, nil)}"
      image: #{get_primary_image(e(activity, :media, []) || e(object, :media, [])) |> Media.media_url()}
      tags:

      ---

      #{content}

      """
    else
      content
    end
  end

  def get_primary_image(files) when is_list(files) do
    Enum.find(files, &is_primary_image?/1)
  end

  def get_primary_image(file) when is_map(file) do
    # Handle single file case
    if is_primary_image?(file) do
      file
    else
      nil
    end
  end

  def get_primary_image(_), do: nil

  defp is_primary_image?(%{media: %{metadata: %{"primary_image" => true}}}), do: true
  defp is_primary_image?(%{metadata: %{"primary_image" => true}}), do: true
  defp is_primary_image?(_), do: false

  @doc """
  Renders a thread's replies (or an already-loaded list of replies) as `:markdown` (each level quoted one `>` deeper) or `:html` (each level in a nested `blockquote`).
  """
  def render_replies(thread_id_or_replies, render_as \\ :html, opts \\ [])

  def render_replies(replies, render_as, opts) when is_list(replies) do
    Threads.prepare_replies_tree(replies, replies_opts(opts))
    |> debug("repliesstreee")
    |> recursive_replies(render_as, opts[:init_level] || 0)
  end

  def render_replies(thread_id, render_as, opts) when is_binary(thread_id) do
    opts = replies_opts(opts) |> Keyword.put(:thread_id, thread_id)

    case Threads.list_replies(thread_id, opts) |> debug("repliess") do
      %{edges: replies} when replies != [] ->
        replies
        |> render_replies(render_as, opts)

      _ ->
        nil
    end
  end

  defp replies_opts(opts \\ []) do
    [
      #  NOTE: we only want to include public ones
      current_user: nil,
      preload: [:with_subject, :with_post_content],
      # reading with no current_user is deliberate here, so don't `err` about the absence of a locality-marked subject_user: `:with_subject` already preloads `character: [:peered]`
      skip_err: true,
      limit: 5000,
      max_depth: 5000
      # sort_by: sort_by
    ]
    |> Keyword.merge(opts)
  end

  defp recursive_replies(replies, render_as \\ :html, level \\ 0) do
    replies
    |> Enum.map(fn {reply, child_replies} ->
      render_recursive_replies(reply, child_replies, render_as, level)
    end)
  end

  defp render_recursive_replies(reply, child_replies, render_as \\ :html, level \\ 0)

  defp render_recursive_replies(reply, child_replies, :markdown, level) do
    content = render_markdown_content(reply, level)

    children =
      child_replies
      |> Enum.map(fn {child, children} ->
        render_recursive_replies(child, children, :markdown, level + 1)
      end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    result =
      if children != "" do
        content <> "\n" <> children
      else
        content
      end

    result
    |> Text.sentence_truncate(50_000)
  end

  defp render_recursive_replies(reply, child_replies, _html, _) do
    fields = [
      {"<strong>#{e(reply, :activity, :subject, :profile, :name, nil)} (#{e(reply, :activity, :subject, :character, :username, nil)}):</strong>",
       true},
      {e(reply, :activity, :object, :post_content, :name, nil), false},
      {e(reply, :activity, :object, :post_content, :summary, nil)
       |> Text.maybe_markdown_to_html(), false},
      {e(reply, :activity, :object, :post_content, :html_body, nil)
       |> Text.maybe_markdown_to_html(), false}
    ]

    content =
      fields
      |> Enum.map(fn
        {text, true} ->
          "<p>#{text}</p>"

        {text, false} when is_binary(text) ->
          text = String.trim(text) |> debug("txxxt")
          if text not in ["", "<p> </p>"], do: "<p>#{text}</p>", else: ""

        _ ->
          ""
      end)
      |> Enum.join("")

    children =
      child_replies
      |> Enum.map(fn {child, children} -> render_recursive_replies(child, children) end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("")

    """
    <blockquote class="ml-4 border-l-1">
    #{content}
    #{children}
    </blockquote>
    """
    |> Text.sentence_truncate(50_000)
  end

  @doc """
  Renders one object's content as markdown: the author line, `## title`, `### summary` and body, each line quoted `level` deep.
  """
  def render_markdown_content(entity, level \\ 0, opts \\ []) do
    only_body = Keyword.get(opts, :only_body, false)
    include_author = Keyword.get(opts, :include_author, true)

    content = object_with_content(entity)

    {title, summary, body} = {
      e(content, :post_content, :name, nil),
      e(content, :post_content, :summary, nil),
      e(content, :post_content, :html_body, nil)
    }

    body = body |> Text.prepare_links_for_remote_render(:markdown)

    cond do
      only_body ->
        body

      include_author == false ->
        render_title_summary_body(nil, title, summary, body, level)

      true ->
        render_title_summary_body(entity, title, summary, body, level)
    end
  end

  defp render_title_summary_body(entity, title, summary, body, level) do
    author =
      e(entity, :activity, :subject, nil) || e(entity, :subject, nil) ||
        e(entity, :created, :creator, nil)

    author =
      e(author, :profile, :name, nil) ||
        e(author, :character, :username, nil)

    fields = [
      if(author, do: "**#{author}**:"),
      if(title, do: "## #{title}"),
      if(summary, do: "### #{summary}"),
      body
    ]

    content =
      fields
      |> Enum.map(fn
        text when is_binary(text) ->
          text = String.trim(text)
          if text not in ["", "<p> </p>", "<p></p>"], do: "#{text}\n", else: ""

        _ ->
          ""
      end)
      |> Enum.join("")
      |> String.trim()

    quote_prefix = String.duplicate("> ", level)

    content
    |> String.split("\n")
    |> Enum.map(&(quote_prefix <> &1))
    |> Enum.join("\n")
  end
end
